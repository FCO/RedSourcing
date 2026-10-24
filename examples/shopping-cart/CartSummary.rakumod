use RedSourcing;
use CartEvents;

unit projection CartSummary;

has Str $.cart-id is entity-id;
has UInt $.lines = 0;
has UInt $.item-count = 0;
has Rat() $.total = 0.0;
has Bool $.checked-out = False;
has Str $.order-id = '';
has %.quantities;

method summary is query {
    %(:$!cart-id, :$!lines, :$!item-count, :$!total, :$!checked-out, :$!order-id)
}

multi method APPLY(ItemAdded $event where { .cart-id eq $!cart-id }) {
    $!lines++ unless %!quantities{$event.product-id}:exists;
    %!quantities{$event.product-id} += $event.quantity;
    $!item-count += $event.quantity;
    $!total += $event.unit-price * $event.quantity;
}

multi method APPLY(QuantityChanged $event where { .cart-id eq $!cart-id }) {
    %!quantities{$event.product-id} = $event.quantity;
    $!item-count = $!item-count - $event.previous-quantity + $event.quantity;
    $!total += $event.unit-price * ($event.quantity - $event.previous-quantity);
}

multi method APPLY(ItemRemoved $event where { .cart-id eq $!cart-id }) {
    %!quantities{$event.product-id}:delete;
    $!lines--;
    $!item-count -= $event.quantity;
    $!total -= $event.unit-price * $event.quantity;
}

multi method APPLY(CartCheckedOut $event where { .cart-id eq $!cart-id }) {
    $!checked-out = True;
    $!order-id = $event.order-id;
}
