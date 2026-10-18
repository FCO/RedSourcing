unit module LifecycleDomain;
use RedSourcing;

class Added does Event is export {
    has Int $.id;
    has Int $.amount;
}

aggregate Account[Retained] is export {
    has Int $.id is entity-id;
    has Int $.amount = 0;
    has @.seen;
    has Hash $.details = { amounts => [] };
    method APPLY(Added $event) {
        $!amount += $event.amount;
        @!seen.push($event.amount);
        $!details<amounts>.push($event.amount);
    }
    method add(Int :$amount!, Bool :$fail = False) is command {
        self.added(:$amount);
        die 'Rejected addition' if $fail;
        $!amount
    }
}

aggregate DefaultAccount is export {
    has Int $.id is entity-id;
    method APPLY {}
    method answer is command { $!id }
    method mode is command { self.^lifecycle.Str }
}

projection Total[Retained] is export {
    has Int $.id is entity-id;
    has Int $.amount = 0;
    method APPLY(Added $event where { .id == $!id }) is transactional {
        $!amount += $event.amount;
    }
}

saga Workflow[Retained] is export {
    has Int $.id is entity-id;
    has Int $.amount = 0;
    method APPLY(Added $event where { .id == $!id }) { $!amount += $event.amount }
    multi method REACT(Added $event where { .id == $!id }) { self.deliver }
    multi method REACT(StepSucceeded $event where { .step eq 'deliver' }) { self.^complete }
    method deliver {
        self.^service('lifecycle-test', 'deliver', \(:id($.id)),
            :retry{ :2max, :1delay }, :!compensation)
    }
    method expire { self.^complete }
}
