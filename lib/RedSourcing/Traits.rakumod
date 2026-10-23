unit module RedSourcing::Traits;

use RedSourcing::Entity;
use RedSourcing::IsEntityId;
use RedSourcing::IsEntityIdMap;
use RedSourcing::IsCommand;
use RedSourcing::IsTransactional;
use RedSourcing::Tags;

multi trait_mod:<is>(Attribute $attribute, Bool :$not-a-tag where *.so) is export {
    die 'is not-a-tag cannot be combined with is tagged or is tag-field'
        if $attribute ~~ TaggedAttribute || $attribute ~~ TagFieldAttribute;
    $attribute does NotATagAttribute;
}

multi trait_mod:<is>(Attribute $attribute, :$tagged!) is export {
    die 'is tagged cannot be combined with is not-a-tag' if $attribute ~~ NotATagAttribute;
    my @names = $tagged ~~ Positional ?? $tagged.List !! ($tagged,);
    die 'is tagged requires one or more nonempty tag names'
        unless @names && @names.all ~~ Str && @names.all.chars;
    $attribute does TaggedAttribute unless $attribute ~~ TaggedAttribute;
    $attribute.tag-aliases.append(@names);
}

multi trait_mod:<is>(Attribute $attribute, Bool :$tag-field where *.so) is export {
    die 'is tag-field cannot be combined with is not-a-tag' if $attribute ~~ NotATagAttribute;
    $attribute does TagFieldAttribute;
}

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
