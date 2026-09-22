# Food delivery example

A runnable food delivery backend with restaurant menus, order placement,
preparation, courier assignment, pickup, delivery and cancellation. Read the
[step-by-step tutorial](../../docs/tutorials/food-delivery.md) to build and
understand the system.

## Run

From the repository root:

```sh
raku -Ilib -Iexamples/food-delivery examples/food-delivery/main.raku
```

The demo uses a fresh in-memory SQLite database. It places an order for two rice
bowls and one juice, delivers it through a deferred command, and cancels a second
customer's order. Amounts use `Rat`; the fixed delivery fee is `2.50`.

```text
Order order-1001: placed, total 30.75
  2 x Rice bowl at 12.5
  1 x Orange juice at 3.25
Customer tracking: assigned
Restaurant board: 1 active order
Rejected: Courier 'someone-else' is not assigned to order 'order-1001'
Deferred delivery: Pending
Delivery result: delivered
Repeated command: delivered
Tracking after checkpoint: delivered
Restaurant board: 0 active orders
Totals: 2 placed, 1 delivered, 1 cancelled, delivered value 30.75
```

## Files

| File | Purpose |
| --- | --- |
| [DeliveryEvents.rakumod](DeliveryEvents.rakumod) | Menu and order lifecycle facts, with shared order identity |
| [Restaurant.rakumod](Restaurant.rakumod) | Menu, availability and opening/closing commands |
| [DeliveryOrder.rakumod](DeliveryOrder.rakumod) | Authoritative pricing, immutable receipt and lifecycle rules |
| [CustomerOrders.rakumod](CustomerOrders.rakumod) | Tracking and receipts for one customer across order streams |
| [RestaurantBoard.rakumod](RestaurantBoard.rakumod) | Active orders for one restaurant |
| [DeliveryTotals.rakumod](DeliveryTotals.rakumod) | Placed, delivered, cancelled and active counts plus delivered value |
| [main.raku](main.raku) | Complete flow, snapshots, rejected pickup and stored-result reuse |

Create an aggregate's first snapshot with `.^create`, then submit commands through
its proxy. Order placement reads the restaurant's current menu and records names,
prices and quantities in `OrderPlaced`; later menu edits do not change that
receipt. The lifecycle is `new`, `placed`, `accepted`, `ready`, `assigned`,
`picked-up`, `delivered`. Cancellation is allowed while `placed` or `accepted`.

Projections select order events through their `APPLY` signatures and can start
without a snapshot. The demo checkpoints the order aggregate and customer view
before delivery. Running the same completed stored delivery command again returns
its saved result without another delivery event.

The example uses courier IDs as labels and does not reserve courier capacity or
inventory, charge a payment provider or expose an HTTP API. The tutorial explains
how those responsibilities can be added and how the command execution policy
affects rejected commands.

## Test

```sh
raku -Ilib t/12-food-delivery-example.rakutest
```

The tests cover domain failures, exact pricing, isolation, delivery and
cancellation, execution-time menu validation, retry, saved results, snapshot
recovery and running the demo entry point.

## CLI and web monitor configuration

This directory includes `red-sourcing.rakuconf`, with a local SQLite store,
example modules, application paths and worker/monitor defaults. From this directory,
the CLI discovers it automatically instead of using the repository's root config:

```sh
cd examples/food-delivery
raku -I../../lib ../../bin/red-sourcing.raku init
raku -I../../lib ../../bin/red-sourcing.raku describe DeliveryOrder
raku -I../../lib ../../bin/red-sourcing.raku create DeliveryOrder --id=order-id=order-1
raku -I../../lib ../../bin/red-sourcing.raku web-monitor
```

Open <http://127.0.0.1:3001/monitor>. New-store mode is enabled, so you can also
start the monitor first and explicitly run **init** in Operations. Relative paths
are resolved from the configuration file; from the repository root, select it
with `-f=examples/food-delivery/red-sourcing.rakuconf`. Use `--port` to override the
monitor port when running multiple examples.

The standalone `main.raku` demonstration still uses a fresh in-memory database.
Its demo records do not populate this persistent CLI store. Create entities and
execute commands through the CLI or Operations to populate it.

Application startup can use this same file through `red-sourcing-defaults`; see
[shared configuration](../../docs/configuration.md). The standalone demo
intentionally selects in-memory SQLite. The [CLI guide](../../docs/cli.md) and
[monitor guide](../../docs/web-monitor.md) explain persistent operations.

## Docker stack

From the repository root:

```sh
docker compose -f examples/food-delivery/compose.yaml up --build -d
```

This uses the shared RedSourcing image, an isolated database volume and a
separate monitor at `http://127.0.0.1:3001/monitor`. See the
[Docker guide](../../docs/docker.md) for ports, services and persistent data.
