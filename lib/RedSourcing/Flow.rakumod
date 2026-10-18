use Red;
use Red::DB;
use JSON::Fast;
use Red::Type::Json;
use RedSourcing::Journal;
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
    has $.source-lookup is index{ .source-kind, .source };
    has $.target-lookup is index{ .target-kind, .target };
}
model ObservedEntity is table<red_sourcing_flow_entity> {
    has UInt $.id is serial;
    has Str $.stream is column is required;
    has Str $.type is column is required;
    has Str $.kind is column is required;
    has Json $.identity is column is required;
    has $.stream-lookup is index{ .stream };
}
my %enabled;
my Lock $lock .= new;

sub retire-legacy-indexes(Mu:U $model, %legacy) {
    my $driver = get-RED-DB;
    my $namespace = '';
    if $driver.^mro.first(*.^name eq 'Red::Driver::Pg').defined {
        # Resolve the table's schema, not the index's search-path visibility.
        # An unrelated index with the same name can exist in an earlier schema.
        $namespace = $driver.execute(q:to/SQL/, $model.^table).row<namespace> ~ '.';
            SELECT quote_ident(n.nspname) AS namespace
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.oid = to_regclass($1)
            SQL
    }
    for $driver.indexes-for-table($model.^table) -> %index {
        next unless %legacy{%index<name>}:exists;
        my @expected = %legacy{%index<name>}.list.map({
            $driver.index-key-fingerprint($driver.table-name-wrapper($_))
        });
        next if %index<unique> || (%index<partial> // False) || !(%index<valid> // True);
        next unless %index<keys>.map({ $driver.index-key-fingerprint($_) }).List eqv @expected.List;
        $driver.execute('DROP INDEX ' ~ $namespace ~ $driver.table-name-wrapper(%index<name>));
    }
}

sub flow-tracing-enabled(--> Bool) is export {
    # Pg begins a transaction with a driver clone. Preserve the caller's recording
    # scope across the library's transaction boundary.
    my $scope = try $*REDSOURCING-FLOW-SCOPE;
    return $scope if $scope.defined;
    my $db = try get-RED-DB;
    return False unless $db.defined;
    $lock.protect({ so %enabled{journal-store()} })
}
sub enable-flow-tracing(Bool :$enabled = True, Bool :$initialize = True) is export {
    Link.^create-table(:unless-exists) if $enabled && $initialize;
    ObservedEntity.^create-table(:unless-exists) if $enabled && $initialize;
    if $enabled && $initialize {
        .^create-indexes for Link, ObservedEntity;
        # The replacements exist before any legacy index is removed. Only
        # retire our known, nonunique definitions; leave conflicting names alone.
        retire-legacy-indexes(Link, {
            rs_flow_source => <source_kind source>, rs_flow_target => <target_kind target>
        });
        retire-legacy-indexes(ObservedEntity, { rs_flow_entity_stream => <stream> });
    }
    $lock.protect({ %enabled{journal-store()} = $enabled });
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
