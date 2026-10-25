use RedSourcing;
use Commerce::Events;
use Commerce::Order;
use Commerce::Inventory;
unit aggregate Commerce::Shipment;

has Str $.order-id is entity-id;
has Str $.status is query = 'new';
has Str $.booking-id = '';
has Str $.tracking-code = '';
has Str $.issue = '';
multi method APPLY(ShipmentBooked $e) { $!status = 'booked'; $!booking-id = $e.booking-id; $!tracking-code = $e.tracking-code }
multi method APPLY(ShipmentDispatched $) { $!status = 'dispatched' }
multi method APPLY(ShipmentDelivered $) { $!status = 'delivered' }
multi method APPLY(ShipmentCancelled $e) { $!status = 'cancelled'; $!issue = $e.reason }
multi method APPLY(ShipmentIssueReported $e) { $!issue = $e.reason }
multi method APPLY(ShippingRecoveryRequested $) { }
method book(Str :$booking-id!, Str :$tracking-code!) is command {
    if $!status eq 'booked' && $!booking-id eq $booking-id { return %(booked => True) }
    die 'Shipment cannot be booked in this state' unless $!status eq 'new';
    self.shipment-booked: :$booking-id, :$tracking-code; %(booked => True)
}
method dispatch is command {
    return %(dispatched => True) if $!status eq any(<dispatched delivered>);
    die 'Shipment must be booked' unless $!status eq 'booked';
    my $order = Commerce::Order.^with-ids(:$!order-id).^load;
    die 'Order has not authorized dispatch' unless $order.status eq 'dispatching';
    for $order.items.List -> %line {
        my $stock = Commerce::Inventory.^with-ids(:warehouse-id($order.warehouse-id), :sku(%line<sku>)).^load;
        die 'Goods are not reserved' unless ($stock.reservations{$!order-id}:exists)
            && $stock.reservations{$!order-id} == %line<quantity>;
    }
    # In this simulation the warehouse confirms the physical carrier handoff.
    self.shipment-dispatched: :warehouse-id($order.warehouse-id), :items($order.items); %(dispatched => True)
}
method deliver is command {
    return %(delivered => True) if $!status eq 'delivered';
    die 'Only dispatched shipments can be delivered' unless $!status eq 'dispatched';
    self.shipment-delivered; %(delivered => True)
}
method cancel(Str :$reason!) is command {
    return %(cancelled => True) if $!status eq 'cancelled';
    die 'Physical dispatch cannot be undone' unless $!status eq any(<new booked>);
    self.shipment-cancelled: :$reason; %(cancelled => True)
}
method report-issue(Str :$reason!) is command { self.shipment-issue-reported: :$reason; %(reported => True) }
method resume-processing is command {
    die 'Only dispatched shipments can resume processing' unless $!status eq any(<dispatched delivered>);
    self.shipping-recovery-requested; True
}
