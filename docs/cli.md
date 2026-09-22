# RedSourcing CLI

The installed executable is `red-sourcing`; in a checkout use
`raku -Ilib bin/red-sourcing.raku`. The monitor and its assets are part of the
same distribution. `red-sourcing-monitor` is also installed as a standalone alias.

Run `red-sourcing --help` for the grouped command guide, or
`red-sourcing SUBCOMMAND --help` for one operation's options, explanation and
examples. `-h` is an alias; invoking the CLI without arguments shows the guide.
The CLI uses its own help renderer rather than printing Raku `MAIN` signatures.
Every operation accepts `-f`/`--file`, `--driver`, `--database` and `--debug`. Without configuration, the default store
is SQLite `a.db`, except `web-monitor`, which requires a database supplied by CLI or config.
The monitor normally requires an existing store; `--allow-new-store` permits explicit
initialization through its Operations workspace.
Unknown flags are rejected. Diagnostics use stderr and failures return nonzero;
`--debug` adds SQL and exception details. Human-readable text is the default;
add `--json` to data-producing commands for machine-readable stdout.

All CLI operations are also available through the independent monitor’s
[Operations workspace](web-monitor.md#operations-workspace), with the same
validation and human-readable results. Database/configuration and server binding
are selected at monitor startup.

## Help and navigation

Help starts with the universal database/configuration options, which are shown
once. The overview then separates shared output, application-import and entity-ID
options, clearly identifying which operations accept them. Commands are grouped by
functionality:

- **Database maintenance:** `init`, `update`.
- **Discovery and inspection:** `types`, entity listings, `describe`, `inspect`.
- **Event and command history:** `streams`, `list-events`, `list-commands`.
- **Entity state:** `create`, `load`, `snapshot`.
- **Command execution and workers:** `command`, `run-command`, `work`.
- **Saga workflows:** `saga-status`, `advance`, `resolve-action`.
- **Monitoring:** `stats`, `web-monitor`.

Each operation explains what it reads or changes and includes usage examples.
Focused help shows only that command's accepted shared and specific options,
including aliases, required migration arguments, built-in limits and configuration
overrides. Its descriptions follow the declared `MAIN` options; missing command
or option documentation is treated as an error when rendering that page.

```sh
red-sourcing --help
red-sourcing load --help
red-sourcing command -h
red-sourcing saga-status --help
red-sourcing --database=events.db work --help
```

Help works even when required arguments are absent or all arguments have already
been supplied. It does not execute discovered/explicit configuration files,
import the requested application modules, open the database or execute handlers.
Examples use illustrative application types; provide your own definitions through
configuration or `-I`/`-M`. Unknown help targets fail with a diagnostic. Invalid
command invocations use the same custom help on stderr and retain nonzero exit codes.

The catalog and option explanations live in `RedSourcing::CLI::Help`; entity and
handler descriptions shown by `describe` still come from native `#|`/`#=` comments.

## Output modes

The default does not depend on whether stdout is a terminal or a pipe:

- Catalogs, entity instances and event/command histories use aligned tables with
  complete names. Empty lists print `(none)`.
- Command results, previews, entity state and saga outcomes use labelled, indented
  fields. Empty command results print `Command completed (no result).`
- `inspect` separates state, events and commands. `stats` shows totals, rates,
  per-entity counts and active minute buckets.
- Workers report processed commands and errors. In human `--watch` mode, idle
  passes remain quiet after the first `No due commands.` message.
- Migrations report how many events were updated or would be updated.

`--json` emits record/result schemas and emits one compact JSON
value per invocation. A JSON watch worker emits one object per pass, including
empty passes. Scripts that parse output must explicitly pass `--json`.
Initialization remains quiet; the monitor prints its startup address.

```sh
red-sourcing types
red-sourcing inspect --stream='MyApp::Domain::Account: account-id = a1'
red-sourcing list-events --details --limit=5
red-sourcing list-commands --details --state=Failed
red-sourcing command Account rename --id=account-id=a1 \
    --data='{"name":"Ana"}' --json
red-sourcing stats --json
```

`--details` expands event/command history into labelled records with payloads,
arguments, results and errors. Table cells escape newlines and control characters;
detail fields preserve indented line breaks and escape terminal controls.
JSON retains the original strings unchanged. Output does not change command
execution, replay, filtering, transaction behavior or failure exit codes.

For PostgreSQL, `init` creates the RedSourcing tables inside an existing database;
it does not create the database itself. With the checkout's Hearth configuration,
run `createdb --host=127.0.0.1 --port=5432 --username="$USER" hearth` first (adjust
connection options to match your config). DB::Pg retries failed connections, so a
missing database can otherwise produce repeated connection errors.

## Configuration files

The [shared configuration guide](configuration.md) covers the complete file schema,
library startup, precedence, path resolution and PostgreSQL/native-library setup.


Applications can also call `red-sourcing-defaults` after `use RedSourcing` to
configure their default Red connection from this same file. It accepts `:file`,
`:driver`, `:database`, `:debug` and `:connection` overrides and returns effective
settings. It reads no command-line arguments, imports no configured modules,
starts no monitor/worker and creates missing storage tables by default. Pass
`:!initialize` to suppress table/index creation; existing schemas are not migrated.
It sets `$PROCESS::RED-DEBUG` from the effective debug setting for SQL logging;
a scoped `my $*RED-DEBUG` takes precedence. See
[application configuration](configuration.md#use-from-application-code).
`use RedSourcing; config { ... }` also works inside the file;

Each directory under `examples/` has a `red-sourcing.rakuconf` with its own
store and module imports. Real-estate uses PostgreSQL; the other examples use SQLite. Running the CLI there discovers that file before
the root configuration. From the root, use `-f=examples/EXAMPLE/red-sourcing.rakuconf`.
The counter, bank, shopping-cart, food-delivery and order-saga scripts run their
standalone in-memory demonstrations; their CLI stores are separate. The real-estate
configuration shares the application's PostgreSQL `hearth` database.


`-f FILE`, `-f=FILE`, `--file FILE` and `--file=FILE` select an explicit file.
Without `-f`, the CLI looks for **red-sourcing.rakuconf** in the current directory,
then each parent up to the filesystem root. It reads the nearest file only;
parent files are not merged. With no discovered file, built-in CLI defaults apply.
A missing explicit file or invalid configuration is an error before database
operations. Help does not execute configuration files.

The repository includes a root `red-sourcing.rakuconf` that selects the Hearth
real-estate example: PostgreSQL `hearth` (or `PGDATABASE`), include path `examples/real-estate/lib`, and the `Estate::Domain` module. It also configures
the monitor on `127.0.0.1:3001` with an application link to port 3000 and a worker
batch of 100 with a one-second polling interval. A closer config, `-f` or explicit
CLI options can override those checkout defaults.

Files use [Configuration](https://github.com/FCO/Configuration)'s Raku builder DSL:

```raku
use RedSourcing::Config;

config {
    .driver = 'SQLite';
    .database = 'var/events.db';
    .includes = <lib domain/lib>;
    .modules = <MyApp::Domain MyApp::Services>;
    .debug = False;

    .monitor: {
        .host = '127.0.0.1';
        .port = 3001;
        .minutes = 120;
        .app-url = 'http://127.0.0.1:3000/';
    }
    .worker: {
        .limit = 50;
        .interval = 0.5;
        .watch = False;
    }
}
```

Include paths and relative SQLite filenames from the file are relative to its
own directory. Explicit CLI paths remain relative to the invocation directory.
Absolute paths, SQLite `:memory:`/`file:` names and server database names retain
their usual meaning. The SQLite database's parent directory must exist.

Scalar CLI options take precedence over configured values, then built-in defaults.
Use `--/debug` or `--/watch` to override configured `True` with `False`.
Configured `includes`/`modules` are followed by repeatable `-I`/`-M` additions,
with duplicates removed. Modules are imported for application-aware operations;
`types`, entity listings, `inspect`, `saga-status --stream`, `stats`, `list-commands`, raw event history without type/import
flags, and the monitor do not import the configured domain list.

For driver-specific connection options, use the top-level `connection` hash:

```raku
config {
    .driver = 'Pg';
    .database = 'property_management';
    .connection = %(host => 'localhost', port => 5432,
        user => 'estate', password => %*ENV<ESTATE_DATABASE_PASSWORD>);
}
```

These named options configure the selected Red driver,
including the monitor's independent connection. Keep `driver`, `database`,
`debug`, `includes` and `modules` at the top level. Driver-specific names and
connection behavior follow Red. For `Pg`, the top-level database is mapped to
`dbname`, including explicit `--database` overrides. JSON compatibility disables
DB::Pg’s second JSON encoding and fixes JSON path/scalar filters. Configuration is loaded once per invocation;
watch workers and the monitor do not hot-reload it. The files execute Raku code
and must be trusted; the CLI never prints the connection hash.

```sh
red-sourcing -f deployment.rakuconf command Account rename \
    --id=account-id=a1 --data='{"name":"Ana"}'
red-sourcing web-monitor -f deployment.rakuconf --port=3005
# From a nested project folder, discover the nearest red-sourcing.rakuconf:
red-sourcing stats
```

The standalone `red-sourcing-monitor` alias uses the same lookup and `-f` option.
A runnable configuration template is included at
[examples/real-estate/red-sourcing.rakuconf.example](../examples/real-estate/red-sourcing.rakuconf.example).

## Available operations

| Operation | Behavior |
| --- | --- |
| `init` | Create both tables if missing; retain existing data |
| `streams [--json]` | List stream names in sorted order |
| `types [--json]` | Discover persisted entity types, kinds, IDs and observed commands |
| `list-entities [--kind=KIND] [--json]` | List persisted entity instances across all kinds |
| `list-aggregates [--json]` | List aggregate instances |
| `list-projections [--json]` | List projection instances |
| `list-sagas [--status=STATUS] [--json]` | List saga instances and their persisted status |
| `inspect [--stream=NAME] [--limit=60]` | Read stored state and recent history without domain code |
| `saga-status [SAGA --id=FIELD=VALUE] [--stream=NAME]` | Diagnose committed workflow state, next action, retries, timeouts and compensation stack |
| `stats [--minutes=60]` | Return journal metrics, minute buckets and per-stream totals |
| `describe ENTITY -M=MODULE` | Report the entity description, declared IDs and original command signatures |
| `create ENTITY --id=FIELD=VALUE [--data=JSON]` | Create the initial snapshot; reject an existing event stream |
| `load ENTITY --id=FIELD=VALUE` | Restore and replay an entity using its application handlers, without writing |
| `snapshot ENTITY --id=FIELD=VALUE` | Load and persist a fresh checkpoint |
| `command ENTITY METHOD --id=FIELD=VALUE --data=JSON` | Execute a validated command; display its result |
| `run-command ID` | Execute an existing pending command; print its persisted record |
| `work [--limit=100] [--watch]` | Process due pending commands, once or repeatedly |
| `advance SAGA --id=FIELD=VALUE [--limit=100]` | Process saga reactions, retries, compensations and due timeouts |
| `resolve-action SAGA ACTION-ID --id=FIELD=VALUE` | Record a confirmed result or error for a blocked/running action |
| `list-events [--json]` | Read event history and metadata |
| `list-commands [--json]` | Read command history, results and errors |
| `update` | Apply an atomic event payload/schema migration |
| `web-monitor --database=PATH` | Serve the independent Cro/HTMX monitor |

Application-aware operations accept repeatable `-I=PATH` and `-M=MODULE` flags.
Supply modules containing target entities, events, migration helpers and service
registrations. Execution and replay retain the library's `resolve-class`
fallback; database-only inspection never resolves persisted class names.
Identity flags must supply exactly the declared entity IDs. Domain arguments are JSON
objects passed through the generated API, retaining aliases, type constraints
and defaults. `create --data` accepts public initial attributes, excluding identity
and internal stream/version/cursor/saga bookkeeping fields.

## Saga diagnosis

Read a saga's current committed workflow state with either its type and identity
or its exact stored stream name:

```sh
red-sourcing saga-status RepairWorkflow -I=examples/real-estate/lib -M=Estate::Domain \
    --id=repair-id=r-boiler
red-sourcing saga-status \
    --stream='Estate::Domain::RepairWorkflow: repair-id = r-boiler'
red-sourcing saga-status -I=examples/real-estate/lib -M=Estate::Domain \
    --stream='Estate::Domain::RepairWorkflow: repair-id = r-boiler'
red-sourcing saga-status --stream='MyApp::OrderSaga: order-id = o1' --details
red-sourcing saga-status --stream='MyApp::OrderSaga: order-id = o1' --json
```

Type selection imports the application only to resolve the saga definition and
its typed IDs; it does not instantiate or replay it. `--ids=JSON` remains supported.
`--stream` works without application modules or service adapters. Without import
flags it ignores configured domain imports. Supply repeatable `-I=PATH` and
`-M=MODULE` (or `--includes=PATH` and `--modules=MODULE`) to load the requested
modules together with the configured paths/modules, just as in entity selection.
Imports do not replay or advance the saga. `--stream` cannot be combined with
an entity or IDs. An unknown stream or a stream belonging to another entity kind
is an error.

The report uses the latest snapshot or saga control record, including controls
written after a snapshot. It shows workflow status, checkpoint version, source
cursor, domain values, queued and failed actions, attempts, errors, UTC deadlines,
timeouts and the compensation stack in execution order. The next action follows
the runtime's ordering: a later ready action cannot bypass the first unfinished
action. Running or uncertain actions need inspection/reconciliation before
rollback can proceed. Registered compensations are available on failure; they
become active when the saga enters `compensating`. `--details` includes action
history, saved arguments/results and inverse arguments; `--json` includes them
in the full structured report.

Inspection does not write records, run commands/services, process timeouts or
consume source events awaiting the controller. A ready action/timeout requires
`advance`; a blocked action requires a confirmed outcome through `resolve-action`.
Schedules are evaluated against the inspection clock, so remaining delays can
change without any new records.

This reports known pending work, not every future step in a dynamically written
workflow. An empty queue does not imply completion: the saga can be waiting for
another event, and its code must explicitly call `.^complete`. The current
real-estate `RepairWorkflow` does not call `.^complete`, so it can remain
`running` with no queued actions. An explicit application-level description of
the expected event or completion criteria would be a future extension.

## Entity IDs

Repeat `--id=FIELD=VALUE` once for each declared identity field. This works with
`load`, `create`, `snapshot`, `command`, `advance`, `saga-status` and `resolve-action`:

```sh
red-sourcing load Repair -M=MyApp::Domain \
    --id=repair-id=rboiler --id=tenant-id=some-other
red-sourcing command Repair assign -M=MyApp::Domain \
    --id=repair-id=rboiler --id=tenant-id=some-other --data='{"contractor":"Ana"}'
```

Field order does not matter. Values use the entity-ID attribute's declared type:
text stays text (`001` stays `001`), numeric fields receive native numbers, and
boolean fields accept `true`/`false`, case-insensitively. Normal entity construction
still checks types and constraints; a fractional value cannot bind to an `Int` ID.
Only the first `=` separates field and value, so `--id=code=a=b` supplies `a=b`.
Empty text values are permitted; quote values containing spaces or shell characters.
Other attribute types receive the literal string and follow normal binding rules.

Missing, unknown, duplicate or malformed IDs are errors. `--ids=JSON` remains
available for existing scripts and JSON values; use either syntax, without mixing
them in one invocation. `run-command ID` takes the stored command row's numeric
ID, which is separate from an entity's identity fields.

## Entity descriptions

`describe` reads the entity's native `.WHY` documentation, including `#|` leading
comments and `#=` trailing comments attached to that declaration by Raku. It also
shows descriptions attached to command handlers. Each command has its own block,
with the source declaration when available, so `where` predicates, aliases and
default expressions remain visible instead of becoming Raku's `{ ... }` placeholders:

```text
Commands
post-message
  method post-message(Str :$author! where *.trim.chars > 0,
                      Str :$body! where *.trim.chars > 0,
                      Str :$message-id!, Bool :$notification = False)
  Source: /path/to/Estate/Domain.rakumod:176
```

Reading a declaration never runs its handler, predicates or default expressions.
The source reader handles nested parentheses, brackets and blocks, ordinary quoted
strings and line comments. If the source is missing or uses quoting that the reader
cannot safely interpret (such as regexes or heredocs), the CLI falls back to the
reflected signature and explicitly identifies hidden predicate bodies. A source
location is included when the file is available.

`describe --json` retains `signature` and structured `parameters` for existing
scripts, adding `declaration` when recovered and `source` with `file` and `line`.

For example, entities can document their purpose directly:

```raku
use RedSourcing;

#| Coordinates repairs and notifications for one tenant.
saga RepairWorkflow {
    has Str $.repair-id is entity-id;
    method APPLY() { }
    method REACT() { }
}
```

For a unit entity, trailing documentation can follow the unit declaration:

```raku
use RedSourcing;
unit projection TenantRepairs; #= Repairs visible to one tenant.
has Str $.tenant-id is entity-id;
method APPLY() { }
```

Placement follows Raku's declarator documentation rules: a `#=` next to a method
or attribute describes that declaration. Prefer `#|` immediately before a block
entity declaration. `describe --json` adds `description` only where documentation
exists. Descriptions come from loaded source modules; database-only `types`,
entity listings and the independent monitor do not load source documentation.

## Listing entities

`types` lists the observed entity types; `list-entities` lists their individual
persisted streams. The kind-specific commands select aggregates, projections or
sagas. They work from the database without loading application modules or running
handlers, including when the configuration contains application imports.

```sh
red-sourcing list-entities
red-sourcing list-aggregates --type=MyApp::Domain::Account --json
red-sourcing list-projections --limit=25 --offset=25
red-sourcing list-sagas --status=running --json
red-sourcing list-entities --stream='MyApp::Domain::Account: account-id = a1' --json
```

Text output is an aligned table with complete kind, type and stream names,
state version, state source and saga status. `--json` returns an array containing
the Inspector's stored records, including persisted state and checkpoint/head
metadata. `--type`, `--stream` and `--status` match exact stored values; type names
are fully qualified, without resolving application aliases. `list-entities`
also accepts `--kind=aggregate|projection|saga|entity`.

Results are sorted by full stream name. Filters apply before `--offset` (default
0) and `--limit` (default 100); a zero limit or unmatched filter returns no records.
Pagination bounds the returned records; discovery uses the Inspector's journal
scan. Concurrent journal changes can shift offset-based pages.

An aggregate or projection shows its latest snapshot, without folding later
events; `state-source`, `version` and `head-version` distinguish that state from
the stream head. Saga controls may supply newer committed state and status.
Targets known only through commands have kind `entity` and unavailable state:
command metadata cannot distinguish aggregates from projections. Bare event
streams are excluded. Entities without any persisted snapshot, control or command
are not discoverable. Use `load` with application modules for a replayed entity,
or `inspect --stream=...` for its stored state and event/command history.

## A complete command flow

Use the provided counter module and its configuration from the repository root.
The configuration supplies paths and imports, so this walkthrough does not
require a hypothetical application module:

```sh
red-sourcing -f=examples/counter/red-sourcing.rakuconf init
red-sourcing -f=examples/counter/red-sourcing.rakuconf describe Counter
red-sourcing -f=examples/counter/red-sourcing.rakuconf create Counter --id=id=1
red-sourcing -f=examples/counter/red-sourcing.rakuconf command Counter increment --id=id=1 --data='{"amount":2}'
red-sourcing -f=examples/counter/red-sourcing.rakuconf load Counter --id=id=1
red-sourcing -f=examples/counter/red-sourcing.rakuconf command Counter increment --id=id=1 --async
red-sourcing -f=examples/counter/red-sourcing.rakuconf work
red-sourcing -f=examples/counter/red-sourcing.rakuconf load CounterTotal --id=id=1
red-sourcing -f=examples/counter/red-sourcing.rakuconf snapshot CounterTotal --id=id=1
```

In a source checkout, replace `red-sourcing` with
`raku -Ilib bin/red-sourcing.raku`. Run `create` once for a fresh ID; the initial
synchronous result is `2`, and the deferred increment makes the aggregate and
projection values `3`. `init` preserves existing data. To isolate another run,
override `--database` consistently or use another ID.

See [the counter guide](../examples/counter/README.md) for executable source and
[shared configuration](configuration.md) for integrating your own modules.

## Pending work and saga control

```sh
red-sourcing work -I=app/lib -M=MyApp::Domain --database=accounts.db --limit=50
red-sourcing work -I=app/lib -M=MyApp::Domain --database=accounts.db \
    --watch --interval=2 --entity=MyApp::Domain::Account
red-sourcing run-command 42 -I=app/lib -M=MyApp::Domain --database=accounts.db
red-sourcing advance RepairWorkflow -I=app/lib -M=MyApp::Domain \
    --database=accounts.db --id=repair-id=r1
red-sourcing resolve-action RepairWorkflow ACTION-ID -I=app/lib -M=MyApp::Domain \
    --database=accounts.db --id=repair-id=r1 \
    --result='{"payment-id":"confirmed-provider-payment"}'
```

The worker selects `Pending` rows whose `next-run` is due, orders by ID and
processes at most `--limit` rows per pass. `--stream` and `--entity` restrict its
scope. Each pass reports processed commands and execution errors. With `--json`,
each pass prints one JSON object, including empty batches. Human watch output
suppresses repeated empty passes. One-shot mode continues through the batch and
exits nonzero if any handler fails. Watch mode continues polling; Ctrl-C shuts it
down. It uses the stored command's existing transactional claim logic.
It does not reset `Failed` commands or implement an additional retry policy.

`run-command --wait` waits until a future scheduled command is due. Without it,
future or already-processing commands retain their state; completed commands
return their stored result. A failed command reports its persisted error.
The worker executes queued commands; it does not discover or advance sagas.
An application controller must advance the relevant saga instances.

`advance --now=ISO-DATETIME` supplies the evaluation time for due saga work;
`--limit` bounds action processing in a pass, following the saga API. Modules
registering service adapters must be imported explicitly. External effects use
the saga's existing retry, uncertainty and idempotency policies.

`resolve-action` requires exactly one of `--result=JSON` or `--error=TEXT`.
Use it after reconciling a blocked/running operation with its provider. It records
the outcome through the saga API and may plan follow-up reactions; subsequent
`advance` executes those plans. Settled operations cannot be resolved twice.

## Inspection and history

`types`, `inspect` and `stats` do not import or instantiate persisted types.
Aggregate/projection state comes from the last stored snapshot; saga controls
can supply state after that checkpoint. `load` replays application code when you
need the folded state. Types with no stored records cannot be discovered.
Metrics use the same definitions and limits as the [monitor](web-monitor.md).

`list-events` accepts `--stream`, `--after=ISO-DATETIME`, `--from-id`,
`--class-name=EXACT-PERSISTED-NAME`, `--schema-version` and `--snapshots` (snapshot
rows only). `-l=TYPE` and `-c=EXPRESSION` retain imported type/rule filtering.
Output reads stored rows without instantiating events. The default is a table;
`--details` shows labelled metadata/payloads and `--json` returns the original
metadata/payload schema. `--rows` remains accepted for compatibility. Application
imports are used only for explicit type/import flags.

`list-commands` accepts `--stream`, `--from-id`, `--entity`, `--method`, `--due`
and `--state=Pending|Processing|Done|Failed`. Due is a schedule filter; add
`--state=Pending` to list executable work. Both history commands accept
`--limit=N` (zero means unlimited) and `--latest` (descending ID); default order
is ascending. The cursor always means IDs strictly greater than `--from-id`,
regardless of output order. `inspect` instead returns recent rows newest first.
Large event-history queries can still scan/materialize matching records before
applying newest-first output; use stream/type/cursor filters to narrow them.

```sh
red-sourcing list-events --database=accounts.db --json --snapshots --latest --limit=10
red-sourcing list-commands --database=accounts.db --json --state=Failed --latest --limit=20
red-sourcing stats --database=accounts.db --minutes=120
red-sourcing inspect --database=accounts.db --stream='MyApp::Domain::Account: account-id = a1'
red-sourcing web-monitor --database=accounts.db
```

See the main README's schema-versioning section for `update`. Its Raku
transformation/import flags execute trusted application code. `--dry-run`
reports candidate rows with `--debug` without applying the transformation.
