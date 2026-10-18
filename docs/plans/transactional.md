# Transactional projection triggers

Status: implemented initial API. See [the projection guide](../projections.md)
for the supported interface. The design and initial experiment notes below retain
the alternatives considered; implementation decisions and follow-ups are listed
here so those alternatives are not mistaken for current behavior.

## Implementation decisions

- `is transactional` is supported on projection `APPLY` methods. On-demand targets
  are inferred from positive equalities; complete branch predicates are validated
  in SQL after ID normalization. Ordinary `&&`/`||` tracing now explores each
  reached boolean path independently, resolving the initial experiment's OR issue.
- Projections support `.^advance`, optional `:checkpoint`, bounded replay through
  `:through-id`, and `projection MyView[:retained] { ... }`. The default lifecycle
  is `OnDemand`. Retained instances are registered through `.^load` and
  released through proxy `.^release`.
- Retained matching uses concrete original signatures. Per-transaction copies and
  driver commit/rollback hooks publish only after the transaction owner commits.
  Registrations created inside a transaction also remain provisional until commit.
- Lifecycle declarations now cover aggregates, projections and sagas through
  `EntityLifecycle`. Configuration `entities` entries override the declaration per
  connection/pool and freeze on first use. The shared cache lives in
  `RedSourcing::Lifecycle`; aggregate commands fold new facts before validation,
  and saga controls publish incrementally after their existing commits. See
  [entity lifecycle](../lifecycle.md).
- PostgreSQL uses the serialized append-gate alternative, scoped by the journal
  table OID; SQLite relies on its database writer lock. Framework event, snapshot
  and saga-control writes participate. Commands retain their bounded optimistic
  retry; the append gate is acquired at the append phase, not before computation.
- Subscription metadata lives on each projection HOW. Runtime discovery recovers
  package-scoped types from loaded/precompiled modules without compiler-frontend
  hooks. Lexical private types can use `.^subscribe`; proxy construction also
  registers their type.
- Native attributes and non-ID receiver-state dependencies remain unsupported for
  on-demand inference. Arbitrary inverse algebra is not implemented. Retained
  discovery can match known instances instead of solving for their identities.
- The cache is local to a connection/pool and process. Cross-process invalidation,
  a synchronized shared-object read API and a more concurrent per-projection
  ownership protocol remain follow-ups.

The regression suite includes mixed annotated/unannotated replay, routing,
retention/rollback and separate PostgreSQL processes with explicit barriers. The
historical temporary experiment results below describe the earlier prototype.

## Name and contract

The trait name is `is transactional`. It marks a trigger for advancing the whole
projection, rather than running only the annotated handler in the transaction.

The trait marks an `APPLY` candidate whose event type triggers an ordered advance
of the **whole projection instance** within the emitting transaction. Replay uses
all of the projection's `APPLY` rules, including unannotated candidates, through
the triggering event's journal position. State and cursor are checkpointed in
that same transaction. A handler failure rolls back the emission and projection
changes together.

Lifecycle is independent. On-demand instances and a store-scoped retained cache
are implemented; retained publication occurs after the outermost commit.
The declaration's lifecycle configuration
must not change replay ordering or the meaning of this trait. Without transactional
triggers, projections continue to advance on demand.

## Identity routing and initial experiments

An annotated candidate registers its projection type, accepted event type and
target discovery policy. Type matching must consider event inheritance and roles.
An explicit field mapping is not required for the common equality case. Select
targets differently for retained instances and instances created on demand.

### Retained instances: match the original signature

For each registered instance of a subscribed type, test the annotated candidate's
original signature against a capture containing the instance and the emitted
event. This checks event type and constraints with the correct `self`, without
executing the `APPLY` body. It requires neither a mapping nor symbolic inference.

This can match several instances and handles ordinary `||`, inequalities and
transformed IDs. Index the registry by store and event type before scanning it;
matching costs grow with the number of eligible retained instances. Only explicitly
registered instances participate: this scan does not create unknown identities.

Matching uses the transaction's working instances, with a defined committed state
boundary, rather than mutating shared cached objects. Constraints must be pure.
State-dependent constraints require an explicit freshness/replay contract; the
experiment below verifies concrete matching, not that transactional contract.

### On-demand instances: infer identity from symbolic equalities

Trace the signature with a detached symbolic receiver and the existing Red event
view. Each `entity-id` attribute represents a distinct symbolic unknown, so Red
can retain both sides of a relation such as:

```raku
method APPLY(MessagePosted $event where {
    .repair-id eq $!repair-id
}) is transactional { ... }
```

The equality determines the target's `repair-id` from the event field. Different
names and reversed operands work too: `.to-client eq $!client-id` and
`$!client-id eq .to-client` describe the same routing relation. Do not infer IDs
just because an event field and an attribute share a name; the signature must
actually establish the relation.

- Extract positive equalities assigning an ID symbol from an event-only expression
  or a constant. Conjunctions can determine several IDs.
- Treat disjunctions as separate candidate branches. Every satisfiable branch
  must determine all IDs. Respect negations and residual predicates; collecting
  every equality found anywhere in the AST is incorrect.
- Compute supported event-side expressions with Red/SQL. A calculation such as
  `(.to-client ~ '-copy') eq $!client-id` does not require inverse algebra.
- Check repeated assignments for consistency, normalize values through the
  declared ID types, reject incomplete or invalid identities, and deduplicate
  targets by projection type and canonical stream.
- Validate the complete predicate for each candidate and restore its actual state
  before ordered replay. An equality-derived identity is only a candidate.
- A projection without IDs has one target, still subject to its event filters.

Do not promise to invert arbitrary expressions involving the projection ID.
For example, `.amount > $!amount` has many solutions, and
`.to-client eq ($!client-id ~ '-copy')` needs an inverse the prototype does not
provide. Non-ID receiver state must not silently become a default constant during
discovery: symbolize/defer it or explicitly reject unsupported dependencies.

If discovery cannot be proved complete, reject the on-demand subscription clearly.
An explicit deterministic router could be a later escape hatch; it is not a
mandatory mapping duplicated alongside ordinary `APPLY` equalities. Scanning
retained instances remains a separate option for otherwise unsupported predicates.

Replay keeps the existing SQL translation of `APPLY` rules; it does not run a
callback once per stored event. Retained target discovery intentionally evaluates
a constraint once per eligible instance against the single triggering event.

### Temporary experiment results (2026-10-13)

Experiments live outside the repository in `/tmp`:

- `redsourcing-transactional-probe.raku`: two checks demonstrating that an identity
  symbol survives a typed private `Str` attribute read and remains in Red's AST.
- `redsourcing-transactional-inference.rakutest`: 37 checks, with 35 ordinary checks
  passing and two short-circuit-OR checks explicitly marked TODO. The TODO checks
  sometimes passed and sometimes lost valid targets; they are not resolved.

The full inference experiment ran against Rakudo 2026.09 / Red 0.2.5 on the host
and Rakudo 2026.06 / Red 0.2.5 in `redsourcing:ci-fixes-test`. The Docker run also
passed the two-check probe. Earlier exploratory runs used host Rakudo 2026.08 /
Red 0.2.3. The database was temporary in-memory SQLite. No framework implementation
or project tests were changed.

Observed results:

| Case | Result |
| --- | --- |
| Same-name, renamed and reversed string equality | IDs inferred successfully |
| Composite IDs with `&&` and an additional amount filter | IDs inferred; residual predicate executed in SQL |
| Numeric `Int` ID with `==` | ID inferred successfully |
| Event-side string concatenation | Computed in SQL and used as the ID |
| Repeated equalities for one ID | Consistent values accepted; contradictory values produced no target |
| Missing ID or an OR branch without a complete identity | Rejected by the prototype |
| Identity-free projection | One target for an accepted event; none for a rejected event |
| Retained instances matched through `Signature.ACCEPTS` | Correct type, `||`, inequalities, transformed IDs and concrete receiver-state checks |
| Short-circuit `||` traced through `rules-from-func` / `Signature.ACCEPTS` | Inconsistent AST branches and omitted valid targets across runs |
| Explicit Red `OR` with symbolic operands | Correct SQL inference and deduplication in the experiment |
| Explicit Red `OR` with concrete signature matching | Failed with unsupported `Bool, Bool` operands; not a shared API workaround |
| Symbolic AST-to-AST `>` | Red operator dispatch reported an ambiguous call |
| Native `int` attribute | Object-symbol injection failed; separate representation needed |

The probe bypasses typed attribute storage with `nqp::bindattr` on a detached
instance. This establishes feasibility for object-backed `Str` and `Int` IDs,
but is not a finalized production representation. It must never touch a live
instance or mutate its type, handler or original signature.

The inference proof evaluates AST expressions through SQLite queries against the
triggering row. It deliberately issues several queries for inspectability; it is
not a performance design or a completed emission hook. All test handler bodies
throw if executed, so successful matching/discovery did not execute those bodies.

Before supporting inferred disjunctions, reproduce and fix the short-circuit
constraint-tracing issue, then prove equivalence to concrete signature matching.
Explicit Red `OR` only proves that the AST can represent the desired relationship;
it is not proposed as required public syntax. Equality/conjunction inference and
retained-instance matching are promising first steps; arbitrary inversion is not.

## Registration and execution

Keep descriptors in a registry indexed by event type. Store configuration on the
projection HOW and handler metadata, without adding projection-specific code to
event classes. Registration must be idempotent across imports and inheritance.
Only projection `APPLY` candidates can carry the trait; unsupported signatures or
incomplete inferred identities fail explicitly for on-demand discovery.

Collect candidate metadata before `EntityHOW.compose` wraps `APPLY`. Resolve
registration after the projection identity and proxy metadata are available.
Configuration must be finalized before first use; changing discovery policy must not
leave obsolete subscriptions registered.

For each domain emission:

1. Join the existing transaction, or establish a transaction covering the append
   and projection work when the public emitter has no transaction owner.
2. Write the event and preserve its existing return value and emission metadata.
3. Find registered triggers; match retained instances or infer on-demand identities
   from their annotated signatures. Deduplicate the resulting targets.
4. Obtain a transaction-local working instance for each target. Avoid replaying
   once in `.^load` and then applying the triggering event a second time.
5. Advance all matching pending events in journal order, bounded by the trigger.
6. Persist changed state and its consumed cursor atomically. Do not write a
   checkpoint for a no-op advance.
7. Publish retained state only when the outermost transaction commits. Rollback
   and optimistic retries discard provisional instances and publication callbacks.

Snapshots and framework control writes must not recursively trigger domain
projection subscriptions. Projection `APPLY` retains its existing restriction on
commands, services and event emission. Flow tracing uses the same transaction,
so an aborted attempt leaves no committed consumption links.

## Ordering and concurrency: prerequisite

The existing event optimistic lock protects `(stream, version)`. It cannot by
itself establish a committed global prefix for a projection consuming multiple
streams:

1. Writer A inserts journal ID 10 in stream A and remains uncommitted.
2. Writer B inserts ID 11 in stream B. Its projection replay cannot see ID 10.
3. B checkpoints cursor 11 and commits.
4. A resumes. A replay using `id > 11` can omit A's own event 10.

The event inserts have different stream/version pairs, so neither must conflict.
A projection snapshot optimistic lock is also insufficient when A loads B's
already committed checkpoint: A has a current snapshot version but a source event
behind its cursor.

Resolve this protocol before claiming transactional replay is ordered across
processes. Two approaches should be evaluated against the same concurrency tests:

### Serialized journal appends

Acquire a transaction-scoped append gate per store before allocating journal IDs,
and retain it through commit. All framework journal writers, including events,
snapshots and controls, must participate. This makes earlier allocated IDs visible
or rolled back before later appends can advance a cursor. It is the simplest
baseline, but serializes the append phase across unrelated streams.

### Projection ownership and optimistic retries

Explore a stable revision/ownership record per projection identity instead of a
store-wide gate. Every emission that the projection can consume must participate,
including event types that do not trigger an automatic advance. Participation
must remain protected through the emitting transaction's commit.

The protocol must reject an emission whose position is already behind a committed
projection cursor and roll back/retry the **entire** command. A revision check
that releases protection before commit, or participation only by annotated event
types, does not close the gap in the example above. Use a stable ownership key;
locking whichever immutable snapshot happens to be newest is not a stable fence.

This option can preserve concurrency between unrelated identities, but requires
proof for late ownership acquisition, multiple targets, manual checkpoint writers
and deadlocks. Do not implement it as merely adding another snapshot unique key.

Projection concurrency failures must be classified as technical conflicts and
propagate to the transaction owner. Reuse the command's bounded retry and state
reconstruction; automatic child-command retries remain outside this design even
with Red 0.2.7 savepoints. Store/discovery failures
and domain handler failures retain distinct outcomes.

## Original implementation sequence

1. Specify and test the ordering protocol, including the cross-stream visibility
   gap, before adding the emission hook.
2. Add `.^advance` to `ProjectionHOW` using the existing replay implementation.
   Preserve `.^load` catch-up and separate public advance from checkpoint creation.
   Update `ProxyHOW` dispatch without accidentally making saga-only timeout
   helpers available on projections.
3. Resolve the experimental representation and constraint-tracing limitations.
   Add the trait metadata role, retained-instance signature matching and validated
   equality-based discovery. Publish future
   modules through `META6.json` and the unified `use RedSourcing` entry point.
4. Add the subscription registry and transaction-local target instances; retain
   all `APPLY` candidates in replay.
5. Integrate append, ordered advance, checkpoints and rollback with `Event.emit`
   and the command transaction owner. Preserve nested-transaction ownership.
6. Add retained lifecycle support separately: a cache keyed by store, projection
   type and stream; explicit release; committed-state publication; and refresh
   after another process commits. The HOW holds policy, not shared instances.
7. Document the final trait syntax, inference limits, registration requirements,
   lifecycle interaction, error behavior and examples of mixed triggers.

## Validation

Use in-memory SQLite for deterministic API cases and independent PostgreSQL
processes with barriers for concurrency. Run tests against the installed
distribution and the Docker image as well as the CI Rakudo version.

- A prior unannotated event and a later trigger both apply once, in order.
- Matching types with several annotated candidates do not advance one target twice.
- Equality-derived, renamed, reversed, calculated, identity-free and multiple-target
  discovery behave consistently; incomplete IDs and unsupported trait placement
  fail clearly. Compare symbolic discovery with concrete signature matching.
- Exercise disjunction truth tables repeatedly with distinct and equal event fields,
  negations, mixed conjunctions and residual predicates; no valid target is omitted.
- Retained scans test the original signature without executing the handler body,
  stay scoped to the store, and only advance registered matching instances.
- Cover native versus object-backed IDs, missing/null fields and receiver-state
  dependencies without substituting misleading default values.
- `where` filtering still runs through Red's SQL translation.
- A fresh process reconstructs the checkpoint without replaying consumed events.
- A command emitting several events preserves their order and atomic outcome.
- A failed `APPLY` rolls back events, checkpoints, cursors and trace evidence.
- Optimistic retry reconstructs provisional state and applies each committed
  event once; it does not publish a failed attempt to a retained object.
- Reproduce A/10 and B/11 with different aggregate streams, both possible
  projection-ownership acquisition orders, and an earlier unannotated event.
- Exercise concurrent manual checkpoints, multiple targets and nested transaction
  rollback with real connections, rather than only injected exceptions.
- Ordinary projections without the trait retain their existing behavior.

The selected ordering protocol and publication boundary must pass these cases
before transactional triggers are considered implemented.
