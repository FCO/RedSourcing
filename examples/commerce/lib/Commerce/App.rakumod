use RedSourcing;
use Commerce::Utils;
use Commerce::Events;
use Commerce::Inventory;
use Commerce::Order;
use Commerce::Shipment;
use Commerce::Workflows;
use Commerce::ReadModels;
use Commerce::Providers;
use Commerce::Webhooks;
unit module Commerce::App;

my @order-sagas = PurchaseSaga, FulfillmentSaga, ShippingSaga, CancellationSaga, ReturnSaga, NotificationSaga, WebhookSaga;
sub order-sagas is export { @order-sagas.List }

class Shop is export {
    has Str $.webhook-url = %*ENV<COMMERCE_WEBHOOK_URL> // 'simulated://commerce';
    has UInt $!cursor = 0;
    has %!instances;
    has %!dirty;
    has %!wakeups;

    method !refresh {
        my %types = (|@order-sagas, ReplenishmentSaga).map({ .^name => $_ });
        my %routes =
            OrderSubmitted.^name => [PurchaseSaga, NotificationSaga],
            OrderPaid.^name => [PurchaseSaga, FulfillmentSaga, NotificationSaga],
            OrderDispatchAuthorized.^name => [FulfillmentSaga],
            ShipmentBooked.^name => [FulfillmentSaga],
            ShipmentDispatched.^name => [ShippingSaga],
            ShipmentDelivered.^name => [ShippingSaga],
            CancellationRequested.^name => [FulfillmentSaga, CancellationSaga],
            ShipmentCancelled.^name => [CancellationSaga],
            OrderCancelled.^name => [FulfillmentSaga, ShippingSaga, CancellationSaga, ReturnSaga, NotificationSaga],
            ReturnRequested.^name => [ReturnSaga],
            ReturnReceived.^name => [ReturnSaga],
            ReturnRecoveryRequested.^name => [ReturnSaga],
            ShippingRecoveryRequested.^name => [ShippingSaga],
            OrderShipped.^name => [NotificationSaga],
            OrderDelivered.^name => [NotificationSaga],
            ReturnCompleted.^name => [NotificationSaga];
        %routes{OrderIssueReported.^name} = [NotificationSaga];
        %routes{ShipmentIssueReported.^name} = [NotificationSaga];
        for OrderSubmitted, OrderPaid, OrderShipped, OrderDelivered, OrderCancelled, ReturnCompleted,
            OrderIssueReported, ShipmentIssueReported -> $event {
            (%routes{$event.^name} //= []).push(WebhookSaga);
        }
        for <StockReceived StockReserved StockReleased StockDispatched StockReturned ReplenishmentRequested> -> $name {
            %routes{"Commerce::Events::$name"} = [ReplenishmentSaga];
        }
        for StoredEvent.^all.grep(*.id > $!cursor).sort(*.id) -> $row {
            $!cursor = $row.id;
            if %types{$row.class}:exists {
                if !(%!instances{$row.stream}:exists) {
                    my $type = %types{$row.class};
                    my %ids = $type.^entity-id-names.map({ $_ => $row.data{$_} });
                    %!instances{$row.stream} = %(type => $type, proxy => $type.^with-ids(|%ids));
                    %!dirty{$row.stream} = True;
                } else {
                    my $live = %!instances{$row.stream}<live>;
                    %!dirty{$row.stream} = True unless $live.defined && $live.^version >= $row.version;
                }
            }
            if (%!instances{$row.stream}:exists) && $row.mro.contains('|RedSourcing::Saga::Control|') {
                # A Cached live reference may already reflect an external
                # resolution while its scheduled wakeup is still based on old state.
                %!dirty{$row.stream} = True
                    unless (%!instances{$row.stream}<wake-version> // 0) >= $row.version;
            }
            for (%routes{$row.class} // []).List -> $type {
                my %ids = $type.^entity-id-names.map({ $_ => $row.data{$_} });
                my $stream = $type.^with-ids(|%ids).^stream-name;
                %!dirty{$stream} = True if %!instances{$stream}:exists;
            }
        }
    }
    method !wake-after($live, DateTime $now) {
        my @due = $live.^state<timers>.values.map(*.<due>);
        my $action = $live.^state<actions>.first({ .<status> eq any(<pending retry running blocked>) });
        if $action && $action<status> ne 'blocked' {
            @due.push($action<status> eq 'running' ?? $now.Instant.Num + 1 !! $action<due>);
        }
        %!wakeups{$live.^stream} = @due ?? @due.min !! Inf;
        %!instances{$live.^stream}<wake-version> = $live.^version;
    }
    method initialize {
        .^create-table(:unless-exists) for StoredEvent, StoredCommand;
        register-commerce-providers;
        self
    }
    method product(Str $sku, Str :$warehouse-id = 'main', Str :$name!, Rat() :$price!, UInt :$quantity = 10,
                   Bool :$replenish = True) {
        my $stock = Commerce::Inventory.^with-ids(:$warehouse-id, :$sku);
        die 'Product stream already exists' if entity-exists($stock);
        $stock.^create; $stock.register(:$name, :unit-price($price));
        $stock.receive(:$quantity, :reference("opening/$warehouse-id/$sku")) if $quantity;
        ReplenishmentSaga.^with-ids(:$warehouse-id, :$sku).^create if $replenish;
        $stock
    }
    method order(Str $order-id) { Commerce::Order.^with-ids(:$order-id) }
    method shipment(Str $order-id) { Commerce::Shipment.^with-ids(:$order-id) }
    method purchase(Str $order-id, :%items!, Str :$warehouse-id = 'main',
                    Str :$email = 'customer@example.test', Str :$address = '18 Cedar Lane, Bristol',
                    Str :$webhook-url = $!webhook-url) {
        die 'Webhook URL must be HTTP, HTTPS, simulated://commerce or empty'
            unless !$webhook-url.chars || $webhook-url eq 'simulated://commerce'
                || $webhook-url.starts-with('http://') || $webhook-url.starts-with('https://');
        my $order = self.order($order-id);
        die 'Order stream already exists' if entity-exists($order);
        $order.^create; self.shipment($order-id).^create;
        .^with-ids(:$order-id).^create for @order-sagas.grep({ !($_ === WebhookSaga) });
        WebhookSaga.^with-ids(:$order-id).^create(:endpoint($webhook-url)) if $webhook-url.chars;
        $order.submit(:$warehouse-id, :$email, :$address, :%items);
        $order
    }
    method !proxies(Mu:U $type) {
        %!instances.values.grep({ .<type> === $type }).map(*.<proxy>).List
    }
    method !after-compensation(Str $order-id) {
        my $purchase = %!instances{PurchaseSaga.^with-ids(:$order-id).^stream-name}<live>;
        my $fulfillment = %!instances{FulfillmentSaga.^with-ids(:$order-id).^stream-name}<live>;
        return unless $purchase.^status eq 'compensated' || $fulfillment.^status eq 'compensated';
        my $order = self.order($order-id).^load;
        if $order.status eq 'submitted' && $purchase.^status eq 'compensated' {
            self.order($order-id).cancel(:reason($purchase.^state<reason> // 'Purchase failed'));
        }
        if $fulfillment.^status eq 'compensated' && $order.status eq any(<paid cancellation-requested>) {
            my $reason = $fulfillment.^state<reason> // 'Fulfillment failed';
            self.order($order-id).request-cancellation(:$reason) if $order.status eq 'paid';
            self.shipment($order-id).cancel(:$reason) unless self.shipment($order-id).status eq 'cancelled';
        }
    }
    method tick(DateTime :$now = DateTime.now, UInt :$limit = 100) {
        self!refresh;
        for |@order-sagas, ReplenishmentSaga -> $type {
            for self!proxies($type) -> $proxy {
                my $stream = $proxy.^stream-name;
                next unless %!dirty{$stream} || (%!wakeups{$stream} // Inf) <= $now.Instant.Num;
                %!dirty{$stream}:delete;
                # Reload dirty state so an external resolution/checkpoint is observed.
                my $live = $proxy.^load;
                $live = $live.^advance(:$now, :$limit) if $live.^status eq any(<running compensating>);
                %!instances{$stream}<live> = $live;
                self!wake-after($live, $now);
            }
        }
        for self!proxies(PurchaseSaga) -> $proxy { self!after-compensation($proxy.^ids-map<order-id>) }
        self
    }
    method drain(DateTime :$now = DateTime.now, UInt :$passes = 25) {
        for ^$passes {
            my $before = StoredEvent.^all.sort(-*.id).head.id // 0;
            self.tick(:$now);
            my $after = StoredEvent.^all.sort(-*.id).head.id // 0;
            return self if $before == $after;
        }
        die 'Controller did not settle within the bounded number of passes';
    }
    method checkpoint {
        self!refresh;
        for |@order-sagas, ReplenishmentSaga -> $type {
            .^load.^emit-snapshot for self!proxies($type);
        }
        WarehouseBoard.^with-ids.^load.^emit-snapshot;
        ShopDashboard.^with-ids.^load.^emit-snapshot;
        self
    }
    method summary { ShopDashboard.^with-ids.^load }
    method notifications(Str $order-id) { OrderNotifications.^with-ids(:$order-id).^load }
}
