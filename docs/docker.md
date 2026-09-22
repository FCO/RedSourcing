# Run RedSourcing and its examples with Docker

The root [Dockerfile](../Dockerfile) installs RedSourcing, its distribution
dependencies, `DB::Pg`, `App::Prove6`, and native SQLite, PostgreSQL and OpenSSL
libraries. It uses the pinned [official Rakudo Star image](https://hub.docker.com/_/rakudo-star).
The runtime uses the installed CLI, library and packaged web assets. Example
code stays on the host and is mounted by Compose; no host Raku installation is needed.

## Build the shared image

From the repository root:

```sh
docker build -t redsourcing:local .
docker run --rm redsourcing:local --help
```

The image's default entrypoint is the RedSourcing CLI. For another program,
override it with `--entrypoint raku`. Its working directory is `/workspace`,
so it does not discover the checkout's root PostgreSQL configuration accidentally.
Each Compose service mounts only its example directory at `/app` and uses `/app`
as its working directory. The CLI discovers that directory's configuration without
`-f`. Raku uses the installed RedSourcing module; `-Ilib` is only for example modules
in a local `lib/` folder. Framework source is not mounted or kept in the image.

## Start one example stack

Every example has a `compose.yaml` using this shared image:

```sh
docker compose -f examples/simple-flow/compose.yaml up --build -d
docker compose -f examples/simple-flow/compose.yaml logs demo
```

Open `http://127.0.0.1:3001/monitor/flow`. The simple-flow demo runs the same
sequence as the [REPL tutorial](tutorials/simple-flow.md), saves it to its own
SQLite volume, and then the independent monitor starts.

| Example | Services |
| --- | --- |
| [Counter](../examples/counter/compose.yaml) | One-shot demo, SQLite volume, monitor |
| [Bank](../examples/bank/compose.yaml) | One-shot demo, SQLite volume, monitor |
| [Shopping cart](../examples/shopping-cart/compose.yaml) | One-shot demo including reminder, SQLite volume, monitor |
| [Food delivery](../examples/food-delivery/compose.yaml) | One-shot demo, SQLite volume, monitor |
| [Order saga](../examples/order-saga/compose.yaml) | One-shot demo with simulated providers, SQLite volume, monitor |
| [Simple flow](../examples/simple-flow/compose.yaml) | One-shot REPL walkthrough, SQLite volume, monitor |
| [Commerce](../examples/commerce/compose.yaml) | Demo, ongoing controller, SQLite volume, monitor |
| [Hearth](../examples/real-estate/compose.yaml) | PostgreSQL, estate web app/controller, monitor |

Each stack has a different Compose project name, isolated network and named
database volume. By default all monitors use host port 3001. To run several
stacks at once, choose different ports:

```sh
MONITOR_PORT=3011 docker compose -f examples/counter/compose.yaml up -d
MONITOR_PORT=3012 docker compose -f examples/bank/compose.yaml up -d
APP_PORT=3020 MONITOR_PORT=3021 docker compose -f examples/real-estate/compose.yaml up -d
```

Hearth creates its own `hearth` database through PostgreSQL's container startup.
The app connects to the stack's `postgres` hostname, waits for database readiness,
initializes and seeds its data, then starts its HTTP server. The monitor waits
for the app to be healthy. Open Hearth at `http://127.0.0.1:3000/` with defaults.
`POSTGRES_PASSWORD` overrides the example password (`estate-example`) when first
creating the volume. The database port is not published to the host.

The simple demos exit after their walkthrough; their monitors stay running.
They use `REDSOURCING_EXAMPLE_DATABASE=/data/events.db` internally and skip seeding
when their volume already contains events. Commerce has its own idempotent demo
and a continuous controller. Simulation does not contact payment/email providers.

## Reload changes with Compose Watch

The example stacks support [Compose Watch](https://docs.docker.com/compose/how-tos/file-watch/).
Use Docker Compose **2.32 or newer**, which supports the `restart` watch action:

```sh
cd examples/bank
docker compose up --build --watch
```

Alternatively, run `docker compose up --build -d`, then `docker compose watch`.
Changes inside the mounted example restart its long-running monitor, controller
or web app. The example directory remains the only source bind mount. Database
files and Raku precompilation directories are ignored to avoid restart loops.

Changes to framework `lib/`, `bin/`, packaged `resources/`, `META6.json`, the
Dockerfile or `.dockerignore` rebuild the installed module image and recreate the
watched services. One-shot demos are not watched: changes do not automatically
repeat commands, transfers or provider simulations in your stored history.
Run a demo explicitly when you intend to execute it again.
Database containers and persistent volumes are not rebuilt by these rules.

See the [Develop specification](https://docs.docker.com/reference/compose-file/develop/)
for the watch actions and their version requirements.

## Inspect, interact and stop

Use the monitor's contextual entity actions, or run the same CLI in that stack:

```sh
docker compose -f examples/simple-flow/compose.yaml exec monitor red-sourcing --database=/data/events.db saga-status Confirmation --id=order-id=demo-1
```

For a fresh interactive in-memory session inside the image:

```sh
docker compose -f examples/simple-flow/compose.yaml run --rm --no-deps --entrypoint raku demo -Ilib
```

Paste the tutorial lines one at a time. This interactive in-memory session is
separate from the Compose store.

```sh
docker compose -f examples/simple-flow/compose.yaml down
```

`down` keeps the named volume. To intentionally discard that example's data and
run its seed again, use `down --volumes`. Changes to example code and configuration
are available immediately through the bind mount; Watch restarts long-running
processes to load changed modules when enabled. Without Watch, restart them manually. Rebuild the image only when changing RedSourcing or its
dependencies. `red-sourcing-demo` is the installed one-shot launcher used by the
small demos; it reads local configuration and skips seeding an existing store.

See Docker's [startup dependency documentation](https://docs.docker.com/compose/how-tos/startup-order/)
for the readiness and one-shot completion conditions used in these stacks.
