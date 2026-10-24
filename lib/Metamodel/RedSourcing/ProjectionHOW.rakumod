unit class Metamodel::RedSourcing::ProjectionHOW;
use Metamodel::RedSourcing::EntityHOW;
use Red;
use RedSourcing::Utils;
use RedSourcing::QueryTemplate;
use RedSourcing::Storage;
use Red::AST::Infixes;
use RedSourcing::Context;
use RedSourcing::IsTransactional;
use RedSourcing::Projection;
use RedSourcing::Lifecycle;
use RedSourcing::Journal;

also is Metamodel::RedSourcing::EntityHOW;

has @!transactional-handlers;
has Map $!projection-descriptor;

# Kept on this HOW so the descriptor belongs to the domain type's compilation
# unit and is serialized with it. Never retain a bound receiver or runtime IDs.
method projection-descriptor(|) { $!projection-descriptor }
method apply-rules(\entity) {
    die $!projection-descriptor<rule-error> if $!projection-descriptor<rule-error>.defined;
    $!projection-descriptor<rules>.map({ $_(entity) }).List
}

method transactional-handlers(|) { @!transactional-handlers }

method compose(Mu \entity, |) {
    die "Projections cannot declare commands: {entity.^name}"
        if entity.^commands.elems;
    callsame;
    my @candidates = entity.^find_method('APPLY').candidates;
    my @attributes = entity.^attributes.map({ .name.substr(2) => $_ });
    my @event-types = @candidates.map: {
        my @parameters = .signature.params.grep({ !.invocant && !.slurpy });
        @parameters.elems == 1 ?? @parameters.head.type !! Mu
    };
    my @rules;
    my $rule-error;
    {
        # A projection may be declared only for its lifecycle or invoked directly
        # (e.g. APPLY {}). Keep query-signature errors deferred until replay, as
        # before, but retain only their text rather than a compiler backtrace.
        CATCH { default { $rule-error = .message } }
        @rules = @candidates.map({ prepare-rule(.signature) }).eager;
    }
    my @inherited;
    for entity.^mro.skip(1) -> $parent {
        next unless $parent.HOW.^can('projection-descriptor');
        my $description = $parent.^projection-descriptor;
        @inherited.append($description<shapes>.List) if $description.defined;
    }
    my @shapes = @candidates.map({
        %( candidate => $_, shape => query-shape($_, @inherited) )
    }).eager;
    my @templates;
    unless $rule-error.defined {
        my $stored = Mu;
        for @shapes.kv -> $i, $entry {
            my $template;
            {
                CATCH { default { $template = %( reason => .message ) } }
                $template = @event-types[$i].^name eq 'RedSourcing::StoredEvent'
                    ?? %( reason => 'raw journal projection' )
                    !! compile-query-template($stored, @event-types[$i], $entry<shape>, @attributes);
            }
            @templates.push($template);
        }
    }
    my $identity = entity.^entity-id-names.Set;
    # Reusing accumulated state is safe only when selection is fixed by IDs and
    # constants. Mutable receiver filters must reconstruct.
    my $instance-cacheable = !$rule-error.defined && @templates.elems == @candidates.elems
        && @templates.map({
            ($_<ast>:exists) && $_<parameters>.List.map({ $identity{.name}:exists }).all
        }).all.so;
    $!projection-descriptor = Map.new(
        :$instance-cacheable,
        type => entity.WHAT,
        attributes => @attributes.eager.List,
        ids => entity.^entity-id-names.Set,
        event-types => @event-types.eager.List,
        native-attributes => @attributes.grep({
            .value.type.^name eq any(<int num str uint int8 int16 int32 uint8 uint16 uint32 num32>)
        }).map(*.key).eager.List,
        rules => @rules.eager.List,
        rule-error => $rule-error,
        shapes => @shapes.List, templates => @templates.List,
    );
    my @handlers = @candidates.grep(* ~~ IsTransactional);
    @!transactional-handlers = @handlers;
    register-projection(entity, @handlers);
}

method subscribe(Mu:U \type) {
    register-projection(type, @!transactional-handlers);
    type
}

method with-ids(\type, |) {
    type.^subscribe;
    callsame
}

method advance(\entity, UInt :$through-id, Bool :$checkpoint = False) {
    assert-effect-allowed('projection advancement');
    entity.^use-lifecycle;
    journal-do {
        my $working = entity-working(entity, :!replay);
        my $cursor = $working.^checkpoint-cursor;
        $working.^apply-new-applyable-events(:$through-id);
        if $checkpoint && $working.^current-id > $cursor {
            my $row = $working.^write-snapshot(:version($working.^version + 1),
                :replay-cursor($working.^current-id));
            $working.^version = $row.version;
            $working.^checkpoint-cursor = $row.replay-cursor;
        } else {
            $working.^maybe-auto-snapshot;
        }
        $working
    }
}

method restore-state(Mu:U \type, $snapshot, Str :$stream!, *%initial) {
	if $snapshot {
		die "Projection snapshot for {type.^name} in '$stream' has no replay-cursor"
			unless $snapshot.replay-cursor.defined;
		$snapshot.COERCE(type)
	} else {
		type.bless(|%initial, :$stream)
	}
}

method replay(\entity) {
	entity.^apply-new-applyable-events
}

method apply-new-applyable-events(\entity, UInt :$through-id) {
	require ::("RedSourcing::StoredEvent");
    my Mu $stored = ::('RedSourcing::StoredEvent');
    my $raw = $!projection-descriptor<event-types>.grep(* === $stored).elems;
    my @values;
    my @filters = $raw ?? () !! projection-query-filters($stored, $!projection-descriptor, entity, @values);
    return unless $raw || @filters;
    my $records;
    if $raw {
        $records = entity.^can('journal-records')
            ?? entity.journal-records(:from-id(entity.^current-id), :$through-id)
            !! $stored.list-events(:row, :from-id(entity.^current-id), :$through-id);
    } else {
        my $filter = @filters.elems == 1 ?? @filters.head !! [OR] @filters;
        my $cursor = QueryBind.new(:index(@values.elems), :value(entity.^current-id));
        @values.push(entity.^current-id);
        my $*RED-INTERNAL = True;
        $filter = $filter AND ($stored.id > $cursor);
        if $through-id.defined {
            my $bound = QueryBind.new(:index(@values.elems), :value($through-id));
            @values.push($through-id);
            $filter = $filter AND ($stored.id <= $bound);
        }
        # Runtime fallback ASTs may contain current concrete values; do not
        # reuse their SQL layout as though they were parameterized templates.
        my $compiled = $!projection-descriptor<templates>.grep({ !($_<ast>:exists) }).elems == 0;
        $records = $compiled
            ?? storage-template-rows($stored, entity.WHAT.WHICH.Str ~ ':replay:' ~ $through-id.defined,
                $filter, @values)
            !! storage-template-rows($stored, '', $filter, @values, :!cache);
    }
    for $records.List -> $row {
        if $raw {
            apply-event(entity, $row) if entity.^find_method('APPLY').cando(\(entity, $row)).elems;
        } else {
            # Domain projections do not consume checkpoints or saga controls.
            next if $row.mro.contains('|Entity|') || ($row.mro.contains('|RedSourcing::Saga::Control|') || $row.mro.contains('|RedSourcing::Service::Protocol::Control|'));
            apply-event(entity, $row.COERCE);
        }
        entity.^record-applied(:at($row.created));
        entity.^current-id max= $row.id;
    }
}

method emit-snapshot(\entity) {
    journal-do {
        my $working = entity-working(entity, :!replay);
        $working.^replay;
        my $row = $working.^write-snapshot(:version($working.^version + 1),
            :replay-cursor($working.^current-id));
        $working.^version = $row.version;
        $working.^checkpoint-cursor = $row.replay-cursor;
        $row
    }
}
