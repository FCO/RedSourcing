unit module RedSourcing::Context;
use RedSourcing::Flow;

# Dynamic scopes also cover calls made through an aggregate proxy.
sub assert-effect-allowed(Str $operation) is export {
    my $phase = (try $*REDSOURCING-PHASE) // '';
    die "$operation is forbidden in APPLY" if $phase eq 'APPLY';
    die "Use saga effect helpers in REACT ($operation)" if $phase eq 'REACT';
}

sub apply-event($entity, $event) is export {
    my $*REDSOURCING-PHASE = 'APPLY';
    my $result = $entity.APPLY($event);
    return $result unless flow-tracing-enabled;
    my $row = $event.StoredEvent;
    my $kind = $entity.HOW.^mro.grep(*.^name.ends-with('ProjectionHOW')).elems ?? 'projection'
        !! $entity.HOW.^mro.grep(*.^name.ends-with('SagaHOW')).elems ?? 'saga' !! 'aggregate';
    # Saga APPLY operates on a provisional clone. Record its consumption only
    # after REACT and the state commit succeed in SagaHOW.advance.
    return $result if $kind eq 'saga';
    observe-flow-entity($entity, $kind) if $row.defined;
    flow-link('event', $row.id.Str, 'entity', $entity.^stream, "applied-$kind") if $row.defined;
    $result
}
