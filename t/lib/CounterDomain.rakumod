unit module CounterDomain;
use RedSourcing;

class CounterFact does Event is export { has Str $.key }
class CounterAmount does Event is export { has Int $.amount is tag-field }
projection CounterView is export {
    has Str $.key is entity-id;
    has Int $.count = 0;
    method APPLY(CounterFact $e where { .key eqv $!key }) { $!count++ }
}
projection CounterRange is export {
    has Int $.minimum is entity-id;
    has Int $.count = 0;
    method APPLY(CounterAmount $e where { .amount > $!minimum }) { $!count++ }
}


use RedSourcing::Counters;
use RedSourcing::Journal;
our $fail-next-command is export = False;
aggregate CounterCommandSource is export {
    has Str $.key is entity-id;
    method APPLY(CounterFact $event) { }
    method record is command {
        if $fail-next-command {
            $fail-next-command = False;
            counter-sql(journal-connection(), q[DO $body$ BEGIN
                RAISE EXCEPTION 'Injected retryable command SQL failure' USING ERRCODE = '40P01';
                END $body$]);
        }
        self.counter-fact;
        True
    }
}
