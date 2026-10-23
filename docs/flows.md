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
Saga consumption proven by stored controls remains visible. Enable
**Show internal links and snapshots** to inspect bookkeeping records. This is
a display filter; no tracing records are written during application execution.

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

## Flow projection

Flow tracing is a normal projection over `StoredEvent` journal records:

```raku
use RedSourcing;
use RedSourcing::Flow;
red-sourcing-defaults(:driver<SQLite>, :database('events.db'));
my $flow = flow-projection();
say $flow.links;
```

The monitor builds this projection once per flow report and follows its links.
It reads metadata without loading application event classes or executing domain
handlers. It does not create tracing tables, write observations during replay,
or emit its own checkpoints. Each report rebuilds from all visible records, so
an earlier serial ID committed later is included on the next read. This also
means reconstruction costs a journal scan; the displayed node limit does not
limit the cost of rebuilding the read model.

`enable-flow-tracing`, `flow-tracing-enabled` and `.flow-tracing` remain compatible
configuration flags. They no longer turn durable causality on or off: command
and action IDs are always recorded with the source rows. Disabling the flag does
not make the existing graph unavailable or discard history.

## Evidence and recovery

Causal metadata lives outside domain payloads:

- `StoredEvent.command-id` identifies the command that emitted an event.
- `StoredEvent.action-id` identifies the logical saga action active during emission.
- `StoredCommand.parent-command-id` identifies a command that submitted a child.
- `StoredCommand.action-id` identifies the saga action that submitted the command.
- Existing saga controls retain source event/action IDs, consumed cursors and
  child command IDs, including previous attempts.

The projection reconstructs publisher, command/event, parent/child command and
provider/action links. A saga control advancing its cursor proves consumption of
that source event. Metadata rolls back with its record on failure or savepoint
rollback. No extra tracing SQL runs during emission, APPLY or REACT.

Ordinary aggregate/projection replays no longer record observations. Their
historical execution cannot be recovered merely from an APPLY/REACT signature or
a projection checkpoint cursor, so the graph does not invent those consumer
links. Snapshot-free projections are no longer registered as observed entities.
Persist their normal checkpoints if they should appear in the stored-state
monitor. The flow projection does not query the former tracing tables.

The flow source reads journal metadata and only the cursor from native saga
controls. It does not hydrate domain payloads or full historical saga states.
Links are indexed in memory; reports fetch related commands and events in batches.
The initial metadata scan still grows linearly with journal size.

## Limits

Records created before causal metadata was introduced cannot retrospectively
identify their emitting commands or provider actions. Existing saga controls,
commands, publication streams and snapshots remain inspectable.

Graphs are bounded to 200 nodes/records per traversal query and disclose
truncation. This is a causal overview, not a distributed timing trace. External
providers still need their own idempotency and recovery protocol.

See [monitor actions](web-monitor.md), [sagas](sagas.md) and
[configuration](configuration.md).
