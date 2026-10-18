unit class Metamodel::RedSourcing::ProxyHOW;

also is Metamodel::ClassHOW;
use RedSourcing::Journal;

has %!command-classes;
has %!command-preparers;
has $!entity-type;

method new_type(:$entity!, |c) {
	my $type = callwith |c;
	$type.HOW.^attributes.first(*.name eq '$!entity-type').set_value: $type.HOW, $entity;
	$type
}

method command-classes(|) { %!command-classes }
method command-preparers(|) { %!command-preparers }
method prepare-command(\proxy, Str $name, *%arguments) {
	%!command-preparers{$name}(%arguments)
}
method entity-type(|) { $!entity-type }

method advance(\proxy, |c) {
    die 'advance requires a projection or saga proxy' unless $!entity-type.HOW.^can('advance');
    if $!entity-type.HOW.^mro.grep(*.^name eq 'Metamodel::RedSourcing::ProjectionHOW').elems {
        return journal-do { proxy.^load.^advance(|c) };
    }
    my $entity = proxy.^load;
    $entity.^advance(|c);
    $entity
}

method check-timeouts(\proxy, |c) {
    die 'check-timeouts requires a saga proxy' unless $!entity-type.HOW.^can('check-timeouts');
    proxy.^advance(|c)
}

method release(\proxy) {
    $!entity-type.^release(:stream(proxy.^stream-name))
}

method get-cmd-class($, Str $name where { %!command-classes{$name}:exists }) { %!command-classes{$name} }

method stream-name(\proxy) {
	"{ $!entity-type.^name }: " ~ join ", ", proxy.^attributes.sort(*.name.substr: 2).map: {
		"{ .name.substr: 2 } = { .get_value: proxy }"
	}
}
method ids-map(\proxy, --> Map()) {
	proxy.^attributes.map: {
		.name.substr(2) => .get_value: proxy
	}
}
method list-commands(\proxy, |c) {
	require ::("RedSourcing::StoredCommand");
	::("RedSourcing::StoredCommand").list-commands: |c, :stream(proxy.^stream-name)
}

method load(\proxy, *%initial) {
	$!entity-type.^load(
		|%initial,
		|proxy.^ids-map,
		stream => proxy.^stream-name,
	)
}

method create(\proxy, |c) {
	my $new = $!entity-type.bless(
		|c,
		|proxy.^ids-map,
		stream => proxy.^stream-name,
	).^emit-snapshot
}
