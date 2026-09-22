use RedSourcing;
use CartEvents;

unit aggregate Cart;

has Str $.cart-id is entity-id;
has %.items;
has Rat() $.total = 0.0;
has Bool $.checked-out = False;
has Str $.order-id = '';

multi method APPLY(ItemAdded $_) {
    if %!items{.product-id}:exists {
        %!items{.product-id}<quantity> += .quantity;
    } else {
        %!items{.product-id} = %(
            product-id => .product-id, name => .name,
            unit-price => .unit-price, quantity => .quantity,
        );
    }
    $!total += .unit-price * .quantity;
}

multi method APPLY(QuantityChanged $_) {
    %!items{.product-id}<quantity> = .quantity;
    $!total += .unit-price * (.quantity - .previous-quantity);
}

multi method APPLY(ItemRemoved $_) {
    %!items{.product-id}:delete;
    $!total -= .unit-price * .quantity;
}

multi method APPLY(CartCheckedOut $_) {
    $!checked-out = True;
    $!order-id    = .order-id;
}

method !ensure-open {
    die "Cart '$!cart-id' has already been checked out" if $!checked-out;
}

method !item(Str $product-id --> Hash) {
    die "Product '$product-id' is not in cart '$!cart-id'"
        unless %!items{$product-id}:exists;
    %!items{$product-id}
}

method add-item(
    Str   :$product-id! where *.chars > 0,
    Str   :$name! where *.chars > 0,
    Rat() :$unit-price! where { $_ > 0 && ($_ * 100).denominator == 1 },
    UInt  :$quantity where * > 0 = 1,
) is command {
    self!ensure-open;
    if %!items{$product-id}:exists {
        my %item = self!item($product-id);
        die "Product '$product-id' already has a different name or price"
            unless %item<name> eq $name && %item<unit-price>.Rat == $unit-price;
    }
    self.item-added(
        :$product-id, :$name, :$unit-price, :$quantity,
    );
    %(product-id => $product-id, quantity => %!items{$product-id}<quantity>,
        total => $!total)
}

method set-quantity(
    Str :$product-id!, UInt :$quantity! where * > 0,
) is command {
    self!ensure-open;
    my %item = self!item($product-id);
    my $previous-quantity = %item<quantity>;
    my $unit-price = %item<unit-price>.Rat;
    # Setting an unchanged quantity is a successful command with no new event.
    if $quantity != $previous-quantity {
        self.quantity-changed(
            :$product-id, :$unit-price,
            :$previous-quantity, :$quantity,
        );
    }
    %(product-id => $product-id, :$quantity, total => $!total)
}

method remove-item(Str :$product-id!) is command {
    self!ensure-open;
    my %item = self!item($product-id);
    my $unit-price = %item<unit-price>.Rat;
    my $quantity = %item<quantity>;
    self.item-removed(
        :$product-id, :$unit-price, :$quantity,
    );
    $!total
}

method checkout is command {
    self!ensure-open;
    die "Cart '$!cart-id' is empty" unless %!items;
    my $order-id = "$!cart-id/{self.^version + 1}";
    my @items = %!items.keys.sort.map: {
        my %item = %!items{$_};
        %item<unit-price> = %item<unit-price>.Rat;
        %item
    };
    my $item-count = [+] @items.map(*.<quantity>);
    self.cart-checked-out(
        :$order-id, :total($!total), :$item-count, :@items,
    );
    %(:$order-id, :total($!total), :$item-count, :@items)
}
