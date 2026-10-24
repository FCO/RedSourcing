unit module RedSourcing::Service::Context;
use RedSourcing::Context;

class ServiceProxy {
    has $.context is required;
    has $.proxy is required;
    method FALLBACK(Str $method, |args) {
        die "Not an aggregate command: $method"
            unless $!proxy.^entity-type.^commands{$method}:exists;
        $!context.executor.context-command($!context, $method, args)
    }
}

class ServiceContext is export {
    has $.executor is required;
    has $.proxy is required;
    has Str $.service-id is required;
    has Str $.owner is required;
    has UInt $.generation is required;
    has Promise $.stopping .= new;
    has Promise $.readiness .= new;
    has Promise $.cleanup .= new;
    has Str $.late-cleanup-error = '';
    has Lock $!lock .= new;
    has @!callbacks;
    has Bool $!stopped = False;
    has Bool $!ready = False;
    method fence { %(service-id => $!service-id, owner => $!owner, generation => $!generation) }
    method aggregate {
        die 'Use ServiceContext.command to target an aggregate from a projection service'
            if $!proxy.^entity-type.HOW.^mro.grep(*.^name eq 'Metamodel::RedSourcing::ProjectionHOW').elems;
        ServiceProxy.new(:context(self), :proxy($!proxy))
    }
    method command($target, Str $method, |arguments) {
        die 'command submission is forbidden in QUERY' if ((try $*REDSOURCING-PHASE) // '') eq 'QUERY';
        $!executor.context-command(self, $method, arguments, :$target)
    }
    method read($target, Str :$method, Hash :$arguments = {}) {
        $!executor.context-state(self, :$target, :$method, :$arguments)
    }
    method state { $!executor.context-state(self) }
    method bind(&callback --> Callable) {
        my $context = self;
        -> |arguments {
            my $phase = (try CALLERS::<$*REDSOURCING-PHASE>) // '';
            my $*REDSOURCING-SERVICE-CONTEXT = $context;
            my $*REDSOURCING-PHASE = $phase eq any('QUERY', 'APPLY', 'REACT', 'SERVICE-READ') ?? $phase !! 'SERVICE';
            callback(|arguments)
        }
    }
    method ready {
        assert-effect-allowed('service readiness');
        my $first = $!lock.protect({
            die 'Service is stopping' if $!stopped;
            return False if $!ready;
            $!ready = True;
            True
        });
        if $first {
            CATCH { default { $!lock.protect({ $!ready = False }); .rethrow } }
            $!executor.context-report(self, 'ready');
            $!readiness.keep(True);
        }
        True
    }
    # Keep Cro loading optional for applications that do not start HTTP services.
    method http($application, Str :$host = '127.0.0.1', Int :$port = 3000 --> Promise) {
        assert-effect-allowed('HTTP service startup');
        die 'HTTP port must be between 1 and 65535' unless 1 <= $port <= 65535;
        start {
            require ::('RedSourcing::Web::Server');
            my $routes = $application;
            if $application ~~ Callable {
                require ::('Cro::HTTP::Router');
                $routes = ::('Cro::HTTP::Router::EXPORT::DEFAULT::&route')($application);
            }
            my $readiness = Promise.new;
            my $server = ::('RedSourcing::Web::Server::EXPORT::DEFAULT::&web-server')(:$host, :$port, :application($routes), :$readiness, :scope(self.bind(-> &work { work() })));
            my $lock = Lock.new;
            my Bool $closed = False;
            sub close-server {
                $lock.protect({
                    unless $closed {
                        $closed = True;
                        $server.stop;
                    }
                });
            }
            # Also close on startup/readiness failure, before the saga retries.
            LEAVE close-server() if $server.defined && $lock.defined;
            $server.start;
            self.on-stop({ close-server() });
            await Promise.anyof($readiness, self.stopping);
            await $readiness unless self.stopping.status == Kept;
            self.ready;
            await self.stopping;
        }
    }
    method touch { assert-effect-allowed('service activity'); $!executor.context-report(self, 'touch') }
    method on-stop(&callback) {
        assert-effect-allowed('service cleanup registration');
        my &bound = self.bind(&callback);
        my $run = $!lock.protect({
            if $!stopped { True } else { @!callbacks.push(&bound); False }
        });
        if $run {
            CATCH { default { $!late-cleanup-error = .message; .rethrow } }
            my $result = bound();
            await $result if $result ~~ Promise;
        }
        self
    }
    method request-stop {
        assert-effect-allowed('service stop');
        my @callbacks = $!lock.protect({
            return () if $!stopped;
            $!stopped = True;
            $!stopping.keep(True);
            $!readiness.break(X::AdHoc.new(payload => 'Service stopped before readiness'))
                if $!readiness.status == Planned;
            @!callbacks.splice(0).List
        });
        # Callbacks can use the context; never run them under the context lock.
        start {
            my $*REDSOURCING-PHASE = 'SERVICE';
            CATCH { default { $!cleanup.break($_) } }
            for @callbacks -> &callback {
                my $result = callback();
                await $result if $result ~~ Promise;
            }
            $!cleanup.keep(True);
        }
    }
}
