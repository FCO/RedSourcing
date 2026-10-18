unit module RedSourcing::Traits;

use RedSourcing::Entity;
use RedSourcing::IsEntityId;
use RedSourcing::IsEntityIdMap;
use RedSourcing::IsCommand;
use RedSourcing::IsTransactional;

multi trait_mod:<is>(Attribute $r, Bool :$entity-id where *.so) is export {
	$r does IsEntityId
}

multi trait_mod:<is>(Method $method, :$command) is export {
	$method does IsCommand
}

multi trait_mod:<is>(Method $method, Bool :$transactional where *.so) is export {
    my $receiver = $method.signature.params.first(*.invocant);
    die 'is transactional is only supported on projection APPLY methods'
        unless $method.name eq 'APPLY' && $receiver.defined
            && $receiver.type.HOW.^mro.grep(*.^name eq 'Metamodel::RedSourcing::ProjectionHOW').elems;
    $method does IsTransactional;
}

multi trait_mod:<is>(Attribute $, Bool :$transactional where *.so) is export {
    die 'is transactional is only supported on projection APPLY methods';
}

multi trait_mod:<is>(Method $method, :$entity-id-map!) is export {
	die "is entity-id-map is only supported on APPLY methods" unless $method.name eq 'APPLY';
	my %map = $entity-id-map;
	die "entity-id-map requires event-field => entity-id string pairs"
		unless %map.kv.all ~~ Str && %map.kv.all.chars;
	$method does IsEntityIdMap;
	$method.event-entity-id-map = %map;
}
