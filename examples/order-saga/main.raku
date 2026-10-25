#!/usr/bin/env raku
use RedSourcing;

use lib $?FILE.IO.parent.Str;
use OrderDomain;

red-sourcing-defaults(:file($?FILE.IO.parent.add('red-sourcing.rakuconf')),
    :database(%*ENV<REDSOURCING_EXAMPLE_DATABASE> // ':memory:'));

# An in-memory adapter simulates a provider that deduplicates by operation key.
# A production adapter must pass this key to a provider with durable deduplication.
my %results;
my @payments;
register-service('payments', sub ($method, Capture $args, Str :$idempotency-key!) {
    return %results{$idempotency-key} if %results{$idempotency-key}:exists;
    my %result;
    given $method {
        when 'charge' {
            @payments.push: "charged {$args.hash<amount>}";
            %result = payment-id => 'payment-1', receipt => 'receipt-1';
        }
        when 'refund' {
            @payments.push: "refunded {$args.hash<payment-id>}";
            %result = refunded => True;
        }
        default { Permanent.new(:message("Unknown payment method '$method'")).throw }
    }
    %results{$idempotency-key} = %result;
});

my $inventory = Inventory.^with-ids: :order-id<order-1>;
$inventory.^create;
my $proxy = OrderSaga.^with-ids: :order-id<order-1>;
$proxy.^create;
OrderSubmitted.new(:order-id<order-1>, :amount(12.50)).emit: :stream<orders>, :version(1);

my $now = DateTime.now;
my $saga = $proxy.^advance: :$now;
say "Payment confirmed: {$saga.paid}";
say "Registered compensations: {$saga.^state<compensations>.elems}";
say "Stock reserved: {$inventory.reserved}";
$saga.^emit-snapshot;

# Reloading is pure: it restores state without calling either adapter again.
say "Restored compensations: {$proxy.^load.^state<compensations>.elems}";

# An external controller calls advance periodically. Here we move the clock forward.
$saga = $proxy.^check-timeouts: :now($now.later(:seconds(901)));
say "After deadline: {$saga.^status}";
say "Stock reserved: {$inventory.reserved}";
say .Str for @payments;
