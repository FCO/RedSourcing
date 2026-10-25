# From examples/simple-flow-decision-model: raku -I../../lib -Ilib
# Paste each non-comment line into the REPL, in order.
use RedSourcing;
use DecisionFlow;
red-sourcing-defaults(:database(%*ENV<REDSOURCING_EXAMPLE_DATABASE> // ':memory:'));
my $order = Order.^with-ids: :order-id<demo-1>;
$order.^create;
my $view = OrderCard.^with-ids: :order-id<demo-1>;
my $pending = $order.place: :item<Pizza>, :!sync;
say $pending.state;
say $order.status;
show-journal;
# Both domain facts commit when this single command succeeds.
say $pending.run<status>;
say $order.status;
say $view.info;
show-journal;
# Re-running a completed command returns its saved result.
say $pending.run<status>;
say $order.^list-commands.elems;
# Checkpoint and reconstruct state without a controller pass.
$order.^load.^emit-snapshot;
say $view.status;
