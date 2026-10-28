#!/usr/bin/env raku
use lib $?FILE.IO.parent.add('lib').Str;
use RedSourcing;
use BankTransfer;
sub balance($id) { Balance.^with-ids(:account-id($id)).amount }
sub MAIN {
    red-sourcing-defaults(:file($?FILE.IO.parent.add('red-sourcing.rakuconf')));
    for <saga-a saga-b decision-a decision-b> -> $id {
        my $account = Account.^with-ids: :account-id($id);
        $account.^create;
        $account.open;
    }
    Account.^with-ids(:account-id<saga-a>).deposit: :amount(10000);
    Account.^with-ids(:account-id<decision-a>).deposit: :amount(10000);
    my $transfer = Transfer.^with-ids: :transfer-id<saga-demo>;
    my $workflow = TransferWorkflow.^with-ids: :transfer-id<saga-demo>;
    $transfer.^create;
    $workflow.^create;
    $transfer.request: :from<saga-a>, :to<saga-b>, :amount(3000);
    $workflow.^advance: :limit(1);
    say "Saga after debit: {balance('saga-a')} / {balance('saga-b')}";
    $workflow.^advance;
    say "Saga completed: {balance('saga-a')} / {balance('saga-b')}";
    my $atomic = Transfer.^with-ids: :transfer-id<decision-demo>;
    $atomic.^create;
    $atomic.execute: :from<decision-a>, :to<decision-b>, :amount(3000);
    say "Decision completed: {balance('decision-a')} / {balance('decision-b')}";
}
