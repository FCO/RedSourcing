use RedSourcing;
unit module CartEvents;

role ForCart {
    has Str $.cart-id is required;
}

class ItemAdded is export does Event does ForCart {
    has Str $.product-id is required;
    has Str $.name is required;
    has Rat() $.unit-price is required;
    has UInt $.quantity is required;
}

class QuantityChanged is export does Event does ForCart {
    has Str $.product-id is required;
    has Rat() $.unit-price is required;
    has UInt $.previous-quantity is required;
    has UInt $.quantity is required;
}

class ItemRemoved is export does Event does ForCart {
    has Str $.product-id is required;
    has Rat() $.unit-price is required;
    has UInt $.quantity is required;
}

class CartCheckedOut is export does Event does ForCart {
    has Str $.order-id is required;
    has Rat() $.total is required;
    has UInt $.item-count is required;
    has @.items is required;
}
