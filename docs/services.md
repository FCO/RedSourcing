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

## Queries and commands through entity proxies

Declare the public read surface with `is query`, on methods or attributes:

```raku
projection Directory {
    has Str $.application-id is entity-id;
    has %.users is query;
    method APPLY(UserRegistered $event where { .application-id eq $!application-id }) {
        %!users{$event.user-id} = $event.name;
    }
    method list is query { %!users.keys.sort.Array }
}
my $directory = Directory.^with-ids(:application-id<demo>);
my $names = $directory.list;
my %users = $directory.users;
$user.tweet(:text('Hello'));
```

Queries work inside and outside services. Outside, the proxy loads the entity
using the application's connection and lifecycle. Inside a service, a dynamic
`ServiceContext` routes both queries and declared commands through that service's
executor, carrying its owner/generation. Proxies retain only identity, so the
same proxy can be reused by different services. Existing identity getters remain
local metadata reads.

`is query` on an attribute marks its public accessor. The proxy exposes only a
getter, even when the source attribute is `is rw`. Changing a returned collection
does not mutate the entity. Private attributes without accessors are rejected.
Only marked queries are forwarded; framework hooks, constructors/destructors and
mixed query/command/service declarations are rejected. Inherited queries and
uniformly marked multi candidates are supported, with positional and named
arguments. Explicit forwarders also handle names such as `list` already present
on `Any`.

Results preserve Raku types rather than round-tripping through JSON: numeric and
string values, `Rat`, dates/instants/durations, and finite data collections.
Arrays and hashes are copied recursively, including typed containers. Sequences
are materialized on the executor. Cycles, ORM models/cursors, handles, Promises,
Supplies and opaque objects are rejected; return plain data collections instead.
Queries must be bounded and finite. Their bodies cannot invoke effects through
the framework, including commands on the receiver or explicit service helpers.
This is a CQRS API guard, not a sandbox for arbitrary SQL written by a developer.

The service entrypoint has its context bound automatically. The HTTP helper also
binds request processing, including delayed request bodies. For callbacks invoked
by outside emitters or timers, capture the context explicitly:

```raku
my &receive = $runtime.bind(-> %message {
    $user.tweet(:text(%message<text>));
});
my $subscription = $incoming.Supply.tap(&receive);
```

`bind` preserves arguments and protected query scopes. It binds the exact service
instance, not just its runtime. Revoked generations and closed executors fail;
they never fall back to ordinary application access. `on-stop` callbacks are
bound automatically. `runtime.proxy` returns the owning entity's normal proxy.

The explicit `read`, `command`, `aggregate` and `state` helpers remain compatible.
In particular, `read($proxy, :method, :arguments)` keeps its existing JSON data
contract; the new typed return contract applies to proxy queries. The `aggregate`
shortcut still targets aggregate owners; projection services can use any
aggregate proxy directly. `:!sync` keeps the originating service fence in queued
commands.

Projection service controls still belong to an internal aggregate, outside the
projection stream. Projections do not gain domain commands. Existing aggregate
service identities and queued controls keep their original path.

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

The proxy/query API has a separate focused regression record in
[query-validation.json](../examples/microblog/query-validation.json), covering
SQLite, Pg, RakuAST, delayed HTTP request bodies, callbacks, typed detached
results and stale service generations. Timing comparisons are documented in
[the microblog performance notes](../examples/microblog/PERFORMANCE.md).

The earlier managed-services validation below predates the proxy/query change.

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
