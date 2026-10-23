# RedSourcing monitor

[README](../README.md#web-monitor) · [Configuration](configuration.md) · [CLI](cli.md)

The **Flows** view follows saga creation, action/command execution, emitted events
using causal links projected from journal metadata. The form groups entities and
typed **Actions**, and the diagram advances left to right through causal steps.
Enable **Show internal links and snapshots** when inspecting bookkeeping.
Detail pages provide **View
flow**; see the [flow guide](flows.md) for reconstruction and the limits of
historical data.

A generic, independent Cro + HTMX **4.0.0** monitor for a RedSourcing database.
It does not require the application to host, register or notify it. Inspection
reads stored events and commands through its own connection without importing
application modules. Its **Operations** workspace also runs the CLI operations
against that store, loading configured domain/service modules only in the execution
process when required. The monitor, Cro dependency and web assets belong to the main RedSourcing distribution.

## Run independently

Install RedSourcing once:

```sh
zef install .
red-sourcing web-monitor --driver SQLite --database my-database.db
```

From a checkout:

```sh
raku -Ilib bin/red-sourcing.raku web-monitor \
    --driver SQLite --database my-database.db
```

Open <http://127.0.0.1:3001/monitor>. By default the database must already contain the
`red_sourcing_event` and `red_sourcing_command` tables. Inspection creates
neither tables nor domain records. For a new store, start with `--allow-new-store`
and explicitly run **init** in Operations; opening the dashboard alone creates
no database file or tables. `--port=3005`, `--host=127.0.0.1`,
`--minutes=120`, `--app-url=http://127.0.0.1:3000/` and `--debug` are optional.
The root CLI loads `RedSourcing::Web::Monitor` only when `web-monitor` is selected.
Help and other CLI operations do not load the HTTP server. All monitor modules
and assets are included in the same installation.
`--database`, or `database` in the configuration file, is required: the monitor does not create the CLI's
`a.db` default or initialize a store.

`red-sourcing-monitor` remains an installed standalone alias, and
`bin/red-sourcing-monitor` is a checkout entry point
with the same options. Both support `-f FILE` and automatic nearest-parent
`red-sourcing.rakuconf` discovery; see the [configuration guide](cli.md#configuration-files).
Configured domain-module lists are not imported for inspection. They are passed
to operation processes; add `-I=PATH` and `-M=MODULE` at startup or in individual
operation forms. The implementations share `run-monitor`.

On Apple Silicon macOS, if Cro aborts with `loading libcrypto in an unsafe way`,
prefix the command with `DYLD_LIBRARY_PATH=/opt/homebrew/opt/openssl@3/lib`.
That points the installed Raku OpenSSL binding at Homebrew OpenSSL. Adjust the
path for another Homebrew installation. This applies to the app and Cro tests too.

## Operations workspace

Open `/monitor/operations`, or choose **Operations** in the navigation. The form
catalog is reflected from the same dispatcher used by `red-sourcing`, and uses
the same grouped explanations, examples, accepted options and required fields.
Results default to readable text; select **JSON** when you need structured output.

| CLI functionality | Web operation |
| --- | --- |
| `init`, `update` | Initialize tables; preview or apply transactional event migrations. |
| `types`, `list-entities`, `list-aggregates`, `list-projections`, `list-sagas` | Discover/filter/paginate persisted entity instances. |
| `describe`, `inspect`, `streams` | Inspect definitions (including source `where` predicates), stored state and stream names. |
| `list-events`, `list-commands` | Use all history filters, limits, ordering, details and typed rule options. |
| `create`, `load`, `snapshot` | Create an initial checkpoint, reconstruct current state or persist a fresh snapshot. |
| `command`, `run-command` | Execute, queue or preview a command; process an existing command row, optionally waiting for its schedule. |
| `work` | Run a bounded pass or start a watch worker, then stop it through its execution panel. |
| `saga-status`, `advance`, `resolve-action` | Diagnose pending work, process reactions/effects or reconcile a confirmed result/error without reissuing a service call. |
| `stats` | Request health statistics for another activity window. |
| `web-monitor` | Show the active connection/import settings. Binding a different port/store requires restarting the monitor. |

Enter **Entity IDs** as one `FIELD=VALUE` per line, like repeatable CLI `--id`.
The identity JSON field is under Advanced options; use one identity
format per operation. Enter command arguments and initial fields as JSON objects.
Repeated imports, event names and rule expressions also use one value per line.
Blank options keep CLI defaults; boolean options offer Default/Yes/No. Watch
workers default to one pass in the browser unless you explicitly choose Yes.

Stream/type/command detail pages act directly on the selected record. **Load
current state**, **Save checkpoint**, **View saga progress** and **Advance saga**
execute in place. **Send command** opens a list of the entity's available methods,
then a parameter form based on the real command signature. **Resolve action**
offers the selected saga's running/blocked actions and confirmed outcome fields.
The entity and IDs are fixed by the record, not entered again. Snapshot-only
identities are recovered using declared ID fields and persisted attribute values.
Application modules must be configured for reconstruction and command execution.

Results use HTML field cards, nested values and tables. Saga progress has action,
retry, timeout and compensation sections; errors are shown next to the action.
Raw JSON, process arguments and diagnostics remain available under **Technical
details**. Live updates refresh the read-only record panels while preserving the
parameter form and result. The general Operations workspace is still available
for store-wide tasks and entities that have not yet been persisted; web responses
use structured HTML rather than a terminal-output format selector.

For example, the checkout's root configuration already includes `Estate::Domain`:

```sh
raku -Ilib bin/red-sourcing.raku web-monitor
# Operations → describe → Conversation
# Operations → command → Conversation / post-message
# Entity IDs: repair-id=r-boiler
# data: {"author":"Agency","body":"Contractor booked","message-id":"m-web-1"}
```

For another application:

```sh
red-sourcing web-monitor --database=my-store.db -I=lib -M=MyApp::Domain
red-sourcing web-monitor --database=new-store.db --allow-new-store -M=MyApp::Domain
```

Domain imports suffice for aggregate commands and replay. Saga external effects
also need modules that **register the same service adapters as the CLI**; importing
an app class does not automatically run its initializer or register instance-bound
adapters. The monitor does not start or seed the application.

Every submission starts a separate Raku process using `RedSourcing::CLI::Application`.
The terminal entry point imports that same dispatcher, including validation,
transactions, replay and error handling. Arguments are passed as an array, with no
shell interpolation. The selected driver/database/connection configuration is
frozen at startup in a private temporary file; browser forms cannot redirect jobs
to another store or configuration file. Additional imports apply only to that job.

Up to four jobs run concurrently. The most recent 32 jobs remain in this monitor
session, with output capped at 1,048,576 characters per stdout/stderr stream and an explicit
truncation notice. Accepted jobs return immediately; HTMX polls each running result
once a second, then stops after completion. A long command, future request or watch
worker does not hold the inspector lock. Watch jobs survive page navigation and can
be reopened from the execution history. **Stop execution** requests SIGINT, then
SIGKILL after three seconds if necessary. Stopping an operation cannot undo an
already committed event or external service effect; inspect persisted commands and
saga status to reconcile uncertain outcomes. Normal monitor shutdown stops its jobs
and removes its private configuration. Execution history itself is not persisted;
domain commands, events and saga controls keep their normal durability.

The operations console is a trusted administrative interface, including Raku
migration expressions and imports. Keep it on loopback, or put authentication and
authorization in front of it when sharing access. Mutations require POST, a console
header and an exact allowed Origin; no CORS access is enabled. The default loopback
origins are `http://127.0.0.1:PORT` and `http://localhost:PORT`. For a reverse proxy,
pass `--origin=https://console.example.com` (repeatable), or set `.monitor.origins`
in configuration. Origin checks prevent cross-site browser submissions; they do
not authenticate a user who can access the console.

## What comes from the database

Snapshots identify aggregates and projections; saga controls identify sagas even
before their first snapshot. Command metadata supplies target names, IDs and
observed methods. Unknown event classes remain plain stored data: the monitor
never resolves class names, instantiates an entity, executes a command, calls
`APPLY`/`REACT`, advances a saga or contacts a service adapter **during inspection**.
These effects require an explicit operation submission.

Aggregate and projection cards show **the last persisted snapshot**, with its
record ID/version and the stream head shown separately. Folding subsequent domain
events requires application code, which is not stored in the journal. Saga
controls contain complete runtime state and domain values, so their latest
committed control supplies current persisted saga state, stacks and timers.
Bare streams and command-only entities are labelled explicitly when state or kind
cannot be established. Types/projections with no stored records cannot be
discovered; checkpoint them through the application's normal snapshot policy if
they need to be visible. No application configuration file is needed.

## Names and detail pages

Hover over a name in the catalog, entity cards, tables or entity charts to see
its complete persisted name. Links expose the full name to assistive technology
as well, even when the visible label omits a namespace.

Click an entity/card, stream or chart row to inspect its stream: checkpoint state,
identity, version, source cursor and the latest 60 events/commands for that stream.
Catalog links show a type's observed IDs, methods, instances and related records.
Event and command names/IDs open their exact stored record, including metadata,
payload, result and error. Records older than the overview's 60-row limit are
still accessible by ID. Names containing Unicode or reserved characters are
encoded in URLs and displayed safely as text.

Detail pages use the same live invalidation stream as the dashboard. They stay
scoped to the selected record when refreshed. State inspection remains entirely
read-only and does not replay application handlers.

Routes are `/monitor/detail?view=stream|type|event|command&name=...` and the
corresponding `/monitor/detail-fragment` for HTMX refreshes. For events/commands,
`name` is the row ID. Missing/invalid records return 404. Restart a running monitor
after updating its code so the process loads newly added routes.

## Health graphs

The dashboard includes six accessible SVG charts, live summary cards and a
sortable per-entity table:

- Domain events/minute, snapshots/minute, saga retries/minute and controls/minute.
- Event volume and failures by entity/stream, distinguishing failed commands
  from final saga outcomes in the ranking table.
- Window-average events/minute and all-time mean events per discovered entity.
- Command failure counts/rates, final saga failures, extra attempts, snapshot
  frequency per entity and events in that stream since its last snapshot.
- Pending/processing commands and blocked saga actions.

The default window is 60 minute buckets, including zero-activity minutes and the
current partial minute; chart times are UTC. Totals cover all persisted history.
Snapshots and control events are excluded from domain-event counts. Event volume
belongs to the emitting stream; projection consumption and cross-stream replay
cost cannot be inferred without `APPLY` rules.

Retries are additional persisted saga attempts plus extra attempts recorded on
command rows. Saga counters are not summed repeatedly across control events or
snapshots. The time chart uses observed attempt transitions; a snapshot alone
supplies a total, not the timestamps of past retries. Command failures have no
failure timestamp in the current schema, so their graph is an all-time comparison.
`store-metrics` delegates to the ordinary raw-record `MetricsProjection`.
Its APPLY accumulates counts, minute buckets and deduplicated saga attempts and
outcomes. Reports can select different windows from the same projected state
without querying the database. No metrics table is created. The source reads
journal metadata and saga state, excluding domain payloads and snapshot values;
it never loads application classes or runs handlers/adapters.

Command lifecycle transitions are not journal events yet. The projection takes
a current snapshot of command ID, stream, state and tries from the operational
command table. Updating the same command replaces its previous contribution.
A checkpoint alone cannot refresh this mutable state; `metrics-projection()`
rebuilds visible journal facts and refreshes command contributions together.
Like flow reconstruction, this includes late commits with lower serial IDs.

These are journal-derived metrics, not measured handler duration or CPU use.

## Live updates and performance

One polling loop checks the store once a second, shared by all browser tabs.
The metrics projection and stored-state report are cached until the
journal/command revision changes. When a new minute starts, the monitor only
renders a new window from the existing projection; it does not replay history.
A data change rebuilds the projection from all visible rows, rather than relying
on a persistent global serial-ID cursor. SSE only invalidates server-rendered HTMX fragments; it carries
no entity state and requires no publisher in the application. Cro response
pipelines terminate on disconnect, cancelling their subscriptions and heartbeat
timers. Genuine route/body failures still propagate.

Inspection routes are `/monitor`, `/monitor/fragment`, `/monitor/report` (JSON) and
`/monitor/live` (SSE). `?kind=aggregate|projection|saga` filters instances;
`?sort=events|failures|retries|snapshots|events-since-snapshot` ranks the table.
HTMX, CSS, JavaScript and charts are local resources, including after installation.
No frontend build, CDN or chart library is required.

The monitor is intended for local development. Payloads can contain personal
data; use authentication and authorization when sharing access. Journals show
at most 60 recent rows and the ranking table 30 streams. Discovery/statistics
currently scan persisted history on invalidation; incremental summaries and
instance pagination are the next optimization for large stores.

## Programmatic inspection and web helpers

`RedSourcing::Inspector.new(:stored-only)` provides the same database-only report
without HTTP. Its trusted `register`/`watch` API is available for
in-process tools that explicitly want application-aware replay. The CLI always
uses database-only inspection. Its `events` and `commands` readers accept
`:stream`, `:type`, `:id` and `:limit` filters; command type queries match either
the stored command class or the target entity name.

`RedSourcing::Web::Server` exports the disconnect-aware `web-server` Cro factory;
Hearth uses this shared HTTP helper without importing the Inspector or monitor.
`RedSourcing::Web` exports `inspector-routes`, `inspector-view` and
`web-asset-routes` for hosts that choose to embed an inspector separately.

## Verification

```sh
raku -Ilib t/15-stored-inspector.rakutest
raku -Ilib -Iexamples/real-estate/lib t/16-web-real-estate-http.rakutest
raku -Ilib t/17-web-disconnect.rakutest
raku -Ilib t/18-web-metrics.rakutest
raku t/19-web-installation.rakutest
raku -Ilib t/20-web-details.rakutest
raku -Ilib t/22-web-monitor-cli.rakutest
raku -Ilib t/31-web-operations.rakutest
raku -Ilib t/32-web-console.rakutest
raku -Ilib t/33-web-console-lifecycle.rakutest
```

Optional browser checks require Playwright and Chromium. Run Hearth and the
independent monitor against the same fresh seeded database, then
`npm run test:browser` and `npm run test:console`.
Override `HEARTH_URL` and `CONSOLE_URL` for nondefault ports. The checks cover
forms, rent, chat, draft preservation, retries, compensation and cross-process
SSE updates. `npm run test:details` verifies full-name labels,
clickable chart/entity links, all four detail views, scoped HTMX refresh and mobile
layout against an independent monitor containing persisted events and commands.
It performs no application writes. See [third-party licenses](web-third-party.md) for the pinned HTMX license.

`npm run test:operations` checks explicit initialization, creation, command results,
CLI/transport validation, draft preservation, watch/stop, detail shortcuts and
390px mobile layout. Run a separate monitor with a **dedicated test database** and
the Cart example first (the test performs writes):

```sh
raku -Ilib bin/red-sourcing.raku web-monitor --driver=SQLite --database=/tmp/console-test.db \
    --allow-new-store --port=3107 -I=examples/shopping-cart -M=Cart
CONSOLE_URL=http://127.0.0.1:3107 npm run test:operations
```

`PLAYWRIGHT_PATH` can select an existing Playwright installation and
`CHROMIUM_PATH` an existing Chromium executable for this check.
