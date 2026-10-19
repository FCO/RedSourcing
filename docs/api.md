# Library API

Use `use RedSourcing` for the public declarations, roles, traits, `StoredEvent`,
`StoredCommand`, configuration helpers and Red database/schema helpers. The
[README quick start](../README.md#quick-start) is a complete runnable introduction.
Configure a connection and initialize tables before using the examples below;
see [shared configuration](configuration.md).

`decision-model` takes projection proxies followed by a block receiving isolated,
loaded projections. It infers their combined event query from `APPLY` and guards
all appends in the block with an optimistic consistency check. Conflicts retry
the complete stored command. See [decision models](decision-models.md) and the
[school example](../examples/school/README.md).

`EntityLifecycle` exposes `OnDemand` and `Retained` for all three entity kinds.
Declarations accept brackets, such as `aggregate Account[:retained] { ... }`,
`projection Balance[:retained] { ... }` and `saga PurchaseWorkflow[:retained] { ... }`.
`.^lifecycle` queries the effective mode; `.^lifecycle(:declared)` queries the
declaration default. `.^lifecycle(:retained)` configures a declaration before
first use and returns the type. These APIs and proxy `.^release` are shared by
all three entity kinds. See [entity lifecycle](lifecycle.md)
for configuration precedence and transaction boundaries.

The event filtering snippets use this event definition in an initialized store:

```raku
use RedSourcing;
red-defaults 'SQLite', :database(':memory:');
schema(StoredEvent, StoredCommand).create;
class UserRegistered does Event {
    has Str $.user-id;
    has Str $.name;
    has Str $.email;
}
```

Sections show alternative query patterns rather than one continuous script.

## Emitting events

Application domain events should only be emitted by commands on aggregates.
The command validates the reconstructed aggregate and calls its generated event
method. The aggregate owns the stream and supplies identity and the next version;
the command transaction saves the event and its result together.

```raku
aggregate User {
    has Str $.user-id is entity-id;
    has Str $.name = '';
    method APPLY(UserRegistered $event) { $!name = $event.name }
    method register(Str :$name!, Str :$email!) is command {
        my $row = self.user-registered(:$name, :$email);
        %(name => $!name, emitted-at => $row.created.Str)
    }
}
my $user = User.^with-ids(:user-id<ana>);
$user.^create;
say $user.register(:name<Ana>, :email<ana@example.com>);
```

Give `UserRegistered` a `$.user-id` attribute when that identity belongs in its
payload. Projections only consume facts: they cannot declare `is command`, own
domain events or emit them. Query a loaded projection with ordinary methods,
such as `$proxy.^load.summary`. Sagas request domain changes by calling aggregate
commands; their snapshots and native control events are runtime bookkeeping.

The low-level `Event.emit(:stream, :version, ...)` storage interface remains
available for framework internals and test fixtures. It bypasses aggregate command
validation and should not be used to publish application domain events. It accepts
an instance (data from public accessors) or a class (explicit data). Instance
attributes named `stream`, `version` or `data` stay in the payload; class calls
can pass these inside `:data(%(...))`.

Storage calls require both `:stream` and `:version`. Calling `$event.emit()` without arguments retains Raku's native supply emission; the bare `emit $event` routine also remains unchanged.

Every `Event` exposes `.emitted-at`, a `DateTime` taken from its journal row's
`.created`. It becomes available after a successful instance `.emit` and retains
the original recorded instant during replay, including for older records.
An event that has not been emitted has an undefined `.emitted-at`.
This metadata is outside the JSON payload; a domain `.timestamp` can still
represent when a transaction happened. Use `list-events(:after($date))` to filter
by emission time.

After replay, inspect the original emission time with `$event.emitted-at`.

## Consuming events

`list-events` returns events in ascending stored ID order. By default it reconstructs
their domain classes. Events doing the `Event` role retain their associated
`StoredEvent` row through the `StoredEvent` accessor; this internal reference
is omitted from their default gist.

Use `:row` to return the stored `StoredEvent` records without constructing
domain objects. Stream, type and payload filters still apply. A row exposes its
`id`, `class`, `version`, `stream` and `data`; call `$row.COERCE` to reconstruct its
recorded class when that class is loaded. `:!row` uses the default reconstruction.

Reconstruction currently uses `.bless` for both events and entity snapshots,
passing the persisted payload and the stored row as `:StoredEvent`.
`BUILD` and `TWEAK` still run, but a custom `.new` method is not invoked during
replay. Initialization required for reconstruction belongs in those hooks under
the current contract. After they finish, the journal reference is attached to
events even when a custom `TWEAK` overrides the role's hook, preserving
`.StoredEvent` and `.emitted-at`.

```raku
for StoredEvent.list-events(:row, :stream<users>) -> $row {
    say "{$row.id}: {$row.class} at version {$row.version}";
}
```

Filters include `:from-id`, `:from-snapshot-of-type`, `:stream`, `:after` and
`:@types`. `:types` may contain multiple event classes. `:from-id` is exclusive:
only rows whose IDs are greater than the given ID are returned.

`:from-snapshot-of-type` finds the latest stored instance of that class within the
requested stream and includes it as the start of replay. Without type or payload
filters, all subsequent events are returned. With explicit filters, the snapshot
is included alongside the matching subsequent events. Earlier snapshots remain
stored in the stream but are excluded from this replay. If no snapshot exists,
the original filters apply to the full history. This option cannot be combined
with `:from-id`; it replaces the old `:including-event-of-type` name.

Use `:stream` when reconstructing an entity. Without it, snapshot selection is
global. Currently `:after` filters every returned row, including the selected
snapshot, so it can remove that first item. Omit it for complete entity replay;
the snapshot-preserving filter contract is tracked in [Next steps](next-steps.md).

## Filtering by event data

`list-events` accepts filter **rules** as an alternative to `:@types`. A rule is a `Pair` whose key is an event type object and whose value is either a `Hash` of expected field values or a `Callable` containing a predicate that Red can translate into a query. Hash values are combined with AND; when several rules are given, an event matches if **any** of the rules matches.

```raku
# A rule with a hash of values: the event must match all of them.
my @jane = StoredEvent.list-events: (UserRegistered) => %(name => "Jane");

my @jane-with-email = StoredEvent.list-events:
    (UserRegistered) => %(name => "Jane", email => "jane@example.com");

# Red translates this predicate into a SQL WHERE condition.
my @john = StoredEvent.list-events:
    (UserRegistered) => -> $event { $event.name eq "John" };

# Several rules are combined with OR.
my @either = StoredEvent.list-events:
    (UserRegistered) => %(name => "Jane"),
    (OrderPlaced) => %(qty => 10);
```

**Parenthesize the event type object in the rule key.** Without parentheses, Raku treats the bareword as a string, and the pair can be routed as a named argument instead of a positional rule. With the type object parenthesized, a single rule can be passed directly; no list wrapper is needed:

```raku
(UserRegistered) => %(name => "Jane")   # correct: a positional Pair with the type object
UserRegistered => %(name => "Jane")     # wrong: bareword string / named argument
```

**A rule block is not called once for each stored event.** Red evaluates it with
query expressions to build a SQL `WHERE` condition, then the database filters
the rows. For example, `$event.name eq "John"` becomes a comparison on the
payload's `name` field. Only matching records are returned and reconstructed.
Use SQL-translatable expressions rather than arbitrary Raku computation, I/O or
side effects in these blocks. This differs from `.grep` on an already loaded
Raku list, which runs its predicate in the application for each item.

## Rules from handler signatures

`use RedSourcing` exports `rules-from-func`. Pass a projection instance and
its handler method to build one rule per candidate. The signature binder supplies
that instance as `self`, so `where` blocks can read its private attributes. Rule
construction and querying do not execute the handler body.

```raku
use RedSourcing;

class RegistrationsByName {
    has Str $.name;
    multi method APPLY(UserRegistered $_ where { .name eq $!name }) { ... }
}

my $registrations = RegistrationsByName.new(:name<Jane>);
my @rules = rules-from-func($registrations, $registrations.^find_method('APPLY'));
say .name for StoredEvent.list-events(|@rules);
```

For a subroutine, use `rules-from-func(&handler)` without an instance. Each
candidate must have exactly one explicit, non-slurpy positional event parameter.
Candidates for the same event type remain separate rules combined with OR.

Named scalar sub-signatures can destructure JSON fields, including nested fields:
`UserRegistered $_ (:$name where { $_ eq 'Jane' })`. These fields currently need
one external name and no explicit nominal type or default. Unsupported aliases,
typed fields, defaults and positional destructuring throw when the rules are
materialized. Constraints must use expressions Red can translate to SQL.

The query uses a copy of the signature whose event parameter accepts the JSON
query view. The original event type remains the rule key, and the handler's
signature and shared parameters remain unchanged. This adaptation relies on
Rakudo internals; the regression tests cover both SQL binding and subsequent
normal handler dispatch.

## Mapping projection values

Transactional projection subscriptions infer identity from their `APPLY`
equalities and do not require these explicit loader mappings. See
[projections and transactional updates](projections.md) for `is transactional`,
`.^advance`, declarations such as `projection MyView[:retained] { ... }`, and `.^release`.

`map-list-events` is a convenience built on top of `list-events` that turns event field values into a loader for a given projection identity. Each mapping describes one event class and how the value to match is obtained from the projection. A `Callable` value is called with the projection; any other value is read as a key when the projection is an `Associative`, or as an accessor method otherwise. Event domain classes are ordinary Raku classes doing the `Event` role; they do not need to be Red models.

```raku
class UsersByName {
    has $.name;
}

my $projection = UsersByName.new(name => "Jane");

my &load-jane = StoredEvent.map-list-events:
    (UserRegistered) => %(name => "name"),
    :data($projection);

say .email for &load-jane();
```

The mapped value can also be computed from the projection with a `Callable`:

```raku
my &loaders = StoredEvent.map-list-events:
    (UserRegistered) => %(name => -> $p { $p.name }),
    :data($projection);
```

A value that is not a `Callable` names the field of the projection to read. It works both with a hash and with a plain class:

```raku
my &loaders = StoredEvent.map-list-events:
    (UserRegistered) => %(name => "name");

&loaders(%(name => "Jane"))();                # reads the key
&loaders(UsersByName.new(name => "John"))();   # reads the accessor
```

`map-list-events` is a factory: calling it without `:data` returns a routine that takes the projection and returns the loader, which is handy to bind the mapping once and reuse it for many projections.

```raku
my &make-loader = StoredEvent.map-list-events:
    (UserRegistered) => %(name => -> $p { $p.name });

for %projections.values -> $projection {
    say .name for &make-loader($projection)();
}
```

## Entities and stored commands

The command API stores commands in `StoredCommand`, separately
from the versioned event history. Declare an `aggregate` (or a saga control command), mark
its identity attributes with `is entity-id`, and mark handler methods with `is command`.
`EntityType.^with-ids` creates a proxy containing only those IDs. For an aggregate,
call `.^create` on the proxy to persist its initial snapshot before submitting commands. Calling a
command first persists a `Pending` record, then executes it synchronously by
default. The executor loads the entity through its metaclass before invoking
the handler: aggregates replay their own stream, while sagas restore their
committed control state. Projections reject `is command` at compilation. Load
them with `.^load` and call ordinary read methods; these queries create no
`StoredCommand` records and cannot own or emit domain events.

```raku
use RedSourcing;

red-defaults "SQLite", :database(":memory:");
schema(StoredEvent, StoredCommand).create;

class CounterIncremented does Event {
    has Int $.id is required;
    has Int $.amount;
}

aggregate Counter {
    has Int $.id is entity-id;
    has Int $.value is rw = 0;
    method APPLY(CounterIncremented $event) {
        $!value += $event.amount;
    }

    method increment(Int :$amount = 1) is command {
        self.counter-incremented(:$amount);
        $!value
    }
}

my $counter = Counter.^with-ids(:id(42));
$counter.^create;                            # Persist the initial entity snapshot
say $counter.increment;                      # 1

my $row = $counter.increment(:amount(2), :!sync);
say $row.state;                             # Pending
say $row.run;                               # 3
say $row.run;                               # 3; the handler does not run again
```

Entity IDs are required on the proxy and retain their declared types. A
stream name consists of the entity name and its IDs sorted by attribute name,
for example `Counter: id = 42`. The proxy's `.^ids-map` exposes these IDs separately
from the command payload. Generated command classes include the entity name,
for example `Counter::Increment`; the original method name is stored separately.

`is entity-id` marks persisted identity for an aggregate, projection or saga.
It determines proxy IDs and the entity's stream; `APPLY` predicates can also read
ordinary attributes that are not marked. Entity identity helpers are
`.^entity-id-attrs`, `.^entity-id-names` and `.^entity-id-map`.

Creation, identity and history helpers belong to `Metamodel::RedSourcing::ProxyHOW`.
Call them with `.^`: `$counter.^create`, `$counter.^load`, `$counter.^ids-map`,
`$counter.^stream-name` and `$counter.^list-commands`.
The proxy metaclass keeps the original entity type,
so the stream uses `Counter`, even though the proxy type is named `CounterProxy`.
Command methods such as `.increment` remain ordinary proxy methods. A handler
named `create` can be declared with `is command`: `$counter.create` submits that
domain command, while `$counter.^create` writes the initial snapshot.

The entity's `.new` method rejects direct construction. Create persisted entities
through `EntityType.^with-ids(...).^create(...)`; restoring their snapshots uses
`.bless` and initializes the private metadata in `TWEAK`.
Entity helpers also use `.^`: `.^data`, `.^version`, `.^current-id`, `.^stream`
and `.^load` are shared by the internal `EntityHOW` base. The `aggregate` keyword
uses `AggregateHOW`, and `projection` uses `ProjectionHOW`; both extend that base.
`.^load`, `.^create`, `.^replay` and
`.^emit-snapshot` choose their behavior from the declared type, with no mode flag.
`AggregateHOW` provides `.^apply-model` and `.^apply-new-events-of-stream`;
`ProjectionHOW` provides `.^apply-new-applyable-events`.

### Aggregate event methods

A concrete event class in an aggregate's single-event `APPLY` signature generates
an emission method on the loaded aggregate, using the event's short name in
kebab-case: `CounterIncremented` creates `counter-incremented`, and
`HTTPRequestReceived` creates `http-request-received`. Proxies and projections do
not receive these methods. Multiple `APPLY` candidates for one event type share
one emission method and must agree on its identity mapping. A broad `APPLY($event)`
or a parameter typed only as the `Event` role does not generate a method.

The generated method accepts `|c`, forwards positionals and named arguments to
the event constructor, and fills matching public event fields from `is entity-id`
attributes. IDs absent from the event's attributes are omitted. Event constructors
retain their required attributes, types, defaults and custom argument handling.
Named identity overrides are rejected unless they match the aggregate; a custom
constructor cannot change the injected IDs either.

To rename an identity field for an event, annotate its `APPLY` candidate. The map
direction is **event field => entity ID**; a mapped ID replaces its default field
name, while other IDs keep their matching-name behavior:

```raku
multi method APPLY(Transaction $event)
    is entity-id-map(:from-client<client-id>) {
    $!amount -= $event.amount;
}

method transfer(Int :$to-client!, Rat() :$amount!) is command {
    self.transaction(:$to-client, :$amount);
    $!amount
}
```

The snippet shows the mapping and emission pattern; the runnable bank example
also validates the recipient and writes its credit. Mappings to unknown identity
attributes or non-public event fields fail during composition. Generated names
that collide with domain methods or another event type's short name also fail.
Inherited helpers are regenerated with the child's identity fields.

Before persistence, the constructed event must match an `APPLY` candidate. The
helper then emits it to the aggregate's stream at `.^version + 1`, applies the
stored event (with its row attached), updates version and cursor, and returns the
stored `StoredEvent` row. Two emissions in one command use consecutive versions
and the second sees the first's updated state. Handlers return that updated state;
adding the change again would double-count it. Replay skips already applied rows.

These helpers share the command executor's transaction and do not open nested
transactions. Command failure discards the loaded entity and rolls back emitted
rows; retry loads committed state again. Always call generated event methods
inside aggregate command handlers. Direct low-level `Event.emit(...)` bypasses
this workflow and does not update an aggregate automatically; it is reserved for
framework internals and test fixtures.

### Snapshots and incremental replay

A snapshot is the entity itself, serialized into a `StoredEvent` row whose
`class` is the entity type. `.^create` accepts initial state, for example
`$counter.^create(:value(10))`, and returns the stored snapshot row. Call it once
for each new identity; creating the proxy alone does not persist an entity.
Entity IDs and `stream` always come from the proxy and take precedence over
arguments supplied to `.^create`. Other arguments initialize the domain state.

The entity role keeps `version`, `current-id` and `stream` in private attributes.
Read them through `$entity.^version`, `$entity.^current-id` and `$entity.^stream`;
the first two accessors are writable. Version and cursor start at `0`, and the
initial snapshot has version `1`. The snapshot payload contains public domain
attributes, including entity IDs; `.^data` excludes the private metadata.
Restoration takes version, cursor and stream from the stored row. `version`
belongs to the stream; `current-id` is an exclusive global ID cursor. Aggregate
snapshots use their own row ID; projection snapshots preserve the last consumed
event ID in `replay-cursor`. Handlers use `self.^version` when deriving event versions.

A stream may retain multiple snapshots. `$proxy.^load` selects the latest snapshot
of the entity type in the proxy's stream, reconstructs it through `.COERCE`, then
folds subsequent stream rows through `.^apply-model`. It returns the entity and
throws an explicit error if the aggregate has no snapshot. Initial-state arguments
do not override a stored snapshot. Command execution uses this same loader:

```raku
my $entity = $counter.^load;

$entity.^apply-new-events-of-stream;   # Fold this stream's rows after current-id
$entity.^emit-snapshot;      # Store another checkpoint and advance the cursor
```

`.^apply-model` accepts a stored row. For domain events, it reconstructs the event
and calls the application's uppercase `APPLY` method before advancing the version
and cursor. A snapshot row encountered during incremental replay advances those
two metadata fields without calling `APPLY` or adding its serialized state again.
This also handles checkpoints published by another instance. Snapshots record the
state produced by the preceding events; later business changes belong in events.

### Projection replay across streams

Declare it with `projection` and load it through `$proxy.^load`. It restores the latest
snapshot of that type in the proxy's own stream. If none exists, it initializes
the entity from its defaults and supplied initial state, with the proxy's IDs
and stream taking precedence. Only after initialization does it derive the
`APPLY` rules and replay applicable domain events across all streams.

For example, using `CounterIncremented` from the command example:

```raku
projection TotalIncreases {
    has Str $.name is entity-id;
    has Int $.value = 0;
    method APPLY(CounterIncremented $event) { $!value += $event.amount }
}

my $totals = TotalIncreases.^with-ids(:name<all>);
my $projection = $totals.^load;
$projection.^emit-snapshot;   # Persist state and consumed cursor
$projection = $totals.^load; # Restore, then replay newer events
$projection.^apply-new-applyable-events;  # Incremental replay on this instance
```

Initial loading returns a new entity with the default `OnDemand` lifecycle.
`Retained` lifecycle reuses registered instances on the connection/pool. For an
already initialized projection, use:

```raku
$projection.^advance;
```

This builds rules from the instance's `APPLY` candidates and queries matching
rows after `.^current-id` across all streams, including its own. The `where`
constraints can use ordinary attributes such as client and month; those attributes
do not need `is entity-id`. Matching rows are
applied in ascending database ID order, and the cursor advances after each
successful `APPLY`. Repeating the call skips previously applied rows. No
candidates or no matching rows leave the instance unchanged. A handler exception
propagates and leaves the cursor at the last successful event; this helper does
not roll back changes already made to the in-memory entity.

Source stream versions do not update the projection's `.^version`, and replay
retains its stream identity. `.^apply-new-events-of-stream` remains the aggregate
path: it selects the entity's own stream and advances both its version and cursor.
For an aggregate, `.^emit-snapshot` uses that stream path. For a projection it
uses applicable-event replay and preserves the consumed global cursor. Both
types expose `.^replay` to select the corresponding incremental method.

Projection replay excludes all entity snapshot rows, including snapshots matched
by a broad `APPLY($event)` signature. Only the projection's own latest snapshot
is used for restoration; snapshots from source streams are not domain events.
The `list-events` snapshot/filter contract is described above.

On a projection, `.^emit-snapshot` first replays applicable events, then saves the
entity state, its next checkpoint version and the actual consumed `replay-cursor`.
It leaves the live cursor at that consumed ID rather than advancing to the new
snapshot row. This preserves events appended between replay and publication.
Cursor zero is valid. A competing checkpoint causes a database unique-constraint
error; reload through `.^load` before retrying, so stale state does
not overwrite a newer checkpoint. Aggregate snapshot retries remain unchanged.

Projection snapshots must contain their consumed `replay-cursor`. Loading a
checkpoint without that metadata fails; rebuild the projection from source facts
rather than substituting the snapshot row's ID. Cursor zero is valid.

### Command parameters

Use named scalar parameters for command payloads. Required parameters and nominal
types are checked when constructing the generated command. Literal and independent
calculated defaults are evaluated once when an omitted argument is filled during
construction, then persisted in `data`. Explicit values bypass that evaluation,
and later execution uses the recorded value.

Named aliases are normalized before construction. For example, this handler
accepts either `:a(4)` or `:b(4)` and returns `14` with either spelling:

```raku
method even-value(:b(:$a) where { $_ %% 2 } = 8) is command { $a + 10 }
```

Both spellings persist `a => 4`; omitting the argument persists the default `8`
and returns `18`. The canonical payload key is the first name returned by the
parameter's `.named_names`. A separate external name such as `:input($value)`
is also supported: the payload key is `input`, and the handler uses `$value`.
The normalized payload is checked against the original handler signature before
persistence. A value such as `:b(3)` fails the `where` constraint and throws
without creating a command row, in both synchronous and deferred modes.

Extra named arguments that an ordinary handler ignores are also ignored by the
proxy and omitted from the persisted payload. Full preservation of explicit
slurpy parameters and their constraints is still pending; the proxy must follow
the original method's binding rules rather than impose blanket rejection of extras.

Defaults that refer to another parameter or to `self` are unsupported by the
current generation mechanism. `:sync` is reserved for execution mode and is not
part of the payload.

### Execution and results

`:!sync` persists and returns the record without executing its handler. Run the CLI
`work` command to process due pending rows, or call `$row.run` from an application,
using the same executor as the synchronous path. The entity and event classes must be
loaded in the executing process, and the entity must implement `APPLY` for its
domain events. Aggregate command execution requires an existing snapshot in its
stream. Saga command execution restores its committed control state. Projections
are read with `.^load` and ordinary methods rather than this command executor.
Synchronous and deferred aggregate commands use the same metaclass-driven loader.
The executor and explicit row coercion use `resolve-class` from
`RedSourcing::Utils`: it first checks the current scope, then requires the
named module or its namespace parents. This supports unit aggregates/projections
and exported event classes defined inside another module. Missing dependencies
from within a module still propagate.

During the handler, `$*COMMAND` is the command record. Generated aggregate event
methods use the loaded entity's stream and next version automatically.
Emitted events, the result and the transition to `Done` are saved in one database
transaction. Results may be JSON-compatible scalars, arrays or maps. A `Nil`
result becomes undefined (`Any`) and still completes the command. Execution
failures throw after recording the error; skipped or already-processing commands
can also return no defined result, so inspect `state` when using `.run` directly.
`.run` refreshes its stored fields first: a completed command returns its saved
result, and a command stored as `Processing`
is left for its current executor. These checks also apply to an old instance
that still holds `Pending` locally.

Before invoking the handler, `.run` updates the command row without changing its
state to acquire the database write lock, refreshes it again, and rechecks state
and schedule. It then changes `Pending` to `Processing` within that transaction.
The handler sees this state through `$*COMMAND`; successful completion saves `Done`
and clears any error message from a previous attempt in the same transaction.

### Scheduling and attempts

New commands initialize `next-run` to the submission time. By default, `.run`
returns no defined result for a pending command whose `next-run` is still in the
future, leaving its state and attempt count unchanged. Use `.run(:wait)` to wait
for that time and receive the result of an execution attempt:

```raku
my $scheduled = $counter.increment(:!sync);
$scheduled.next-run = DateTime.now.later(:seconds(0.1));
$scheduled.^save;
say $scheduled.run(:wait);                 # 4, after the earlier examples
```

Waiting happens outside the transaction. If the locked read finds a newly
postponed schedule, it leaves the command pending and exits the transaction before
checking again. Without `:wait`, the future command is skipped; with `:wait`, it
waits for the updated time. `Done` and `Processing` are checked before any wait.
The synchronous proxy currently calls `.run` without `:wait`; new commands are due
immediately, but the proxy does not opt into waiting for a postponed schedule.

`tries` increments immediately before each handler invocation. Success saves the
count with the result; a handler failure saves it with the error after rollback.
Optimistic retries count each handler invocation on the same record.
Waiting, skipped commands and reading saved results add no attempts. Errors during
reconstruction before the handler is invoked do not increment this counter.

`RedSourcing::X::OptimisticLockFailed` is handled as technical contention. When
`.run` owns the transaction, it rolls back the complete attempt, reacquires the
command row lock, rechecks state/schedule, reconstructs the entity from committed
events and runs the same handler with its stored normalized arguments. It makes
up to **five attempts per execution pass**. Only the successful attempt commits
its events, telemetry and result. Defaults are not evaluated again.

If all five attempts conflict, the command remains `Pending`, retains its schedule
and invocation count, and has no saved failure/result. The last conflict is
rethrown to the executor; a later worker pass or `.run` can resume the same record.
A saga retains the same running action and child command for its next advance;
this does not consume saga retry policy or trigger compensation.

Red 0.2.7 provides savepoints for explicit nested `red-do :transaction` scopes.
RedSourcing preserves its batch-level retry policy: a `.run` inside an existing transaction
propagates optimistic conflicts to that transaction's owner, which must roll back
and restart the complete batch. It does not retry inside an aborted transaction.
Handlers may therefore run more than once. Keep external effects in saga services
with their idempotency/recovery protocol; SQL rollback cannot undo an HTTP request.

On other failures, the transaction rolls back its events. The record is then saved as
`Failed` with the exception message in `error`, and the original exception is
rethrown. This applies to synchronous and deferred calls, including `.run(:wait)`.
A failed record is terminal: calling `.run` again reports its saved error and does
not invoke the handler or schedule another attempt. Retry requires a new command
submission. Sagas own retry limits, delays and backoff; see [Sagas](sagas.md).
`next-run` remains the initial execution schedule.

### Command history

`StoredCommand.list-commands` returns a `Seq` of stored command records ordered
by ascending `id`. It accepts `:stream`, `:state` and an exclusive `:from-id` cursor.
Filters apply together; omitting them returns the whole history. Records expose
their payload, result, error and `next-run`, and can be executed through `.run`.

```raku
my @history = $counter.^list-commands;
my @completed = StoredCommand.list-commands:
    :stream($counter.^stream-name),
    :state(StoredCommand::State::Done),
    :from-id(0);

for @completed -> $command {
    say "{$command.id}: {$command.state} = {$command.result}";
}
```

The proxy's `.^list-commands` supplies its own stream and forwards the other
filters. Passing another `:stream` to the proxy does not change its scope; the
proxy's stream takes precedence. Use the model method to query other streams.

Listing does not execute or reserve commands. It includes future scheduled
commands and all states unless filtered. The model method currently has no `:limit`, entity/command
filter or ready-work option. The CLI supplies these filters and limits; its
`work` command selects `Pending` rows whose `next-run` has arrived. Failed commands are excluded; a saga
retry creates a new pending record.

## Schema versioning

Each stored event has an `event-schema-version`, initially `0` unless the event class provides an `api` version. The `update` CLI command can migrate rows for one event class from a source schema version to a target version. It applies a Raku transformation to each matching row's data and saves the transformed JSON with the target version. All matching rows are migrated in one database transaction; if a transformation or save fails, the entire batch is rolled back. External side effects performed by transformation code are not rolled back.

    # Change the data key from "something" to "name" for stored version 0 events.
    red-sourcing update \
        -c=MyApp::UserRegistered -v=0 -n=1 \
        -e='.<name> = .<something>:delete' --database=events.sqlite3

    # Inspect which rows match without transforming or saving them.
    red-sourcing update \
        -c=MyApp::UserRegistered -v=0 -n=1 \
        -e='.<name> = .<something>:delete' --dry-run --debug \
        --database=events.sqlite3

`--new-version` defaults to the source version plus one. The transformation body is evaluated as Raku for each matching row; by default, `$_` refers to the row's mutable data, passed through `StoredEvent (:data($_), |)`. Use `--trans-signature` to supply a different signature. `-c`/`--class` selects the stored event class, while `-v`/`--version` selects the source schema version. With `--dry-run`, no transformations are applied or saved; use `--debug` to inspect the matching rows.

## Database and concurrency contract

`StoredEvent` uses table `red_sourcing_event`; `StoredCommand` uses
`red_sourcing_command`. The unique `(stream, version)` constraint detects stale
writers. Command execution automatically reconstructs committed state before
retrying a conflict; simply choosing a larger number on an old entity can
invalidate domain validation.

A business or other handler failure rolls back database events and records a
terminal failure. Optimistic conflicts follow the retry/pending contract above.
External calls performed directly in a handler are outside that rollback; use
saga service intents for provider work. Transaction ownership constraints
and multi-executor ownership are described in the [roadmap](next-steps.md).

SQLite is exercised by the main suite. PostgreSQL JSON translation, the estate
workflow and independent command writers have dedicated checks; see [testing](testing.md). Other Red drivers have
not been validated by this project's integration suite.

## Related APIs

- [Sagas](sagas.md): state/reaction scopes, services, retries, compensation and timeouts.
- [Configuration](configuration.md): default connections and shared file settings.
- [CLI](cli.md): command preparation, history, migrations and entity inspection.
- [Roadmap](next-steps.md): unsupported signatures and concurrency work.

## Automatic snapshot policy

All three declarations accept `[:retained, :auto-snapshot{ :100count, :300seconds }]`.
`.^auto-snapshot` returns the effective immutable policy or an undefined value when
disabled; `:!auto-snapshot`, `:auto-snapshot(False)` and `:auto-snapshot(Nil)`
all disable optional snapshots. `:declared` reports the declaration default. The built-in policy is
`count => 100`. See [automatic snapshots](auto-snapshot.md) for count semantics,
configuration, rollback and required checkpoints.
