# Internal bank transfer: saga versus decision-model

This extends the [bank example](../bank/README.md) with two implementations of
the same internal transfer. Both use the same account events and balance
projection. There is no external payment provider. Amounts are integer cents.

## Run

From the repository root:

```sh
raku -Ilib examples/bank-transfer/main.raku
```

```text
Saga after debit: 7000 / 0
Saga completed: 7000 / 3000
Decision completed: 7000 / 3000
```

The demo uses an in-memory SQLite database. Read the complete
[domain module](lib/BankTransfer.rakumod) and [demo](main.raku).

## With a saga

`Transfer.request` records the intent. A `TransferWorkflow` consumes it, calls
`Account.debit`, then `Account.credit`, then marks the transfer complete.
Each command commits separately. The demo pauses the controller after one action
so the debit is visible while the credit is pending.

If credit fails because the target account is not open, the saga refunds the
source through a compensating command. That refund is a new fact; it does not
roll back the debit. The intermediate balance remains part of history.
The controller must keep advancing the workflow for it to finish or compensate.
Stored command results and transfer IDs prevent duplicate effects on replay.
If the final completion-record command exhausts its retries after credit has
committed, its failed action needs operator recovery. It must not refund the
source alone, which would create money. This example compensates failures before
a successful credit, not arbitrary cancellation of a completed transfer.

## With a decision-model

`Transfer.execute` reads two `Balance` projections, one for each account. It
checks that both accounts are open and that the source has sufficient funds.
It then appends the debit, credit and completion in the same transaction,
without invoking child commands. Any failure rolls them all back.

```raku
decision-model(
    (Balance) => %(:account-id($from)),
    (Balance) => %(:account-id($to)),
    -> $source, $target {
        # Validate both accounts, then append both account facts and completion.
    },
)
```

The framework checks the observed projection versions at commit. A concurrent
transfer that changes the balance forces the losing command to retry against
current state. If funds are no longer sufficient, that attempt fails without
leaving a debit or credit. Account stream versions also protect the appends.

## What the comparison demonstrates

| Aspect | Saga | Decision-model |
| --- | --- | --- |
| Visibility | Debit and credit become visible separately | Both commit together |
| Failed credit | Refund compensates an already committed debit | Debit is rolled back |
| Execution | Controller advances several durable commands | One command and transaction |
| Concurrency | Account commands protect each individual debit | Projection checks protect the whole decision, alongside stream checks |
| Best fit here | Demonstrates a multi-step workflow | Simpler fit for two accounts in the same store |

No reserve step is needed for this atomic internal transfer. External bank
transfers would introduce a different boundary: database rollback cannot undo a
provider request, so the same substitution would not preserve that workflow.

This teaching example assumes unique transfer IDs for each business operation.
The saga retains per-transfer deduplication metadata on accounts; it is not a
complete banking ledger or an account-lifecycle implementation. A failed saga
remains `requested` on the transfer aggregate; its terminal compensation status
belongs to the workflow.

See the guides for [sagas](../../docs/sagas.md) and
[decision-models](../../docs/decision-models.md), the
[behavior tests](../../t/87-bank-transfer.rakutest), and the
[concurrent Pg test](../../t/88-bank-transfer-pg.rakutest).
