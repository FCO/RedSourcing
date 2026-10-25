#!/usr/bin/env raku
use RedSourcing;
use RedSourcing::Service;

# Ephemeral transport: no WebSocket implementation or socket is persisted.
my $incoming = Supplier.new;
class MessageRecorded does Event { has Str $.room-id; has Str $.text }
aggregate Room[:!auto-snapshot] {
    has Str $.room-id is entity-id;
    has @.messages is query;
    method APPLY(MessageRecorded $event) { @!messages.push: $event.text }
    method record-message(Str :$text!) is command {
        self.message-recorded: :$text;
        @!messages.elems
    }
    method serve(ServiceContext $runtime) is service {
        start {
            my $room = $runtime.proxy;
            my $id = $room.room-id;
            my &receive = $runtime.bind: -> %message {
                $runtime.touch;
                $room.record-message: :text(%message<text>);
            };
            my $subscription = $incoming.Supply.grep(*.<room> eq $id).tap: &receive;
            $runtime.on-stop: { $subscription.close };
            $runtime.ready;
            await $runtime.stopping;
        }
    }
}

my $file = $*TMPDIR.add: 'redsourcing-room-' ~ $*PID ~ '-' ~ (2**63).rand.Int ~ '.db';
LEAVE $file.unlink if $file.e;
red-sourcing-defaults(:driver<SQLite>, :database($file.Str), :!flow-tracing);
my $runtime = ServiceRuntime.new(:poll-interval(.05), :stop-grace(1)).initialize;
LEAVE $runtime.shutdown;
my $room = Room.^with-ids: :room-id<general>; $room.^create;
$room.^start-service: 'serve';
my $controller = $runtime.run;
sub wait-phase(Str $phase) {
    my $deadline = now + 10;
    until $room.^service-status('serve')<phase> eq $phase {
        die "Room did not reach $phase" if now > $deadline;
        await Promise.in: .01;
    }
}
wait-phase('active');
$incoming.emit: %(room => 'general', text => 'Hello');
$incoming.emit: %(room => 'general', text => 'Portable state');
$room.^stop-service: 'serve';
wait-phase('stopped');
$runtime.shutdown;
await $controller;
say 'Messages: ' ~ $room.messages.join: ', ';
say 'Service: ' ~ $room.^service-status('serve')<phase>;
