# Shared configuration

A `red-sourcing.rakuconf` describes a store, application modules, worker defaults
and monitor settings. The library, CLI, standalone monitor and example
applications use the same Configuration-based Raku DSL.

## A complete file

Save this as `red-sourcing.rakuconf` in your application directory:

```raku
use RedSourcing::Config;

config {
    .driver = 'SQLite';
    .database = 'events.db';
    .debug = False;
    .flow-tracing = False;
    .includes = <lib>;
    .modules = <MyApp::Domain MyApp::Services>;
    .connection = %(timeout => 5000);
    .entities = {
        'MyApp::Domain::Account' => { lifecycle => 'Retained' },
        'MyApp::Domain::Balance' => { lifecycle => 'OnDemand' },
        'MyApp::Domain::PurchaseWorkflow' => { lifecycle => 'Retained' },
    };
    .worker: { .limit = 100; .interval = 1; .watch = False }
    .monitor: {
        .host = '127.0.0.1'; .port = 3001; .minutes = 60;
        .app-url = 'http://127.0.0.1:3000/';
        .allow-new-store = False;
    }
}
```

`use RedSourcing; config { ... }` also provides the builder. Files execute Raku
code; only load configurations you control. The CLI does not display the
connection hash, which may contain credentials.

## Discovery and precedence

| Setting | Behavior |
| --- | --- |
| Automatic lookup | Search the current directory, then its parents, for the nearest `red-sourcing.rakuconf` |
| Explicit file | CLI `-f FILE` / `--file=FILE`; library `:file('FILE')` |
| Parent configuration | Read one file; do not merge it with ancestor files |
| Missing explicit file | Fail before replacing the selected connection |
| No file | SQLite / `a.db`, with default settings |
| Scalar override | Explicit caller/CLI value, then file value, then built-in default |
| Library connection overrides | Merge keys over the file's `connection` hash |
| CLI imports | Configured include/module lists followed by `-I`/`-M`, with duplicates removed |
| Reload | Read once per startup/invocation; no hot reload |
| Entity lifecycle | File `entities` entry overrides that type's declaration default on the selected connection/pool; omitted types retain their declaration default |

Relative include paths and SQLite filenames in a file resolve against that file's
directory. Explicit relative database overrides resolve against the process
working directory. Absolute paths, `:memory:`, SQLite `file:` names and server
database names preserve their meaning. A SQLite file's parent directory must exist.

The `entities` map uses exact full class names and supports aggregates, projections
and sagas. An entry accepts `cached` (Bool or nonnegative Int), `retained` (Bool),
`auto-snapshot`, or `lifecycle`
(`Cached`/`OnDemand`/`Retained`). Use one lifecycle spelling per entry. `.auto-snapshot`
sets the global policy; omitted policies default to `{ :100count }`. Explicit
`False` or `Nil` disables optional snapshots. See [automatic snapshots](auto-snapshot.md)
for declaration precedence and operation boundaries. Native bootstrap and the
CLI install overrides on the selected
connection/pool, including for modules loaded later. A used type cannot change
mode on that connection. See [entity lifecycle](lifecycle.md) for startup behavior,
retained updates, release and cross-process freshness.

The repository's root configuration targets the Hearth PostgreSQL example. Every
example has a closer file. Select one from the root with, for example,
`-f=examples/counter/red-sourcing.rakuconf`.

`.flow-tracing` remains a compatibility flag for the flow read model. It creates
no auxiliary tables and adds no tracing queries during emission or replay.
Causal command/action metadata is always stored outside domain JSON, including
when this flag is False. See [workflow visualization](flows.md) for the projected
evidence and its limits.

## Use from application code

```raku
use RedSourcing;

my $settings = red-sourcing-defaults;
```

The call configures Red's default driver, creates missing `StoredEvent` and
`StoredCommand` tables, and returns
`RedSourcing::Config::Settings`. Importing `RedSourcing` does not read files or
change the connection. The call sets `$PROCESS::RED-DEBUG` from the effective
`.debug` setting before table initialization, so `.debug = True` or `:debug`
enables SQL logging automatically. `:!debug` disables the process default.
A scoped `my $*RED-DEBUG = False` overrides that default within its dynamic scope;
the process value applies again after leaving the scope.

```raku
my $settings = red-sourcing-defaults(:file<deployment.rakuconf>);
my $overridden = red-sourcing-defaults(
    :driver<SQLite>, :database(':memory:'), :!debug,
    :connection{:timeout(5000)});
```

`:file` accepts a string or `IO::Path`. `:directory($path.IO)` changes the start
of discovery and the base of relative configuration filenames. A caller's
`$*RED-DB` keeps Red's normal precedence over the configured default connection.

`Bool :$initialize = True` controls table creation. Repeated initialization uses
`:unless-exists` and preserves existing rows. It also calls `.^create-indexes`
to add the declared query indexes to existing tables. Initialization creates
missing tables, not a missing PostgreSQL database, and does not migrate columns. For a
connection to an existing store without any table/index creation, use:

```raku
red-sourcing-defaults(:!initialize);
```

Flow reconstruction uses a projection over existing journal records and creates
no auxiliary tracing tables. Causal command/action metadata is always stored,
independently of `.flow-tracing`.

The returned settings include normalized `.includes`, `.modules`, `.connection`,
`.monitor` and `.worker`. This runtime call does not import modules,
start a worker or start HTTP. Keep compile-time imports explicit:

```raku
use RedSourcing;
use MyApp::Domain;
use MyApp::Services;  # registers adapters for a saga controller

my $settings = red-sourcing-defaults(:file<deployment.rakuconf>);
```

Use `-I` on the Raku invocation or the application's own `use lib` for these
compile-time imports. The configured include list cannot retroactively affect an
already compiled `use MyApp::Domain` statement. The CLI's runtime importer handles
configured paths/modules for application-aware operations.

`RedSourcing::Config` also exports `Settings`, `find-config`, `load-config`,
`config-database`, `store-connection-options` and `store-driver`. `load-config`
returns a hash with `settings` and the selected file's `directory` without
changing the default connection. Most applications only need
`red-sourcing-defaults`.

## Use from the CLI and monitor

```sh
red-sourcing -f deployment.rakuconf init
red-sourcing -f deployment.rakuconf command Account deposit --id=account-id=a1 --data='{"amount":10}'
red-sourcing web-monitor -f deployment.rakuconf --port=3005
```

Every CLI operation accepts configuration, driver, database and debug overrides.
`--/debug` and worker `--/watch` override configured `True` values with `False`.
Help does not execute configuration, open a connection or import domain code.

Read-only database discovery and monitor inspection do not load configured domain
modules. Operations such as `command`, `load`, `snapshot`, `advance` and
`resolve-action` require application definitions and service registrations.
The monitor runs them in subprocesses, separately from its inspection process.
See [CLI](cli.md) and [monitor](web-monitor.md) for the operation-specific behavior.

## PostgreSQL

Install the driver and create the database before initializing RedSourcing tables:

```sh
zef install DB::Pg
export PGHOST=127.0.0.1 PGPORT=5432 PGUSER="$USER" PGDATABASE=events
createdb "$PGDATABASE"
```

Use this connection section instead of the SQLite fields:

```raku
config {
    .driver = 'Pg';
    .database = %*ENV<PGDATABASE> // 'events';
    .connection = %(host => %*ENV<PGHOST> // '127.0.0.1',
        port => (%*ENV<PGPORT> // '5432').Int,
        user => %*ENV<PGUSER> // %*ENV<USER> // 'postgres');
}
```

libpq supports `PGPASSWORD` and password files; avoid committing credentials.
The example files explicitly map `PGHOST`, `PGPORT`, `PGUSER` and `PGDATABASE` to
these options. Environment variables are not a separate override layer for
arbitrary config fields: read them in the configuration when needed.

The top-level `.database` is mapped to Pg's `dbname`. Keep `driver`, `database`,
`debug`, `includes` and `modules` outside `.connection`. RedSourcing's Pg adapter
uses one JSON encoder and supports bound JSON paths, scalar casts and equality.
Prefer `red-sourcing-defaults` or the shared `store-driver` helper for this setup.

`init` creates tables, not the server database. If `hearth` does not exist, create
it before starting the real-estate example. DB::Pg retries unsuccessful
connections, so a missing database or invalid credentials can produce repeated
messages rather than immediately terminating.

### macOS native libraries

If the OpenSSL binding reports `loading libcrypto in an unsafe way`, point the
process at the compatible Homebrew libraries. On Apple Silicon:

```sh
DYLD_LIBRARY_PATH=/opt/homebrew/opt/openssl@3/lib:/opt/homebrew/opt/libpq/lib \
    raku -Ilib -Iexamples/real-estate/lib examples/real-estate/main.raku
```

Use the same prefix for CLI/monitor processes and Cro tests. Adjust paths for your
Homebrew installation. The libpq directory resolves a missing native `pq`
library; the OpenSSL directory addresses the Cro/OpenSSL binding.

## PostgreSQL MRO storage

PostgreSQL stores `red_sourcing_event.mro` as native `text[]`, with the
`red_sourcing_event_mro_gin` GIN index. SQLite and other drivers retain the
pipe-delimited text format. The Raku `StoredEvent.mro` accessor and reports
continue returning the pipe-delimited string on every driver.

Framework queries test type membership with `@>` on PostgreSQL and `LIKE` on
other drivers. Classes, ancestors and roles retain their recorded membership;
reading an old event never recomputes its MRO from the current application code.
New stores create the native column and index during initialization. Repeating
`StoredEvent.^create-indexes` also ensures the GIN exists.

Existing PostgreSQL stores require an explicit migration before using this
version. Initialization detects a legacy text column and reports the migration
path; it does not convert historical rows automatically.

1. Stop application processes and writers, and back up the database.
2. Select the application's database and schema and run:

   ```sh
   PGOPTIONS='-csearch_path=app,public' psql --dbname=DATABASE \
     --set=ON_ERROR_STOP=1 --file=tools/migrate-pg-mro-array.sql
   ```

3. Restart all clients, so prepared statements and cached result metadata are
   recreated for the new column type.

Replace `app` and `DATABASE` with the actual schema and database. The migration
runs in one transaction, preserves event IDs, versions, payloads and type order,
and can be repeated. It accepts legacy `text`/`varchar` or already-converted
`text[]`; unexpected types abort the transaction. Conversion takes an exclusive
table lock and index creation adds work proportional to the stored history.
Direct SQL clients must use the new array type after migration; the compatibility
string interface applies to the framework's Raku objects and internal row reads.

`.entity-cache-size` limits the total number of `Cached` instances per store (default 100; zero disables caching). Per-type `entities` entries accept `cached => N` or `cached => True` (100). Both limits apply simultaneously; see [entity lifecycle](lifecycle.md).
