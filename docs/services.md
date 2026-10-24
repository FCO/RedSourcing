# Managed aggregate services

`is service` declares external, long-lived behavior on an aggregate or projection. Business
state is still recorded by aggregate commands/events. An internal saga per
aggregate identity and method stores requested state, timers, attempts and
outcomes. The optional `ServiceRuntime` holds the actual Promise and resources.

```raku
use RedSourcing;
use RedSourcing::Service;

aggregate Room {
    has Str $.room-id is entity-id;
    # Declare domain APPLY/command methods normally.
    method serve(ServiceContext $runtime, Str :$topic = 'general') is service {
        start {
            # Open resources, then register their cleanup:
            $runtime.on-stop({ ... });
            $runtime.ready;
            # For each received message:
            # $runtime.touch;
            # $runtime.aggregate.record-message(:text(...));
            await $runtime.stopping;
        }
    }
}
```

Services must be public, single aggregate or projection methods, including inherited methods.
Sagas continue to use their effect helpers.
They accept one required positional `ServiceContext`, then named business
arguments. They cannot also be commands. The body must return a Promise; its
result is not persisted. A kept Promise ends the service, while a broken Promise
uses the configured restart budget. Direct event emission from service bodies
is rejected: use `ServiceContext.aggregate` for state changes.

## Services on projections and other entities

Projection services use the same lifecycle APIs as aggregates. Their controls
are stored in an internal aggregate per service, outside the projection's
stream; projections still cannot declare commands. Existing aggregate service
identities and their queued control commands keep their original path.

`state` reconstructs the owning entity, including a projection. To use another
entity from a handler:

```raku
my $page = $runtime.read($timeline, :method<page>, :arguments(%(:limit(50))));
$runtime.command($user, 'tweet', :text('Hello'));
my $pending = $runtime.command($user, 'tweet', :text('Later'), :!sync);
```

`read($proxy)` returns fresh detached state. With `:method` and `:arguments`, it
runs the query on the executor and returns JSON-compatible materialized data;
queries must return bounded plain data, not ORM cursors. Declared commands and
services cannot be invoked as read methods. Framework effects are forbidden
inside a read method. `command` accepts only declared aggregate commands, and
preserves the source service's fence even when the target is another aggregate.
The `aggregate` shortcut remains available for aggregate owners; projection
owners use an explicit target through `command`.

The [microblog example](../examples/microblog/README.md) demonstrates a shared
transactional tweet index, author/feed projections and a projection-owned HTTP
service with SSE.

## Cro HTTP services

Pass a block containing Cro endpoint declarations directly to the context:

```raku
use Cro::HTTP::Router;
method serve(ServiceContext $runtime, Int :$port = 3000) is service {
    $runtime.http(:$port, {
        get -> 'messages' {
            $runtime.touch;
            content 'application/json', $runtime.state.messages.Array;
        }
    })
}
```

`http(&routes, :host<127.0.0.1>, :port(3000))` wraps the block in Cro’s `route`
and returns the service lifetime
Promise. It starts Cro, waits for the listener to bind before calling `ready`, and closes
the server on stop or readiness failure. A bind failure breaks the service Promise
without acknowledging readiness. An already-built Cro application is also accepted. Cro loads only when the helper
is used. Import `Cro::HTTP::Router` in the aggregate file for its endpoint DSL. Handlers still use context
commands for writes and explicit `touch` for activity; HTTP requests do not
implicitly renew inactivity. See the [HTTP example](../examples/services/http.raku).

## Explicit lifecycle API

After selecting a store and creating its normal event/command schema:

```raku
my $runtime = ServiceRuntime.new.initialize;
my $room = Room.^with-ids(:room-id<general>);
$room.^create; # Normal aggregate creation, once.
$room.^start-service('serve', :args(%(:topic<general>)), :idle-timeout(300));
my $controller = $runtime.run;

$room.^touch-service('serve');
my %status = $room.^service-status('serve');
$room.^stop-service('serve');
$runtime.shutdown;
await $controller;
```

`start-service`, `touch-service` and `stop-service` submit internal stored
aggregate commands. Default `:sync` returns committed request metadata, not a
Promise of the service's whole lifetime. `:!sync` returns a StoredCommand for the
normal command worker. Start acknowledgement means requested, not ready.

Identity is `(entity type name, stream, method)`. Repeating the same active
request/arguments/timeout is idempotent; changing arguments requires stopping
first. Touch requires requested/active intent and never implicitly starts a
service. An explicit start after failure resets the budget. Status is read-only
and exposes desired state, phase, generation, owner, deadlines, error and lease.

`ready` durably acknowledges readiness; the saga's launch action remains running
until this acknowledgement. `touch` durably renews inactivity. `stopping` is a
Promise to observe in the service loop. `on-stop` registers cleanup, including
callbacks returning Promises. Cleanup runs once and errors are observable.
`state` reconstructs a fresh detached entity. For an aggregate owner, `aggregate` exposes its declared
commands with the current service fence; `:!sync` keeps that fence in the queued
command so executing it later cannot bypass ownership checks.

Context-originated database operations are handed to the executor through an
in-memory queue. `run` wakes promptly for queued work. For an embedding that
supplies its own event loop, call `tick` regularly; callbacks waiting on context
operations need those passes to progress. The controller must run outside an
application transaction. No thread starts merely by importing the library,
creating an aggregate, replaying it or calling generic `advance-sagas`.

## Ownership, recovery and stopping

The built-in lifecycle saga is created before its first source control event in
the same request transaction. Commands consume lifecycle controls with a
zero-action saga pass; actual adapters execute only in a runtime pass after
commit. Service controls are excluded from domain decision facts/counters.
Discovery selects latest internal saga records, not every aggregate snapshot.

Pg coordinates executors through conditional leases using the database clock.
Each new acquisition increments a generation that is never reused, including
after explicit stop/restart. Every command originating in a service stores its
identity, owner and generation. Execution locks/validates the lease in the same
transaction as the command; retries and queued commands are checked again.
Expired generations cannot write or acknowledge saga actions. Plain application
commands keep their existing optimistic concurrency behavior.

SQLite supports a local executor. Use one runtime per driver. Background `run`
opens an independent connection for file stores so it cannot see an application
transaction before commit. For `:memory:`, use manual `tick` or supply an
independent connection factory to the same store. A connection factory
may supply an unscoped driver for the same store; never return a completed scoped
transaction driver. Promises/closures/transactions are never restored from
snapshots. After executor failure, a different Pg process recovers requested
services once their leases expire, using a new Promise and generation.

Shutdown stops local resources and releases ownership while preserving requested
intent for recovery. `stop-service` changes durable intent as well. Inactivity
is renewed only by explicit activity, not by controller polling or heartbeats.

Stopping is cooperative. A service that ignores its stop signal cannot be killed
by the runtime. Grace expiry records `unconfirmed-stop` and revokes its lease;
cleanup failure is recorded without silently reporting success. A generation
protects database commands, not arbitrary external effects: use idempotency or
external fencing when interacting with external systems. Sockets/connections do
not migrate; real network routing and reconnection are application concerns.

## Defaults

| Setting | Default |
| --- | ---: |
| `idle-timeout` on start | 300 seconds |
| `lease-seconds` | 30 seconds |
| `heartbeat-seconds` | 10 seconds |
| `poll-interval` | 1 second |
| `ready-timeout` | 30 seconds |
| `stop-grace` | 10 seconds |
| `max-restarts` | 3 |

Intervals are finite; lease must exceed heartbeat and polling intervals.
Service failures use waits of 1, 2 and 4 seconds by default, then mark failed and
require explicit activation. Executor loss/reacquisition does not consume this
application-failure budget. Deadlines survive restart. `shutdown` is idempotent.

## Existing stores and migration

Stop writers and apply the additive migration before using this version on an
existing store, even if services will remain disabled: StoredCommand now has a
nullable JSON `service_context` column. Old command rows remain unfenced.

```sh
raku -Ilib tools/migrate-services.raku --driver=SQLite --database=app.db
# Pg uses normal libpq settings; --file can select the application's config.
raku -Ilib tools/migrate-services.raku --driver=Pg --database=app
```

The migration checks columns before adding the nullable field and creates the
lease table; it can be repeated. New stores get the command field through normal
schema creation. Runtime initialization validates it and creates the optional
lease table. No new Red feature is required.

The [room examples](../examples/services/README.md) include a simulated transport
and a real HTTP server owned by the aggregate service. They do not supply a
distributed HTTP gateway or WebSocket hibernation.

## Verification

Verified with Red 0.2.7 and Rakudo 2026.09. All new service tests pass, including
SQLite transaction isolation/recovery, Pg ownership across processes, migration
and RakuAST. The full run passed 75 of 77 test files; the two installation tests
produce compiler warnings also reproduced on the unchanged baseline. Detailed
results are in [validation.json](../examples/services/validation.json).

With services disabled, five alternating warmed school runs measured a median
of 5.486s before and 5.453s after
(-0.60%, within the 2% regression limit). This measures full-process
SQLite execution, including startup, schema and tracing, rather than active-service
throughput. Samples and source hashes are in
[disabled-performance.json](../examples/services/disabled-performance.json).
