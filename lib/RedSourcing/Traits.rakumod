unit module RedSourcing::Traits;

use RedSourcing::Entity;
use RedSourcing::IsEntityId;
use RedSourcing::IsEntityIdMap;
use RedSourcing::IsCommand;

multi trait_mod:<is>(Attribute $r, Bool :$entity-id where *.so) is export {
	$r does IsEntityId
}

multi trait_mod:<is>(Method $method, :$command) is export {
	$method does IsCommand
}

multi trait_mod:<is>(Method $method, :$entity-id-map!) is export {
	die "is entity-id-map is only supported on APPLY methods" unless $method.name eq 'APPLY';
	my %map = $entity-id-map;
	die "entity-id-map requires event-field => entity-id string pairs"
		unless %map.kv.all ~~ Str && %map.kv.all.chars;
	$method does IsEntityIdMap;
	$method.event-entity-id-map = %map;
}
