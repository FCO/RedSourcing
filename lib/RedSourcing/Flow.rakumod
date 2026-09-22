use Red;
use Red::DB;
use JSON::Fast;
use Red::Type::Json;
unit module RedSourcing::Flow;

# Independent telemetry: domain event payloads and existing tables stay unchanged.
model Link is table<red_sourcing_flow_link> {
    has UInt $.id is serial;
    has Str $.source-kind is column is required;
    has Str $.source is column is required;
    has Str $.target-kind is column is required;
    has Str $.target is column is required;
    has Str $.relation is column is required;
    has DateTime $.created is column .= now;
}
model ObservedEntity is table<red_sourcing_flow_entity> {
    has UInt $.id is serial;
    has Str $.stream is column is required;
    has Str $.type is column is required;
    has Str $.kind is column is required;
    has Json $.identity is column is required;
}
my %enabled;
my Lock $lock .= new;
sub flow-tracing-enabled(--> Bool) is export {
    # Pg begins a transaction with a driver clone. Preserve the caller's recording
    # scope across the library's transaction boundary.
    my $scope = try $*REDSOURCING-FLOW-SCOPE;
    return $scope if $scope.defined;
    my $db = try get-RED-DB;
    return False unless $db.defined;
    $lock.protect({ so %enabled{$db.WHICH.Str} })
}
sub enable-flow-tracing(Bool :$enabled = True, Bool :$initialize = True) is export {
    Link.^create-table(:unless-exists) if $enabled && $initialize;
    ObservedEntity.^create-table(:unless-exists) if $enabled && $initialize;
    if $enabled && $initialize {
        get-RED-DB.execute('CREATE INDEX IF NOT EXISTS rs_flow_source ON red_sourcing_flow_link (source_kind, source)');
        get-RED-DB.execute('CREATE INDEX IF NOT EXISTS rs_flow_target ON red_sourcing_flow_link (target_kind, target)');
        get-RED-DB.execute('CREATE INDEX IF NOT EXISTS rs_flow_entity_stream ON red_sourcing_flow_entity (stream)');
    }
    $lock.protect({ %enabled{get-RED-DB.WHICH.Str} = $enabled });
    $enabled
}
sub observe-flow-entity($entity, Str $kind) is export {
    return unless flow-tracing-enabled;
    my $stream = $entity.^stream;
    return if ObservedEntity.^all.grep(*.stream eq $stream).head;
    ObservedEntity.^create(:$stream, :type($entity.^name), :$kind,
        :identity($entity.^entity-id-map.Hash));
}
sub observed-flow-entities(--> Array) is export {
    my $result = try ObservedEntity.^all.head(1000).Seq.map({
        %(stream => .stream, type => .type, kind => .kind, identity => from-json(to-json(.identity)))
    }).Array;
    $result // []
}
sub flow-revision(--> Str) is export {
    my $id = try Link.^all.sort(-*.id).head.id;
    ($id // 0).Str
}
sub flow-link(Str $source-kind, Str $source, Str $target-kind, Str $target, Str $relation) is export {
    return unless flow-tracing-enabled;
    # Replaying the same event does not grow an unbounded list of identical links.
    return if Link.^all.grep({ .source-kind eq $source-kind && .source eq $source
        && .target-kind eq $target-kind && .target eq $target && .relation eq $relation }).head;
    Link.^create(:$source-kind, :$source, :$target-kind, :$target, :$relation);
}
sub trace-emission($row) is export {
    return unless flow-tracing-enabled;
    my $command = try $*COMMAND;
    my $action = try $*REDSOURCING-ACTION;
    if $command.defined { flow-link('command', $command.id.Str, 'event', $row.id.Str, 'emitted') }
    elsif $action.defined { flow-link('action', $action.Str, 'event', $row.id.Str, 'emitted') }
    flow-link('entity', $row.stream, 'event', $row.id.Str,
        $row.mro.contains('|Entity|') ?? 'checkpoint' !! 'published');
}

# Read-only: the monitor may inspect this table without enabling instrumentation.
sub flow-links(Str :$source-kind, Str :$source, Str :$target-kind, Str :$target, UInt :$limit = 500) is export {
    my $rows = Link.^all;
    $rows = $rows.grep(*.source-kind eq $source-kind) with $source-kind;
    $rows = $rows.grep(*.source eq $source) with $source;
    $rows = $rows.grep(*.target-kind eq $target-kind) with $target-kind;
    $rows = $rows.grep(*.target eq $target) with $target;
    $rows.sort(-*.id).head($limit).Seq.map({
        %(source-kind => .source-kind, source => .source, target-kind => .target-kind,
            target => .target, relation => .relation, recorded-at => .created.Str)
    }).Array
}
