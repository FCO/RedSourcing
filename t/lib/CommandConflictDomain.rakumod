use RedSourcing;
unit module CommandConflictDomain;

class CreditCommitted does Event is export { has Int $.amount }
aggregate ConcurrentBalance is export {
    has Str $.id is entity-id;
    has Int $.balance = 0;
    method APPLY(CreditCommitted $event) { $!balance += $event.amount }
    method credit(Int :$amount!, Str :$barrier = '') is command {
        if $barrier.chars {
            # Signal that this process has reconstructed state but not appended.
            ($barrier ~ '.ready').IO.spurt(self.^version.Str);
            my $deadline = now + 30;
            until ($barrier ~ '.resume').IO.e {
                die 'Concurrent writer barrier timed out' if now > $deadline;
                await Promise.in(0.02);
            }
        }
        self.credit-committed(:$amount);
        $!balance
    }
}
