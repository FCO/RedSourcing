# Projections and transactional updates

## Sequence: ordered replay and the two update paths

```mermaid
sequenceDiagram
    autonumber
    actor Application
    participant A as Aggregate
    participant J as Journal
    participant P as Projection
    Application->>A: Execute domain command
    A->>J: Append domain event inside command transaction
    alt Matching APPLY is transactional
        J->>P: Resolve target identity and advance through emitted row
        P->>J: Restore checkpoint and select matching facts after cursor
        P->>P: APPLY facts in global ID order, including earlier matching<br/>events
        P->>J: Write required checkpoint with consumed cursor
        J-->>Application: Commit command, event and checkpoint together
    else Projection advances on demand
        J-->>Application: Commit command and event
        Application->>P: advance
        P->>J: Restore optional checkpoint and select matching facts
        P->>P: APPLY ordered batch
        opt Optional autosnapshot count OR time is due
            P->>J: Save checkpoint with replay cursor
        end
        P-->>Application: Updated projection
    end
    Application->>P: query (is query)
    P-->>Application: Reconstructed or retained state, without a new snapshot
    Note over P,J: Red translates APPLY rule<br/>blocks into SQL filters
    Note over P,J: Snapshot row ID is distinct<br/>from the consumed source<br/>cursor
```

Projections consume domain events and build read models. They cannot declare
commands or emit domain events. Use aggregate commands to change domain state.

Declare public read methods or accessors with `is query` and call them directly
on the proxy. Their results preserve Raku types and copy collections, so callers
cannot mutate the projection through a returned value.

By default, each `$proxy.^load` restores the latest projection checkpoint and
replays matching events. `.^advance` also catches up an existing instance or a
proxy. It does not save a checkpoint unless you pass `:checkpoint`; use
`.^emit-snapshot` to explicitly save one even when no newer event was consumed.

## Prepared replay metadata

Each projection prepares its `APPLY` signatures, attributes and ID names when
its type is composed. This immutable descriptor is stored on the projection's
metamodel and, for precompiled modules, serialized with the type in `.precomp`.
Loading the module in another process reuses the descriptor. Dynamically
composed types prepare it when they are composed at runtime.

Ordinary replay and `decision-model` share parameterized `Red::AST` templates
stored in these descriptors. Event-type membership uses a driver-independent
AST node: PostgreSQL translates it to indexed native-array containment, while
other drivers keep string membership. The compiler accepts event field access, receiver
attributes, scalar literals, comparisons, `!`, `&&`, `||` and parentheses. It
never executes the original `where` to discover constants. Calls, interpolation
and sub-signatures use the existing runtime analysis path when supported.

An `APPLY` or `REACT` parameter's `where` must not capture external variables.
Type composition rejects these captures, normally at compilation time, with the
entity, handler and variable in the error. Use event parameters, entity
attributes or variables declared inside the filter instead. This restriction
also applies to aggregates and sagas; handler bodies are unaffected.
Validated inherited handlers retain that validation in `.precomp`. A constraint
imported from an uninspected precompiled role is rejected when its source is
unavailable; declare that filter on the entity instead. This check detects direct
variable references, including interpolation, rather than proving that functions
called by a predicate are pure.

The descriptor also stores prepared clone paths for binding; execution does not
reflect over AST attributes and shares constant-only subtrees. Each execution
binds current receiver attributes to fresh parameter slots.
Ordinary replay can therefore use mutable receiver state; decisions still allow
only IDs and constants. SQL and bind layouts use a driver-scoped LRU cache of
128 shapes, separated by parameter type and nullness. Unsupported filters keep
runtime analysis and translation, so captured values are never frozen.

SQLite retains up to 128 idle prepared read statements per physical connection.
Each execution leases an exclusive handle and resets its cursor and bindings
before returning it; failures dispose the handle. Connection teardown disposes
idle handles. PostgreSQL uses DB::Pg's connection-local prepared statement cache.
The caches retain no projection instances, execution IDs, events or counter
versions. Types and methods must remain stable after composition. Non-queryable
`APPLY` signatures keep their existing error at query/replay time; merely
declaring the projection is valid.

## Advance inside an aggregate command's transaction

Annotate an `APPLY` candidate with `is transactional`:

```raku
use RedSourcing;
red-sourcing-defaults(:driver<SQLite>, :database(':memory:'));

class Credited does Event {
    has Str $.account-id;
    has Int $.amount;
}

aggregate Account {
    has Str $.account-id is entity-id;
    has Int $.amount = 0;
    method APPLY(Credited $event) { $!amount += $event.amount }
    method credit(Int :$amount!) is command {
        self.credited: :$amount;
        $!amount
    }
}

projection Balance {
    has Str $.id is entity-id;
    has Int $.amount is query = 0;
    method APPLY(Credited $event where { .account-id eq $!id })
        is transactional {
        $!amount += $event.amount;
    }
}

my $account = Account.^with-ids: :account-id<a1>;
$account.^create;
$account.credit: :amount(5);
# Balance: id = a1 already has a committed checkpoint with amount 5.
say Balance.^with-ids(:id<a1>).amount;
```

The event triggers an ordered advance of the **whole projection** through that
event's journal ID. Earlier pending events handled by unannotated candidates are
also consumed. It does not invoke only the annotated candidate out of order.
Several matching candidates or routing branches advance one identity once.

The projection state and consumed cursor are checkpointed in the same transaction
as the event. If an `APPLY` fails, the command's events and all intermediate
checkpoints roll back together. The command's technical optimistic-lock retries
reconstruct state before trying again. A handler's business exception remains a
command failure.

The process executing commands must import the modules declaring its transactional
projections. Package-scoped types are discovered from loaded modules, including
precompiled modules. A lexical `my projection` in a precompiled module must call
`MyView.^subscribe` during application initialization if no proxy is constructed
before events arrive. Constructing a proxy also registers its type. The database
does not contain executable `APPLY` definitions.

## Infer IDs from the signature

The default `Cached` lifecycle and explicit `OnDemand` infer target IDs from positive equalities in the
annotated signature. No separate mapping is required:

```raku
.account-id eq $!id                           # Different field names
$!id eq .account-id                           # Reversed operands
.client-id eq $!client-id && .month eq $!month # Composite identity
.to-client eq $!id || .from-client eq $!id     # More than one target
(.account-id ~ '-copy') eq $!id                # Computed event-side value
```

Every satisfiable routing branch must determine all `entity-id` attributes. The
implementation checks conflicting assignments, validates ID types, checks the
remaining predicates and deduplicates the resulting streams. A projection without
IDs has a single target. Rule blocks are translated into SQL filters; they are
not callbacks executed for every stored event.

The implementation does not solve arbitrary inverse expressions such as
`.amount > $!minimum` or `.account-id eq ($!id ~ '-copy')`. On-demand discovery also
rejects dependencies on mutable non-ID receiver state and native attributes such
as `int`; object-backed `Int` and `Str` IDs are supported. Unsupported discovery
raises an error and rolls back the emission rather than silently missing targets.
Conditions must be pure and SQL-translatable. Ordinary `&&` and `||` are supported;
do not replace them with Red's SQL-only `AND`/`OR` in signatures that must also
match concrete in-memory events.

## Keep instances in memory

Lifecycle is shared with aggregates and sagas. See [entity lifecycle](lifecycle.md)
for `EntityLifecycle`, per-type configuration overrides and shared cache boundaries.

Choose lifecycle in the projection declaration. Omitting brackets is equivalent
to `[:!retained]`; `[:retained]` keeps instances loaded on the connection/pool:

```raku
projection Balance[:retained] {
    has Str $.id is entity-id;
    has Int $.amount = 0;
    method APPLY(Credited $event where { .account-id eq $!id })
        is transactional {
        $!amount += $event.amount;
    }
}
```

Replace the earlier `Balance` declaration with this one. Load the identity before
submitting credits so the retained instance participates in updates:

```raku
my $proxy = Balance.^with-ids: :id<a1>;
my $view = $proxy.^load;
# Repeated load returns this registered instance on the same connection/pool.
$account.credit: :amount(2);
say $view.amount; # 7, after the command's transaction commits
$proxy.^advance; # Catch up facts written by another process
$proxy.^release; # Stop retaining this identity
```

The metaclass's `.^lifecycle(:retained)` remains available for
programmatic configuration before first use. The declaration
calls this same configuration path during compilation.

Retained target discovery scans registered instances of the subscribed type and
checks the original signature with each instance as `self` and the emitted event
as its argument. It does not execute the handler body. This supports predicates
that cannot uniquely infer IDs, including inequalities. It does not create unseen
identities. Register the instances you want to maintain by loading their proxies.

Every transaction uses detached working state. Shared instances receive the new
state only after the outer transaction commits, including caller-owned `red-do`
transactions. Rollback discards provisional scalar, array and hash changes. A
released instance receives no further updates; a later load creates a new one.

The cache is process-local and scoped to the Red connection or PostgreSQL pool.
Keep its schema/search-path configuration fixed. Another process's writes do not
push updates into this cache: call `.^advance` to catch up and refresh a newer
checkpoint. Applications sharing retained objects across threads must serialize
their reads and calls. Constraints should normally use IDs and immutable settings;
current-state conditions are evaluated before the triggered replay, using the
transaction's starting state.

## Ordering across streams

SQLite and PostgreSQL appends use optimistic stream versions and field/tag
counters. Framework writers no longer acquire a global journal advisory lock.
Database updates can wait on shared counters, and SQLite retains its native
single-writer behavior.

PostgreSQL serial IDs follow allocation order, not commit order. Independent
transactions may commit out of order. The current `id > cursor` checkpoint can
miss a lower ID that becomes visible after a higher ID was consumed. This is a
known limitation, measured by the PostgreSQL ordering diagnostic and concurrency
benchmark; it does not cause an insert exception. Full replay still sees the
persisted facts. See [decision models](decision-models.md#serial-ids-and-projection-cursors).

## Projections over journal records

A projection may handle `StoredEvent` directly instead of reconstructed domain
objects. It then receives all journal rows, including entity checkpoints and saga
controls, without loading the recorded event classes:

```raku
projection JournalCount {
    has UInt $.count = 0;
    method APPLY(StoredEvent $record) { $!count++ }
}
```

This opt-in mode scans the journal and dispatches the raw row to APPLY. Ordinary
projections continue filtering domain events from their signatures. The
[flow projection](flows.md#flow-projection) uses raw records to reconstruct
causality without running application handlers.

A raw-record projection can supply `journal-records(:from-id, :through-id)` to
select a smaller set of columns. This source must honor both bounds and return
records in journal ID order. The flow projection uses this hook to avoid loading
application payloads.
