unit module TransactionalDomain;
use RedSourcing;

class JournalOrderFact does Event is export {
    has Str $.source-id;
    has Int $.sequence;
    has Bool $.automatic;
}
aggregate JournalOrderSource is export {
    has Str $.source-id is entity-id;
    method APPLY(JournalOrderFact $event) { }
    method record(Int :$sequence!, Bool :$automatic = True, Str :$barrier = '') is command {
        my $row = self.journal-order-fact(:$sequence, :$automatic);
        if $barrier.chars {
            ($barrier ~ '.ready').IO.spurt($row.id.Str);
            my $deadline = now + 40;
            until ($barrier ~ '.resume').IO.e {
                die 'Timed out waiting for the append barrier' if now > $deadline;
                await Promise.in(0.02);
            }
        }
        $sequence
    }
}
projection JournalOrderProjection is export {
    has @.seen;
    multi method APPLY(JournalOrderFact $event where { !.automatic }) { @!seen.push($event.sequence) }
    multi method APPLY(JournalOrderFact $event where { .automatic }) is transactional { @!seen.push($event.sequence) }
}

projection JournalRetainedProjection[Retained] is export {
    has @.seen;
    method APPLY(JournalOrderFact $event) { @!seen.push($event.sequence) }
}
