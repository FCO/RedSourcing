unit module ProjectionPlanDomain;
use RedSourcing;

class PlanFact does Event is export { has Str $.key; has Int $.amount }
class PlanNestedFact does Event is export { has Hash $.details; has Int $.amount }

projection PlanTotal is export {
    has Str $.key is entity-id;
    has Int $.total = 0;
    multi method APPLY(PlanFact $e where { .key eqv $!key }) { $!total += $e.amount }
}
projection PlanInherited is PlanTotal is export { }
projection PlanCombined is export {
    has Str $.key is entity-id;
    has Int $.total = 0;
    multi method APPLY(PlanFact $e where { .key eqv $!key }) { $!total += $e.amount }
    multi method APPLY(PlanNestedFact $e (:$details (:$owner where { $_ eqv $!key }), :$amount)) {
        $!total += $e.amount;
    }
}
projection PlanNative is export {
    has Str $.key is entity-id;
    has int $.count = 0;
    method APPLY(PlanFact $e where { .key eqv $!key }) { $!count++ }
}
projection PlanStateful is export {
    has Str $.key is entity-id;
    has Int $.minimum is rw = 0;
    has Int $.total = 0;
    method APPLY(PlanFact $e where { .key eqv $!key && .amount >= $!minimum }) { $!total += $e.amount }
}
projection PlanRaw is export {
    has Int $.count = 0;
    method APPLY(StoredEvent $row) { $!count++ }
}

projection PlanEmpty is export { method APPLY { } }
