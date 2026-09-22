use RedSourcing;
use BankEvents;

unit projection Balance;

has Int $.client-id is entity-id;
has Rat() $.balance = 0.0;

method amount { $!balance }

multi method APPLY(Deposited $_ where { .client-id == $!client-id }) {
    $!balance += .amount;
}
multi method APPLY(Transaction $_ where { .from-client == $!client-id }) {
    $!balance -= .amount;
}
multi method APPLY(Transaction $_ where { .to-client == $!client-id }) {
    $!balance += .amount;
}
