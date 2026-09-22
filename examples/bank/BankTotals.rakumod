use RedSourcing;
use BankEvents;

unit projection BankTotals;

has Rat() $.deposited = 0.0;
has Rat() $.transferred = 0.0;
has UInt $.transfers = 0;

multi method APPLY(Deposited $event) { $!deposited += $event.amount }
multi method APPLY(Transaction $event) {
    $!transferred += $event.amount;
    $!transfers++;
}
