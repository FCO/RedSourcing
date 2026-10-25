use RedSourcing;
use Commerce::Events;
unit module Commerce::ReadModels;

#| Rebuilds an order's in-app inbox from facts, even when email or webhooks fail.
projection OrderNotifications is export {
    has Str $.order-id is entity-id;
    has Array $.messages = [];
    multi method APPLY(OrderSubmitted $e where { .order-id eq $!order-id }) { self!add: $e, 'Order received' }
    multi method APPLY(OrderPaid $e where { .order-id eq $!order-id }) { self!add: $e, 'Payment confirmed' }
    multi method APPLY(OrderShipped $e where { .order-id eq $!order-id }) { self!add: $e, 'Order shipped' }
    multi method APPLY(OrderDelivered $e where { .order-id eq $!order-id }) { self!add: $e, 'Order delivered' }
    multi method APPLY(OrderCancelled $e where { .order-id eq $!order-id }) { self!add: $e, 'Order cancelled' }
    multi method APPLY(ReturnCompleted $e where { .order-id eq $!order-id }) { self!add: $e, 'Return refunded' }
    multi method APPLY(OrderIssueReported $e where { .order-id eq $!order-id }) { self!add: $e, $e.reason }
    multi method APPLY(ShipmentIssueReported $e where { .order-id eq $!order-id }) { self!add: $e, $e.reason }
    method !add(Event $event, Str $message) {
        $!messages.push(%(id => $event.StoredEvent.id, type => $event.^name,
            emitted-at => $event.emitted-at.Str, :$message));
    }
}

#| Lists warehouse balances and reservations across all product streams.
projection WarehouseBoard is export {
    has Hash $.products = {};
    multi method APPLY(ProductRegistered $e) {
        $!products{"{$e.warehouse-id}/{$e.sku}"} = %(name => $e.name, unit-price => $e.unit-price, on-hand => 0, available => 0, held => 0);
    }
    multi method APPLY(StockReceived $e) { $!products{"{$e.warehouse-id}/{$e.sku}"}<on-hand> += $e.quantity; self!level: $e }
    multi method APPLY(StockReserved $e) { $!products{"{$e.warehouse-id}/{$e.sku}"}<held> += $e.quantity; self!level: $e }
    multi method APPLY(StockReleased $e) { $!products{"{$e.warehouse-id}/{$e.sku}"}<held> -= $e.quantity; self!level: $e }
    multi method APPLY(StockDispatched $e) {
        $!products{"{$e.warehouse-id}/{$e.sku}"}<held> -= $e.quantity;
        $!products{"{$e.warehouse-id}/{$e.sku}"}<on-hand> -= $e.quantity; self!level: $e;
    }
    multi method APPLY(StockReturned $e) { $!products{"{$e.warehouse-id}/{$e.sku}"}<on-hand> += $e.quantity; self!level: $e }
    method !level($e) { $!products{"{$e.warehouse-id}/{$e.sku}"}<available> = $e.available }
}
#| Follows order states, payments and refunds without running any workflow.
projection ShopDashboard is export {
    has Hash $.orders = {};
    has Rat() $.captured = 0.0; has Rat() $.refunded = 0.0;
    multi method APPLY(OrderSubmitted $e) { $!orders{$e.order-id} = %(status => 'submitted', total => $e.total, email => $e.email) }
    multi method APPLY(OrderPaid $e) { $!orders{$e.order-id}<status> = 'paid' }
    multi method APPLY(OrderDispatchAuthorized $e) { $!orders{$e.order-id}<status> = 'dispatching' }
    multi method APPLY(OrderShipped $e) { $!orders{$e.order-id}<status> = 'shipped' }
    multi method APPLY(OrderDelivered $e) { $!orders{$e.order-id}<status> = 'delivered' }
    multi method APPLY(CancellationRequested $e) { $!orders{$e.order-id}<status> = 'cancellation-requested' }
    multi method APPLY(OrderCancelled $e) { $!orders{$e.order-id}<status> = 'cancelled' }
    multi method APPLY(ReturnRequested $e) { $!orders{$e.order-id}<status> = 'return-requested' }
    multi method APPLY(ReturnReceived $e) { $!orders{$e.order-id}<status> = 'return-received' }
    multi method APPLY(ReturnCompleted $e) { $!orders{$e.order-id}<status> = 'returned' }
    multi method APPLY(PaymentCaptured $e) { $!captured += $e.amount }
    multi method APPLY(PaymentRefunded $e) { $!refunded += $e.amount }
}
