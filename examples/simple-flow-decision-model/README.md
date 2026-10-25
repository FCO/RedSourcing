# Simple flow with a decision-model

This copies [Simple flow](../simple-flow/README.md) and replaces its only saga,
`Confirmation`, with a decision inside `Order.place`. There are no sagas or saga
controllers in this version.

This is deliberately a small teaching example: checking the aggregate's own
state would suffice here. The projection demonstrates the decision API;
[School](../school/README.md) demonstrates constraints across different streams.

## Run

From the repository root:

```sh
raku -Ilib examples/simple-flow-decision-model/main.raku
```

Expected output:

```text
Command: Pending
Before run: new
Result: confirmed
After run: confirmed
Card: Pizza: confirmed
Commands: 1
Domain events: 2
Saga controls: 0
After checkpoint: confirmed
```

The default database is in memory. Pass `--database=orders.db` to persist it.
For a line-by-line REPL walkthrough, start `raku -I../../lib -Ilib` in this
directory and paste the statements from [repl.raku](repl.raku).
The [domain module](lib/DecisionFlow.rakumod) contains the complete implementation.

## What changes

| Aspect | Original with saga | This decision-model version |
| --- | --- | --- |
| Placement | Emits `OrderPlaced`, returns `placed` | Emits `OrderPlaced`, reads `OrderCard`, emits `OrderConfirmed`, returns `confirmed` |
| Confirmation | Saga schedules a separate `confirm` command | Part of the original `place` command |
| Transactions | Placement and confirmation commit separately | Both facts commit together; failure rolls back both |
| Intermediate state | `placed` can be observed before confirmation | `placed` exists inside the transaction |
| Workflow records | Saga snapshot, controls and child command | One normal stored command and two domain events |
| Progress | Requires the saga controller | Running the command completes the flow |

The business facts and final state are equivalent; their timing and transaction
boundaries change. `:!sync` still creates a pending stored command, and running a
completed command again returns its saved result without repeating the events.
It does not create a saga action.

A decision-model reads projections and validates their observed versions when
committing. Conflicting work can retry. External effects such as payments or
emails must not run inside a retryable decision block: rolling back the database
cannot undo them. A saga remains useful for durable multi-step work, external
results, timers, retries and compensation.

Read the framework guides for [sagas](../../docs/sagas.md) and
[decision-models](../../docs/decision-models.md).
