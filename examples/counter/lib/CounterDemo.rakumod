use RedSourcing;
unit module CounterDemo;

class CounterIncremented is export does Event {
    has Int $.id is required;
    has Int $.amount is required;
}
#| A counter with validated commands and an event-sourced value.
aggregate Counter is export {
    has Int $.id is entity-id;
    has Int $.value = 0;
    method APPLY(CounterIncremented $event) { $!value += $event.amount }
    #| Increase the value by a positive integer.
    method increment(Int :$amount where * > 0 = 1) is command {
        self.counter-incremented(:$amount);
        $!value
    }
}
#| A read model following one counter across the shared event journal.
projection CounterTotal is export {
    has Int $.id is entity-id;
    has Int $.value = 0;
    method APPLY(CounterIncremented $event where { .id eqv $!id }) { $!value += $event.amount }
}
