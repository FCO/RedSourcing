use Red::DB;
use RedSourcing::Journal;
unit module RedSourcing::Flow;

# Enablement controls the optional read model, never recording on the write path.
my %enabled;
my Lock $lock .= new;
sub flow-tracing-enabled(--> Bool) is export {
    return False unless (try get-RED-DB).defined;
    $lock.protect({ so %enabled{journal-store()} })
}
sub enable-flow-tracing(Bool :$enabled = True, Bool :$initialize = True) is export {
    $lock.protect({ %enabled{journal-store()} = $enabled });
    $enabled
}

# Durable causality is stored with the source records, independently of whether
# the optional flow projection is enabled.
sub emission-causality(--> Hash) is export {
    my $command = try $*COMMAND;
    my $action = (try $*REDSOURCING-ACTION) // ($command.defined ?? $command.action-id !! Str);
    my %metadata;
    %metadata<command-id> = $command.id if $command.defined;
    %metadata<action-id> = $action.Str if $action.defined;
    %metadata
}
sub command-causality(--> Hash) is export {
    my %metadata = emission-causality();
    %metadata<parent-command-id> = %metadata<command-id>:delete if %metadata<command-id>:exists;
    %metadata
}

# Each read starts from the complete visible journal. There is no persistent
# global cursor that could skip a late commit with a lower serial ID.
sub flow-projection() is export {
    require ::('RedSourcing::Flow::Projection');
    my $view = ::('RedSourcing::Flow::Projection::FlowProjection').^restore-state(Nil, :stream<red-sourcing-flow>);
    $view.^replay;
    require ::('RedSourcing::StoredCommand');
    $view.include-command($_) for ::('RedSourcing::StoredCommand').^all.sort(*.id).Seq;
    $view
}
sub observed-flow-entities(--> Array) is export { [] }
sub flow-revision(--> Str) is export {
    require ::('RedSourcing::StoredEvent');
    require ::('RedSourcing::StoredCommand');
    # Counts also change when an earlier allocated ID commits after a later ID.
    my $events = try ::('RedSourcing::StoredEvent').^all.elems;
    my $commands = try ::('RedSourcing::StoredCommand').^all.elems;
    ($events // 0) ~ ':' ~ ($commands // 0)
}
sub flow-links(Str :$source-kind, Str :$source, Str :$target-kind, Str :$target, UInt :$limit = 500) is export {
    my $view = (try $*REDSOURCING-FLOW-PROJECTION) // flow-projection();
    $view.find-links(:$source-kind, :$source, :$target-kind, :$target, :$limit)
}
