# Testing RedSourcing

Run commands from the repository root. The regular suite uses isolated temporary
stores; the estate PostgreSQL checks and writable browser checks require their own
test databases.

## Unit and integration suite

```sh
zef install --test-depends --deps-only .
zef install App::Prove6 'App::RaCoCo:ver<2.0.1>'
prove6 --exec='raku -Ilib' t
```

For a faster run, independent files can run in parallel:

```sh
prove6 --jobs=4 --exec='raku -Ilib' t
```

Tests cover event/command storage, aggregate and projection replay, typed IDs,
command signatures (including multiple defaults and explicit overrides), rollback,
optimistic command retries and state revalidation,
saga retries/compensation/recovery, examples,
configuration discovery, CLI output/help, installation, Cro HTTP disconnects,
monitor details/metrics and Operations job lifecycle. Run individual files with
`raku -Ilib t/FILE.rakutest` while developing.

Saga command checks cover both aggregate types and already constructed proxies.
Operations tests wait for job completion before asserting output limits and
history pruning, so those assertions also hold under coverage instrumentation.

On affected macOS OpenSSL installations, prefix Cro tests or the whole suite with
`DYLD_LIBRARY_PATH=/opt/homebrew/opt/openssl@3/lib`. PostgreSQL checks also need the
libpq directory; see [configuration](configuration.md#macos-native-libraries).

The CI matrix runs the suite directly on Linux, macOS and Windows using the latest
prebuilt Rakudo. Coverage and PostgreSQL jobs pin **2026.09**, an available binary
release in the [setup-raku catalog](https://github.com/Raku/setup-raku#what-raku-versions-are-available).
A source release need not have corresponding binaries for that action.
Native PostgreSQL, SQLite and OpenSSL libraries must be available before Zef
resolves dependencies: Red pulls in `DB::Pg` even for SQLite tests. Linux jobs
install the development packages; macOS exports the Homebrew library paths.
Windows exposes the runner's PostgreSQL DLLs, supplies the `pq.dll` name used by
Zef's native dependency check, and downloads the pinned official SQLite DLL.
The matrix checks native database library loading before installing Raku modules.
Installation checks expect `.exe` wrappers on Windows. HTTP and worker startup,
operations, and process termination are checked there; assertions that a child
handles a programmatically sent `SIGINT` gracefully run on Unix platforms only.
[libuv's Windows process implementation](https://github.com/libuv/libuv/blob/v1.x/src/win/process.c)
uses `TerminateProcess` for that request, which bypasses the child's handler.
Direct Operations cancellation and shutdown remain tested on every platform.

## Coverage

```sh
raku -I. xt/coverage.rakutest
```

The check starts a fresh suite, requires every `META6.json` provided module to
appear in the `lib/` report, and compares the covered fraction against
`coverage-baseline.json`. Reviewed non-executable VM annotations are listed in
`xt/coverage-exclusions.json`; executable business logic remains measured.
Raw and adjusted counts are written to `.racoco/coverage-summary.json`.
Coverage does not establish concurrency or production guarantees.

## PostgreSQL

The SQL translation checks do not need a server:

```sh
raku -Ilib t/34-postgres-json.rakutest
```

The estate workflow can run against a dedicated PostgreSQL database. It creates
and removes isolated schemas inside that database; the role must have permission
to create schemas:

```sh
export PGHOST=127.0.0.1 PGPORT=5432 PGUSER="$USER"
createdb red_sourcing_test
RED_SOURCING_TEST_PG_DATABASE=red_sourcing_test \
    raku -Ilib t/14-real-estate-example.rakutest
RED_SOURCING_TEST_PG_DATABASE=red_sourcing_test \
    raku -Ilib t/41-flow-tracing.rakutest
RED_SOURCING_TEST_PG_DATABASE=red_sourcing_test \
    raku -Ilib t/43-saga-controller.rakutest
RED_SOURCING_TEST_PG_DATABASE=red_sourcing_test \
    raku -Ilib t/45-command-conflicts-pg.rakutest
```

The CI PostgreSQL job runs the estate workflows, controller and independent-writer
command checks. The latter pauses one process after reconstruction, commits a
competing command from another connection, then verifies automatic rollback,
reload and retry of the rejected append. This covers JSON, domain commands and
estate saga behavior, not arbitrary real-world provider behavior or a complete
multi-controller concurrency protocol. Commerce's dedicated suite uses SQLite.

## Browser checks

```sh
npm install
```

Start Hearth and a separate monitor using a seeded **test** store, then:

```sh
HEARTH_URL=http://127.0.0.1:3000 CONSOLE_URL=http://127.0.0.1:3001 \
    npm run test:browser
CONSOLE_URL=http://127.0.0.1:3001 npm run test:console
CONSOLE_URL=http://127.0.0.1:3001 npm run test:details
CONSOLE_URL=http://127.0.0.1:3001 npm run test:flows
```

`test:browser` and `test:console` exercise business forms, rent, chat, retries,
compensation and cross-process SSE. `test:details` checks names, links, detail
views, refresh and mobile layout. Use the documented test data/ports in the
[monitor guide](web-monitor.md#verification).

`test:flows` is read-only and needs a traced workflow (for example SimpleFlow).
It checks card timestamps and persistent hover/focus details in a separate panel,
verifies that the preview never overlaps the diagram, samples curved arrow paths
to check their directness and physical separation between card endpoints,
verifies that intermediate cards paint above crossing connectors, and repeats routing checks after live refresh and
in landscape and portrait viewports, including a rotated phone. Screenshots go
to `/tmp/redsourcing-flow-screenshots`.
Set `FLOW_FIXTURE_HTML=/path/to/captured-flow.html` to replay a saved flow page
with current assets. In this mode browser requests are intercepted locally,
allowing dense historical graphs to be verified without contacting the app/store.

`test:operations` creates entities and runs commands. Give it a separate monitor
and disposable database:

```sh
raku -Ilib bin/red-sourcing.raku web-monitor --driver=SQLite \
    --database=/tmp/console-test.db --allow-new-store --port=3107 \
    -I=examples/shopping-cart -M=Cart
CONSOLE_URL=http://127.0.0.1:3107 npm run test:operations
```

`PLAYWRIGHT_PATH` selects an installed Playwright package and `CHROMIUM_PATH` an
existing Chromium executable. Browser checks do not replace the Raku suite.

## Documentation and examples

The README is maintained as Markdown; distribution generation must not overwrite
it from the shorter module POD. The POD points to the public guides. Runnable
snippets and local Markdown links are checked alongside the published examples.
`t/42-repl-tutorial.rakutest` executes the [simple flow tutorial](tutorials/simple-flow.md)
in Raku's process REPL, checks each documented stage and resumes a pending saga
from the configured SQLite store in a new process.

The Docker CI job builds the shared image, validates every Compose file, runs the
SQLite demos through their configured launcher arguments, and checks the SQLite
monitor and PostgreSQL web stack over HTTP. See [Docker](docker.md) to run these
same stacks locally. `t/43-saga-controller.rakutest` covers discovery, terminal
state, limits, timers, compensation and isolated failures; `t/44-projection-boundaries.rakutest`
checks command rejection, ordinary reads and monitor actions.

Run a specific demo using the command in its README. In-memory demonstrations
and persistent CLI stores are separate unless the example explicitly shares its
configured store. Do not infer multi-process safety from an in-memory test; the
[roadmap](next-steps.md) records the remaining validation work.
