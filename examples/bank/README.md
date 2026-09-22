# Bank example

Run from the repository root:

```sh
raku -Ilib -Iexamples/bank examples/bank/main.raku
```

The demo creates an in-memory SQLite database, opens two accounts, deposits money,
transfers it, reads projections, saves a monthly checkpoint and executes a deferred
transfer. It also shows rejection for insufficient funds and an unknown recipient.
The example uses `use RedSourcing` for the event-store API and Red's database
configuration; it does not need separate imports for roles, traits or commands.

## Accounts and transfers

`Account` is an aggregate identified by `client-id` (one account per client in this
example). Create its initial zero-balance snapshot, then fund it through events:

```raku
my $ana = Account.^with-ids(:client-id(1));
my $bob = Account.^with-ids(:client-id(2));
$ana.^create;
$bob.^create;
$ana.deposit(:amount(100.00));

my %result = $ana.transfer(:to-client(2), :amount(25.50));
say %result<transaction-id>;
say %result<remaining>; # 74.5
```

Money uses `Rat`, with coercive `Rat()` arguments and attributes. Integers can be
passed as inputs and become `Rat`. Commands accept positive values with at most
two decimal places. This keeps every monetary value exact through the store's
JSON decimal serialization; arbitrary fractions such as `1/3` would be rounded
by the current serializer and are rejected. Account and projection checkpoints
also restore balances as `Rat`.

`transfer` checks the available balance, rejects a self-transfer, verifies that
the target has an `Account` snapshot and loads its current stream version before
emitting anything. It writes two linked events:

| Event | Stream | Purpose |
| --- | --- | --- |
| `Transaction` | Source account | Canonical transfer; debits the source |
| `TransferReceived` | Target account | Credits the target; references `Transaction` by row ID |

`APPLY` generates `deposited`, `transaction` and `transfer-received` methods on
loaded accounts. Their identity maps fill `client-id`, `from-client` and
`to-client`, respectively. Each helper emits, applies the event and advances the
account's metadata; handlers return the resulting balance. The recipient helper
is called on its loaded aggregate, within the same command transaction.

Both appends and command completion use the executor's existing transaction.
A conflict or failure on the recipient append rolls back the sender append too.
No nested command or transaction is opened. An optimistic conflict records a terminal `Failed` command. Retry by submitting
a new transfer command, which reloads both balances and stream versions. A successful repeated `.run` returns its saved result without moving
money again.

To defer execution:

```raku
my $pending = $ana.transfer(:to-client(2), :amount(1.25), :!sync);
$pending.run;
```

An executed rejection is recorded as a terminal `Failed` command with its
error; the caller receives the exception. Retrying requires a new submission. Invalid amounts
are rejected during submission before a command record is created.

## Projections

- `Balance`: current balance for one client. Its `.amount` method reads a loaded projection; `.^load.balance` reads the loaded projection directly.
- `MonthlyStatement`: one projection per client, with a current `balance`,
  closing balances in `balance-by-month` and entry lists in `transactions-by-month`.
  The hash keys are numeric periods (`year * 100 + month`, such as `202610`).
  `.amount` queries the current balance; `.amount-on-month(:period(202610))`
  queries the stored closing balance for October.
- `BankTotals`: total deposited, transfer volume and number of transfers across
  all accounts.

The projections consume `Deposited` and the canonical `Transaction`, so the
recipient's `TransferReceived` does not double-count a transfer. They consume
events from every account stream and exclude entity snapshots.

```raku
my $proxy = MonthlyStatement.^with-ids(:client-id(1));
my $statement = $proxy.^load;
say $statement.balance;
say $statement.balance-by-month{202610};
.say for $statement.transactions-by-month{202610}.list;
say $proxy.^load.amount-on-month(:period(202610));
$statement.^emit-snapshot;
my $restored = $proxy.^load;
```

Events are assumed to arrive in chronological order; backdated transactions are
not supported by this example. Each entry records the running balance in `total`,
and the last entry in each month sets that month's closing balance. Only months
with events have buckets: querying an absent period returns an undefined value.
A client with no history has a zero current balance and empty monthly hashes.

Events declare `DateTime()` timestamps, coercing the ISO strings supplied by
commands and reconstructed from JSON. Their `period` method derives the numeric
key from the timestamp; the payload does not store a separate period. Projection
rules filter by client in SQL, and replay groups those events by month. The
coercive `UInt()` hash key types also accept the string keys restored from JSON
snapshots. A checkpoint saves the client's whole projection, including all its
monthly buckets; subsequent replay adds only later applicable events.

The demo finishes with Ana at `79.75`, Bob at `40.25`, total deposits of `120` and
transfer volume of `30.75` across two transfers.

## Verification and remaining work

```sh
raku -Ilib t/08-bank-example.rakutest
```

The tests cover both account streams, projections, rejection, deferred execution,
saved-result reuse, `Rat` arithmetic, timestamp coercion, monthly balances and
entry lists across checkpoint restoration. The rollback test uses a SQLite
trigger to reject the recipient insert; it does not establish behavior between
concurrent database connections.

The example opens accounts at zero and funds them through `deposit`. Seeding a
nonzero amount directly in an account snapshot would be invisible to these
projections. Account closing, withdrawals, currencies, real concurrent connections
and PostgreSQL remain outside this example.

## CLI and web monitor configuration

This directory includes `red-sourcing.rakuconf`, with a local SQLite store,
example modules, application paths and worker/monitor defaults. From this directory,
the CLI discovers it automatically instead of using the repository's root config:

```sh
cd examples/bank
raku -I../../lib ../../bin/red-sourcing.raku init
raku -I../../lib ../../bin/red-sourcing.raku describe Account
raku -I../../lib ../../bin/red-sourcing.raku create Account --id=client-id=1
raku -I../../lib ../../bin/red-sourcing.raku web-monitor
```

Open <http://127.0.0.1:3001/monitor>. New-store mode is enabled, so you can also
start the monitor first and explicitly run **init** in Operations. Relative paths
are resolved from the configuration file; from the repository root, select it
with `-f=examples/bank/red-sourcing.rakuconf`. Use `--port` to override the
monitor port when running multiple examples.

The standalone `main.raku` demonstration still uses a fresh in-memory database.
Its demo records do not populate this persistent CLI store. Create entities and
execute commands through the CLI or Operations to populate it.

Application startup can use this same file through `red-sourcing-defaults`; see
[shared configuration](../../docs/configuration.md). The standalone demo
intentionally selects in-memory SQLite. The [CLI guide](../../docs/cli.md) and
[monitor guide](../../docs/web-monitor.md) explain persistent operations.

## Docker stack

From the repository root:

```sh
docker compose -f examples/bank/compose.yaml up --build -d
```

This uses the shared RedSourcing image, an isolated database volume and a
separate monitor at `http://127.0.0.1:3001/monitor`. See the
[Docker guide](../../docs/docker.md) for ports, services and persistent data.
