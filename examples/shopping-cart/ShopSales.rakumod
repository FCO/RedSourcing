use RedSourcing;
use CartEvents;

unit projection ShopSales;

has UInt $.orders = 0;
has UInt $.items-sold = 0;
has Rat() $.revenue = 0.0;

multi method APPLY(CartCheckedOut $event) {
    $!orders++;
    $!items-sold += $event.item-count;
    $!revenue += $event.total;
}
