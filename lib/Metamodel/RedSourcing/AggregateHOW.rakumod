unit class Metamodel::RedSourcing::AggregateHOW;
use Metamodel::RedSourcing::EntityHOW;
use RedSourcing::IsEntityIdMap;
use RedSourcing::Context;
use RedSourcing::Event;

also is Metamodel::RedSourcing::EntityHOW;

my role AggregateEventMethod[Mu $event] {
	method emitted-event { $event }
}

method compose(Mu \entity, |) {
	callsame;
	my Mu $event-role = Event;
	my %events;
	my %names;
	my %id-names = entity.^entity-id-names.map({ $_ => True });
	for entity.^find_method('APPLY').candidates -> &handler {
		my @params = &handler.signature.params.grep({ !.invocant && !.slurpy });
		next unless @params.elems == 1 && @params.head.positional;
		my Mu $event = @params.head.type;
		next unless $event.HOW ~~ Metamodel::ClassHOW && $event.^does($event-role);
		my $name = $event.^name.split('::').tail
			.subst(/(<[A..Z]>+) (<[A..Z]><[a..z]>)/, { "$0-$1" }, :g)
			.subst(/(<[a..z0..9]>) (<[A..Z]>)/, { "$0-$1" }, :g).lc;
		my %fields = $event.^attributes.grep(*.has_accessor).map({ .name.substr(2) => True });
		my %explicit = &handler ~~ IsEntityIdMap ?? &handler.event-entity-id-map !! ();
		for %explicit.kv -> $field, $id {
			die "Unknown entity ID '$id' in mapping for {$event.^name}"
				unless %id-names{$id}:exists;
			die "Unknown event field '$field' in mapping for {$event.^name}"
				unless %fields{$field}:exists;
		}
		my %mapped-ids = %explicit.values.map({ $_ => True });
		my %map = %id-names.keys.grep({
			(%fields{$_}:exists) && !(%mapped-ids{$_}:exists)
		}).map({ $_ => $_ });
		%map{$_} = %explicit{$_} for %explicit.keys;
		if %events{$event.WHICH}:exists {
			die "Conflicting entity-id-map candidates for {$event.^name}"
				unless %events{$event.WHICH}<map> eqv %map;
			next;
		}
		my $existing = entity.^find_method($name);
		die "Event method '$name' conflicts with an existing method or another event in {entity.^name}"
			if (%names{$name}:exists) || ($existing && !(
				$existing ~~ AggregateEventMethod && $existing.emitted-event === $event
			));
		%events{$event.WHICH} = %(:$event, :$name, :%map);
		%names{$name} = True;
	}
	for %events.values -> %definition {
		my Mu $event = %definition<event>;
		my %map = %definition<map>;
		my &emitter = my method (Mu:D \SELF: |c) {
			my %args = c.hash;
			my %ids = SELF.^entity-id-map;
			for %map.kv -> $field, $id {
				die "Cannot override entity ID '$id' through event field '$field'"
					if (%args{$field}:exists) && !(%args{$field} eqv %ids{$id});
				%args{$field} = %ids{$id};
			}
			my $instance = $event.new(|c.list, |%args);
			for %map.kv -> $field, $id {
				die "Event constructor changed entity ID '$id' in field '$field'"
					unless $instance."$field"() eqv %ids{$id};
			}
			die "Event {$event.^name} does not match any APPLY candidate"
				unless SELF.^find_method('APPLY').cando(\(SELF, $instance));
			my $row = $instance.emit(:stream(SELF.^stream), :version(SELF.^version + 1));
			apply-event(SELF, $row.COERCE($event));
			SELF.^version = $row.version;
			SELF.^current-id = $row.id;
			$row
		};
		&emitter does AggregateEventMethod[$event];
		entity.^add_method: %definition<name>, &emitter;
	}
}

method restore-state(Mu:U \type, $snapshot, Str :$stream!, *%initial) {
	die "No snapshot for {type.^name} in '$stream'" unless $snapshot;
	$snapshot.COERCE(type)
}

method replay(\entity) {
	entity.^apply-new-events-of-stream
}

method apply-new-events-of-stream(\entity) {
	require ::("RedSourcing::StoredEvent");
	entity.^apply-model: $_ for ::("RedSourcing::StoredEvent").list-events:
		:row,
		:stream(entity.^stream),
		:from-id(entity.^current-id),
}

method apply-model(\entity, $_) {
	apply-event(entity, .COERCE) unless .class eq entity.^name;
	entity.^version    max= .version;
	entity.^current-id max= .id;
}

method emit-snapshot(\entity) {
	my $retries-yet = 5;
	my $error;
	repeat {
		CATCH {
			when X::Red::Driver::Mapped::Unique {
				$retries-yet--;
				$error = $_;
			}
		}
		entity.^replay;
		my $row = entity.^write-snapshot(:version(++(entity.^version)));
		entity.^current-id max= $row.id;
		return $row;
	} while $retries-yet;
	$error.rethrow
}
