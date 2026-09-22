use RedSourcing;
use DeliveryEvents;

unit projection RestaurantBoard;

has Str $.restaurant-id is entity-id;
has %.orders;

method active-orders {
    %!orders.keys.sort.map({ %!orders{$_} }).grep({
        .<status> ne 'delivered' && .<status> ne 'cancelled'
    }).Array
}

method APPLY(ForDeliveryOrder $event where { .restaurant-id eq $!restaurant-id }) {
    given $event {
        when OrderPlaced {
            %!orders{.order-id} = %(
                order-id => .order-id, customer-id => .customer-id,
                items => .items.Array, total => .total, courier-id => '',
            );
        }
        when CourierAssigned { %!orders{.order-id}<courier-id> = .courier-id }
    }
    %!orders{$event.order-id}<status> = $event.status;
}
