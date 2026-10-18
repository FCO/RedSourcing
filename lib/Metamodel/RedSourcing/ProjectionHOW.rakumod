unit class Metamodel::RedSourcing::ProjectionHOW;
use Metamodel::RedSourcing::EntityHOW;
use RedSourcing::Utils;
use RedSourcing::Context;
use RedSourcing::IsTransactional;
use RedSourcing::Projection;
use RedSourcing::Lifecycle;
use RedSourcing::Journal;

also is Metamodel::RedSourcing::EntityHOW;

has @!transactional-handlers;

method transactional-handlers(|) { @!transactional-handlers }

method compose(Mu \entity, |) {
    die "Projections cannot declare commands: {entity.^name}"
        if entity.^commands.elems;
    callsame;
    my @handlers = entity.^find_method('APPLY').candidates.grep(* ~~ IsTransactional);
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
        my $working = entity-working(entity);
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
	my @rules = rules-from-func(entity, entity.^find_method('APPLY'));
	return unless @rules;
	for ::("RedSourcing::StoredEvent").list-events(:row, :from-id(entity.^current-id), :$through-id, |@rules) {
		# Entity snapshots are restoration points, not domain events for APPLY.
		next if .mro.contains('|Entity|') || .mro.contains('|RedSourcing::Saga::Control|');
		apply-event(entity, .COERCE);
		entity.^record-applied(:at(.created));
		# Source versions belong to their streams; advance only the global cursor.
		entity.^current-id max= .id;
	}
}

method emit-snapshot(\entity) {
    journal-do {
        my $working = entity-working(entity);
        $working.^replay;
        my $row = $working.^write-snapshot(:version($working.^version + 1),
            :replay-cursor($working.^current-id));
        $working.^version = $row.version;
        $working.^checkpoint-cursor = $row.replay-cursor;
        $row
    }
}
