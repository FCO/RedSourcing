unit role Metamodel::RedSourcing::EntityIdContainer;
use RedSourcing::IsEntityId;

method entity-id-attrs(Mu \entity) { entity.^attributes.grep: IsEntityId }
method entity-id-names(Mu \entity) { entity.^entity-id-attrs.map: { .name.substr: 2 } }

method entity-id-map($obj --> Map()) {
	do for $obj.^entity-id-attrs {
		.name.substr(2) => .get_value: $obj;
	}
}
