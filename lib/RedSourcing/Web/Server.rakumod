use Cro::HTTP::Server;
use Cro::TCP;
use Cro::TCP::NoDelay;
unit module RedSourcing::Web::Server;

# Cro's TCP sink waits for an infinite response body after the read side ends.
# Bound each response pipeline to the lifetime of its connection instead. This
# also cancels the SSE subscriptions/keepalive timers when a tab navigates away.
my class LiveReplier is Cro::TCP::Replier {
    has $!socket;
    has Promise $!disconnected;
    submethod BUILD(:$!socket!, :$!disconnected!) { }
    method sinker(Supply:D $pipeline --> Supply:D) {
        supply {
            whenever $!disconnected { done }
            whenever $pipeline -> $message {
                whenever $!socket.write($message.data) {
                    # Only write failures end the connection here. Exceptions
                    # from routing or the response body still propagate to Cro.
                    QUIT { default { done } }
                }
            }
            CLOSE { try $!socket.close }
        }
    }
}
my class LiveConnection is Cro::TCP::ServerConnection {
    has $!socket;
    has Promise $!disconnected .= new;
    submethod BUILD(:$!socket!) { }
    method replier { LiveReplier.new(:$!socket, :$!disconnected) }
    method incoming {
        my $incoming = callsame;
        supply {
            whenever $incoming -> $message {
                emit $message;
                QUIT {
                    default {
                        .rethrow unless .message.lc.contains('connection reset by peer');
                        done;
                    }
                }
            }
            CLOSE { try $!disconnected.keep(True) }
        }
    }
}
my class LiveListener is Cro::TCP::Listener {
    method incoming {
        supply {
            whenever IO::Socket::Async.listen($.host, $.port) -> $socket {
                nodelay($socket) if $.nodelay;
                emit LiveConnection.new(:$socket);
            }
        }
    }
}

# Local HTTP server with disconnect-aware streaming; the Cro HTTP routing and
# serialization pipeline is unchanged. TLS servers need their own listener.
sub web-server(:$host = '127.0.0.1', :$port = 3000, :$application!) is export {
    my $server = Cro::HTTP::Server.new(:$host, :$port, :$application);
    $server.components[0] = LiveListener.new(:$host, :$port, :nodelay);
    $server
}

