use RedSourcing;
use DeliveryEvents;

unit projection DeliveryTotals;

has UInt $.placed = 0;
has UInt $.delivered = 0;
has UInt $.cancelled = 0;
has Rat() $.delivered-value = 0.0;

method report {
    %(:$!placed, :$!delivered, :$!cancelled, :$!delivered-value,
        active => $!placed - $!delivered - $!cancelled)
}

multi method APPLY(OrderPlaced $event) { $!placed++ }
multi method APPLY(OrderDelivered $event) {
    $!delivered++;
    $!delivered-value += $event.total;
}
multi method APPLY(OrderCancelled $event) { $!cancelled++ }
