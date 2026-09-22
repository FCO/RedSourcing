use RedSourcing;
unit module DeliveryEvents;

class MenuItemSet is export does Event {
    has Str $.restaurant-id is required;
    has Str $.item-id is required;
    has Str $.name is required;
    has Rat() $.unit-price is required;
    has Bool $.available is required;
}

class RestaurantOpened is export does Event {
    has Str $.restaurant-id is required;
}

class RestaurantClosed is export does Event {
    has Str $.restaurant-id is required;
}

# Every order event carries enough identity for projections to select it.
role ForDeliveryOrder is export {
    has Str $.order-id is required;
    has Str $.restaurant-id is required;
    has Str $.customer-id is required;
}

class OrderPlaced is export does Event does ForDeliveryOrder {
    has Str $.address is required;
    has Array $.items is required;
    has Rat() $.subtotal is required;
    has Rat() $.delivery-fee is required;
    has Rat() $.total is required;
    method status { 'placed' }
}

class OrderAccepted is export does Event does ForDeliveryOrder {
    method status { 'accepted' }
}

class OrderReady is export does Event does ForDeliveryOrder {
    method status { 'ready' }
}

class CourierAssigned is export does Event does ForDeliveryOrder {
    has Str $.courier-id is required;
    method status { 'assigned' }
}

class OrderPickedUp is export does Event does ForDeliveryOrder {
    has Str $.courier-id is required;
    method status { 'picked-up' }
}

class OrderDelivered is export does Event does ForDeliveryOrder {
    has Str $.courier-id is required;
    has Rat() $.total is required;
    method status { 'delivered' }
}

class OrderCancelled is export does Event does ForDeliveryOrder {
    has Str $.reason is required;
    method status { 'cancelled' }
}
