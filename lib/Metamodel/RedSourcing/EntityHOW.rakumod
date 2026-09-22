unit class Metamodel::RedSourcing::EntityHOW;
use Red;
use Metamodel::RedSourcing::EntityIdContainer;
use Metamodel::RedSourcing::CommandContainer;
use RedSourcing::Command;
use Metamodel::RedSourcing::ProxyHOW;
use RedSourcing::Context;
use RedSourcing::Flow;

also is Metamodel::ClassHOW;
also does Metamodel::RedSourcing::EntityIdContainer;
also does Metamodel::RedSourcing::CommandContainer;

use RedSourcing::Entity;

has $!proxy;
has $!version-attr;
has $!curr-id-attr;
has $!stream-attr;

method proxy(|) { $!proxy }

method compose(Mu \entity, |) {
	entity.^add_role: Entity;

	callsame;
	my $apply = entity.^find_method('APPLY');
	$apply.wrap(my method (Mu \SELF: |c) {
		my $*REDSOURCING-PHASE = 'APPLY';
		callsame
	});

	$!version-attr = entity.^attributes.first: { .name eq '$!version'    }
	$!curr-id-attr = entity.^attributes.first: { .name eq '$!current-id' }
	$!stream-attr  = entity.^attributes.first: { .name eq '$!stream'     }

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
	require ::("RedSourcing::StoredEvent");
	my $*RED-FALLBACK = False;
	my $snapshot = ::("RedSourcing::StoredEvent").^all.grep({
		.class eq type.^name && .stream eq $stream
	}).sort(-*.id).head;
	my $entity = type.^restore-state($snapshot, :$stream, |%initial);
	$entity.^replay;
	$entity
}

# Shared persistence; the concrete HOW chooses replay and cursor policy.
method write-snapshot(\entity, UInt :$version!, UInt :$replay-cursor) {
	assert-effect-allowed('snapshot emission');
	require ::("RedSourcing::StoredEvent");
	my $event-schema-version = entity.^api.UInt // 0;
	my $mro = "|"
		~ [
			|entity.^mro,
			|entity.^roles
		].map(*.^name).grep({
			$_ !~~ /"<anon|" \d+ ">"/
		}).join("|")
		~ "|";
	my $row = ::("RedSourcing::StoredEvent").^create:
		:$event-schema-version,
		:$version,
		:stream(entity.^stream),
		:class(entity.^name),
		:$mro,
		:data(entity.^data),
		:$replay-cursor,
	;
	trace-emission($row);
	$row
}
