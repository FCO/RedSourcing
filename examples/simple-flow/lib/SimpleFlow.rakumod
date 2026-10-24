use RedSourcing;
use JSON::Fast;
unit module SimpleFlow;

class OrderPlaced does Event is export {
    has Str $.order-id is required;
    has Str $.item is required;
}
class OrderConfirmed does Event is export {
    has Str $.order-id is required;
}

#| Accept an order and record its confirmation.
aggregate Order is export {
    has Str $.order-id is entity-id;
    has Str $.item = '';
    has Str $.status is query = 'new';

    multi method APPLY(OrderPlaced $event) {
        $!item = $event.item;
        $!status = 'placed';
    }
    multi method APPLY(OrderConfirmed $event) { $!status = 'confirmed' }

    #| Place this order exactly once.
    method place(Str :$item! where *.chars > 0) is command {
        die 'Order has already been placed' unless $!status eq 'new';
        self.order-placed(:$item);
        %(status => $!status)
    }
    #| Confirm a previously placed order.
    method confirm is command {
        die 'Order must be placed before confirmation' unless $!status eq 'placed';
        self.order-confirmed;
        %(status => $!status)
    }
}

#| A read model built from this order's facts in the shared journal.
projection OrderCard is export {
    has Str $.order-id is entity-id;
    has Str $.item = '';
    has Str $.status is query = 'new';

    multi method APPLY(OrderPlaced $event where { .order-id eqv $!order-id }) {
        $!item = $event.item;
        $!status = 'placed';
    }
    multi method APPLY(OrderConfirmed $event where { .order-id eqv $!order-id }) {
        $!status = 'confirmed';
    }
}

#| Confirm a placed order through a durable aggregate command.
saga Confirmation is export {
    has Str $.order-id is entity-id;
    has Bool $.confirmed = False;

    multi method REACT(OrderPlaced $event where { .order-id eqv $!order-id }) {
        self.confirm-order;
    }
    multi method APPLY(StepSucceeded $event where { .step eq 'confirm-order' }) {
        $!confirmed = True;
    }
    multi method REACT(StepSucceeded $event where { .step eq 'confirm-order' }) {
        self.^complete;
    }
    method confirm-order {
        self.^command(Order, 'confirm', \(), :!compensation);
    }
}

# Teaching helpers only: they read records without executing any work.
sub show-journal() is export {
    say 'COMMANDS';
    for StoredCommand.list-commands -> $row {
        say "C{$row.id} {$row.method} {$row.state} " ~ to-json($row.data, :!pretty);
    }
    say 'EVENTS (global ID, stream version, type, payload)';
    for StoredEvent.list-events(:row) -> $row {
        my $kind = $row.mro.contains('|Entity|') ?? 'snapshot'
            !! $row.mro.contains('|RedSourcing::Saga::Control|') ?? 'control' !! 'event';
        say "E{$row.id} v{$row.version} [$kind] {$row.class}";
        say '  ' ~ to-json($row.data, :!pretty) if $kind eq 'event';
    }
}
sub show-actions($saga) is export {
    say "Saga: {$saga.^status}; confirmed: {$saga.confirmed}";
    for $saga.^state<actions>.List -> %action {
        my $command = %action<row-id> ?? "C{%action<row-id>}" !! 'not submitted';
        say "{%action<step>}: {%action<status>}; attempts={%action<attempts>}; "
            ~ "source=E{%action<source-event-id>}; command=$command";
    }
}
