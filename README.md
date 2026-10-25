# RedSourcing

Event sourcing for **Raku**, built on [Red](https://github.com/FCO/Red).
Define aggregates that validate commands and emit events, projections that rebuild
read models, and sagas that coordinate commands, external services, retries,
compensations and timeouts. SQLite and PostgreSQL stores share the same API.

A single `use RedSourcing` imports the declarations, roles, traits, storage models,
configuration helpers and Red's database/schema helpers. The distribution also
includes a CLI and an independent **Cro / HTMX 4** web monitor.

- [Install and run](#install-and-run)
- [Quick start](#quick-start)
- [Application configuration](#application-configuration)
- [Entities and stored commands](#entities-and-stored-commands)
- [Sagas](#sagas)
- [CLI](#cli)
- [Web monitor](#web-monitor)
- [Examples](#examples)
- [Documentation](#documentation)
- [Testing and current limits](#testing-and-current-limits)

## Install and run

RedSourcing requires **Red 0.2.7 or newer**, including its savepoint and declarative
index support.

From a checkout, install the distribution and its dependencies:

```sh
zef install .
red-sourcing --help
```

When editing RedSourcing itself, load the checkout's `lib/` so your changes are
used without reinstalling the distribution:

```sh
zef install --deps-only .
raku -Ilib examples/counter/main.raku
raku -Ilib bin/red-sourcing.raku --help
```

For application development, use the installed module or the
[Docker image](docs/docker.md).

SQLite is the default when no configuration file exists. PostgreSQL requires
`DB::Pg`, libpq and an existing database:

```sh
zef install DB::Pg
createdb --host=127.0.0.1 --port=5432 --username="$USER" events
```

`init` creates the event and command tables **inside** an existing database; it
does not create a PostgreSQL database. See [configuration](docs/configuration.md)
for connection options and macOS native-library setup.

**Checkout defaults:** this repository's root `red-sourcing.rakuconf` selects
Hearth, the real-estate example, using PostgreSQL database `hearth` and
`Estate::Domain`. Each example has its own configuration. Use `-f` to select one
explicitly, or run from that example's directory. The counter demonstration above
uses an in-memory SQLite database and needs no PostgreSQL server.

## Quick start

This complete program defines an aggregate, submits synchronous and deferred
commands, and reconstructs a projection:

```raku
use RedSourcing;

red-sourcing-defaults(:driver<SQLite>, :database(':memory:'));

class CounterIncremented does Event {
    has Int $.id is required;
    has Int $.amount is required;
}

aggregate Counter {
    has Int $.id is entity-id;
    has Int $.value is query = 0;

    method APPLY(CounterIncremented $event) {
        $!value += $event.amount;
    }

    method increment(Int :$amount where * > 0 = 1) is command {
        self.counter-incremented: :$amount;
        $!value
    }
}

projection CounterTotal {
    has Int $.id    is entity-id;
    has Int $.value is query = 0;

    method APPLY(CounterIncremented $event where { .id eqv $!id }) {
        $!value += $event.amount;
    }
}

my $counter = Counter.^with-ids: :1id;
$counter.^create;                       # Initial snapshot, before any command
say $counter.increment: :2amount;       # 2

my $pending = $counter.increment: :3amount, :!sync;
say $pending.state;                     # Pending
say $pending.run;                       # 5
say $pending.run;                       # 5; reuse the stored result

say CounterTotal.^with-ids(:1id).value; # 5
```

`red-sourcing-defaults` configures the store and creates missing tables by default.
This example explicitly selects in-memory SQLite. In an application, call it
without arguments to use the nearest `red-sourcing.rakuconf`.

The event emission method `counter-incremented` is generated from the aggregate's
`APPLY` signature. It fills the entity ID, writes the next event version and
applies the event. The command returns the resulting state. The projection's
signature selects only events belonging to its counter.

`is query` on `value` exposes its accessor through the proxy. Calling
`CounterTotal.^with-ids(:1id).value` loads the current projection and returns
its value. Read methods can also declare `is query`; their results preserve
Raku types and collections are copied so callers cannot mutate entity state.

Run the equivalent [counter example](examples/counter/README.md), or continue with
the [aggregate, projection and saga REPL tutorial](docs/tutorials/simple-flow.md)
or the [food delivery tutorial](docs/tutorials/food-delivery.md).

## Application configuration

Applications, the CLI and the monitor can share one `red-sourcing.rakuconf`:

```raku
use RedSourcing::Config;

config {
    .driver = 'SQLite';
    .database = 'events.db';
    .includes = <lib>;
    .modules = <MyApp::Domain MyApp::Services>;
    .debug = False;
    .worker: { .limit = 100; .interval = 1; .watch = False }
    .monitor: { .host = '127.0.0.1'; .port = 3001; .minutes = 60 }
}
```

Load it explicitly during application startup:

```raku
use RedSourcing;

my $settings = red-sourcing-defaults;
```

`red-sourcing-defaults` searches the current directory and its parents for the
nearest file, configures Red's default connection, creates missing storage tables
and returns effective settings. It sets `$PROCESS::RED-DEBUG` from the effective
`.debug` setting, enabling SQL logging automatically when True. A scoped
`my $*RED-DEBUG` takes precedence. Repeated calls preserve existing tables and data.
Pass `:!initialize` to connect without creating tables or indexes; schema migrations
remain explicit.
Importing the module alone does not configure a connection. Choose another file
or override its values:

```raku
my $settings  = red-sourcing-defaults(:file<deployment.rakuconf>);
my $temporary = red-sourcing-defaults(:driver<SQLite>, :database(':memory:'));
```

Relative SQLite filenames and include paths in the file resolve against its
directory. Explicit database overrides remain relative to the process working
directory. The library returns include/module and worker/monitor settings; keep
application imports and controller startup explicit. The CLI
imports configured domain modules when an operation needs them.

For PostgreSQL, use `.driver = 'Pg'`, `.database = 'events'` and a `.connection`
hash with `host`, `port`, `user` and any other libpq options. RedSourcing maps the
database name to the Pg driver and configures JSON serialization and filtering.
See the [shared configuration guide](docs/configuration.md).

## Entities and stored commands

| Declaration | Responsibility | Replay |
| --- | --- | --- |
| `aggregate` | Validate commands and emit facts | Its own stream, starting from a required snapshot |
| `projection` | Derive read models | Matching domain events across streams, with an optional checkpoint |
| `saga` | Coordinate work over time | Its own committed control state; `.^advance` consumes new source events |

`is entity-id` defines identity. `Entity.^with-ids(...)` returns a proxy; domain
commands and declared queries use ordinary methods, while lifecycle/metadata
helpers use `.^`:

```raku
my $proxy = Counter.^with-ids: :1id;
$proxy.^create;                 # Persist the initial snapshot once
my $entity = $proxy.^load;      # Reconstruct committed state
$entity.^emit-snapshot;         # Save a checkpoint
say $proxy.^stream-name;
say $entity.^version;
```

The example above assumes the counter definitions and an initialized store;
use a fresh ID when creating another instance. Direct entity `.new` is rejected.
Keep state in public, JSON-compatible attributes so it can be restored.

A stream groups one entity's events. `(stream, version)` is unique: conflicting
writers raise `RedSourcing::X::OptimisticLockFailed`. Command execution automatically
rolls back, reloads committed state and retries these conflicts. Snapshots store
the entity itself; a projection checkpoint also stores its consumed global event cursor.

Commands are persisted as `StoredCommand` records. Named arguments, aliases,
constraints and supported defaults are validated before submission. Synchronous
execution is the default; `:!sync` returns a pending record. Successful execution
saves emitted events, result and `Done` state in one database transaction. Business
or other handler errors roll back events and record a terminal `Failed` command.
Optimistic conflicts retry the same record, with up to five transaction attempts
per execution pass; persistent contention leaves it `Pending`, without consuming
saga retries. Re-running a completed record returns its saved result; a failed record reports
its saved failure. Sagas submit fresh child records when retrying business failures.

Application domain events should only be emitted inside aggregate command
handlers, through generated event methods. Projections cannot declare commands
or own/emit domain events. Declare read methods with `is query`, such as
`method summary is query { ... }`, and call them through the proxy:
`$projection-proxy.summary`. Use `.^load` when you need an explicit entity for
a checkpoint or inspection. Sagas call aggregate commands to change domain
state; their native control events are managed by the runtime.

Use `is transactional` on a projection's `APPLY` candidate to advance and
checkpoint the whole projection in the emitting command's transaction. Target
IDs are inferred from equalities such as `.account-id eq $!id`; no mapping is
needed. Pending events handled by other candidates are applied first, in journal
order. `.^advance` catches up a projection explicitly. Declare
`projection MyView[:retained] { ... }` to keep loaded
instances in memory; matching instances receive committed state after the outer
transaction completes. See [projections and transactional updates](docs/projections.md)
for routing limits, lifecycle, rollback and cross-stream ordering.

Aggregates, projections and sagas default to `Cached`, with LRU limits of 100 per
type and 100 total per store. Declare `aggregate Account[:50cached] { ... }` to
change a type's limit; configure `.entity-cache-size = 200` to change the total.
`EntityLifecycle` also exposes explicit `OnDemand` and unbounded `Retained`.
Override a type with `.entities = { 'App::Account' => { cached => 50 } }`.
These settings apply to the selected connection/pool before first use. Retained
aggregates fold new events before commands; sagas restore passively and keep their
explicit advance/controller behavior. See [entity lifecycle](docs/lifecycle.md)
for configuration precedence, commit publication and release.

Events expose `.emitted-at`, the journal's recorded timestamp, and `.StoredEvent`
for their storage metadata. [The library API](docs/api.md) covers low-level
emission, identity maps, filters, command scheduling and snapshot semantics.

## Sagas

Sagas use `APPLY` to update persisted state and `REACT` to plan effects. A named
saga method can schedule an aggregate command or a registered service:

```raku
method reserve-stock {
    Inventory.^with-ids(:$.order-id).reserve:
        :$.order-id,
        :service-retry{:3max, :2delay};
}

method compensate-reserve-stock(Str :$reservation-id!, |) {
    Inventory.^with-ids(:$.order-id).release: :$reservation-id, :service-retry{:5max, :10delay};
}
```

These are methods inside a saga whose `Inventory` aggregate defines those
commands. The default compensator is `compensate-` plus the originating method
name. A successful operation saves its inverse invocation; it does not run the
inverse. `self.^compensate(:reason(...))` runs saved inverses in reverse order.
On a proxy call, use `:service-retry{...}` to configure retries and
`:!service-compensation` for effects without a meaningful inverse. These options
belong to the saga action and are not passed to the aggregate command. The call
returns an action ID; the controller executes the command later.

A service adapter receives the operation, captured arguments and a stable
idempotency key. Retry policies support fixed delays and exponential backoff.
Unknown external outcomes require reconciliation rather than assuming failure.
Named deadlines persist across restarts:

```raku
self.set-timeout: 'delivery-deadline', 15 * 60,
    expire => \(reason => 'Delivery deadline exceeded');
self.cancel-timeout: 'delivery-deadline';
```

The timeout names a method of that saga. An external controller must periodically
call `$proxy.^advance`, `$proxy.^check-timeouts`, or the exported `advance-sagas`
function for all active persisted instances; `work` processes pending
commands and does not advance sagas. Loading a saga restores its committed state
without running reactions or services. `self.^now` supplies the controller clock.

```raku
my %tick = advance-sagas(:limit(100)); # Limit per saga; one pass over the store
say "Advanced {%tick<advanced>}; failed {%tick<failed>}";
```

Rule blocks supplied to `StoredEvent.list-events`, including rules derived from
`APPLY` signatures, are translated by Red into SQL `WHERE` conditions. They do
not run once per stored event in the application: the database selects matching
rows before reconstruction.

Use [the saga guide](docs/sagas.md) for a complete definition and the failure
contract. The [commerce example](examples/commerce/README.md) combines eight sagas
for purchase, fulfillment, delivery, cancellation, returns, replenishment and
notifications and outgoing webhooks, with a replayable in-app inbox. Its [API feedback](examples/commerce/README.md#saga-api-feedback)
records the facilities that would simplify this usage.

## CLI

The installed command is `red-sourcing`; in a checkout, use
`raku -Ilib bin/red-sourcing.raku`. Human-readable output is the default;
`--json` supports scripts. `--help` groups commands, explains options and includes
examples. Every command accepts `-f`, `--driver`, `--database` and `--debug`.

| Task | Commands |
| --- | --- |
| Initialize or migrate | `init`, `update` |
| Discover types and instances | `types`, `list-entities`, `list-aggregates`, `list-projections`, `list-sagas` |
| Describe or inspect | `describe`, `inspect` |
| Create, restore or checkpoint | `create`, `load`, `snapshot` |
| Submit and process commands | `command`, `run-command`, `work` |
| Read history | `streams`, `list-events`, `list-commands` |
| Diagnose and advance sagas | `saga-status`, `advance`, `resolve-action` |
| Observe store health | `stats`, `web-monitor` |

A complete counter flow from the repository root:

```sh
raku -Ilib bin/red-sourcing.raku -f=examples/counter/red-sourcing.rakuconf init
raku -Ilib bin/red-sourcing.raku -f=examples/counter/red-sourcing.rakuconf describe Counter
raku -Ilib bin/red-sourcing.raku -f=examples/counter/red-sourcing.rakuconf create Counter --id=id=1
raku -Ilib bin/red-sourcing.raku -f=examples/counter/red-sourcing.rakuconf command Counter increment --id=id=1 --data='{"amount":2}'
raku -Ilib bin/red-sourcing.raku -f=examples/counter/red-sourcing.rakuconf load Counter --id=id=1
```

Run `create` once per identity. Repeat `--id=FIELD=VALUE` for composite IDs.
Configuration supplies import paths/modules; `-I=PATH` and `-M=MODULE` add them
explicitly. `describe` includes entity/handler `#|`/`#=` descriptions and command
source signatures, including `where` constraints when source is available.

For deferred execution, add `--async` to `command`, then run `work`. Inspect saga
progress by type/identity or by stream name:

```sh
red-sourcing list-sagas
red-sourcing saga-status --stream='MyApp::OrderWorkflow: order-id = order-1'
red-sourcing advance OrderWorkflow -I=app/lib -M=MyApp::Workflows --id=order-id=order-1
red-sourcing work --watch
red-sourcing list-commands --state=Failed --details
```

The last commands require the named application/store. `saga-status` reports
pending actions, retries, timeouts, failed actions and compensation stacks without
executing work. [The CLI guide](docs/cli.md) documents every operation, identity
parsing, output modes, migrations and reconciliation.

## Web monitor

Run the monitor as a separate process against the same database:

```sh
raku -Ilib bin/red-sourcing.raku -f=examples/counter/red-sourcing.rakuconf web-monitor
```

Open <http://127.0.0.1:3001/monitor>. The monitor discovers aggregates, projections,
sagas, history and workflow state from storage; the application does not register
it or import it. Inspection does not execute domain handlers.

Live charts show events/minute, snapshots/minute, events per entity, command
failures and saga retries. Full names have hover labels and links to detail pages.
The **Operations** workspace exposes CLI operations through forms, including
command execution, checkpoints, workers and saga reconciliation. Operations that
need application code use the configured modules in isolated subprocesses.

SSE refreshes HTMX fragments as the store changes. Cro, HTMX, charts and assets are
included in the distribution. See [the monitor guide](docs/web-monitor.md) for
startup settings, independent connections, job controls and metrics definitions.

Entity actions run in place with their target fixed; command parameters come from
the signature and results use HTML cards/tables. **Flows** connects saga actions,
actual child commands and emitted events in causal order, using a projection
over journal metadata. Choose an entity or a typed saga action; internal
bookkeeping links are hidden by default and can be shown when needed. Causal
command/action IDs are always stored; no tracing tables or replay observations
are required. [The flow guide](docs/flows.md) covers reconstruction and its limits.

## Automatic snapshots

Aggregates, projections and sagas checkpoint after 100 applied records by default.
Configure retention and snapshot frequency independently on the declaration:

```raku
saga PurchaseWorkflow[:retained, :auto-snapshot{ :100count, :300seconds }] { ... }
aggregate Account[:!auto-snapshot] { ... }
```

`count` and `seconds` use OR and are checked at successful operation boundaries.
A plain load never writes a snapshot or executes saga effects. Configuration can
set `.auto-snapshot` globally and override `retained`/`auto-snapshot` by class in
`.entities`; `False` or `Nil` disables optional snapshots. Initial aggregate snapshots
and transactional projection checkpoints remain required. See
[automatic snapshots](docs/auto-snapshot.md) for policies and transaction behavior.

## Examples

Each example includes a README and `red-sourcing.rakuconf` for its own store.
Each also has a `compose.yaml` using the shared root Docker image. For an isolated
stack with its own database and monitor, see the [Docker guide](docs/docker.md).
Use `docker compose up --build --watch` inside an example to restart its running
services on example changes and rebuild the installed module on framework changes
(Compose 2.32+).
Run these commands from the repository root:

| Example | What it demonstrates | Run |
| --- | --- | --- |
| [Counter](examples/counter/README.md) | Minimal aggregate, projection and CLI walkthrough | `raku -Ilib examples/counter/main.raku` |
| [School](examples/school/README.md) | Dynamic consistency: at most 10 classes per student and 30 students per class | `raku -Ilib examples/school/main.raku` |
| [Simple flow](examples/simple-flow/README.md) | One aggregate, projection and saga, inspected line by line in the REPL | See the linked REPL walkthrough |
| [Bank](examples/bank/README.md) | Rational money, transfers and monthly projections | `raku -Ilib -Iexamples/bank examples/bank/main.raku` |
| [Shopping cart](examples/shopping-cart/README.md) | Checkout and a 24-hour abandoned-cart email saga | `raku -Ilib -Iexamples/shopping-cart examples/shopping-cart/main.raku` |
| [Food delivery](examples/food-delivery/README.md) | Menus, delivery lifecycle and customer/restaurant views | `raku -Ilib -Iexamples/food-delivery examples/food-delivery/main.raku` |
| [Order saga](examples/order-saga/README.md) | Reserve, charge, checkpoint and compensate | `raku -Ilib examples/order-saga/main.raku` |
| [Commerce](examples/commerce/README.md) | Eight cooperating sagas for purchase, stock, shipping, returns and webhooks | `raku -Ilib examples/commerce/main.raku` |
| [Hearth](examples/real-estate/README.md) | PostgreSQL, rent, repairs, chat and a live Cro/HTMX web application | `raku -Ilib -Iexamples/real-estate/lib examples/real-estate/main.raku` |

The command-line demos use in-memory SQLite unless documented otherwise. Hearth
uses PostgreSQL; its database must exist before startup. Commerce also supports
a persistent database and a separate controller process. Simulated providers do
not make real payments, ship goods or send emails. Commerce can optionally POST
webhooks to a configured HTTP endpoint; its default webhook provider is simulated.

## Documentation

- [Shared configuration](docs/configuration.md): file discovery, library usage,
  driver options, application imports and PostgreSQL setup.
- [Docker](docs/docker.md): shared image and an isolated Compose stack for every example.
- [Library API](docs/api.md): events, identity, commands, replay, snapshots,
  filtering, schema versions and failure behavior.
- [Decision models](docs/decision-models.md): consistent decisions across projections and command retries.
- [Sagas](docs/sagas.md): reactions, compensation, retries, services and timeouts.
- [Managed aggregate services](docs/services.md): optional Promise-based services,
  durable lifecycle sagas, cooperative shutdown and Pg ownership leases.
- [CLI](docs/cli.md): all commands, options, examples and readable/JSON output.
- [Web monitor](docs/web-monitor.md): live inspection, metrics and Operations.
- [Workflow visualization](docs/flows.md): causal links reconstructed from journal metadata.
- [REPL tutorial](docs/tutorials/simple-flow.md): follow one order through an aggregate,
  projection and saga, inspecting commands, events and recovery at each step.
- [Food delivery tutorial](docs/tutorials/food-delivery.md): a step-by-step application.
- [Performance](docs/performance.md): measurements, storage optimizations and remaining costs.
- [Testing](docs/testing.md): local checks, coverage, PostgreSQL and browser checks.
- [Roadmap](docs/next-steps.md): remaining API, concurrency and storage work.

## Testing and current limits

```sh
zef install --test-depends --deps-only .
zef install App::Prove6 'App::RaCoCo:ver<2.0.1>'
prove6 --exec='raku -Ilib' t
raku -I. xt/coverage.rakutest
```

The suite covers aggregate/projection reconstruction, command failures,
saga compensation/recovery, CLI behavior, packaged installation, Cro routes and
monitor operations. The coverage gate measures every published library module
against `coverage-baseline.json`; it is not a measurement of production readiness.

RedSourcing is under active development. Durable multi-controller leases/fencing,
large-journal pagination, compact saga controls and some signature forms need more
work. Command defaults depending on another parameter or `self` are unsupported;
explicit slurpy payload preservation is incomplete. Provider idempotency is
required for reliable external retries. See the [roadmap](docs/next-steps.md) for
specific constraints and the [testing guide](docs/testing.md) for validation scope.

## Author and license

Fernando Correa de Oliveira. Copyright 2026.
Distributed under the **Artistic License 2.0**. Bundled web assets retain their
[third-party licenses](docs/web-third-party.md).

The [Pio microblog example](examples/microblog/README.md) combines a transactional
SQL tweet index, per-user projections, a projection-owned HTTP service and SSE.
