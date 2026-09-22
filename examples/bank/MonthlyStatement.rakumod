use RedSourcing;
use BankEvents;

unit projection MonthlyStatement;

has Int   $.client-id is entity-id;
has Rat() $.balance = 0.0;
has Rat() %.balance-by-month{UInt()};
has       %.transactions-by-month{UInt()};

method amount                          { $!balance                   }
method amount-on-month(UInt :$period!) { %!balance-by-month{$period} }

# Events arrive in timestamp order. Each month's last entry sets its closing balance.
multi method APPLY(Deposited $_ where { .client-id == $!client-id }) {
    self!record($_, .amount, 'deposit');
}

multi method APPLY(Transaction $_ where { .from-client == $!client-id }) {
    self!record($_, -.amount, 'outgoing');
}

multi method APPLY(Transaction $_ where { .to-client == $!client-id }) {
    self!record($_, .amount, 'incoming');
}

method !record($event, Rat $change, Str $direction) {
    $!balance += $change;
    %!balance-by-month{$event.period} = $!balance;
    %!transactions-by-month{$event.period}.push: %(
        event-id    => $event.StoredEvent.id,
        timestamp   => $event.timestamp,
        amount      => $event.amount,
        total       => $!balance,
        :$change, :$direction,
        from-client => $direction eq 'deposit' ?? $!client-id !! $event.from-client,
        to-client   => $direction eq 'deposit' ?? $!client-id !! $event.to-client,
    );
}
