# Follow a workflow in the web monitor

For a small hands-on introduction, follow the
[aggregate, projection and saga REPL tutorial](tutorials/simple-flow.md).

Open **Flows** in the navigation, or **View flow** on an entity detail page.
The **Focus** selector groups streams under **Aggregates**, **Projections**,
**Sagas** and **Other entities**. **Actions** lists persisted saga actions, including
their **Command** or **Service** type, target and owning saga. Selecting an action
shows that action and its downstream work, including earlier retry attempts.

Columns follow recorded causality (**Cause**, **Step 1**, **Step 2**, …), rather
than grouping boxes by type. Producers precede their events, and actions follow
the facts or actions that triggered them. The focused entity appears above the
diagram: it need not be the first cause in its history. An event can therefore
appear before the selected saga when it triggered that saga's work.

By default, the diagram hides snapshot bookkeeping, event replay by the emitting
aggregate, redundant aggregate-to-event publication when a command is the known
emitter, and event-to-saga consumption already represented by an action trigger.
Other aggregates and projections consuming the event remain visible. Enable
**Show internal links and snapshots** to inspect those connections. Stored
telemetry is preserved; this is a display filter, not a recording change.

All visible arrows advance from left to right. If recorded links contain a cycle,
the closing edge ends at an explicitly labeled **reference** card for the same
record. This does not claim that a command or action ran a second time.

Cards link to entity, command or event details. Hover or focus a card to inspect
its full name, identity, payload/arguments, result, error and available state
metadata. Previews limit long strings, collections and nesting; open the card
for full details. In landscape orientation, the preview occupies a separate
sidebar, including on laptops and in dense flows. In portrait orientation it
appears below the diagram. It never covers cards or arrows and retains the last selected
card when the pointer moves away. Escape or **Clear card preview** clears it.
Related connections also highlight.

Card headers show UTC timestamps next to their type. **Emitted** is the stored
event or snapshot emission time. **Recorded** is an action's first appearance in
the retained control history. **Checkpoint** is the entity's persisted state
record time; it does not claim that a snapshot is its current reconstructed state.
**Observed** identifies a snapshot-free consumer's replay observation.
**Scheduled** is a command's `next-run`: command rows currently have no separate
creation timestamp, so this is not presented as one. Missing times are explicit.

Arrows follow a direct, gentle curve from source to destination, including links
that skip columns. They can pass behind intermediate cards;
opaque cards always paint above the connector layer. Incoming and outgoing links share one allocator on each
card edge, with 14 pixels between ports. Busy gaps expand to keep room around
card edges. Dense diagrams scroll within their container; preview placement
depends on screen orientation.
At crossings, a thin background outline separates wires visually. The connection table supplies the same information without
relying on the diagram. Live updates refresh the selected flow. Open a child
entity to narrow a large workflow.

## Enable recording

The monitor reads evidence without running application handlers to guess
subscriptions. Enable recording in shared configuration:

```raku
use RedSourcing::Config;
config {
    .driver = 'SQLite';
    .database = 'events.db';
    .flow-tracing = True;
    .includes = <lib>;
    .modules = <MyApp::Domain>;
}
```

Applications using `red-sourcing-defaults` enable tracing on their selected
connection. The CLI enables it for execution, reconstruction and initialization
operations when configured. Imports, help, type descriptions and the standalone
monitor do not create telemetry tables. Example configuration files enable it.

For code using Red directly, enable it after selecting a connection:

```raku
use RedSourcing;
red-defaults 'SQLite', :database('events.db');
schema(StoredEvent, StoredCommand).create;
enable-flow-tracing;
```

Recording is opt-in without configuration. `enable-flow-tracing(:!enabled)` stops
recording on that connection and preserves history. Enable it independently in
each worker/service process using the same store.

## Evidence and recovery

The additional `red_sourcing_flow_link` and `red_sourcing_flow_entity` tables
store links and observed identities. Existing tables and event payloads remain
unchanged.

- Command execution records the exact command ID responsible for an event.
- Commands submitted from another command retain their parent/child connection.
- Saga actions retain their source event/action IDs and child command ID.
  Control history preserves earlier child commands when an action retries.
- Provider events emitted while a saga service runs retain that logical action.
- Successful `APPLY` records the event and consumer stream. Saga source processing
  records `REACT` consumption after committing its control state.
- Replaying an observed event does not duplicate its consumer link. Projections
  without snapshots become discoverable through observed identity metadata;
  use **Load current state** to reconstruct their domain state.
- Command transactions roll back emitted-event links with the events on handler
  failure. The failed command remains visible in the graph.

A consumer link means an actual replay/application occurred. It is not a list of
types that *could* match a signature. A projection the application never loads
does not appear as a proven consumer. Observation metadata contains type, kind
and IDs; it is not a checkpoint or current domain state.
Queued child commands can execute after their parent commits. Synchronous nesting
still follows Red's existing transaction limitations; tracing does not add
savepoints or change that execution policy.

## Limits

Records written without tracing have incomplete connections. Initial snapshots (in the internal view)
and saga child-command IDs can still be shown from existing records. The monitor
does not infer command/event links from timestamps or consumption from cursors.
Native controls remain in the journal rather than cluttering the domain graph.

Graphs are bounded to 200 nodes/records per traversal query and disclose
truncation. Identity nodes can combine several replay observations: this is a
causal overview, not a complete distributed timing trace. External providers
still need their own idempotency and recovery protocol. Concurrent replay may
create duplicate telemetry rows; the graph coalesces equivalent links. Recording
adds SQL work and requires permission to create its optional tables.
Source, target and observed-stream indexes support traversal without repeatedly
scanning all telemetry rows.

See [monitor actions](web-monitor.md), [sagas](sagas.md) and
[configuration](configuration.md).
