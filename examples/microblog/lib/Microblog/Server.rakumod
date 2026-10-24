use RedSourcing;
use Microblog::Domain;
use Cro::HTTP::Router;
use JSON::Fast;
unit module Microblog::Server;

our $SUBSCRIBERS = 0;
our $SUBSCRIBER-LOCK = Lock.new;

projection MicroblogServer is export {
    has Str $.application-id is entity-id;
    has Str $.server-id is entity-id;
    method APPLY(UserRegistered $e where { .application-id eq $!application-id }) { }
    method serve(ServiceContext $runtime, Str :$host = '127.0.0.1', Int :$port = 3090,
            Str :$assets!) is service {
        my $application = $!application-id;
        sub user(Str $id) { User.^with-ids(:application-id($application), :user-id($id)) }
        sub timeline(Str $id) { UserTimeline.^with-ids(:application-id($application), :user-id($id)) }
        sub exists(Str $id) {
            die 'User does not exist' unless $runtime.read(Directory.^with-ids(:application-id($application))).users{$id}:exists;
        }
        sub page(Str $id, Bool :$profile = False, Int :$before = 0, Int :$limit = 50) {
            exists($id);
            my $proxy = $profile
                ?? UserTweets.^with-ids(:application-id($application), :user-id($id)) !! timeline($id);
            $runtime.read($proxy, :method<page>, :arguments(%(:$before, :$limit)))
        }
        sub json(&action, Int :$status = 200) {
            CATCH {
                default {
                    response.status = .message.contains('does not exist') ?? 404 !! 400;
                    content 'application/json', %(error => .message);
                }
            }
            $runtime.touch;
            my $result = action();
            response.status = $status;
            content 'application/json', $result;
        }
        $runtime.http(:$host, :$port, {
            after { header 'Cache-Control', 'no-store'; header 'X-Content-Type-Options', 'nosniff' }
            get -> { static $assets.IO, 'index.html' }
            get -> 'assets', Str $file where * eq any(<app.css app.js>) { static $assets.IO, $file }
            get -> 'api', 'users' {
                json { $runtime.read(Directory.^with-ids(:application-id($application)), :method<list>) }
            }
            post -> 'api', 'users' {
                request-body -> %body {
                    json :status(201), {
                        die 'Provide string id and name' unless %body<id> ~~ Str && %body<name> ~~ Str;
                        $runtime.command(Accounts.^with-ids(:application-id($application)), 'register-user',
                            :user-id(%body<id>), :name(%body<name>))
                    }
                }
            }
            get -> 'api', 'users', Str $id {
                json {
                    exists($id);
                    my $state = $runtime.read(user($id));
                    %(id => $id, name => $state.name,
                        following => $runtime.read(timeline($id), :method<follows>))
                }
            }
            get -> 'api', 'users', Str $id, 'tweets', Int :$before = 0, Int :$limit = 50 {
                json { page($id, :profile, :$before, :$limit) }
            }
            post -> 'api', 'users', Str $id, 'tweets' {
                request-body -> %body {
                    json :status(201), {
                        exists($id);
                        die 'Provide a text string' unless %body<text> ~~ Str;
                        $runtime.command(user($id), 'tweet', :text(%body<text>))
                    }
                }
            }
            get -> 'api', 'users', Str $id, 'timeline', Int :$before = 0, Int :$limit = 50 {
                json { page($id, :$before, :$limit) }
            }
            post -> 'api', 'users', Str $id, 'following', Str $author {
                json { exists($id); exists($author); $runtime.command(user($id), 'follow', :author-id($author)); %(ok => True) }
            }
            delete -> 'api', 'users', Str $id, 'following', Str $author {
                json { exists($id); exists($author); $runtime.command(user($id), 'unfollow', :author-id($author)); %(ok => True) }
            }
            get -> 'api', 'users', Str $id, 'events' {
                CATCH { default { response.status = 404; content 'application/json', %(error => .message) } }
                exists($id);
                $runtime.touch;
                header 'X-Accel-Buffering', 'no';
                content 'text/event-stream', supply {
                    $SUBSCRIBER-LOCK.protect({ $SUBSCRIBERS++ });
                    CLOSE { $SUBSCRIBER-LOCK.protect({ $SUBSCRIBERS-- }) }
                    my $previous;
                    my $ticks = 0;
                    sub update {
                        my $payload = %(page => page($id),
                            following => $runtime.read(timeline($id), :method<follows>));
                        unless $previous.defined && $payload eqv $previous {
                            $previous = $payload;
                            my $data = to-json($payload, :!pretty);
                            emit "event: timeline\ndata: $data\n\n".encode('utf-8');
                        }
                    }
                    update();
                    whenever Supply.interval(1) {
                        update();
                        $ticks++;
                        emit ": heartbeat\n\n".encode('utf-8') if $ticks %% 15;
                        $runtime.touch if $ticks %% 30;
                    }
                }
            }
        })
    }
}
