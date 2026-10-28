use RedSourcing;
unit module BankTransfer;

class AccountOpened does Event is export { has Str $.account-id is required }
class MoneyDeposited does Event is export { has Str $.account-id is required; has Int $.amount is required }
class MoneyDebited does Event is export {
    has Str $.account-id is required; has Str $.transfer-id is required; has Int $.amount is required;
}
class MoneyCredited does Event is export {
    has Str $.account-id is required; has Str $.transfer-id is required; has Int $.amount is required;
}
class DebitRefunded does Event is export {
    has Str $.account-id is required; has Str $.transfer-id is required; has Int $.amount is required;
}
class TransferRequested does Event is export {
    has Str $.transfer-id is required; has Str $.from is required; has Str $.to is required; has Int $.amount is required;
}
class TransferCompleted does Event is export { has Str $.transfer-id is required }

# Money is stored as integer cents. Both versions use the same account facts.
projection Balance is export {
    has Str $.account-id is entity-id;
    has Bool $.opened = False;
    has Int $.amount is query = 0;
    multi method APPLY(AccountOpened $e where { .account-id eqv $!account-id }) { $!opened = True }
    multi method APPLY(MoneyDeposited $e where { .account-id eqv $!account-id }) { $!amount += $e.amount }
    multi method APPLY(MoneyDebited $e where { .account-id eqv $!account-id }) { $!amount -= $e.amount }
    multi method APPLY(MoneyCredited $e where { .account-id eqv $!account-id }) { $!amount += $e.amount }
    multi method APPLY(DebitRefunded $e where { .account-id eqv $!account-id }) { $!amount += $e.amount }
}

aggregate Account is export {
    has Str $.account-id is entity-id;
    has Bool $.opened = False;
    has Int $.amount is query = 0;
    has %!debits;
    has %!credits;
    has %!refunds;
    multi method APPLY(AccountOpened $) { $!opened = True }
    multi method APPLY(MoneyDeposited $e) { $!amount += $e.amount }
    multi method APPLY(MoneyDebited $e) { $!amount -= $e.amount; %!debits{$e.transfer-id} = $e.amount }
    multi method APPLY(MoneyCredited $e) { $!amount += $e.amount; %!credits{$e.transfer-id} = $e.amount }
    multi method APPLY(DebitRefunded $e) { $!amount += $e.amount; %!refunds{$e.transfer-id} = True }
    method open is command { self.account-opened unless $!opened; True }
    method deposit(Int :$amount! where * > 0) is command {
        die 'Account is not open' unless $!opened;
        self.money-deposited: :$amount;
        $!amount
    }
    method debit(Str :$transfer-id!, Int :$amount! where * > 0) is command {
        die 'Account is not open' unless $!opened;
        if %!debits{$transfer-id}:exists {
            die 'Transfer amount changed' unless %!debits{$transfer-id} == $amount;
        } else {
            die 'Insufficient funds' if $amount > $!amount;
            self.money-debited: :$transfer-id, :$amount;
        }
        %(:$transfer-id, :$amount)
    }
    method credit(Str :$transfer-id!, Int :$amount! where * > 0) is command {
        die 'Account is not open' unless $!opened;
        if %!credits{$transfer-id}:exists {
            die 'Transfer amount changed' unless %!credits{$transfer-id} == $amount;
        } else { self.money-credited: :$transfer-id, :$amount }
        %(:$transfer-id, :$amount)
    }
    method refund(Str :$transfer-id!, Int :$amount!) is command {
        die 'Unknown debit' unless (%!debits{$transfer-id} // 0) == $amount;
        self.debit-refunded: :$transfer-id, :$amount unless %!refunds{$transfer-id}:exists;
        %(:$transfer-id, :$amount)
    }
}

aggregate Transfer is export {
    has Str $.transfer-id is entity-id;
    has Str $.status is query = 'new';
    multi method APPLY(TransferRequested $) { $!status = 'requested' }
    multi method APPLY(TransferCompleted $) { $!status = 'completed' }
    method request(Str :$from!, Str :$to!, Int :$amount! where * > 0) is command {
        die 'Transfer already submitted' unless $!status eq 'new';
        die 'Choose different accounts' if $from eq $to;
        self.transfer-requested: :$from, :$to, :$amount;
        $!status
    }
    method complete is command {
        self.transfer-completed unless $!status eq 'completed';
        $!status
    }
    method execute(Str :$from!, Str :$to!, Int :$amount! where * > 0) is command {
        die 'Transfer already submitted' unless $!status eq 'new';
        die 'Choose different accounts' if $from eq $to;
        decision-model(
            (Balance) => %(:account-id($from)), (Balance) => %(:account-id($to)),
            -> $source, $target {
                die 'Source account is not open' unless $source.opened;
                die 'Target account is not open' unless $target.opened;
                die 'Insufficient funds' if $amount > $source.amount;
                # Append facts directly: no child commands or separately committed steps.
                my $sender = Account.^with-ids(:account-id($from)).^load;
                my $receiver = Account.^with-ids(:account-id($to)).^load;
                $sender.money-debited: :$!transfer-id, :$amount;
                $receiver.money-credited: :$!transfer-id, :$amount;
                self.transfer-completed;
                $!status
            },
        )
    }
}

saga TransferWorkflow is export {
    has Str $.transfer-id is entity-id;
    has Str $.from = '';
    has Str $.to = '';
    has Int $.amount = 0;
    multi method APPLY(TransferRequested $e where { .transfer-id eqv $!transfer-id }) {
        $!from = $e.from; $!to = $e.to; $!amount = $e.amount;
    }
    multi method REACT(TransferRequested $e where { .transfer-id eqv $!transfer-id }) { self.debit }
    multi method REACT(StepSucceeded $e where { .step eq 'debit' }) { self.credit }
    multi method REACT(StepSucceeded $e where { .step eq 'credit' }) { self.finish }
    multi method REACT(StepSucceeded $e where { .step eq 'finish' }) { self.^complete }
    # After credit committed, a completion-record failure must not refund only
    # the sender. Keep that failed action for operator recovery instead.
    multi method REACT(StepFailed $e where { .step ne 'finish' }) {
        self.^compensate: :reason('Transfer step failed');
    }
    method debit {
        Account.^with-ids(:account-id($!from)).debit: :$!transfer-id, :$!amount, :service-retry{:1max};
    }
    method compensate-debit(Str :$transfer-id!, Int :$amount!) {
        Account.^with-ids(:account-id($!from)).refund: :$transfer-id, :$amount, :!service-compensation;
    }
    method credit {
        Account.^with-ids(:account-id($!to)).credit: :$!transfer-id, :$!amount,
            :service-retry{:1max}, :!service-compensation;
    }
    method finish {
        Transfer.^with-ids(:$!transfer-id).complete: :!service-compensation;
    }
}
