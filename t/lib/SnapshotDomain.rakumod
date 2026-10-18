unit module SnapshotDomain;
use RedSourcing;

our $injections = 0;
class Fact does Event is export { has Int $.id; has Int $.amount; has Bool $.atomic = False; }

aggregate Peer[:auto-snapshot{ count => 1 }] is export {
    has Int $.id is entity-id;
    has Int $.amount = 0;
    method APPLY(Fact $event) { $!amount += $event.amount }
}

aggregate Batch[:retained, :auto-snapshot{ count => 2 }] is export {
    has Int $.id is entity-id;
    has Int $.amount = 0;
    has @.seen;
    method APPLY(Fact $event) { $!amount += $event.amount; @!seen.push($event.amount) }
    method add(Int :$n = 1, Int :$to = 0, Bool :$fail = False) is command {
        self.fact(:amount(1)) for ^$n;
        Peer.^with-ids(:id($to)).^load.fact(:amount(1)) if $to;
        die 'Rejected batch' if $fail;
        $!amount
    }
}

aggregate DefaultBatch is export {
    has Int $.id is entity-id;
    has Int $.amount = 0;
    method APPLY(Fact $event) { $!amount += $event.amount }
    method add(Int :$n = 1, Bool :$conflict = False, Bool :$atomic = False) is command {
        self.fact(:amount(1), :$atomic) for ^$n;
        Fact.emit(:stream(self.^stream), :version(self.^version + 1), :id($.id), :amount(0))
            if $conflict && $injections++ == 0;
        $!amount
    }
    method read is command { $!amount }
    method policy is command { self.^auto-snapshot.defined ?? self.^auto-snapshot.Hash !! Nil }
}

aggregate Disabled[:!auto-snapshot] is export {
    has Int $.id is entity-id;
    has Int $.amount = 0;
    method APPLY(Fact $event) { $!amount += $event.amount }
    method add(Int :$n = 1) is command { self.fact(:amount(1)) for ^$n; $!amount }
}

projection View[:auto-snapshot{ count => 2 }] is export {
    has Int $.id is entity-id;
    has Int $.amount = 0;
    method APPLY(Fact $event where { .id == $!id }) { $!amount += $event.amount }
}
projection Atomic[:!auto-snapshot] is export {
    has Int $.id is entity-id;
    has Int $.amount = 0;
    method APPLY(Fact $event where { .id == $!id && .atomic }) is transactional { $!amount += $event.amount }
}
projection TimedView[:auto-snapshot{ :100seconds }] is export {
    has Int $.id is entity-id;
    has Int $.amount = 0;
    method APPLY(Fact $event where { .id == $!id }) { $!amount += $event.amount }
}
saga Workflow[:retained, :auto-snapshot{ count => 2 }] is export {
    has Int $.id is entity-id;
    has Int $.amount = 0;
    method APPLY(Fact $event where { .id == $!id }) { $!amount += $event.amount }
    multi method REACT(Fact $event where { .id == $!id }) { self.send }
    multi method REACT(StepSucceeded $event where { .step eq 'send' }) { self.^complete }
    method send { self.^service('autosnapshot-test', 'send', \(:id($.id)), :!compensation) }
}
