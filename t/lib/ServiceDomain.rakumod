unit module ServiceDomain;
use RedSourcing;
our $LOCK = Lock.new;
our %CONTEXTS;
our %STOPS;
our $STARTS = 0;
our $RELEASE = Promise.new;
class ServiceMessage does Event is export { has Str $.room-id; has Str $.text }
aggregate ServiceRoom[:!auto-snapshot] is export {
    has Str $.room-id is entity-id;
    has @.messages;
    method APPLY(ServiceMessage $event) { @!messages.push($event.text) }
    method record-message(Str :$text!) is command { self.service-message(:$text); @!messages.elems }
    method record-and-touch(Str :$text!) is command {
        my $id = $*COMMAND.service-context<service-id>;
        my $ctx = $LOCK.protect({ %CONTEXTS{$id} });
        $ctx.touch;
        self.service-message(:$text);
        @!messages.elems
    }
    method serve(ServiceContext $context, Str :$mode = 'normal') is service {
        start {
            $LOCK.protect({ $STARTS++; %CONTEXTS{$context.service-id} = $context });
            $context.on-stop({ $LOCK.protect({ %STOPS{$context.service-id}++ }) });
            die 'fixture service failed' if $mode eq 'broken';
            if $mode eq 'cleanup-failure' { $context.on-stop({ die 'cleanup failed' }) }
            if $mode eq 'direct-write' { self.record-message(:text<forbidden>) }
            $context.ready unless $mode eq 'unready';
            if $mode eq 'stubborn' { await $RELEASE }
            else { await $context.stopping unless $mode eq 'complete' }
        }
    }
}
aggregate ServiceChild is ServiceRoom is export { }
