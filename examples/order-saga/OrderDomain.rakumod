use RedSourcing;
unit module OrderDomain;

class OrderSubmitted does Event is export { has Str $.order-id; has Rat() $.amount; }
class StockReserved does Event is export { has Str $.order-id; }
class StockReleased does Event is export { has Str $.order-id; }

aggregate Inventory is export {
    has Str $.order-id is entity-id;
    has Bool $.reserved is query = False;
    multi method APPLY(StockReserved $) { $!reserved = True }
    multi method APPLY(StockReleased $) { $!reserved = False }
    method reserve is command {
        die 'Stock is already reserved' if $!reserved;
        self.stock-reserved;
        %(reservation-id => $.order-id, warehouse => 'main')
    }
    method release(Str :$reservation-id!) is command {
        die 'Wrong reservation' unless $reservation-id eq $.order-id;
        self.stock-released if $!reserved;
        %(released => True)
    }
}

saga OrderSaga is export {
    has Str $.order-id is entity-id;
    has Rat() $.amount = 0.0;
    has Bool $.paid = False;
    multi method APPLY(OrderSubmitted $event where { .order-id eq $!order-id }) {
        $!amount = $event.amount;
    }
    multi method APPLY(StepSucceeded $event where { .step eq 'charge-payment' }) { $!paid = True }
    multi method REACT(OrderSubmitted $event where { .order-id eq $!order-id }) {
        self.set-timeout('delivery-deadline', 15 * 60,
            expire => \(reason => 'Delivery deadline exceeded'));
        self.reserve-stock;
    }
    multi method REACT(StepSucceeded $event where { .step eq 'reserve-stock' }) { self.charge-payment }
    multi method REACT(StepFailed $event) { self.^compensate(:reason($event.error)) }
    method reserve-stock {
        self.^command(Inventory, 'reserve', \(), :retry{:3max,:2delay})
    }
    method compensate-reserve-stock(Str :$reservation-id!, |) {
        self.^command(Inventory, 'release', \(:$reservation-id), :retry{:5max,:10delay})
    }
    method charge-payment {
        self.^service('payments', 'charge', \(:order-id($.order-id), :amount($.amount)),
            :retry{:5max,:backoff(Exponential),:1init-delay,:30max-delay})
    }
    method compensate-charge-payment(Str :$payment-id!, |) {
        self.^service('payments', 'refund', \(:$payment-id), :retry{:5max,:10delay})
    }
    method expire(Str :$reason!) is command { self.^compensate(:$reason) }
}
