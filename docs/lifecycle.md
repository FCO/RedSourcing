# Entity lifecycle

Aggregates, projections and sagas default to `Cached`: loaded instances are reused
within a bounded LRU cache on the current connection or PostgreSQL pool.
`OnDemand` creates a new instance on each load. Explicit `Retained` reuses loaded
instances without automatic eviction. Lifecycle is independent of transactional
projection subscriptions.

## Choose a declaration default

```raku
aggregate Account { ... }              # Cached, at most 100 for this type
projection Balance[:50cached] { ... }  # Cached, at most 50 for this type
saga PurchaseWorkflow[:cached] { ... } # Cached, at most 100 for this type
aggregate Temporary[OnDemand] { ... }  # No instance reuse
aggregate Pinned[Retained] { ... }     # Explicit retention without eviction
```

`[:Ncached]` sets the type capacity; `[:cached]` uses 100. `[:!cached]` and
`[:!retained]` explicitly select `OnDemand`. `[:0cached]` keeps the `Cached`
lifecycle with storage disabled for that type. Accept only Bool or nonnegative
Int values. `cached`, `retained` and `lifecycle` cannot be combined in one option
map. `[Cached]`, `[Retained]` and `[OnDemand]` are supported aliases. Declaration
options survive precompilation without serializing cached instances and do not
change persisted class or stream names.

`.^lifecycle(:50cached)` configures the declaration before first use.
`.^lifecycle` queries the effective mode; `.^lifecycle(:declared)` queries the
declaration. `.^cache-size` and `.^cache-size(:declared)` query the type capacity.
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
    .entity-cache-size = 200; # Total across all Cached types
    .includes = <lib>;
    .modules = <App::Domain App::Services>;
    .entities = {
        'App::Account' => { cached => 100 },
        'App::Balance' => { retained => False },
        'App::PurchaseWorkflow' => { cached => 50 },
    };
}
```

The file takes precedence over the declaration; an omitted type keeps its own
default. Keys are exact full class names. Entries accept `cached` (Bool or
nonnegative Int), `retained` (Bool), `auto-snapshot`, or the enum spelling
`lifecycle` (`Cached`/`OnDemand`/`Retained`). Choose one lifecycle spelling per entry.
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

## Cache limits

The default total capacity is 100, shared by all `Cached` types in the store.
Each type also defaults to 100; both limits apply simultaneously. A full total
cache evicts its globally least recently accessed entry even when every type is
below its individual limit. A full type cache evicts that type's least recently
accessed entry first. Hits renew recency. Explicit `Retained` entries are outside
these limits. Transaction working copies are temporary and are not cache entries.

`.entity-cache-size = 0` disables the entire bounded cache. Programmatic setup
accepts `configure-lifecycles(%entities, :entity-cache-size(200))` from
`RedSourcing::Lifecycle`. Configure capacities before first use; identical settings
can be reapplied. Cache state is local to the process and connection/pool.

## Load, update and release

```raku
my $proxy = Account.^with-ids(:account-id<a1>);
$proxy.^create;
my $account = $proxy.^load;
my $same = $proxy.^load; # Same object while still cached
$proxy.credit(:amount(5)); # Existing reference updates after commit
$proxy.^release; # Future loads reconstruct a new instance
```

Retention starts at `.^load`, including internal loads performed by commands
and saga controllers. Choosing `Retained` does not preload every identity.
Eviction and release stop automatic updates to old references without invalidating
them. Pending commits do not resurrect removed entries. `Retained` users should
release identities they no longer need. This is not a distributed cache.

Each type retains its existing update policy:

| Type | Updates |
| --- | --- |
| Aggregate | A command restores a newer checkpoint when available and folds newer events from its stream before validation. Its successful transaction publishes the resulting state into the retained object. |
| Projection | `.^advance` replays its matching events. An `is transactional` candidate triggers ordered replay and checkpointing in the emitting transaction. Retained subscriptions target loaded identities only. |
| Saga | `.^advance` consumes source facts, executes eligible actions and checks timers. Each committed control publishes its state. Ordinary loading restores snapshots and controls without running `REACT` or services. |

Checkpoint/snapshot APIs support every lifecycle. By default all types checkpoint
after 100 applied records at their existing operation boundaries. In addition,
evicting or explicitly releasing a dirty `Cached` entity saves a snapshot even
below that threshold. Clean entities do not create another snapshot, and
`:!auto-snapshot` or an effective `auto-snapshot => False` disables this behavior.

Eviction snapshots run outside the cache lock, after the caller commits. Active
entity operations finish before checkpointing; rollback discards deferred work.
A checkpoint failure does not fail an already committed operation: journal replay
remains available, and the store records `eviction-snapshot-failures` and
`eviction-snapshot-error` diagnostics. No background controller is started.
See [automatic snapshots](auto-snapshot.md).

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

A `Cached` load checks the latest checkpoint metadata and replays only new events
when the checkpoint has not superseded its state. Reads and commands therefore
still query the journal; caching avoids full reconstruction and historical replay.
Projection filters and passive saga controls retain their existing semantics.
Projections whose selection depends on mutable non-ID attributes, raw journal
providers or unsupported predicates reconstruct on each
load instead of reusing accumulated state. Their lifecycle remains `Cached`, but
this conservative fallback preserves runtime filter changes. Explicit `Retained`
continues to provide its existing opt-in retention behavior.
External variable captures in `APPLY`/`REACT` filters are rejected during type
composition; see [projection filters](projections.md).

Another process does not push updates into retained references. Aggregates catch
up before commands; projections and sagas catch up through their existing advance
APIs. Release and load again to reconstruct a fresh read-only view. Serialize
access to a retained identity in application threads; readers can otherwise observe
an update while its attributes are being copied. Publication rejects older
versions, but is not a synchronized multi-attribute read API. Mutable custom objects
inside entity attributes need their own copying discipline; built-in array/hash/map
state is covered by the runtime's detached copies.
