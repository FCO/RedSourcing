# Roadmap

RedSourcing provides aggregate/projection replay, persisted commands, shared
configuration, saga intents/retries/compensation/timeouts, a CLI and a standalone
Cro/HTMX monitor. The examples exercise those facilities; the tasks below address
remaining constraints rather than a history of implementation changes.

See [the API](api.md), [saga contract](sagas.md) and [testing scope](testing.md).
The [commerce example](../examples/commerce/README.md#saga-api-feedback) makes several
of these limitations visible in a complete application.

## Saga composition and completion

- **Terminal hooks/events.** Emit or schedule application work when a saga
  completes, compensates or reaches a terminal failure. Commerce uses an
  idempotent controller bridge to turn compensated purchase/fulfillment state
  into order/shipment facts. A journaled hook would remove that polling logic.
- **Explicit step identity.** Named methods provide useful action names and
  compensation discovery. Direct effect calls in `REACT` use `REACT` as the
  originating step. A `:step` option or explicit step scope would make repeated
  operations and dynamic workflows easier to describe and resume.
- **Child workflows and joins.** Sagas can cooperate through domain events;
  there is no built-in child-saga lifecycle, fan-out/fan-in or parallel join.
  Multi-product reservations and returns use sequential indexes in Commerce.
- **Compensation scopes.** A long-running saga needs a way to finish one
  reversible phase without discarding the whole workflow. Physical handoff is
  a commit boundary; Commerce separates its pre-handoff and delivery sagas.
- **Independent work.** Ready actions run in insertion order. A delayed or blocked
  action prevents later actions from executing, even when they are independent.
  Timers can plan escalation work, but that work remains behind the blocked action.
  Separate notification sagas provide isolation, not a parallel queue API.

Validation should include acknowledgements lost at every boundary, late events,
multiple reservations, child failures and recovery after the last snapshot.

## Controllers, ownership and recovery

- Provide a reusable controller with identity discovery, subscription routing,
  due-work queries and a next-wakeup API. Commerce maintains its own input routes
  and wakeups to avoid loading every saga on every idle pass.
- Add durable leases/fencing for multiple controllers. Optimistic stream versions
  detect conflicts but do not guarantee one owner of an external request.
- Add an operator retry/resume API for repaired, exhausted actions and inverse
  operations. `.^resolve-action` settles blocked/running outcomes; it does not
  requeue every kind of terminal failure. Commerce emits explicit recovery facts
  for its forward workflows.
- Define stale command failure ownership after rollback. Failure persistence must
  not overwrite another executor's result. Preserve exception classification when
  a child command is recovered from its stored failure.
- Define synchronous behavior when another process owns a command: return its
  handle, wait for a result, or report ownership distinctly from a `Nil` result.

Use actual independent connections and process termination tests on SQLite and
PostgreSQL. The isolated workflow tests do not establish this complete protocol.

## Journal size and query costs

- Bound source batches, history pagination and work discovery in SQL. An operation
  limit bounds ready actions, not the full source event scan.
- Replace full-state saga control payloads with versioned deltas/checkpoints when
  journal size warrants it. Actions and contexts can make repeated state expensive.
- Make monitor summaries incremental and paginate instance rankings. Its cached
  reports still scan history when invalidated.
- Avoid replaying already acknowledged control rows during saga restoration.
- Provide migrations for persisted type, method and adapter identities.
- Add telemetry retention and indexed paging for recorded workflow connections;
  bounded diagrams should disclose gaps when older trace evidence is pruned.
- Normalize scheduler timestamps to a fixed precision. Reconstructing the same
  floating instant twice can differ below a microsecond at an exact due boundary.

Measure query counts and latency as histories and instance counts grow. Preserve
exclusive global ID cursors and fixed stream scope when adding pagination.

## Signatures and command payloads

- Preserve explicit named slurpy arguments and constraints instead of discarding
  payload fields that are not represented by generated attributes.
- Support defaults that depend on another parameter or `self`, with a clear policy
  for when they are evaluated. Supported defaults are normalized once at submission.
- Extend nested signature rules with typed fields, aliases/defaults and a defined
  missing-key policy. Unsupported forms must fail explicitly.
- Preserve original signatures and code context while adapting a query signature;
  keep integration tests when upgrading Rakudo and Red.
- Extend date expressions such as `DateTime.year/month` in SQL-translated rules.

`sync` remains reserved by the proxy. Constraints requiring current aggregate
state belong in the loaded command handler, not only in payload normalization.

## Snapshots and transaction boundaries

`is transactional` now triggers an ordered advance and checkpoint of a whole
projection in the emitting transaction. See [the projection guide](projections.md)
for equality-based identity discovery and retained lifecycle, and
[the implementation plan](plans/transactional.md) for the design and follow-ups.
PostgreSQL journal appends use a transaction-scoped gate to protect cross-stream
cursor order; a more concurrent per-projection ownership protocol remains future
work. Retained caches still need optional cross-process invalidation and a defined
API for synchronized access from multiple threads.

All three entity kinds now support `Cached`/`OnDemand`/`Retained` declaration lifecycles
and connection/pool-scoped overrides through configuration `entities` entries.
See [entity lifecycle](lifecycle.md). Remaining cache work includes automatic
eviction and synchronized reads. Automatic snapshots now support count/time policies on declarations and in
configuration, with a default of 100 applied records and explicit `Nil` to disable.
See [automatic snapshots](auto-snapshot.md). A future idle checkpoint controller
would need identity discovery and bounded scheduling; current time policies are
checked during operations.

- Define consistent snapshot lookup/replay reads across concurrent transactions.
  A selected snapshot must remain the first and only snapshot in a snapshot query.
- Specify `:after` combined with snapshot selection: the current date filter can
  exclude the snapshot. Entity reconstruction must not silently lose its base state.
- Make duplicate `.^create` behavior explicit in the library; the CLI rejects an
  existing stream, but library callers must avoid resetting an existing identity.
- Validate projection cursors under out-of-order transaction visibility. Database
  IDs and commit order are not interchangeable under all concurrency patterns.
- Specify recovery after a handler mutates an object and then throws. Restore a
  fresh instance rather than reusing that partly changed in-memory object.
- Preserve deliberate transaction ownership for retries. Red 0.2.7 supports
  explicit savepoints, including journal state rollback, but nested commands
  continue to propagate conflicts for complete-batch retry.

Database rollback does not undo an HTTP request. Provider adapters need durable
idempotency/reconciliation; physical shipping and returns need explicit domain
boundaries, not automatic inverse guesses.

## Configuration and operational tools

- Add hot reload only with a defined lifecycle for connections, modules, adapters
  and worker/monitor settings. Current configuration is read at startup.
- Detect permanent connection failures promptly; DB::Pg retries missing databases
  and invalid credentials. `init` creates tables inside an existing database.
- Add deployment authentication/authorization and durable Operations job history.
  The current monitor is a local administrative tool with session-bounded jobs.
- Keep database-only inspection separate from application replay and execution.

## Validation discipline

Maintain executable documentation snippets, isolated installed-consumer tests,
example flows, CLI/HTTP tests and opt-in PostgreSQL checks. Coverage must include
all provided library modules and retain the committed fraction. The explicit VM
annotation exclusions are not a substitute for tests of executable behavior.

See [testing](testing.md) for commands and scope. Generated coverage reports carry
measured counts, so this roadmap does not duplicate numbers that become stale.
