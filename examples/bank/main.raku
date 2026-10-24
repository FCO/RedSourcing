use lib $?FILE.IO.parent.Str;
use RedSourcing;
use Account;
use Balance;
use MonthlyStatement;
use BankTotals;

red-sourcing-defaults(:file($?FILE.IO.parent.add('red-sourcing.rakuconf')),
    :database(%*ENV<REDSOURCING_EXAMPLE_DATABASE> // ':memory:'));

my $ana = Account.^with-ids(:client-id(1));
my $bob = Account.^with-ids(:client-id(2));
$ana.^create;
$bob.^create;
$ana.deposit(:amount(100.00), :timestamp<2026-09-30T12:00:00Z>);
$bob.deposit(:amount(20.00), :timestamp<2026-09-30T12:00:00Z>);

my %transfer = $ana.transfer(:to-client(2), :amount(25.50),
    :timestamp<2026-10-05T12:00:00Z>);
say "Transfer {%transfer<transaction-id>}: {%transfer<amount>} from Ana to Bob";
say "Ana: {$ana.amount}; Bob: {$bob.amount}";

my $statement-proxy = MonthlyStatement.^with-ids(:client-id(1));
# Load one view for several fields and checkpoint that same state.
my $statement = $statement-proxy.^load;
say "Ana's September closing: {$statement.balance-by-month{202609}}";
say "Ana's October closing: {$statement-proxy.amount-on-month(:period(202610))}";
say "  {.<direction>}: {.<amount>}" for $statement.transactions-by-month{202610}.list;
$statement.^emit-snapshot;

my $pending = $bob.transfer(:to-client(1), :amount(5.25),
    :timestamp<2026-10-06T12:00:00Z>, :!sync);
say "Deferred transfer: {$pending.state}";
$pending.run;
$statement = $statement-proxy.^load;
say "Ana's October after checkpoint: {$statement.balance-by-month{202610}}";
say "Ana's balance projection: {Balance.^with-ids(:client-id(1)).amount}";

try {
    CATCH { default { say "Rejected: {.message}" } }
    $ana.transfer(:to-client(2), :amount(1000.00));
}
try {
    CATCH { default { say "Rejected: {.message}" } }
    $ana.transfer(:to-client(999), :amount(1.00));
}

my $totals = BankTotals.^with-ids.^load;
say "Bank deposits: {$totals.deposited}; transferred: {$totals.transferred} in {$totals.transfers} transfers";
