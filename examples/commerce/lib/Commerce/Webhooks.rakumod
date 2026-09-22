use RedSourcing;
use Commerce::Events;
unit module Commerce::Webhooks;

#| Delivers immutable order facts without coupling partner availability to purchase.
saga WebhookSaga is export {
    has Str $.order-id is entity-id;
    has Str $.endpoint = 'simulated://commerce';
    has UInt $.delivered = 0;
    has Array $.failures = [];
    multi method APPLY(StepSucceeded $e where { .step eq 'deliver-webhook' }) { $!delivered++ }
    multi method APPLY(StepFailed $e where { .step eq 'deliver-webhook' }) {
        $!failures.push(%(action-id => $e.action-id, error => $e.error));
    }
    multi method REACT(OrderSubmitted $e where { .order-id eq $!order-id }) { self.deliver-webhook($e) }
    multi method REACT(OrderPaid $e where { .order-id eq $!order-id }) { self.deliver-webhook($e) }
    multi method REACT(OrderShipped $e where { .order-id eq $!order-id }) { self.deliver-webhook($e) }
    multi method REACT(OrderDelivered $e where { .order-id eq $!order-id }) { self.deliver-webhook($e) }
    multi method REACT(OrderCancelled $e where { .order-id eq $!order-id }) { self.deliver-webhook($e) }
    multi method REACT(ReturnCompleted $e where { .order-id eq $!order-id }) { self.deliver-webhook($e) }
    multi method REACT(OrderIssueReported $e where { .order-id eq $!order-id }) { self.deliver-webhook($e) }
    multi method REACT(ShipmentIssueReported $e where { .order-id eq $!order-id }) { self.deliver-webhook($e) }
    method deliver-webhook(Event $event) {
        my $row = $event.StoredEvent;
        my %payload = event-id => $row.id, type => $row.class, stream => $row.stream,
            order-id => $.order-id, emitted-at => $event.emitted-at.Str, data => $row.data.Hash;
        self.^service('commerce-webhook', 'deliver', \(:order-id($.order-id), :endpoint($.endpoint), :%payload),
            :retry{:5max, :backoff(Exponential), :1init-delay, :30max-delay}, :!compensation);
    }
}
