use RedSourcing;
use JSON::Fast;
unit module DecisionFlow;

class OrderPlaced does Event is export {
    has Str $.order-id is required;
    has Str $.item is required;
}
class OrderConfirmed does Event is export {
    has Str $.order-id is required;
}

projection OrderCard is export {
    has Str $.order-id is entity-id;
    has Str $.item = '';
    has Str $.status is query = 'new';
    method info is query { %(:$!order-id, :$!item, :$!status) }
    multi method APPLY(OrderPlaced $event where { .order-id eqv $!order-id }) {
        $!item = $event.item;
        $!status = 'placed';
    }
    multi method APPLY(OrderConfirmed $event where { .order-id eqv $!order-id }) {
        $!status = 'confirmed';
    }
}

# The original Confirmation saga only performed local work. Here the decision
# and both domain facts belong to one aggregate command/journal transaction.
aggregate Order is export {
    has Str $.order-id is entity-id;
    has Str $.item = '';
    has Str $.status is query = 'new';
    multi method APPLY(OrderPlaced $event) { $!item = $event.item; $!status = 'placed' }
    multi method APPLY(OrderConfirmed $event) { $!status = 'confirmed' }
    method place(Str :$item! where *.chars > 0) is command {
        die 'Order has already been placed' unless $!status eq 'new';
        self.order-placed: :$item;
        decision-model (OrderCard) => %(:$!order-id), -> $card {
            die 'Decision expected this placed order'
                unless $card.status eq 'placed' && $card.item eq $item;
            self.order-confirmed;
            %(status => $!status)
        }
    }
}

# Read-only teaching helper: normal StoredCommand records remain, but there
# are no saga snapshots, native saga controls, action IDs or child commands.
sub show-journal() is export {
    say 'COMMANDS';
    for StoredCommand.list-commands -> $row {
        say "C{$row.id} {$row.method} {$row.state}";
    }
    say 'EVENTS';
    for StoredEvent.list-events(:row) -> $row {
        my $kind = $row.mro.contains('|Entity|') ?? 'snapshot' !! 'event';
        say "E{$row.id} v{$row.version} [$kind] {$row.class}";
        say '  ' ~ to-json($row.data, :!pretty) if $kind eq 'event';
    }
}
