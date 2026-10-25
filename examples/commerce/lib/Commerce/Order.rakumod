use RedSourcing;
use Commerce::Utils;
use Commerce::Events;
use Commerce::Inventory;
unit aggregate Commerce::Order;

has Str $.order-id is entity-id;
has Str $.warehouse-id = '';
has Str $.email = '';
has Str $.address = '';
has Array $.items = [];
has Rat() $.total = 0.0;
has Str $.status is query = 'draft';
has Str $.payment-id = '';
has Str $.tracking-code = '';
has Str $.issue = '';

multi method APPLY(OrderSubmitted $e) {
    $!warehouse-id = $e.warehouse-id; $!email = $e.email; $!address = $e.address;
    $!items = $e.items; $!total = $e.total; $!status = 'submitted';
}
multi method APPLY(OrderPaid $e) { $!payment-id = $e.payment-id; $!status = 'paid' }
multi method APPLY(OrderDispatchAuthorized $) { $!status = 'dispatching' }
multi method APPLY(OrderShipped $e) { $!tracking-code = $e.tracking-code; $!status = 'shipped' }
multi method APPLY(OrderDelivered $) { $!status = 'delivered' }
multi method APPLY(CancellationRequested $e) { $!status = 'cancellation-requested'; $!issue = $e.reason }
multi method APPLY(OrderCancelled $e) { $!status = 'cancelled'; $!issue = $e.reason }
multi method APPLY(ReturnRequested $e) { $!status = 'return-requested'; $!issue = $e.reason }
multi method APPLY(ReturnReceived $) { $!status = 'return-received' }
multi method APPLY(ReturnCompleted $) { $!status = 'returned'; $!issue = '' }
multi method APPLY(ReturnRecoveryRequested $) { }
multi method APPLY(OrderIssueReported $e) { $!issue = $e.reason }
method !require(Str $status) { die "Order must be '$status', currently '$!status'" unless $!status eq $status }

method submit(Str :$warehouse-id!, Str :$email! where *.chars > 0,
              Str :$address! where *.chars > 0, :%items! where *.elems > 0) is command {
    self!require: 'draft';
    my @lines = %items.keys.sort.map: -> $sku {
        my $quantity = %items{$sku};
        die 'Quantities must be positive integers' unless $quantity ~~ UInt && $quantity > 0;
        my $proxy = Commerce::Inventory.^with-ids: :$warehouse-id, :$sku;
        die "Unknown product '$sku'" unless entity-exists($proxy);
        my $product = $proxy.^load;
        die "Unknown product '$sku'" unless $product.defined && $product.name.chars;
        %(sku => $sku, name => $product.name, unit-price => $product.unit-price.Rat, :$quantity)
    };
    my Rat $total = 5.00 + [+] @lines.map: { .<unit-price> * .<quantity> };
    self.order-submitted: :$warehouse-id, :$email, :$address, :items(@lines.Array), :$total;
    %(:$!order-id, :$total)
}
method confirm-payment(Str :$payment-id!, Rat() :$amount!) is command {
    if $!status eq 'paid' && $!payment-id eq $payment-id { return %(paid => True) }
    self!require('submitted'); die 'Payment amount does not match quote' unless $amount == $!total;
    self.order-paid: :$payment-id; %(paid => True)
}
# Both cancellation and dispatch authorization change this stream. They cannot
# both win an optimistic version check on the same paid order.
method authorize-dispatch is command {
    self!require: 'paid';
    require Commerce::Shipment;
    my $shipment = Commerce::Shipment.^with-ids(:$!order-id).^load;
    die 'Shipment must be booked first' unless $shipment.defined && $shipment.status eq 'booked';
    self.order-dispatch-authorized; %(authorized => True)
}
method mark-shipped(Str :$tracking-code!) is command {
    return %(shipped => True) if $!status eq 'shipped' && $!tracking-code eq $tracking-code;
    self!require: 'dispatching'; self.order-shipped: :$tracking-code; %(shipped => True)
}
method mark-delivered is command {
    return %(delivered => True) if $!status eq 'delivered';
    self!require: 'shipped'; self.order-delivered; %(delivered => True)
}
method request-cancellation(Str :$reason! where *.chars > 0) is command {
    return %(requested => True) if $!status eq 'cancellation-requested';
    self!require: 'paid'; self.cancellation-requested: :$reason; %(requested => True)
}
method cancel(Str :$reason! where *.chars > 0) is command {
    return %(cancelled => True) if $!status eq 'cancelled';
    die 'Only a submitted or cancellation-requested order can be cancelled'
        unless $!status eq any(<submitted cancellation-requested>);
    self.order-cancelled: :$reason; %(cancelled => True)
}
method request-return(Str :$reason! where *.chars > 0) is command {
    self!require: 'delivered'; self.return-requested: :$reason; %(requested => True)
}
method receive-return is command {
    return %(received => True) if $!status eq 'return-received';
    self!require: 'return-requested'; self.return-received; %(received => True)
}
method finish-return is command {
    return %(returned => True) if $!status eq 'returned';
    self!require: 'return-received'; self.return-completed; %(returned => True)
}
method resume-return is command { self!require: 'return-received'; self.return-recovery-requested; True }
method report-issue(Str :$reason!) is command { self.order-issue-reported: :$reason; %(reported => True) }
