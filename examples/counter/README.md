# Counter

A minimal aggregate, projection and persisted command example. Run from the root:

```sh
raku -Ilib examples/counter/main.raku
```

Expected output:

```text
2
Pending
5
5
5
```

[`CounterDemo`](lib/CounterDemo.rakumod) exports `CounterIncremented`, `Counter`
and `CounterTotal`. `increment` emits an event through the generated
`counter-incremented` helper. Its `amount` must be a positive integer.
`CounterTotal` filters by its own `id`. Re-running a completed deferred command
returns the saved result without another event.

## Sequence: submit, execute and read

```mermaid
sequenceDiagram
    autonumber
    actor Caller
    participant C as Counter proxy
    participant X as Command executor
    participant J as Journal
    participant P as CounterTotal
    Caller->>C: create
    C->>J: Initial Counter snapshot at version 1
    Caller->>C: increment amount 2
    C->>J: Store pending command
    C->>X: run synchronously
    X->>J: Restore Counter snapshot and later facts
    X->>J: Append CounterIncremented and save result 2 in one transaction
    X-->>Caller: 2
    Caller->>C: increment amount 3 asynchronously
    C->>J: Store pending command
    C-->>Caller: Pending handle
    Caller->>X: pending.run
    X->>J: Reload, append CounterIncremented, save result 5 and commit
    X-->>Caller: 5
    Caller->>X: Run the same completed command again
    X->>J: Read saved result
    X-->>Caller: 5, without another event
    Caller->>P: load
    P->>J: Read optional snapshot and matching facts for this id
    P->>P: APPLY facts in global ID order
    P-->>Caller: value 5
    Note over X,J: Commands evaluate optional<br/>autosnapshot at completion
    Note over P,J: Plain load does not write a<br/>snapshot
```

## Persistent CLI walkthrough

The demo above uses an in-memory database. The configuration selects a separate
persistent `counter.db` inside this directory:

```sh
cd examples/counter
raku -I../../lib ../../bin/red-sourcing.raku init
raku -I../../lib ../../bin/red-sourcing.raku describe Counter
raku -I../../lib ../../bin/red-sourcing.raku create Counter --id=id=1
raku -I../../lib ../../bin/red-sourcing.raku command Counter increment --id=id=1 --data='{"amount":2}'
raku -I../../lib ../../bin/red-sourcing.raku command Counter increment --id=id=1 --async
raku -I../../lib ../../bin/red-sourcing.raku work
raku -I../../lib ../../bin/red-sourcing.raku load Counter --id=id=1
raku -I../../lib ../../bin/red-sourcing.raku load CounterTotal --id=id=1
raku -I../../lib ../../bin/red-sourcing.raku web-monitor
```

Create the aggregate once. The projection can load without an initial snapshot.
The monitor runs independently at <http://127.0.0.1:3001/monitor>. For an isolated
run, override `--database` or choose another ID; `init` does not clear an existing
store. From the root, pass `-f=examples/counter/red-sourcing.rakuconf` instead of
changing directory. See [the main quick start](../../README.md#quick-start).

## Docker stack

From the repository root:

```sh
docker compose -f examples/counter/compose.yaml up --build -d
```

This uses the shared RedSourcing image, an isolated database volume and a
separate monitor at `http://127.0.0.1:3001/monitor`. See the
[Docker guide](../../docs/docker.md) for ports, services and persistent data.
