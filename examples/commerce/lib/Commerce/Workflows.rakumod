use RedSourcing;
use Commerce::Events;
use Commerce::Inventory;
use Commerce::Order;
use Commerce::Shipment;
unit module Commerce::Workflows;

sub unsettled($saga) { so $saga.^state<actions>.first: { .<status> eq any(<pending running retry blocked>) } }
sub order(Str $order-id) { Commerce::Order.^with-ids(:$order-id).^load }
sub stock(Str $warehouse-id, Str $sku) { Commerce::Inventory.^with-ids: :$warehouse-id, :$sku }
sub remaining($saga, DateTime $emitted, Numeric $seconds) { ($emitted.Instant.Num + $seconds - $saga.^now.Instant.Num) max 0 }

#| Reserves each product, captures payment, and confirms the paid order.
saga PurchaseSaga is export {
    has Str $.order-id is entity-id;
    has Str $.warehouse-id = ''; has Array $.items = []; has Rat() $.total = 0.0;
    has UInt $.index = 0; has Str $.payment-id = '';
    multi method APPLY(OrderSubmitted $e where { .order-id eq $!order-id }) {
        $!warehouse-id = $e.warehouse-id; $!items = $e.items; $!total = $e.total;
    }
    multi method APPLY(StepSucceeded $e where { .step eq 'reserve-next' }) { $!index++ }
    multi method APPLY(StepSucceeded $e where { .step eq 'charge-payment' }) { $!payment-id = $e.result<payment-id> }
    multi method REACT(OrderSubmitted $e where { .order-id eq $!order-id }) {
        self.set-timeout: 'purchase-deadline', remaining(self, $e.emitted-at, 15 * 60), expire => \();
        self.reserve-next;
    }
    multi method REACT(StepSucceeded $e where { .step eq 'reserve-next' }) {
        $.index < $.items.elems ?? self.reserve-next !! self.charge-payment;
    }
    multi method REACT(StepSucceeded $e where { .step eq 'charge-payment' }) {
        self.confirm-payment;
    }
    multi method REACT(OrderPaid $e where { .order-id eq $!order-id }) { self.cancel-timeout: 'purchase-deadline' }
    multi method REACT(StepSucceeded $e where { .step eq 'confirm-payment' }) { self.^complete }
    multi method REACT(StepFailed $e) { self.^compensate: :reason($e.error) }
    method reserve-next {
        my %line = $.items[$.index];
        stock($.warehouse-id, %line<sku>).reserve:
            :$.order-id, :quantity(%line<quantity>),
            :service-retry{:3max, :2delay};
    }
    method compensate-reserve-next(Str :$warehouse-id!, Str :$sku!, Str :$order-id!, |) {
        stock($warehouse-id, $sku).release: :$order-id, :service-retry{:5max, :2delay};
    }
    method confirm-payment {
        Commerce::Order.^with-ids(:$.order-id).confirm-payment:
            :$.payment-id, :amount($.total),
            :!service-compensation;
    }
    method charge-payment {
        self.^service: 'commerce-payments', 'charge', \(:$.order-id, :amount($.total)),
            :retry{:3max, :backoff(Exponential), :1init-delay, :4max-delay};
    }
    method compensate-charge-payment(Str :$payment-id!, |) {
        self.^service: 'commerce-payments', 'refund', \(:$payment-id), :retry{:5max, :2delay};
    }
    method expire { self.^compensate: :reason('Purchase deadline exceeded') }
}

#| Books a carrier and waits for warehouse authorization before physical handoff.
saga FulfillmentSaga is export {
    has Str $.order-id is entity-id;
    has Str $.booking-id = ''; has Str $.tracking-code = ''; has Bool $.authorized = False;
    multi method APPLY(StepSucceeded $e where { .step eq 'book-carrier' }) {
        $!booking-id = $e.result<booking-id>; $!tracking-code = $e.result<tracking-code>;
    }
    multi method APPLY(OrderDispatchAuthorized $e where { .order-id eq $!order-id }) { $!authorized = True }
    multi method REACT(OrderPaid $e where { .order-id eq $!order-id }) { self.book-carrier }
    multi method REACT(StepSucceeded $e where { .step eq 'book-carrier' }) {
        self.book-shipment;
    }
    multi method REACT(ShipmentBooked $e where { .order-id eq $!order-id }) {
        self.set-timeout: 'warehouse-handoff', remaining(self, $e.emitted-at, 86400), expire => \() unless $.authorized;
    }
    multi method REACT(OrderDispatchAuthorized $e where { .order-id eq $!order-id }) {
        self.cancel-timeout: 'warehouse-handoff';
        self.dispatch-shipment;
    }
    multi method REACT(StepSucceeded $e where { .step eq 'dispatch-shipment' }) { self.^complete }
    multi method REACT(CancellationRequested $e where { .order-id eq $!order-id }) { self.^compensate: :reason($e.reason) }
    multi method REACT(OrderCancelled $e where { .order-id eq $!order-id }) { self.^complete unless unsettled(self) }
    multi method REACT(StepFailed $e) {
        if $.authorized {
            self.report-issue: :reason($e.error)
                unless $e.step eq 'report-issue';
        } else { self.^compensate: :reason($e.error) }
    }
    method book-shipment {
        Commerce::Shipment.^with-ids(:$.order-id).book:
            :$.booking-id, :$.tracking-code,
            :!service-compensation;
    }
    method dispatch-shipment {
        Commerce::Shipment.^with-ids(:$.order-id).dispatch:
            :service-retry{:3max, :2delay},
            :!service-compensation;
    }
    method report-issue(Str :$reason!) {
        Commerce::Shipment.^with-ids(:$.order-id).report-issue:
            :$reason,
            :!service-compensation;
    }
    method book-carrier {
        my $order = order($.order-id);
        self.^service: 'commerce-carrier', 'book', \(:$.order-id, :address($order.address)),
            :retry{:3max, :2delay};
    }
    method compensate-book-carrier(Str :$booking-id!, |) {
        self.^service: 'commerce-carrier', 'cancel', \(:$.order-id, :$booking-id), :retry{:5max, :2delay};
    }
    method expire { self.^compensate: :reason('Warehouse handoff deadline exceeded') }
}

#| Records stock movements and delivery after the physical handoff; no rollback of shipped goods.
saga ShippingSaga is export {
    has Str $.order-id is entity-id;
    has Str $.warehouse-id = ''; has Array $.items = []; has UInt $.index = 0;
    has Bool $.shipped = False; has Bool $.delivered = False;
    multi method APPLY(ShipmentDispatched $e where { .order-id eq $!order-id }) {
        $!warehouse-id = $e.warehouse-id; $!items = $e.items;
    }
    multi method APPLY(ShipmentDelivered $e where { .order-id eq $!order-id }) { $!delivered = True }
    multi method APPLY(StepSucceeded $e where { .step eq 'consume-next' }) { $!index++ }
    multi method APPLY(StepSucceeded $e where { .step eq 'mark-shipped' }) { $!shipped = True }
    multi method REACT(ShipmentDispatched $e where { .order-id eq $!order-id }) { self.resume }
    multi method REACT(ShippingRecoveryRequested $e where { .order-id eq $!order-id }) { self.resume }
    multi method REACT(StepSucceeded $e where { .step eq 'consume-next' }) { self.resume }
    multi method REACT(StepSucceeded $e where { .step eq 'mark-shipped' }) {
        self.set-timeout: 'delivery-deadline', 3 * 86400, overdue => \() unless $.delivered;
        self.resume;
    }
    multi method REACT(ShipmentDelivered $e where { .order-id eq $!order-id }) {
        self.cancel-timeout: 'delivery-deadline'; self.resume;
    }
    multi method REACT(StepSucceeded $e where { .step eq 'mark-delivered' }) { self.^complete }
    multi method REACT(OrderCancelled $e where { .order-id eq $!order-id }) { self.^complete }
    multi method REACT(StepFailed $e) {
        self.report-issue: :reason($e.error)
            unless $e.step eq 'report-issue';
    }
    method resume {
        return if unsettled(self);
        if $.index < $.items.elems { self.consume-next }
        elsif !$.shipped { self.mark-shipped }
        elsif $.delivered { self.mark-delivered }
    }
    method consume-next {
        my %line = $.items[$.index];
        stock($.warehouse-id, %line<sku>).dispatch:
            :$.order-id, :quantity(%line<quantity>),
            :service-retry{:3max, :2delay},
            :!service-compensation;
    }
    method mark-shipped {
        my $shipment = Commerce::Shipment.^with-ids(:$.order-id).^load;
        Commerce::Order.^with-ids(:$.order-id).mark-shipped:
            :tracking-code($shipment.tracking-code),
            :!service-compensation;
    }
    method mark-delivered {
        Commerce::Order.^with-ids(:$.order-id).mark-delivered: :!service-compensation;
    }
    method report-issue(Str :$reason!) {
        Commerce::Shipment.^with-ids(:$.order-id).report-issue:
            :$reason,
            :!service-compensation;
    }
    method overdue {
        self.report-issue: :reason('Delivery deadline exceeded; investigate with carrier');
    }
}

#| Refunds a paid cancellation after the carrier booking has been cancelled.
saga CancellationSaga is export {
    has Str $.order-id is entity-id;
    has Bool $.requested = False; has Bool $.shipment-cancelled = False;
    has Bool $.refunded = False; has UInt $.index = 0;
    multi method APPLY(CancellationRequested $e where { .order-id eq $!order-id }) { $!requested = True }
    multi method APPLY(ShipmentCancelled $e where { .order-id eq $!order-id }) { $!shipment-cancelled = True }
    multi method APPLY(StepSucceeded $e where { .step eq 'refund' }) { $!refunded = True }
    multi method APPLY(StepSucceeded $e where { .step eq 'release-next' }) { $!index++ }
    multi method REACT(CancellationRequested $e where { .order-id eq $!order-id }) { self.resume }
    multi method REACT(ShipmentCancelled $e where { .order-id eq $!order-id }) { self.resume }
    multi method REACT(StepSucceeded $e where { .step eq 'refund' }) { self.resume }
    multi method REACT(StepSucceeded $e where { .step eq 'release-next' }) { self.resume }
    multi method REACT(StepSucceeded $e where { .step eq 'cancel-order' }) { self.^complete }
    multi method REACT(OrderCancelled $e where { .order-id eq $!order-id }) { self.^complete unless unsettled(self) }
    method resume {
        return unless $.requested && $.shipment-cancelled;
        return if unsettled(self);
        if !$.refunded { self.refund }
        elsif $.index < order($.order-id).items.elems { self.release-next }
        else { self.cancel-order }
    }
    method refund {
        self.^service: 'commerce-payments', 'refund', \(:payment-id(order($.order-id).payment-id)),
            :retry{:5max, :2delay}, :!compensation;
    }
    method release-next {
        my $order = order($.order-id); my %line = $order.items[$.index];
        stock($order.warehouse-id, %line<sku>).release:
            :$.order-id,
            :service-retry{:5max, :2delay},
            :!service-compensation;
    }
    method cancel-order {
        Commerce::Order.^with-ids(:$.order-id).cancel:
            :reason(order($.order-id).issue),
            :!service-compensation;
    }
}

#| Restocks a physically received full-order return, then refunds and records completion.
saga ReturnSaga is export {
    has Str $.order-id is entity-id;
    has Bool $.label-ready = False; has Bool $.received = False; has UInt $.index = 0;
    has Bool $.refunded = False;
    multi method APPLY(ReturnReceived $e where { .order-id eq $!order-id }) { $!received = True }
    multi method APPLY(StepSucceeded $e where { .step eq 'return-label' }) { $!label-ready = True }
    multi method APPLY(StepSucceeded $e where { .step eq 'restock-next' }) { $!index++ }
    multi method APPLY(StepSucceeded $e where { .step eq 'refund-return' }) { $!refunded = True }
    multi method REACT(ReturnRequested $e where { .order-id eq $!order-id }) {
        self.return-label;
        self.set-timeout: 'return-deadline', remaining(self, $e.emitted-at, 14 * 86400), overdue => \();
    }
    multi method REACT(ReturnReceived $e where { .order-id eq $!order-id }) { self.cancel-timeout: 'return-deadline'; self.resume }
    multi method REACT(ReturnRecoveryRequested $e where { .order-id eq $!order-id }) { self.resume }
    multi method REACT(StepSucceeded $e where { .step eq 'return-label' }) { self.resume }
    multi method REACT(StepSucceeded $e where { .step eq 'restock-next' }) { self.resume }
    multi method REACT(StepSucceeded $e where { .step eq 'refund-return' }) { self.resume }
    multi method REACT(StepSucceeded $e where { .step eq 'finish-return' }) { self.^complete }
    multi method REACT(StepFailed $e) {
        self.report-issue: :reason($e.error) unless $e.step eq 'report-issue';
    }
    multi method REACT(OrderCancelled $e where { .order-id eq $!order-id }) { self.^complete }
    method resume {
        return unless $.received && $.label-ready;
        return if unsettled(self);
        if $.index < order($.order-id).items.elems { self.restock-next }
        elsif !$.refunded { self.refund-return }
        else { self.finish-return }
    }
    method restock-next {
        my $order = order($.order-id); my %line = $order.items[$.index];
        stock($order.warehouse-id, %line<sku>).restock-return:
            :$.order-id, :quantity(%line<quantity>),
            :service-retry{:3max, :2delay},
            :!service-compensation;
    }
    method refund-return {
        self.^service: 'commerce-payments', 'refund', \(:payment-id(order($.order-id).payment-id)), :retry{:5max, :2delay}, :!compensation;
    }
    method return-label {
        self.^service: 'commerce-carrier', 'return-label', \(:$.order-id), :retry{:3max, :2delay}, :!compensation;
    }
    method finish-return {
        Commerce::Order.^with-ids(:$.order-id).finish-return: :!service-compensation;
    }
    method report-issue(Str :$reason!) {
        Commerce::Order.^with-ids(:$.order-id).report-issue: :$reason, :!service-compensation;
    }
    method overdue {
        self.report-issue: :reason('Return has not reached the warehouse');
    }
}

#| Orders simulated supplier stock when available units fall below the threshold.
saga ReplenishmentSaga is export {
    has Str $.warehouse-id is entity-id; has Str $.sku is entity-id;
    has UInt $.threshold = 2; has UInt $.target = 12; has UInt $.available = 0;
    multi method APPLY(StockReceived $e where { .warehouse-id eq $!warehouse-id && .sku eq $!sku }) { $!available = $e.available }
    multi method APPLY(StockReserved $e where { .warehouse-id eq $!warehouse-id && .sku eq $!sku }) { $!available = $e.available }
    multi method APPLY(StockReleased $e where { .warehouse-id eq $!warehouse-id && .sku eq $!sku }) { $!available = $e.available }
    multi method APPLY(StockDispatched $e where { .warehouse-id eq $!warehouse-id && .sku eq $!sku }) { $!available = $e.available }
    multi method APPLY(StockReturned $e where { .warehouse-id eq $!warehouse-id && .sku eq $!sku }) { $!available = $e.available }
    multi method APPLY(StepSucceeded $e where { .step eq 'receive-stock' }) { $!available = $e.result<available> }
    multi method REACT(StockReceived $e where { .warehouse-id eq $!warehouse-id && .sku eq $!sku }) { self.reorder }
    multi method REACT(StockReserved $e where { .warehouse-id eq $!warehouse-id && .sku eq $!sku }) { self.reorder }
    multi method REACT(StockDispatched $e where { .warehouse-id eq $!warehouse-id && .sku eq $!sku }) { self.reorder }
    multi method REACT(ReplenishmentRequested $e where { .warehouse-id eq $!warehouse-id && .sku eq $!sku }) { self.reorder }
    multi method REACT(StepSucceeded $e where { .step eq 'order-stock' }) {
        self.receive-stock: :reference($e.result<supply-id>), :quantity($e.result<quantity>);
    }
    method reorder {
        die 'Replenishment target must exceed threshold' unless $.target > $.threshold;
        return if $.available >= $.threshold || unsettled(self);
        self.order-stock;
    }
    method order-stock {
        self.^service: 'commerce-supplier', 'deliver', \(:$.warehouse-id, :$.sku, :quantity($.target - $.available)),
            :retry{:3max, :10delay}, :!compensation;
    }
    method receive-stock(Str :$reference!, UInt :$quantity!) {
        Commerce::Inventory.^with-ids(:$.warehouse-id, :$.sku).receive:
            :$reference, :$quantity,
            :service-retry{:5max, :2delay},
            :!service-compensation;
    }
}

#| Sends order updates independently so notification failures do not undo purchases.
saga NotificationSaga is export {
    has Str $.order-id is entity-id;
    has UInt $.sent = 0;
    multi method APPLY(StepSucceeded $e where { .step eq 'notify' }) { $!sent++ }
    multi method REACT(OrderSubmitted $e where { .order-id eq $!order-id }) { self.notify: :message('Order received') }
    multi method REACT(OrderPaid $e where { .order-id eq $!order-id }) { self.notify: :message('Payment confirmed') }
    multi method REACT(OrderShipped $e where { .order-id eq $!order-id }) { self.notify: :message('Order shipped') }
    multi method REACT(OrderDelivered $e where { .order-id eq $!order-id }) { self.notify: :message('Order delivered') }
    multi method REACT(OrderCancelled $e where { .order-id eq $!order-id }) { self.notify: :message('Order cancelled') }
    multi method REACT(ReturnCompleted $e where { .order-id eq $!order-id }) { self.notify: :message('Return refunded') }
    multi method REACT(OrderIssueReported $e where { .order-id eq $!order-id }) { self.notify: :message($e.reason) }
    multi method REACT(ShipmentIssueReported $e where { .order-id eq $!order-id }) { self.notify: :message($e.reason) }
    method notify(Str :$message!) {
        self.^service: 'commerce-email', 'send', \(:$.order-id, :email(order($.order-id).email), :$message),
            :retry{:3max, :5delay}, :!compensation;
    }
}
