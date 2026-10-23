# From examples/simple-flow: raku -I../../lib -Ilib
# Paste each non-comment line into the REPL, in order.
use RedSourcing;
use SimpleFlow;
use RedSourcing::Flow;
red-sourcing-defaults(:database(%*ENV<REDSOURCING_EXAMPLE_DATABASE> // ':memory:'));

# Create the aggregate and saga snapshots before placing the order.
my $order = Order.^with-ids(:order-id<demo-1>);
$order.^create; say 'Order created';
my $workflow = Confirmation.^with-ids(:order-id<demo-1>);
$workflow.^create; say 'Saga created';
my $view = OrderCard.^with-ids(:order-id<demo-1>);
show-journal;

# Store a command without running its handler yet.
my $pending = $order.place(:item<Pizza>, :!sync);
say $pending.state;
say $order.^load.status;
show-journal;

# Run the command: now OrderPlaced exists, but no saga action has run.
say $pending.run<status>;
say $pending.state;
say $order.^load.status;
my $card = $view.^load; say "{$card.item}: {$card.status}";
show-journal;

# Read OrderPlaced and save the saga's decision, without executing it.
my $saga = $workflow.^advance(:limit(0)); show-actions($saga);
say $order.^list-commands.elems;
show-journal;

# Restore the decision from control events after the initial snapshot.
$saga = $workflow.^load; show-actions($saga);
say $order.^load.status;

# Run exactly one saga action: it calls Order.confirm and completes.
$saga = $workflow.^advance(:limit(1)); show-actions($saga);
say $order.^load.status;
say $card.status;
$card = $view.^load; say "{$card.item}: {$card.status}";
show-journal;

# Inspect exact causal IDs and independently reload the projection state.
my $action = $saga.^state<actions>[0];
say "E{$action<source-event-id>} -> confirm-order -> C{$action<row-id>}";
say flow-links(:source-kind<command>, :source($action<row-id>.Str)).map({ "C{.<source>} -> E{.<target>} ({.<relation>})" }).join("\n");
say 'Projection state: ' ~ $view.^load.status;

# Replay is read-only: a completed saga does not confirm the order twice.
$saga = $workflow.^load; show-actions($saga);
say $order.^list-commands.elems;
