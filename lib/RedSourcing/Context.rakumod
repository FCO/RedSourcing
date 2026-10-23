unit module RedSourcing::Context;

# Dynamic scopes also cover calls made through an aggregate proxy.
sub assert-effect-allowed(Str $operation) is export {
    my $phase = (try $*REDSOURCING-PHASE) // '';
    die "$operation is forbidden in APPLY" if $phase eq 'APPLY';
    die "Use saga effect helpers in REACT ($operation)" if $phase eq 'REACT';
}

sub apply-event($entity, $event) is export {
    my $*REDSOURCING-PHASE = 'APPLY';
    $entity.APPLY($event)
}
