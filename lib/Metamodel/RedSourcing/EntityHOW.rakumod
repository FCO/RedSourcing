unit class Metamodel::RedSourcing::EntityHOW;
use Red;
use Metamodel::RedSourcing::EntityIdContainer;
use Metamodel::RedSourcing::CommandContainer;
use RedSourcing::Command;
use Metamodel::RedSourcing::ProxyHOW;
use RedSourcing::Context;
use RedSourcing::Flow;
use RedSourcing::IsTransactional;
use RedSourcing::Journal;
use RedSourcing::Tags;
use RedSourcing::Lifecycle;
use RedSourcing::QueryTemplate;
use RedSourcing::X::OptimisticLockFailed;
use X::Red::Exceptions;

also is Metamodel::ClassHOW;
also does Metamodel::RedSourcing::EntityIdContainer;
also does Metamodel::RedSourcing::CommandContainer;

use RedSourcing::Entity;

has $!proxy;
has @!validated-handlers;
has $!version-attr;
has $!curr-id-attr;
has $!stream-attr;
has $!checkpoint-attr;
has EntityLifecycle $!lifecycle;
has Bool $!used;
has Int $!cache-size;
has $!auto-snapshot;
has Bool $!auto-snapshot-explicit;
has $!snapshot-events-attr;
has $!snapshot-at-attr;

multi method lifecycle(Mu \type, Bool :$declared = False, *%options) {
    if %options {
        die 'Cannot combine :declared with lifecycle configuration' if $declared;
        return self!configure-lifecycle(type, |%options);
    }
    my $default = $!lifecycle // Cached;
    $declared ?? $default !! effective-lifecycle(type.WHAT, $default)
}

multi method lifecycle(Mu:U \type, EntityLifecycle $lifecycle) {
    self.lifecycle(type, :$lifecycle)
}

method !configure-lifecycle(Mu:U \type, *%options) {
    assert-effect-allowed('entity lifecycle configuration');
    my %normalized = lifecycle-options(%options);
    my $lifecycle = %normalized<lifecycle> // self.lifecycle(type, :declared);
    my $size = %normalized<cache-size> // $!cache-size // 100;
    die 'Entity cache size must be configured before first use'
        if $!used && $size != ($!cache-size // 100);
    my $policy = (%options<auto-snapshot>:exists) ?? snapshot-policy(%options<auto-snapshot>) !! $!auto-snapshot;
    die 'Entity lifecycle must be configured before first use'
        if $!used && $lifecycle != self.lifecycle(type, :declared);
    die 'Auto snapshot must be configured before first use'
        if $!used && (%options<auto-snapshot>:exists)
            && (!$!auto-snapshot-explicit || !($policy eqv $!auto-snapshot));
    $!lifecycle = $lifecycle;
    $!cache-size = $size;
    if %options<auto-snapshot>:exists {
        $!auto-snapshot = $policy;
        $!auto-snapshot-explicit = True;
    }
    type
}

method cache-size(Mu \type, Bool :$declared = False) {
    $declared ?? ($!cache-size // 100) !! effective-cache-size(type.WHAT, $!cache-size // 100)
}

method auto-snapshot(Mu \type, Bool :$declared = False, Bool :$explicit = False) {
    return $!auto-snapshot-explicit if $explicit;
    my $policy = $declared
        ?? ($!auto-snapshot-explicit ?? $!auto-snapshot !! default-auto-snapshot())
        !! effective-auto-snapshot(type.WHAT, $!auto-snapshot, $!auto-snapshot-explicit);
    $policy.defined ?? $policy !! Nil
}

method snapshot-events(\entity) is rw { $!snapshot-events-attr.get_value(entity) }
method snapshot-at(\entity) is rw { $!snapshot-at-attr.get_value(entity) }
method record-applied(\entity, DateTime :$at = DateTime.now) {
    entity.^snapshot-at = $at.Instant.Num unless entity.^snapshot-at;
    entity.^snapshot-events++
}

method maybe-auto-snapshot(\entity) {
    my $policy = entity.^auto-snapshot;
    return unless $policy.defined && entity.^snapshot-events;
    my $instant = DateTime.now.Instant.Num;
    return unless (($policy<count>:exists) && entity.^snapshot-events >= $policy<count>)
        || (($policy<seconds>:exists) && $instant - entity.^snapshot-at >= $policy<seconds>);
    my $aggregate = self.^can('apply-new-events-of-stream').so;
    my %cursor = $aggregate ?? {} !! { replay-cursor => entity.^current-id };
    my $row;
    {
        CATCH {
            when X::Red::Driver::Mapped::Unique {
                RedSourcing::X::OptimisticLockFailed.new(:event-class(entity.^name),
                    :stream(entity.^stream), :version(entity.^version + 1)).throw
            }
        }
        $row = entity.^write-snapshot(:version(entity.^version + 1), |%cursor);
    }
    entity.^version = $row.version;
    if $aggregate { entity.^current-id = $row.id }
    else { entity.^checkpoint-cursor = $row.replay-cursor }
    publish-entity(entity);
    $row
}

method use-lifecycle(Mu \type) {
    $!used = True;
    mark-entity-used(type.WHAT);
}

method release(Mu:U \type, Str :$stream!) {
    assert-effect-allowed('entity release');
    release-entity(type, $stream)
}

method proxy(|) { $!proxy }
method validated-handlers(|) { @!validated-handlers.List }

method compose(Mu \entity, |) {
	entity.^add_role: Entity;

	callsame;
	my @trusted;
	for entity.^mro.skip(1) -> $parent {
		@trusted.append($parent.^validated-handlers)
			if $parent.HOW.^can('validated-handlers');
	}
	@!validated-handlers = validate-handler-constraints(entity, @trusted);
	my $apply = entity.^find_method('APPLY');
	die 'is transactional is only supported on projection APPLY methods'
		if $apply.candidates.grep(* ~~ IsTransactional)
		&& !self.^mro.grep(*.^name eq 'Metamodel::RedSourcing::ProjectionHOW').elems;
	$apply.wrap(my method (Mu \SELF: |c) {
		my $*REDSOURCING-PHASE = 'APPLY';
		callsame
	});

	$!version-attr = entity.^attributes.first: { .name eq '$!version'    }
	$!curr-id-attr = entity.^attributes.first: { .name eq '$!current-id' }
	$!stream-attr  = entity.^attributes.first: { .name eq '$!stream'     }
	$!checkpoint-attr = entity.^attributes.first: { .name eq '$!checkpoint-cursor' }
	$!snapshot-events-attr = entity.^attributes.first(*.name eq '$!snapshot-events');
	$!snapshot-at-attr = entity.^attributes.first(*.name eq '$!snapshot-at');

	my Str $name = entity.^name ~ "Proxy";
	$!proxy := Metamodel::RedSourcing::ProxyHOW.new_type: :$name, :entity(entity.WHAT);
	for entity.^entity-id-attrs {
		my $attr = Attribute.new:
			:name(.name),
			:type(.type),
			:package($!proxy),
			:has_accessor(1),
		;
		trait_mod:<is>($attr, :required);
		$!proxy.^add_attribute: $attr;
	}
	for entity.^commands.kv -> Str $name, &cmd {
		my $snake     = tc $name.subst: :g, /'-'+(\w)/, { uc $0 };
		my $cmd-name  = "{entity.^name}::$snake";
		my $cmd-class = Metamodel::ClassHOW.new_type: :name($cmd-name);
		$cmd-class.^add_role: Command;
		my @params =  &cmd.signature.params.skip.grep: { .named && !.slurpy };
		my %map;
		for @params {
			my $to   = .named_names.head;
			%map{$_} = $to for .named_names;
			my $attr = Attribute.new:
				:name('$!' ~ $to),
				:type(.type),
				:package($!proxy),
				:has_accessor(1),
			;
			my &default = .default;
			$attr.set_build: -> $, | { default() } if &default.defined;
			trait_mod:<is>($attr, :required) unless .optional;
			$cmd-class.^add_attribute: $attr;
		}
		$!proxy.^command-classes{$cmd-name} = $cmd-class;
		$cmd-class.^compose;

		$!proxy.^command-preparers{$name} = -> %pars {
			my $cmd = $cmd-class.new: |%pars.kv.map(-> $key, $value { %map{$key} // $key => $value }).Map;

			my %data = $cmd.^attributes.grep(*.has_accessor).map: -> $attr {
				$attr.name.substr(2) => $attr.get_value: $cmd
			}

			my $c = \(entity, |%data);
			die "Parameters %data.raku() does not match the signature (&cmd.signature().raku()) of method $name"
				unless $c ~~ &cmd.signature;
			$cmd
		};

		# TODO: use the original signature
		$!proxy.^add_method: $name, my method (Mu \SELF: :$sync = True, *%pars) {
			assert-effect-allowed('command submission');
			my $cmd = SELF.^prepare-command($name, |%pars);
			my $stream = SELF.^stream-name;
			my $row = $cmd.emit:
				:entity(entity.^name),
				:entity-ids(SELF.^ids-map),
				:method($name),
				:$stream,
			;
			return $row.run if $sync;
			$row
		}
	}
	$!proxy.^compose
}

method data (\entity --> Map()) {
	entity.^attributes.map({
		next unless .has_accessor;
		my $name = .name.substr: 2;
		$name => .get_value: entity
	})
}

method version(\entity) is rw {
	$!version-attr.get_value: entity
}

method current-id(\entity) is rw {
	$!curr-id-attr.get_value: entity
}

method checkpoint-cursor(\entity) is rw {
    $!checkpoint-attr.get_value: entity
}

method stream(\entity) {
	$!stream-attr.get_value: entity
}

method with-ids(\entity, *%ids) {
	$!proxy.new: |%ids;
}

method from(\entity, $source) {
	my %ids;
	for entity.^entity-id-names -> $name {
		die "Missing entity ID '$name' on {$source.^name}" unless $source.^can($name);
		%ids{$name} = $source."$name"();
	}
	entity.^with-ids(|%ids)
}

method load(Mu:U \type, Str :$stream!, *%initial) {
    type.^use-lifecycle;
    my $fresh-combined;
    my &restore = {
        my $read = type.^restore-and-replay(:$stream, |%initial);
        $fresh-combined = $read<entity> if $read<combined>;
        $read<entity>
    };
    return restore() if type.^lifecycle == OnDemand;
    return cached-load(type, $stream, &restore) if type.^lifecycle == Cached;
    my $entity = retained-load(type, $stream, &restore);
    $entity.^replay if ((try $*RED-TRANSACTION-RUNNING) // False)
        && !($fresh-combined.defined && $entity === $fresh-combined);
    $entity
}

# Internal result distinguishes a completed combined read from the generic path.
method restore-and-replay(Mu:U \type, Str :$stream!, *%initial) {
    my $entity = type.^restore(:$stream, |%initial);
    $entity.^replay;
    %( :$entity, combined => False )
}

method restore(Mu:U \type, Str :$stream!, *%initial) {
	require ::("RedSourcing::StoredEvent");
	my $*RED-FALLBACK = False;
	my Mu $stored = ::("RedSourcing::StoredEvent");
    my $snapshot = $stored.^all.where($stored.journal-filter(:class(type.^name), :$stream)).sort(-*.id).head;
	type.^restore-state($snapshot, :$stream, |%initial)
}

# Shared persistence; the concrete HOW chooses replay and cursor policy.
method write-snapshot(\entity, UInt :$version!, UInt :$replay-cursor) {
	assert-effect-allowed('snapshot emission');
	entity.^use-lifecycle;
	require ::("RedSourcing::StoredEvent");
	my Mu $stored-event = ::("RedSourcing::StoredEvent");
	my $event-schema-version = entity.^api.UInt // 0;
	my $mro = "|"
		~ [
			|entity.^mro,
			|entity.^roles
		].map(*.^name).grep({
			$_ !~~ /"<anon|" \d+ ">"/
		}).join("|")
		~ "|";
    my %data = normalize-event-data(entity.^data);
    my %keys; # Checkpoints are not facts selected by decision-model.
    my $row = journal-append %keys, {
		my $row = $stored-event.^create:
			:$event-schema-version,
			:$version,
			:stream(entity.^stream),
			:class(entity.^name),
			:$mro,
			:data(%data),
			:$replay-cursor,
            |emission-causality(),
		;
		$row
	};
	entity.^snapshot-events = 0;
	entity.^snapshot-at = $row.created.Instant.Num;
	$row
}
