use RedSourcing;
unit module Commerce::Events;

role ForStock { has Str $.warehouse-id is required; has Str $.sku is required; }
role ForOrder { has Str $.order-id is required; }

class ProductRegistered is export does Event does ForStock {
    has Str $.name is required; has Rat() $.unit-price is required;
}
class StockReceived is export does Event does ForStock {
    has UInt $.quantity is required; has Str $.reference is required; has UInt $.available is required;
}
class StockReserved is export does Event does ForStock {
    has UInt $.quantity is required; has Str $.order-id is required; has UInt $.available is required;
}
class StockReleased is export does Event does ForStock {
    has UInt $.quantity is required; has Str $.order-id is required; has UInt $.available is required;
}
class StockDispatched is export does Event does ForStock {
    has UInt $.quantity is required; has Str $.order-id is required; has UInt $.available is required;
}
class StockReturned is export does Event does ForStock {
    has UInt $.quantity is required; has Str $.order-id is required; has UInt $.available is required;
}
class ReplenishmentRequested is export does Event does ForStock { }
class OrderSubmitted is export does Event does ForOrder {
    has Str $.warehouse-id is required; has Str $.email is required; has Str $.address is required;
    has Array $.items is required; has Rat() $.total is required;
}
class OrderPaid is export does Event does ForOrder { has Str $.payment-id is required; }
class OrderDispatchAuthorized is export does Event does ForOrder { }
class OrderShipped is export does Event does ForOrder { has Str $.tracking-code is required; }
class OrderDelivered is export does Event does ForOrder { }
class CancellationRequested is export does Event does ForOrder { has Str $.reason is required; }
class OrderCancelled is export does Event does ForOrder { has Str $.reason is required; }
class ReturnRequested is export does Event does ForOrder { has Str $.reason is required; }
class ReturnReceived is export does Event does ForOrder { }
class ReturnCompleted is export does Event does ForOrder { }
class ReturnRecoveryRequested is export does Event does ForOrder { }
class OrderIssueReported is export does Event does ForOrder { has Str $.reason is required; }
class ShipmentBooked is export does Event does ForOrder {
    has Str $.booking-id is required; has Str $.tracking-code is required;
}
class ShipmentDispatched is export does Event does ForOrder {
    has Str $.warehouse-id is required; has Array $.items is required;
}
class ShipmentDelivered is export does Event does ForOrder { }
class ShipmentCancelled is export does Event does ForOrder { has Str $.reason is required; }
class ShippingRecoveryRequested is export does Event does ForOrder { }
class ShipmentIssueReported is export does Event does ForOrder { has Str $.reason is required; }

# The simulated providers persist requests/results and physical/payment facts.
class ProviderReceipt is export does Event {
    has Str $.provider is required; has Str $.operation is required;
    has Hash $.arguments is required; has Hash $.result is required;
}
class PaymentCaptured is export does Event does ForOrder {
    has Str $.payment-id is required; has Rat() $.amount is required;
}
class PaymentRefunded is export does Event does ForOrder {
    has Str $.payment-id is required; has Rat() $.amount is required;
}
class CarrierBookingCreated is export does Event does ForOrder { has Str $.booking-id is required; }
class CarrierBookingCancelled is export does Event does ForOrder { has Str $.booking-id is required; }
class NotificationSent is export does Event does ForOrder { has Str $.email is required; has Str $.message is required; }
class WebhookDelivered is export does Event does ForOrder {
    has Str $.delivery-id is required; has Str $.endpoint is required;
    has UInt $.source-id is required; has Hash $.payload is required; has UInt $.status is required;
}
class SupplierStockDelivered is export does Event does ForStock {
    has Str $.supply-id is required; has UInt $.quantity is required;
}
