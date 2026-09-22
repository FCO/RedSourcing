unit class Metamodel::RedSourcing::ProjectionHOW;
use Metamodel::RedSourcing::EntityHOW;
use RedSourcing::Utils;
use RedSourcing::Context;

also is Metamodel::RedSourcing::EntityHOW;

method compose(Mu \entity, |) {
    die "Projections cannot declare commands: {entity.^name}"
        if entity.^commands.elems;
    callsame;
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

method apply-new-applyable-events(\entity) {
	require ::("RedSourcing::StoredEvent");
	my @rules = rules-from-func(entity, entity.^find_method('APPLY'));
	return unless @rules;
	for ::("RedSourcing::StoredEvent").list-events(:row, :from-id(entity.^current-id), |@rules) {
		# Entity snapshots are restoration points, not domain events for APPLY.
		next if .mro.contains('|Entity|') || .mro.contains('|RedSourcing::Saga::Control|');
		apply-event(entity, .COERCE);
		# Source versions belong to their streams; advance only the global cursor.
		entity.^current-id max= .id;
	}
}

method emit-snapshot(\entity) {
	entity.^replay;
	my $row = entity.^write-snapshot(
		:version(entity.^version + 1),
		:replay-cursor(entity.^current-id),
	);
	entity.^version = $row.version;
	$row
}
