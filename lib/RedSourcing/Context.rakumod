unit module RedSourcing::Context;

# Dynamic scopes also cover calls made through an aggregate proxy.
sub assert-effect-allowed(Str $operation) is export {
    my $phase = (try $*REDSOURCING-PHASE) // '';
    die "Use ServiceContext for state changes ($operation)"
        if $phase eq any('SERVICE', 'SERVICE-READ') && $operation eq any('command submission', 'command execution', 'event emission', 'snapshot emission');
    die "$operation is forbidden in APPLY" if $phase eq 'APPLY';
    die "Use saga effect helpers in REACT ($operation)" if $phase eq 'REACT';
}

sub apply-event($entity, $event) is export {
    my $*REDSOURCING-PHASE = 'APPLY';
    $entity.APPLY($event)
}
