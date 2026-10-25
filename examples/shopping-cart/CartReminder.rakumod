use RedSourcing;
use Cart;
use CartEvents;

unit module CartReminder;

# A durable stand-in for an email provider. No actual email is sent.
class ReminderEmailSent is export does Event {
    has Str $.cart-id is required;
    has Str $.email is required;
    has UInt $.activity-id is required;
    has Str $.message-id is required;
    has Str $.subject = 'You left something in your cart';
}

sub register-cart-reminder-email is export {
    register-service 'cart-reminder-email', sub (Str $operation, Capture $arguments,
                                               Str :$idempotency-key!) {
        die Permanent.new: :message("Unknown email operation '$operation'")
            unless $operation eq 'send';
        my %args = $arguments.hash;
        my $stream = "ShoppingCartEmail: $idempotency-key";
        my $receipt = StoredEvent.list-events(:types[ReminderEmailSent], :$stream).head;
        if $receipt {
            die Permanent.new: :message('Email idempotency key reused with different arguments')
                unless $receipt.cart-id eq %args<cart-id> && $receipt.email eq %args<email>
                    && $receipt.activity-id == %args<activity-id>;
            return %(sent => True, message-id => $receipt.message-id);
        }
        # Recheck at delivery time: checkout/new activity can arrive after the
        # timer queued an action, including while a provider retry was waiting.
        my $proxy = Cart.^with-ids: :cart-id(%args<cart-id>);
        my $cart = $proxy.^load;
        return %(sent => False, reason => 'Cart is closed or empty')
            unless $cart.defined && !$cart.checked-out && $cart.items;
        my $last = StoredEvent.list-events(:row, :stream($proxy.^stream-name),
            :types[ItemAdded, QuantityChanged, ItemRemoved]).tail;
        return %(sent => False, reason => 'Cart activity changed')
            unless $last && $last.id == %args<activity-id>;
        ReminderEmailSent.emit: :$stream, :version(1),
            :cart-id(%args<cart-id>), :email(%args<email>),
            :activity-id(%args<activity-id>), :message-id($idempotency-key),
            :subject('You left something in your cart');
        %(sent => True, message-id => $idempotency-key)
    }
}

#| Sends one reminder after a nonempty, open cart has been inactive for 24 hours.
saga AbandonedCartReminder is export {
    has Str $.cart-id is entity-id;
    has Str $.email is required;
    has UInt $.item-count = 0;
    has Numeric $.last-activity = 0;
    has UInt $.activity-id = 0;
    has Bool $.checked-out = False;
    has Bool $.reminded = False;
    has Str $.message-id = '';

    multi method APPLY(ItemAdded $event where { .cart-id eq $!cart-id }) {
        $!item-count += $event.quantity;
        $!last-activity = $event.emitted-at.Instant.Num;
        $!activity-id = $event.StoredEvent.id;
    }
    multi method APPLY(QuantityChanged $event where { .cart-id eq $!cart-id }) {
        $!item-count += $event.quantity - $event.previous-quantity;
        $!last-activity = $event.emitted-at.Instant.Num;
        $!activity-id = $event.StoredEvent.id;
    }
    multi method APPLY(ItemRemoved $event where { .cart-id eq $!cart-id }) {
        $!item-count -= $event.quantity;
        $!last-activity = $event.emitted-at.Instant.Num;
        $!activity-id = $event.StoredEvent.id;
    }
    multi method APPLY(CartCheckedOut $event where { .cart-id eq $!cart-id }) {
        $!checked-out = True;
    }
    # Native controls are already scoped to this saga's own stream.
    multi method APPLY(StepSucceeded $event where { .step eq 'send-reminder' }) {
        if $event.result<sent> {
            $!reminded = True;
            $!message-id = $event.result<message-id>;
        }
    }
    multi method REACT(ItemAdded $event where { .cart-id eq $!cart-id }) { self.schedule-reminder }
    multi method REACT(QuantityChanged $event where { .cart-id eq $!cart-id }) { self.schedule-reminder }
    multi method REACT(ItemRemoved $event where { .cart-id eq $!cart-id }) { self.schedule-reminder }
    multi method REACT(CartCheckedOut $event where { .cart-id eq $!cart-id }) {
        self.cancel-timeout: 'abandoned-cart';
        self.^complete unless self!has-unsettled-email;
    }
    multi method REACT(StepSucceeded $event where { .step eq 'send-reminder' }) {
        if $.reminded || $.checked-out {
            self.^complete;
        } else {
            # A stale queued reminder was skipped. Use the most recent activity.
            self.schedule-reminder;
        }
    }
    multi method REACT(StepFailed $event where { .step eq 'send-reminder' }) {
        self.^compensate: :reason($event.error);
    }
    method !has-unsettled-email {
        so self.^state<actions>.first: { .<status> eq any(<pending running retry blocked>) }
    }
    method schedule-reminder {
        self.cancel-timeout: 'abandoned-cart';
        return if $.checked-out || $.reminded || !$.item-count || self!has-unsettled-email;
        # Anchor to journal time, so a late controller does not add another day.
        my $delay = ($.last-activity + 24 * 60 * 60 - self.^now.Instant.Num) max 0;
        self.set-timeout: 'abandoned-cart', $delay, send-reminder => \();
    }
    method send-reminder {
        return if $.checked-out || $.reminded || !$.item-count || self!has-unsettled-email;
        return self.schedule-reminder if self.^now.Instant.Num < $.last-activity + 24 * 60 * 60;
        self.^service: 'cart-reminder-email', 'send',
            \(:$.cart-id, :$.email, :$.activity-id),
            :retry{:3max, :300delay}, :!compensation;
    }
}

# Registration only installs adapter code; imports do not send messages or
# create tables. Every controller process must load this module.
register-cart-reminder-email;
