use RedSourcing;
use JSON::Fast;
use Commerce::Events;
unit module Commerce::Providers;

# Faults apply before an effect, or after a durable receipt (lost acknowledgement).
my %faults;
sub provider-fault(Str $provider, Str $operation, Str :$kind = 'retryable', UInt :$times = 1) is export {
    die 'Unknown fault kind' unless $kind eq any(<retryable permanent uncertain>);
    %faults{"$provider/$operation"} = %(:$kind, left => $times);
}
sub clear-provider-faults is export { %faults = () }
sub facts(Mu:U $type, Str $stream) { StoredEvent.list-events(:types[$type], :$stream).Array }
sub persist(Mu:U $type, Str $stream, *%data) { $type.emit(:$stream, :version(1), |%data) }

sub register-commerce-providers is export {
    for <payments carrier supplier email webhook> -> $provider {
        register-service "commerce-$provider", sub (Str $operation, Capture $arguments, Str :$idempotency-key!) {
            my %args = from-json(to-json($arguments.hash.Hash));
            my $receipt-stream = "CommerceProviderReceipt: $idempotency-key";
            if facts(ProviderReceipt, $receipt-stream).head -> $receipt {
                die Permanent.new(:message('Idempotency key reused with different arguments'))
                    unless $receipt.provider eq $provider && $receipt.operation eq $operation && $receipt.arguments eqv %args;
                return $receipt.result;
            }
            my %fault := %faults{"$provider/$operation"} // {};
            my $fault = %fault<left> ?? %fault<kind> !! '';
            %fault<left>-- if %fault<left>;
            die Permanent.new(:message("$provider/$operation rejected")) if $fault eq 'permanent';
            die Retryable.new(:message("$provider/$operation temporarily unavailable")) if $fault eq 'retryable';
            my %result;
            my $order-id = %args<order-id> // '';
            # HTTP runs outside the receipt transaction. Receivers must deduplicate
            # the stable delivery ID if acceptance precedes a lost acknowledgement.
            my UInt $webhook-status = 200;
            my %webhook-payload;
            if $provider eq 'webhook' && $operation eq 'deliver' {
                %webhook-payload = |%args<payload>, delivery-id => $idempotency-key;
                unless %args<endpoint> eq 'simulated://commerce' {
                    require ::('Commerce::WebhookHTTP');
                    my &post-webhook = ::('Commerce::WebhookHTTP').WHO{'&post-webhook'};
                    $webhook-status = post-webhook(
                        %args<endpoint>, %webhook-payload, :$idempotency-key);
                }
            }
            red-do :transaction, {
            given "$provider/$operation" {
                when 'payments/charge' {
                    my $payment-id = "payment/$order-id";
                    my $stream = "CommercePayment: $order-id";
                    if facts(PaymentCaptured, $stream).head -> $payment {
                        die Permanent.new(:message('Order payment reused with another amount')) unless $payment.amount == %args<amount>;
                    } else { persist(PaymentCaptured, $stream, :$order-id, :$payment-id, :amount(%args<amount>.Rat)) }
                    %result = :$payment-id, amount => %args<amount>;
                }
                when 'payments/refund' {
                    my $payment-id = %args<payment-id>;
                    my $paid = StoredEvent.list-events(:types[PaymentCaptured]).first(*.payment-id eq $payment-id);
                    die Permanent.new(:message('Unknown payment')) unless $paid;
                    my $stream = "CommerceRefund: $payment-id";
                    persist(PaymentRefunded, $stream, :order-id($paid.order-id), :$payment-id, :amount($paid.amount))
                        unless facts(PaymentRefunded, $stream);
                    %result = refunded => True, :$payment-id, amount => $paid.amount;
                }
                when 'carrier/book' {
                    my $booking-id = "booking/$order-id";
                    my $stream = "CommerceBooking: $order-id";
                    persist(CarrierBookingCreated, $stream, :$order-id, :$booking-id) unless facts(CarrierBookingCreated, $stream);
                    %result = :$booking-id, tracking-code => "TRACK-$order-id";
                }
                when 'carrier/cancel' {
                    require ::('Commerce::Shipment');
                    my $shipment = ::('Commerce::Shipment').^with-ids(:$order-id).^load;
                    die Permanent.new(:message('Carrier handoff cannot be cancelled')) if $shipment.status eq any(<dispatched delivered>);
                    my $booking-id = %args<booking-id>;
                    my $stream = "CommerceBookingCancelled: $booking-id";
                    persist(CarrierBookingCancelled, $stream, :$order-id, :$booking-id) unless facts(CarrierBookingCancelled, $stream);
                    %result = cancelled => True;
                }
                when 'carrier/return-label' { %result = label-id => "return/$order-id" }
                when 'supplier/deliver' {
                    my $supply-id = "supply/$idempotency-key";
                    persist(SupplierStockDelivered, "CommerceSupply: $supply-id",
                        :warehouse-id(%args<warehouse-id>), :sku(%args<sku>),
                        :quantity(%args<quantity>), :$supply-id);
                    %result = :$supply-id, quantity => %args<quantity>;
                }
                when 'email/send' {
                    persist(NotificationSent, "CommerceEmail: $idempotency-key",
                        :$order-id, :email(%args<email>), :message(%args<message>));
                    %result = message-id => $idempotency-key;
                }
                when 'webhook/deliver' {
                    persist(WebhookDelivered, "CommerceWebhook: $idempotency-key",
                        :$order-id, :delivery-id($idempotency-key), :endpoint(%args<endpoint>),
                        :source-id(%args<payload><event-id>), :payload(%webhook-payload), :status($webhook-status));
                    %result = delivery-id => $idempotency-key, status => $webhook-status;
                }
                default { die Permanent.new(:message("Unknown provider operation $provider/$operation")) }
            }
            persist(ProviderReceipt, $receipt-stream, :$provider, :$operation, :arguments(%args), :result(%result));
            True
            }
            die Uncertain.new(:message("$provider/$operation acknowledgement lost")) if $fault eq 'uncertain';
            %result
        }
    }
}
# Module import registers code only; journal/provider effects run in the controller.
register-commerce-providers;
