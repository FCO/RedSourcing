# Simple flow: one aggregate, one projection, one saga

Follow the [line-by-line REPL tutorial](../../docs/tutorials/simple-flow.md)
to place an order, inspect its pending command, let a saga confirm it and
rebuild a projection. All state stays in memory unless you select the supplied
SQLite configuration.

From the repository root, start the REPL:

```sh
cd examples/simple-flow
raku -I../../lib -Ilib
```

Paste the lines of [repl.raku](repl.raku) one at a time. The entity definitions
and two inspection helpers are in [SimpleFlow.rakumod](lib/SimpleFlow.rakumod).
Each executable line is complete; no multiline declarations are needed in the REPL.

To run the same walkthrough as a regular program:

```sh
cd examples/simple-flow
raku -I../../lib -Ilib repl.raku
```

The tutorial also explains how to use [red-sourcing.rakuconf](red-sourcing.rakuconf)
and view this REPL session in the standalone web monitor.

## Sequence: the REPL walkthrough

```mermaid
sequenceDiagram
    autonumber
    actor REPL
    participant O as Order
    participant J as Journal
    participant C as Confirmation saga
    participant X as Saga controller
    participant P as OrderCard
    REPL->>O: create
    O->>J: Initial Order snapshot
    REPL->>C: create with the same order-id
    C->>J: Initial saga snapshot
    REPL->>O: place asynchronously
    O->>J: Persist pending place command
    REPL->>J: Inspect pending command and unchanged history
    REPL->>O: Run pending command
    O->>J: Append OrderPlaced and commit saved result
    REPL->>P: load
    P->>J: Select this order's facts
    P-->>REPL: status placed
    REPL->>X: advance Confirmation with limit 0
    X->>J: Read OrderPlaced after the saga cursor
    X->>C: REACT plans confirm-order
    C->>J: Persist action intent and source cursor
    REPL->>X: advance again
    X->>J: Persist running claim and child command row
    X->>O: Execute confirm
    O->>J: Append OrderConfirmed and save child result
    X->>C: APPLY and REACT StepSucceeded
    C->>J: Persist confirmed state and completed status
    REPL->>P: load again
    P->>J: Restore optional checkpoint and fold matching facts
    P-->>REPL: status confirmed
    REPL->>C: load
    C-->>REPL: Completed state, without another confirm command
    Note over C,J: Optional snapshots preserve<br/>pending actions and the<br/>source cursor
```

## Docker stack

From the repository root:

```sh
docker compose -f examples/simple-flow/compose.yaml up --build -d
```

This uses the shared RedSourcing image, an isolated database volume and a
separate monitor at `http://127.0.0.1:3001/monitor`. See the
[Docker guide](../../docs/docker.md) for ports, services and persistent data.
