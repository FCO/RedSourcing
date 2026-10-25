#!/usr/bin/env raku
use lib $?FILE.IO.parent.add('lib').Str;
use RedSourcing;
use Commerce::App;
use Commerce::Providers;
use Commerce::Workflows;
use Commerce::Events;

sub MAIN(Str :$database = ':memory:', Str :$webhook-url = %*ENV<COMMERCE_WEBHOOK_URL> // 'simulated://commerce') {
    red-sourcing-defaults(:file($?FILE.IO.parent.add('red-sourcing.rakuconf')), :$database);
    my $shop = Shop.new(:$webhook-url).initialize;
    unless StoredEvent.^all.head {
        $shop.product: 'coffee', :name<Coffee>, :price(12.50), :quantity(10);
        $shop.product: 'mug', :name<Mug>, :price(8.90), :quantity(10);
        my $clock = DateTime.now;
        $shop.purchase: 'delivered', :items{:coffee(2), :mug(1)};
        $shop.drain: :now($clock);
        $shop.order('delivered').authorize-dispatch;
        $shop.drain: :now($clock);
        $shop.shipment('delivered').deliver;
        $shop.drain: :now($clock);
        say "Delivered order: {$shop.order('delivered').status}";

        $shop.order('delivered').request-return: :reason('Changed my mind');
        $shop.drain: :now($clock);
        $shop.order('delivered').receive-return;
        $shop.drain: :now($clock);
        say "Returned order: {$shop.order('delivered').status}";

        $shop.purchase: 'cancelled', :items{:mug(1)};
        $shop.drain: :now($clock);
        $shop.order('cancelled').request-cancellation: :reason('Wrong address');
        $shop.drain: :now($clock);
        say "Cancelled order: {$shop.order('cancelled').status}";

        provider-fault('payments', 'charge', :kind<permanent>);
        $shop.purchase: 'declined', :items{:coffee(1)};
        $shop.drain: :now($clock);
        say "Declined order: {$shop.order('declined').status}";

        provider-fault('payments', 'charge', :kind<uncertain>);
        $shop.purchase: 'recovered', :items{:coffee(1)};
        $shop.drain: :now($clock);
        $shop.checkpoint;
        $shop = Shop.new(:$webhook-url).initialize;
        $shop.drain: :now($clock.later(:seconds(10)));
        say "Recovered purchase: {$shop.order('recovered').status}";

        # Reserve almost all coffee; its independent replenishment saga receives stock.
        $shop.purchase: 'large-order', :items{:coffee(9)};
        $shop.drain: :now($clock.later(:seconds(20)));
        $shop.checkpoint;
    }
    my $summary = $shop.summary;
    say "Orders: {$summary.orders.elems}; captured {$summary.captured}; refunded {$summary.refunded}";
    say "{.key}: {.value<status>}" for $summary.orders.sort: *.key;
    say "Notifications for delivered: {$shop.notifications('delivered').messages.elems}";
    say "Webhook deliveries: {StoredEvent.list-events(:types[WebhookDelivered]).elems}";
    say "Payment, shipping and email providers are simulated. Webhook endpoint: $webhook-url";
}
