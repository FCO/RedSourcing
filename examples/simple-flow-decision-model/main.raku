#!/usr/bin/env raku
use lib $?FILE.IO.parent.add('lib').Str;
use RedSourcing;
use DecisionFlow;

sub MAIN(Str :$database = ':memory:') {
    red-sourcing-defaults(:file($?FILE.IO.parent.add('red-sourcing.rakuconf')), :$database);
    my $order = Order.^with-ids: :order-id<demo-1>;
    $order.^create;
    my $view = OrderCard.^with-ids: :order-id<demo-1>;
    my $pending = $order.place: :item<Pizza>, :!sync;
    say "Command: {$pending.state}";
    say "Before run: {$order.status}";
    say 'Result: ' ~ $pending.run<status>;
    say "After run: {$order.status}";
    my %card = $view.info;
    say "Card: {%card<item>}: {%card<status>}";
    $pending.run;
    say 'Commands: ' ~ $order.^list-commands.elems;
    say 'Domain events: ' ~ StoredEvent.list-events(:types[OrderPlaced, OrderConfirmed]).elems;
    say 'Saga controls: ' ~ StoredEvent.^all.grep(*.mro.contains('|RedSourcing::Saga::Control|')).elems;
    $order.^load.^emit-snapshot;
    say 'After checkpoint: ' ~ $view.status;
}
