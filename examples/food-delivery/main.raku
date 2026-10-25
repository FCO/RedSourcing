use lib $?FILE.IO.parent.Str;
use RedSourcing;
use Restaurant;
use DeliveryOrder;
use CustomerOrders;
use RestaurantBoard;
use DeliveryTotals;

red-sourcing-defaults(:file($?FILE.IO.parent.add('red-sourcing.rakuconf')),
    :database(%*ENV<REDSOURCING_EXAMPLE_DATABASE> // ':memory:'));

my $restaurant = Restaurant.^with-ids: :restaurant-id<green-kitchen>;
$restaurant.^create: :name('Green Kitchen');
$restaurant.set-menu-item: :item-id<bowl>, :name('Rice bowl'), :unit-price(12.50);
$restaurant.set-menu-item: :item-id<juice>, :name('Orange juice'), :unit-price(3.25);
$restaurant.open-for-orders;

my $order = DeliveryOrder.^with-ids: :order-id<order-1001>;
$order.^create;
my %receipt = $order.place-order: :restaurant-id<green-kitchen>, :customer-id<ana>,
    :address('10 Market Street'), :items{ bowl => 2, juice => 1 };
say "Order {%receipt<order-id>}: {%receipt<status>}, total {%receipt<total>}";
say "  {.<quantity>} x {.<name>} at {.<unit-price>}" for %receipt<items>.list;
$order.accept;
$order.mark-ready;
$order.assign-courier: :courier-id<sam>;

my $customer = CustomerOrders.^with-ids: :customer-id<ana>;
my $board = RestaurantBoard.^with-ids: :restaurant-id<green-kitchen>;
say "Customer tracking: {$customer.tracking(:order-id<order-1001>)<status>}";
say "Restaurant board: {$board.active-orders.elems} active order";
$order.^load.^emit-snapshot;
$customer.^load.^emit-snapshot;

try {
    CATCH { default { say "Rejected: {.message}" } }
    $order.pick-up: :courier-id<someone-else>;
}
$order.pick-up: :courier-id<sam>;
my $pending = $order.deliver: :courier-id<sam>, :!sync;
say "Deferred delivery: {$pending.state}";
say "Delivery result: {$pending.run}";
say "Repeated command: {$pending.run}";
say "Tracking after checkpoint: {$customer.tracking(:order-id<order-1001>)<status>}";

my $other = DeliveryOrder.^with-ids: :order-id<order-1002>;
$other.^create;
$other.place-order: :restaurant-id<green-kitchen>, :customer-id<bob>,
    :address('20 Market Street'), :items{ bowl => 1 };
$other.cancel: :reason('Customer changed plans');
say "Restaurant board: {$board.active-orders.elems} active orders";

my %totals = DeliveryTotals.^with-ids.report;
say "Totals: {%totals<placed>} placed, {%totals<delivered>} delivered, "
    ~ "{%totals<cancelled>} cancelled, delivered value {%totals<delivered-value>}";
