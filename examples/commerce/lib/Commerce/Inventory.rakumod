use RedSourcing;
use Commerce::Events;
unit aggregate Commerce::Inventory;

has Str $.warehouse-id is entity-id;
has Str $.sku is entity-id;
has Str $.name = '';
has Rat() $.unit-price = 0.0;
has UInt $.on-hand = 0;
has Hash $.reservations = {};
has Hash $.dispatched = {};
has Hash $.returns = {};
has Hash $.receipts = {};

method available { $!on-hand - ([+] $!reservations.values) }
multi method APPLY(ProductRegistered $e) { $!name = $e.name; $!unit-price = $e.unit-price }
multi method APPLY(StockReceived $e) { $!on-hand += $e.quantity; $!receipts{$e.reference} = $e.quantity }
multi method APPLY(StockReserved $e) { $!reservations{$e.order-id} = $e.quantity }
multi method APPLY(StockReleased $e) { $!reservations{$e.order-id}:delete }
multi method APPLY(StockDispatched $e) {
    $!on-hand -= $e.quantity; $!reservations{$e.order-id}:delete; $!dispatched{$e.order-id} = $e.quantity;
}
multi method APPLY(StockReturned $e) { $!on-hand += $e.quantity; $!returns{$e.order-id} = $e.quantity }
multi method APPLY(ReplenishmentRequested $) { }

method register(Str :$name! where *.chars > 0,
                Rat() :$unit-price! where { $_ > 0 && ($_ * 100).denominator == 1 }) is command {
    die 'Product is already registered' if $!name.chars;
    self.product-registered(:$name, :$unit-price);
    %(:$!warehouse-id, :$!sku)
}
method receive(UInt :$quantity! where * > 0, Str :$reference! where *.chars > 0) is command {
    die 'Register the product first' unless $!name.chars;
    if $!receipts{$reference}:exists {
        die 'Receipt reference reused with different quantity' unless $!receipts{$reference} == $quantity;
    } else { self.stock-received(:$quantity, :$reference, :available(self.available + $quantity)) }
    %(:$!warehouse-id, :$!sku, :$quantity, :$reference, available => self.available)
}
method reserve(Str :$order-id!, UInt :$quantity! where * > 0) is command {
    die 'Order has already dispatched this stock' if $!dispatched{$order-id}:exists;
    if $!reservations{$order-id}:exists {
        die 'Reservation reused with different quantity' unless $!reservations{$order-id} == $quantity;
    } else {
        die Permanent.new(:message("Insufficient stock for '$!sku'")) if self.available < $quantity;
        self.stock-reserved(:$order-id, :$quantity, :available(self.available - $quantity));
    }
    %(:$!warehouse-id, :$!sku, :$order-id, :$quantity)
}
method release(Str :$order-id!) is command {
    require Commerce::Order;
    my $order = Commerce::Order.^with-ids(:$order-id).^load;
    die Permanent.new(:message('Dispatch-authorized reservations cannot be released'))
        if $order.defined && $order.status eq any(<dispatching shipped delivered return-requested return-received returned>);
    die 'Dispatched stock needs a physical return' if $!dispatched{$order-id}:exists;
    if $!reservations{$order-id}:exists {
        my $quantity = $!reservations{$order-id};
        self.stock-released(:$order-id, :$quantity, :available(self.available + $quantity));
    }
    %(released => True, :$order-id)
}
method dispatch(Str :$order-id!, UInt :$quantity! where * > 0) is command {
    if $!dispatched{$order-id}:exists {
        die 'Dispatch reused with different quantity' unless $!dispatched{$order-id} == $quantity;
    } else {
        require Commerce::Shipment;
        my $shipment = Commerce::Shipment.^with-ids(:$order-id).^load;
        die 'Physical handoff must be confirmed first' unless $shipment.defined && $shipment.status eq any(<dispatched delivered>);
        die 'Missing or mismatched reservation' unless $!reservations{$order-id}:exists
            && $!reservations{$order-id} == $quantity;
        self.stock-dispatched(:$order-id, :$quantity, :available(self.available));
    }
    %(:$order-id, :$!sku, :$quantity)
}
method restock-return(Str :$order-id!, UInt :$quantity! where * > 0) is command {
    require Commerce::Order;
    my $order = Commerce::Order.^with-ids(:$order-id).^load;
    die 'Warehouse must acknowledge the returned goods first' unless $order.defined && $order.status eq any(<return-received returned>);
    die 'Return does not match dispatched goods' unless $!dispatched{$order-id}:exists
        && $!dispatched{$order-id} == $quantity;
    if $!returns{$order-id}:exists {
        die 'Return reused with different quantity' unless $!returns{$order-id} == $quantity;
    } else { self.stock-returned(:$order-id, :$quantity, :available(self.available + $quantity)) }
    %(restocked => True, :$order-id, :$!sku)
}
method request-replenishment is command { self.replenishment-requested; True }
