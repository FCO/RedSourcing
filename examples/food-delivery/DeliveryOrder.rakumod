use RedSourcing;
use DeliveryEvents;
use Restaurant;

unit aggregate DeliveryOrder;

has Str $.order-id is entity-id;
has Str $.restaurant-id = '';
has Str $.customer-id = '';
has Str $.address = '';
has Str $.status = 'new';
has Array $.items = [];
has Rat() $.subtotal = 0.0;
has Rat() $.delivery-fee = 0.0;
has Rat() $.total = 0.0;
has Str $.courier-id = '';
has Str $.cancellation-reason = '';

multi method APPLY(OrderPlaced $event) {
    $!restaurant-id = $event.restaurant-id;
    $!customer-id = $event.customer-id;
    $!address = $event.address;
    $!items = $event.items;
    $!subtotal = $event.subtotal;
    $!delivery-fee = $event.delivery-fee;
    $!total = $event.total;
    $!status = $event.status;
}

multi method APPLY(OrderAccepted $event) { $!status = $event.status }
multi method APPLY(OrderReady $event) { $!status = $event.status }

multi method APPLY(CourierAssigned $event) {
    $!courier-id = $event.courier-id;
    $!status = $event.status;
}

multi method APPLY(OrderPickedUp $event) { $!status = $event.status }
multi method APPLY(OrderDelivered $event) { $!status = $event.status }

multi method APPLY(OrderCancelled $event) {
    $!cancellation-reason = $event.reason;
    $!status = $event.status;
}

method !require-status(Str $expected) {
    die "Order '$!order-id' must be '$expected', but is '$!status'"
        unless $!status eq $expected;
}

method !require-courier(Str $courier-id) {
    die "Courier '$courier-id' is not assigned to order '$!order-id'"
        unless $courier-id eq $!courier-id;
}

method !event-ids { %(:$!restaurant-id, :$!customer-id) }

method place-order(
    Str :$restaurant-id! where *.chars > 0,
    Str :$customer-id! where *.chars > 0,
    Str :$address! where *.chars > 0,
    :%items! where *.elems > 0,
) is command {
    self!require-status('new');
    my $restaurant-proxy = Restaurant.^with-ids(:$restaurant-id);
    die "Restaurant '$restaurant-id' does not exist"
        unless StoredEvent.^all.grep({
            .class eq Restaurant.^name && .stream eq $restaurant-proxy.^stream-name
        }).head;
    my $restaurant = $restaurant-proxy.^load;
    die "Restaurant '$restaurant-id' is closed" unless $restaurant.open;

    # Resolve current names and prices on the server, before emitting any event.
    my @lines = %items.keys.sort.map: -> $item-id {
        my $quantity = %items{$item-id};
        die "Quantity for '$item-id' must be a positive integer"
            unless $quantity ~~ UInt && $quantity > 0;
        die "Item '$item-id' is not on the menu"
            unless $restaurant.menu{$item-id}:exists;
        my %item = $restaurant.menu{$item-id};
        die "Item '$item-id' is unavailable" unless %item<available>;
        %(item-id => $item-id, name => %item<name>,
            unit-price => %item<unit-price>.Rat, :$quantity)
    };
    my Rat $subtotal = [+] @lines.map({ .<unit-price> * .<quantity> });
    my Rat $delivery-fee = 2.50;
    my Rat $total = $subtotal + $delivery-fee;
    self.order-placed(:$restaurant-id, :$customer-id, :$address,
        :items(@lines), :$subtotal, :$delivery-fee, :$total);
    %(:$!order-id, :$!status, :$!subtotal, :$!delivery-fee, :$!total, :$!items)
}

method accept is command {
    self!require-status('placed');
    self.order-accepted(|self!event-ids);
    $!status
}

method mark-ready is command {
    self!require-status('accepted');
    self.order-ready(|self!event-ids);
    $!status
}

method assign-courier(Str :$courier-id! where *.chars > 0) is command {
    self!require-status('ready');
    self.courier-assigned(|self!event-ids, :$courier-id);
    $!status
}

method pick-up(Str :$courier-id! where *.chars > 0) is command {
    self!require-status('assigned');
    self!require-courier($courier-id);
    self.order-picked-up(|self!event-ids, :$courier-id);
    $!status
}

method deliver(Str :$courier-id! where *.chars > 0) is command {
    self!require-status('picked-up');
    self!require-courier($courier-id);
    self.order-delivered(|self!event-ids, :$courier-id, :total($!total));
    $!status
}

method cancel(Str :$reason! where *.chars > 0) is command {
    die "Order '$!order-id' cannot be cancelled while '$!status'"
        unless $!status eq any('placed', 'accepted');
    self.order-cancelled(|self!event-ids, :$reason);
    $!status
}
