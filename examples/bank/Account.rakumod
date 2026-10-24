use RedSourcing;
use BankEvents;
use BankMoney;

unit aggregate Account;

has Int   $.client-id is entity-id;
has Rat() $.amount is query = 0.0;

multi method APPLY(Deposited $event) { $!amount += $event.amount }
multi method APPLY(Transaction $event) is entity-id-map(:from-client<client-id>) {
    $!amount -= $event.amount
}
multi method APPLY(TransferReceived $event) is entity-id-map(:to-client<client-id>) {
    $!amount += $event.amount
}

method deposit(
    Rat() :$amount! where &positive-money,
    Str   :$timestamp = DateTime.now.Str,
) is command {
    self.deposited(:$amount, :$timestamp);
    $!amount
}

method transfer(
    Int   :$to-client!,
    Rat() :$amount! where &positive-money,
    Str   :$timestamp = DateTime.now.Str,
) is command {
    die 'Cannot transfer to the same account' if $to-client == $!client-id;
    die "Insufficient funds in account $!client-id" if $amount > $!amount;

    my $target = ::?CLASS.^with-ids(:client-id($to-client));
    my $target-stream = $target.^stream-name;
    my $account-class = ::?CLASS.^name;
    my $*RED-FALLBACK = False;
    die "Target account $to-client does not exist"
        unless StoredEvent.^all.grep({
            .class eq $account-class && .stream eq $target-stream
        }).head;
    my $receiver = $target.^load;

    # The command executor already owns the transaction. Do not open a nested
    # transaction or invoke another command: both appends and Done commit together.
    my $transaction = self.transaction(
        :$to-client, :$amount, :$timestamp,
    );
    $receiver.transfer-received(
        :transaction-id($transaction.id),
        :from-client($!client-id), :$amount, :$timestamp,
    );

    %(transaction-id => $transaction.id, from-client => $!client-id,
        :$to-client, :$amount, remaining => $!amount)
}
