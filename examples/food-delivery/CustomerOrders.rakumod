use RedSourcing;
use DeliveryEvents;

unit projection CustomerOrders;

has Str $.customer-id is entity-id;
has %.orders;

method tracking(Str :$order-id!) {
    die "Order '$order-id' is not tracked for customer '$!customer-id'"
        unless %!orders{$order-id}:exists;
    %!orders{$order-id}
}

method orders-list {
    %!orders.keys.sort.map({ %!orders{$_} }).Array
}

method APPLY(ForDeliveryOrder $event where { .customer-id eq $!customer-id }) {
    given $event {
        when OrderPlaced {
            %!orders{.order-id} = %(
                order-id => .order-id, restaurant-id => .restaurant-id,
                address => .address, items => .items.Array, total => .total,
                courier-id => '', cancellation-reason => '',
            );
        }
        when CourierAssigned { %!orders{.order-id}<courier-id> = .courier-id }
        when OrderCancelled { %!orders{.order-id}<cancellation-reason> = .reason }
    }
    %!orders{$event.order-id}<status> = $event.status;
}
