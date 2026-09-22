unit class Metamodel::RedSourcing::ProxyHOW;

also is Metamodel::ClassHOW;

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
	die 'advance requires a saga proxy' unless $!entity-type.HOW.^can('advance');
	my $entity = proxy.^load;
	$entity.^advance(|c);
	$entity
}

method check-timeouts(\proxy, |c) { proxy.^advance(|c) }

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
