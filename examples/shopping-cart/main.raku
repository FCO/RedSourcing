use lib $?FILE.IO.parent.Str;
use RedSourcing;
use Cart;
use CartSummary;
use ShopSales;
use CartReminder;

red-sourcing-defaults(:file($?FILE.IO.parent.add('red-sourcing.rakuconf')),
    :database(%*ENV<REDSOURCING_EXAMPLE_DATABASE> // ':memory:'));

my $cart = Cart.^with-ids: :cart-id<ana>;
$cart.^create;
$cart.add-item: :product-id<coffee>, :name<Coffee>, :unit-price(12.50), :quantity(2);
$cart.add-item: :product-id<mug>, :name<Mug>, :unit-price(8.90);
$cart.add-item: :product-id<coffee>, :name<Coffee>, :unit-price(12.50);
$cart.set-quantity: :product-id<coffee>, :quantity(2);
$cart.remove-item: :product-id<mug>;

my $summary-proxy = CartSummary.^with-ids: :cart-id<ana>;
# Load one view for several fields and checkpoint that same state.
my $summary = $summary-proxy.^load;
say "Cart: {$summary.lines} product, {$summary.item-count} units, total {$summary.total}";
$summary.^emit-snapshot;
$cart.^load.^emit-snapshot;

my $pending = $cart.checkout: :!sync;
say "Checkout: {$pending.state}";
my %order = $pending.run;
say "Order {%order<order-id>}: {%order<item-count>} units, total {%order<total>}";
say "  {.<name>}: {.<quantity>} x {.<unit-price>}" for %order<items>.list;
my %same-order = $pending.run;
say "Repeated run: {%same-order<order-id>}";
say "Restored summary: {$summary-proxy.summary<checked-out> ?? 'checked out' !! 'open'}";

try {
    CATCH { default { say "Rejected: {.message}" } }
    $cart.add-item: :product-id<tea>, :name<Tea>, :unit-price(4.25);
}

my $other = Cart.^with-ids: :cart-id<bob>;
$other.^create;
$other.add-item: :product-id<tea>, :name<Tea>, :unit-price(4.25), :quantity(3);
$other.checkout;
my $sales = ShopSales.^with-ids.^load;
say "Sales: {$sales.orders} orders, {$sales.items-sold} units, revenue {$sales.revenue}";

# A third cart stays open. Advance a controlled clock instead of waiting a day.
my $forgotten = Cart.^with-ids: :cart-id<carol>;
$forgotten.^create;
my $reminder = AbandonedCartReminder.^with-ids: :cart-id<carol>;
$reminder.^create: :email<carol@example.test>;
$forgotten.add-item: :product-id<mug>, :name<Mug>, :unit-price(8.90);
my $workflow = $reminder.^advance;
$workflow.^emit-snapshot;
say "Reminder: scheduled for 24 hours after the last cart change";
my $due = $workflow.^state<timers><abandoned-cart><due>;
my $clock = DateTime.now;
my $expired = $clock.later: :seconds($due - $clock.Instant.Num + 1);
$reminder.^advance: :now($expired);
my $email = StoredEvent.list-events(:types[ReminderEmailSent]).head;
say "Simulated email to {$email.email}: {$email.subject}";
$reminder.^advance: :now($expired.later(:seconds(1)));
say "Emails after another controller pass: {StoredEvent.list-events(:types[ReminderEmailSent]).elems}";
