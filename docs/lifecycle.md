# Entity lifecycle

Aggregates, projections and sagas support the same `EntityLifecycle` enum:
`OnDemand` creates a new instance on each load; `Retained` reuses a loaded instance
for its type and stream on the current connection or PostgreSQL pool. The default
is `OnDemand`. Lifecycle is independent of transactional projection subscriptions.

## Choose a declaration default

```raku
aggregate Account[:retained] { ... }
projection Balance[:retained] { ... }
saga PurchaseWorkflow[:retained] { ... }
```

`[:!retained]` explicitly chooses `OnDemand`, the default. Use named pairs in
declarations so lifecycle and snapshot options share the same syntax. The aliases
`[Retained]` and `[OnDemand]` remain supported. Brackets configure the metaclass
before composition, and survive module precompilation. They do not change the
class or stream name, so the same persisted identity can use either lifecycle.
`.^lifecycle(:retained)` is available for programmatic declaration
configuration before the type's first use. `.^lifecycle` reports the effective
mode; `.^lifecycle(:declared)` reports the declaration default.
Configuration calls return the type and accept the same named pairs as brackets:

```raku
Account.^lifecycle(:retained, :auto-snapshot{ :100count, :300seconds });
Account.^lifecycle;           # Query the effective lifecycle
Account.^lifecycle(:declared); # Query the declaration default
```

`:declared` is a query option; do not combine it with configuration options.

## Override defaults in configuration

```raku
use RedSourcing::Config;
config {
    .driver = 'SQLite';
    .database = 'events.db';
    .includes = <lib>;
    .modules = <App::Domain App::Services>;
    .entities = {
        'App::Account' => { retained => True },
        'App::Balance' => { retained => False },
        'App::PurchaseWorkflow' => { retained => True },
    };
}
```

The file takes precedence over the declaration; an omitted type keeps its own
default. Keys are exact full class names. Entries accept `retained` (Bool),
`auto-snapshot`, or the enum spelling
`lifecycle` (`OnDemand`/`Retained`). Choose one lifecycle spelling per entry.
Invalid values fail when reading the file. See [automatic snapshots](auto-snapshot.md)
for the default policy, declaration options and explicit `Nil`.

`red-sourcing-defaults` applies the settings after choosing its connection.
Ordinary `use RedSourcing` does not read configuration. The CLI applies the same
settings, and the monitor forwards them to its operation subprocesses. Native
bootstrap keeps `includes`/`modules` as metadata; import your application modules
explicitly. Overrides also work for modules loaded after bootstrap: names are
matched when a type is used, without importing code from configuration implicitly.
An unknown name therefore remains unused rather than triggering a module import.

Settings are connection/pool-scoped. A type's effective lifecycle is frozen at
its first create, load or operation in that store. Reapplying identical settings
is allowed; changing a used type's mode fails before replacing any settings.
Restart the application to change modes on a running store. A different connection
can use a different mode for the same class.

## Load, update and release

```raku
my $proxy = Account.^with-ids(:account-id<a1>);
$proxy.^create;
my $account = $proxy.^load;
my $same = $proxy.^load; # Same object when this type uses Retained
$proxy.credit(:amount(5)); # Existing reference updates after commit
$proxy.^release; # Future loads create a new retained instance
```

Retention starts at `.^load`, including internal loads performed by commands
and saga controllers. Choosing `Retained` does not preload every identity.
Applications with many identities should release ones they no longer need.
Automatic eviction is not implemented. Retention is local to the process and
connection/pool, not a distributed cache.

Each type retains its existing update policy:

| Type | Updates |
| --- | --- |
| Aggregate | A command restores a newer checkpoint when available and folds newer events from its stream before validation. Its successful transaction publishes the resulting state into the retained object. |
| Projection | `.^advance` replays its matching events. An `is transactional` candidate triggers ordered replay and checkpointing in the emitting transaction. Retained subscriptions target loaded identities only. |
| Saga | `.^advance` consumes source facts, executes eligible actions and checks timers. Each committed control publishes its state. Ordinary loading restores snapshots and controls without running `REACT` or services. |

Checkpoint/snapshot APIs support every lifecycle. Retention does not change the
automatic snapshot policy or start a background
controller. By default all types checkpoint after 100 applied records at their
existing operation boundaries; see [automatic snapshots](auto-snapshot.md).

## Transactions and freshness

The runtime uses detached working instances. Arrays, hashes and maps are copied;
transaction rollback discards provisional mutations. Caller-owned `red-do`
transactions publish only after the outer commit. A load in that transaction
returns its working state. Registrations made inside it remain provisional until
commit. Explicit nested `red-do :transaction` scopes use Red's savepoints: an
inner rollback restores working instances, projection cursors and snapshot
counters, and discards provisional registrations and publications. Releasing a
savepoint does not publish retained state; only the physical commit does.
Nested commands still propagate optimistic conflicts to their transaction owner
for complete-batch rollback and retry; they do not automatically open savepoints.

Saga advances preserve their existing durability boundaries: a claim is committed
before an external action executes; individual controls record progress. A later
failure does not undo controls that already committed. Loading never reissues an
external effect. Retry and compensation semantics remain unchanged.

Another process does not push updates into retained references. Aggregates catch
up before commands; projections and sagas catch up through their existing advance
APIs. Release and load again to reconstruct a fresh read-only view. Serialize
access to a retained identity in application threads; readers can otherwise observe
an update while its attributes are being copied. Publication rejects older
versions, but is not a synchronized multi-attribute read API. Mutable custom objects
inside entity attributes need their own copying discipline; built-in array/hash/map
state is covered by the runtime's detached copies.
