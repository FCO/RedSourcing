# Decision models and dynamic consistency boundaries

`decision-model` combines projections into an isolated view used to make a
consistent decision across streams. It protects its reads with optimistic
counters derived from event fields and tags. Writers do not register or inspect
projection signatures, and there is no global journal advisory lock.

## A student takes at most 10 classes; a class has at most 30 students

The [complete school example](../examples/school/README.md) uses an enrollment
aggregate identified by student and class:

```raku
method enroll is command {
    decision-model(
        (StudentClasses) => %(:$!student-id),
        (ClassRoster)    => %(:$!class-id),
        -> $student, $class {
            die 'Unknown student' unless $student.exists;
            die 'Unknown class' unless $class.exists;
            do if $!active { False } else {
                die 'Student already participates in 10 classes'
                    if $student.class-count >= 10;
                die 'Class already has 30 students'
                    if $class.student-count >= 30;
                self.student-enrolled;
                True
            }
        },
    )
}
```

Parentheses around the type are significant: `Model => %ids` is parsed by Raku
as a named argument with a string key. `(Model) => %ids` supplies an ordered
positional pair whose key is the actual type. Supply every entity ID, followed
by a block receiving the projections in the same order. Its result is returned
unchanged. The older projection-proxy arguments are no longer accepted.

Each projection defines its normal `APPLY` selection rules:

```raku
multi method APPLY(StudentEnrolled $event where {
    .student-id eqv $!student-id
}) { %!classes{$event.class-id} = True }

multi method APPLY(StudentEnrolled $event where {
    .class-id eqv $!class-id
}) { %!students{$event.student-id} = True }
```

## Cached decision metadata

The ordered list of projection type identities selects a process-local plan;
order and repeated types are significant. Plans reference the descriptors prepared
on each projection's metamodel during type composition, including attributes,
ID names and prepared signatures for inherited `APPLY` candidates. These descriptors also serve ordinary replay and
are serialized with precompiled projection modules. Types and methods must remain
stable after composition. `REACT` continues to belong to saga processing and does
not select decision events.

Each call binds fresh receivers to its current IDs. Supported `where` expressions
reuse the projection's serialized, parameterized AST; unsupported expressions
retain runtime symbolic analysis. When all candidates have templates, the list
plan also stores their combined OR expression, domain exclusions, binding paths
and validated counter dependency recipes. These are composed once per ordered
list; subsequent calls bind IDs by list position without recombining or scanning
the AST. Repeated projection types therefore retain independent parameter slots.
Lists containing runtime constraints keep the original inference path.
Counter dependency recipes are cached without
bound IDs and produce fresh counter keys on every call. SQL and bind layouts are
cached per driver context; native prepared reads are reused per physical
connection. See [projection query templates](projections.md) for the supported
subset and statement lifecycle.

Counter versions are read again on every execution. Eligible reconstructed state
can also be reused as described below; nested and concurrent decisions always
keep detached state and separate IDs.

## Cached decision state

Projections using the `Cached` lifecycle and compiled, ID-only query templates
can reuse a committed reconstruction. Decision bases share the entity cache's
per-type and total capacities (100 by default), store isolation and release rules.
They contain detached projection state, its cursor/checkpoint version and the
counter versions observed during reconstruction. They are independent of public
entity references and of the objects passed to decision blocks.
Decision admission currently requires at least four applied facts since the
checkpoint. Smaller reconstructions stay uncached to avoid copy overhead and
displacing useful entities from the shared pool; ordinary entity loads keep
their existing admission policy.

The combined query still checks the latest database checkpoint and fetches the
union of tails after eligible cached cursors. A newer checkpoint supersedes the
base. Changed counters must be completely explained by fetched event tags;
otherwise the decision discards its bases and repeats the full checkpoint/tail
query. This conservative fallback handles lower-ID late commits and dependency
counters wider than the event predicate. Counter guards at append are unchanged.

Only reconstruction state captured before the user block is staged for
publication after the outer transaction commits. Rollback and savepoint rollback
discard provisional publication; mutations made by a decision block never enter
the base. Facts emitted by that block are consumed as tail events on the next
decision. Ordinary entity-cache publication invalidates decision metadata when
replacing an entry.

`OnDemand`, `Retained`, runtime query fallbacks and states containing arbitrary
mutable domain objects keep full reconstruction. State eligible for copying uses
scalar values and recursively detached Hash/Array/Map containers; cycles and
unsupported object state bypass this optimization. Cache eviction retains its
normal automatic-snapshot policy, which can emit checkpoints after commit.

## Read, decide, append

The decision freezes predicates using IDs and constants, reads their counter
versions, then restores each projection from an eligible cached base or its latest snapshot. SQLite and
PostgreSQL read snapshots and source events together in one SELECT with a
checkpoint CTE. Per-projection cursor predicates select only the required union
of replay tails; the cursors remain inside the database query. Results contain
checkpoints first, then domain events ordered by ID. A projection without a snapshot starts from its initial
state. An event populates each matching projection only when newer than that
projection's cursor, even when other projections need older events.

Every decision position has its own detached instance, including repeated
identities. Retained caches are not used or updated. Domain replay excludes
snapshots and saga control records. Reconstruction itself writes no snapshots;
cache eviction can checkpoint according to the configured lifecycle policy.

Every emitted domain event increments counters for its payload fields and values
in the same transaction as the event. Entity snapshots and native saga controls
are excluded: checkpoints accelerate reconstruction but do not change domain
dependencies. Counter guards still cover the complete predicate, including facts
already represented by a snapshot.
An active decision still validates its guards when appending metadata. Event types are not part of counter keys.
The keys preserve JSON value semantics: strings, numbers, booleans and null are
distinct; equivalent JSON numbers share a key. Nested paths and object member
order are normalized. Large values are stored outside the primary-key index;
fixed-size fingerprints are checked against their complete definitions.

The only addition supplied by a decision to an emit is a dynamic append
condition. It validates the counters on which active decisions depend, including
keys absent at read time. Validation is an atomic conditional insert/update
(CAS), not a separate unprotected SELECT. A conflicting version causes rollback.
Counters are created only on append, so loading an empty decision reserves no
rows. Multiple emits in a transaction account for their own increments.

Counters also cover events emitted outside `decision-model`. Several appends
are atomic; nested decisions use savepoints. Rollback restores provisional
entities, counter increments and pending validation together.

## Tags and field-wide dependencies

Every payload field is a tag under its original name. Add aliases with
`is tagged`, including multiple aliases or a shared alias on several attributes:

```raku
class NickChanged does Event {
    has Str $.old-nick is tagged<nick identity>;
    has Str $.new-nick is tagged<nick>;
}
```

A rename from Alice to Bob updates `old-nick=Alice`, `new-nick=Bob`,
`nick=Alice`, `nick=Bob`, and `identity=Alice`. Duplicate name/value keys are
counted once per event. Map-style event queries resolve aliases to their source
attributes:

```raku
StoredEvent.list-events((NickChanged) => %(nick => 'Alice'));
```

A field-wide counter supports predicates whose values are not known in advance:

```raku
class AmountRecorded does Event {
    has Int $.amount is tag-field;
}

projection LargeAmounts {
    has Int $.minimum is entity-id;
    has Int $.count = 0;
    method APPLY(AmountRecorded $event where {
        .amount > $!minimum
    }) { $!count++ }
}
```

`is tag-field` adds a counter for the field name regardless of its value,
including any declared aliases, while retaining ordinary value counters.
An event with a previously unseen amount therefore invalidates the decision.

Boolean AND/OR and direct field comparisons with IDs/constants are supported.
Every possible matching branch needs a positive equality or a field-wide
counter. A conjunction can be protected conservatively by its equality fields;
otherwise comparisons such as inequalities require `is tag-field`. Casts that
coerce a field also require field-wide protection unless another equality covers
the conjunction. Null-valued tags are stored and queryable, but decision
comparisons with null are rejected because absent JSON paths can compare
differently between drivers. Unbounded
and unsupported predicates fail before the block runs. Predicates cannot depend
on mutable projection state or external reads. Native projection attributes
remain unsupported; use boxed `Int`, `Num` and `Str`.

The query still filters exactly, but validation is conservative. `Alice AND
Math` can be invalidated by Bob joining Math; `amount > 10` can be invalidated by
an amount of 5. Event types sharing a field/value can invalidate one another.
A field-wide counter creates contention between all events emitting that field.

## Conflicts and retries

Counter operations are deduplicated and ordered consistently. There is no
application-acquired global lock or SQLite zero-row write reservation. Database
updates and uniqueness checks can still wait for transactions touching the same
counter. SQLite also retains its native single-writer behavior.

Inside a stored command, CAS failures, SQLite stale-write/busy conflicts and
PostgreSQL deadlocks repeat the whole command, including aggregate loading and
all decisions, up to five attempts. Several emits or nested decisions can still
acquire resources in different orders across a transaction, so deadlocks remain
recoverable rather than being claimed impossible. Nested commands propagate
conflicts to the transaction owner. Exhaustion leaves the command Pending.
Direct decisions propagate conflicts after rollback; they do not rerun just the
block. External effects must tolerate retries.

PostgreSQL decisions use READ COMMITTED. The supported drivers are SQLite and
PostgreSQL. All application appends must go through RedSourcing; direct SQL/ORM
inserts bypass counter updates.

## Excluding payload fields from tags

All payload fields are tags by default. Mark a field `is not-a-tag` to keep it
in the stored JSON without maintaining counters for it or any nested values:

```raku
class DocumentUploaded does Event {
    has Str $.document-id;
    has Str $.content is not-a-tag;
}
```

The field remains available to `list-events` and projection filters. A decision
cannot use it as a counter dependency; each query alternative still needs a
protected equality or an `is tag-field` dependency on another field. Combining
`is not-a-tag` with `is tagged` or `is tag-field` is an error, in either order.
Changing this metadata on an existing store requires the counter rebuild below.

## Serial IDs and projection cursors

Event IDs remain serial, and stream concurrency remains `(stream, version)`.
Removing the global write gate allows independent PostgreSQL transactions to
commit out of ID allocation order. A consumer using only `id > cursor` can
therefore miss an earlier ID that becomes visible later. This change does not
claim to solve that cursor limitation for ordinary replay or existing checkpoints,
and successful inserts do not establish that no events were missed. Decision
state-cache reuse additionally checks counter coverage and falls back to a full
reconstruction when its cached cursor cannot account for changed dependencies.

The PostgreSQL ordering diagnostic forces this schedule and compares persisted
facts with consumed facts. The concurrency benchmark reports cursor misses
separately from database errors, with tracing enabled or disabled.

## Existing stores

Stop application writers when installing this schema or changing tag metadata.
The normal bootstrap creates `red_sourcing_counter`. Load the application's event
modules, select the store, and rebuild counters before restarting writers:

```raku
red-sourcing-defaults;
say rebuild-event-counters(); # Number of journal rows scanned
```

Rebuilding is transactional and does not change stored events. Do not rebuild
with active writers or decisions. No automatic cleanup resets counter versions.

See the [DCB specification](https://dcb.events/specification/) and
[Axoniq's introduction](https://www.axoniq.io/concepts/dynamic-consistency-boundary).
