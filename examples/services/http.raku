#!/usr/bin/env raku
use RedSourcing;
use RedSourcing::Service;
use Cro::HTTP::Router;

class HTTPMessageRecorded does Event { has Str $.room-id; has Str $.text }
aggregate HTTPRoom[:!auto-snapshot] {
    has Str $.room-id is entity-id;
    has @.messages;
    method APPLY(HTTPMessageRecorded $event) { @!messages.push($event.text) }
    method record-message(Str :$text!) is command {
        self.http-message-recorded(:$text);
        @!messages.elems
    }
    method serve(ServiceContext $runtime, Str :$host!, Int :$port!) is service {
        $runtime.http: :$host, :$port, {
            get -> {
                $runtime.touch;
                content 'application/json', %(service => 'HTTPRoom', endpoints => ['GET /messages', 'POST /messages {"text":"Hello"}']);
            }
            get -> 'messages' {
                $runtime.touch;
                my $state = $runtime.state;
                content 'application/json', %(room => $state.room-id, messages => $state.messages.Array);
            }
            post -> 'messages' {
                request-body -> %body {
                    if %body<text> ~~ Str && %body<text>.chars {
                        $runtime.touch;
                        my $count = $runtime.aggregate.record-message(:text(%body<text>));
                        response.status = 201;
                        content 'application/json', %(count => $count);
                    } else {
                        response.status = 400;
                        content 'application/json', %(error => 'Provide a nonempty text string');
                    }
                }
            }
        }
    }
}

sub MAIN(Str :$host = '127.0.0.1', Int :$port = 3080) {
    my $file = $*TMPDIR.add('redsourcing-http-' ~ $*PID ~ '.db');
    LEAVE $file.unlink if $file.e;
    red-sourcing-defaults(:driver<SQLite>, :database($file.Str), :!flow-tracing);
    my $runtime = ServiceRuntime.new(:poll-interval(.05)).initialize;
    LEAVE $runtime.shutdown;
    my $room = HTTPRoom.^with-ids(:room-id<general>);
    $room.^create;
    $room.^start-service('serve', :args(%(:$host, :$port)), :idle-timeout(3600));
    my $controller = $runtime.run;
    my $deadline = now + 30;
    until $room.^service-status('serve')<phase> eq 'active' {
        die 'HTTP service did not become ready: ' ~ $room.^service-status('serve').raku if now > $deadline;
        await Promise.in(.05);
    }
    say "Room HTTP: http://{$host}:{$port}/messages";
    say 'Press Ctrl+C to stop. Idle timeout: 1 hour. Database: ' ~ $file;
    $*OUT.flush;
    react {
        whenever signal(SIGINT) { done }
        whenever signal(SIGTERM) { done }
    }
    $room.^stop-service('serve');
    $runtime.shutdown;
    await $controller;
}
