use RedSourcing;
use DeliveryEvents;

unit aggregate Restaurant;

has Str $.restaurant-id is entity-id;
has Str $.name is required;
has Bool $.open = False;
has %.menu;

multi method APPLY(MenuItemSet $event) {
    %!menu{$event.item-id} = %(
        item-id => $event.item-id, name => $event.name,
        unit-price => $event.unit-price, available => $event.available,
    );
}

multi method APPLY(RestaurantOpened $event) { $!open = True }
multi method APPLY(RestaurantClosed $event) { $!open = False }

method set-menu-item(
    Str :$item-id! where *.chars > 0,
    Str :$name! where *.chars > 0,
    Rat() :$unit-price! where { $_ > 0 && ($_ * 100).denominator == 1 },
    Bool :$available = True,
) is command {
    self.menu-item-set(:$item-id, :$name, :$unit-price, :$available);
    %!menu{$item-id}
}

method open-for-orders is command {
    die "Restaurant '$!restaurant-id' has no available menu items"
        unless %!menu.values.grep(*.<available>);
    self.restaurant-opened unless $!open;
    $!open
}

method close-for-orders is command {
    self.restaurant-closed if $!open;
    $!open
}
