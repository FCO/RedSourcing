# Performance

Use `tools/benchmark-performance.raku` to measure append, stream reads, replay,
decisions, commands, sagas and monitor reports separately. It prints JSON with
elapsed time, SQL prepare counts and functional results.

```sh
raku -Ilib tools/benchmark-performance.raku --events=100 --iterations=12
raku -Ilib tools/benchmark-saga-state.raku --actions=12 --controls=8 --reads=12 --clones=12
```

## Changes

Storage models cache column metadata and hydrate fixed-schema rows without
repeating Red reflection. Structural SQL projections retain Red's normal path.
Stable INSERT shapes and SQLite RETURNING avoid repeated statement construction
and follow-up reads. Stream filters construct Red AST directly.

Counter updates use atomic conditional batches of at most 128 keys. A conflict
in any batch rolls back the complete append. Snapshot and native control rows
do not increment domain counters. Command claiming uses one conditional UPDATE;
optimistic concurrency and complete-command retries remain in place.

Saga restoration reads lightweight historical headers to preserve version and
snapshot metrics, then hydrates only the final complete state. Provisional state
remains deeply isolated. Monitor summaries select the latest stored states;
flow reports use metadata, indexed links and batched related-record reads.

## Measurements

Measurements use SQLite in memory, Red 0.2.7 and Raku/MoarVM 2026.09 on the same
machine. Each number is the median of three runs with 100 events and 12
iterations. Module startup/compilation is excluded; the benchmark reports the
first flow read separately. Functional results are compared between versions.

| Phase | Operations | Before (s) | After (s) | Speedup | SQL prepares before → after |
| --- | ---: | ---: | ---: | ---: | ---: |
| bootstrap | 1 | 0.135 | 0.110 | 1.22× | 23 → 23 |
| emit | 100 | 1.683 | 0.539 | 3.12× | 702 → 402 |
| emit-wide | 25 | 0.493 | 0.170 | 2.90× | 600 → 100 |
| stream-query | 12 | 2.800 | 0.693 | 4.04× | 12 → 12 |
| projection-replay | 12 | 0.591 | 0.264 | 2.24× | 24 → 24 |
| decision-read | 12 | 0.467 | 0.198 | 2.35× | 48 → 48 |
| commands | 12 | 1.965 | 0.401 | 4.90× | 230 → 158 |
| decision-append | 12 | 0.539 | 0.216 | 2.50× | 110 → 74 |
| sagas | 3 | 0.312 | 0.109 | 2.86× | 126 → 45 |
| flow-first-read | 1 | 0.522 | 0.155 | 3.36× | 2 → 2 |
| flow-read | 3 | 1.404 | 0.313 | 4.49× | 6 → 6 |
| inspector | 3 | 2.139 | 0.182 | 11.72× | 18 → 18 |
| monitor-flow | 3 | 2.350 | 0.440 | 5.34× | 93 → 15 |
| school | 21 | 6.543 | 3.453 | 1.89× | 642 → 422 |
| rebuild-counters | 1 | 0.791 | 0.194 | 4.09× | 890 → 7 |

A separate saga-state benchmark uses 12 planned actions, eight complete controls,
12 restores and 12 clones. Across three runs, committing controls fell from
1.872 s to 0.222 s (8.45×), restoring state from 0.778 s to 0.164 s (4.73×),
and repeated flow reads from 0.478 s to 0.117 s (4.10×). Results were identical.
The adapter is registered but never executed: this isolates framework state work.

The school scenario includes creating one class, registering ten students and
ten enrollments. It still exceeds one second. These timings describe this
workload, not a latency guarantee.

## Remaining costs

A flow projection still scans visible journal metadata; its cost grows with
history. Saga restoration scans stream headers, although it no longer decodes
every historical state. Domain replay must still apply matching events. Module
loading, database round trips, durable commits and application handlers can
dominate other workloads. Large-history pagination and compact saga controls
remain future work.

The existing serial-ID cursor limitation is unchanged: transactions may commit
out of ID order. See [decision models](decision-models.md#serial-ids-and-projection-cursors).

## Projection query templates

This separate comparison isolates the projection query cache from the earlier
storage optimizations above. The baseline already prepared signatures during
projection composition. The new version serializes parameterized ASTs and bind
paths in `.precomp`, caches SQL/bind layouts and reuses native read statements.
Both use Red 0.2.7, Raku/MoarVM 2026.09 and SQLite in memory.

Five alternating samples per version follow one warmup each, with no concurrent
test jobs. The school measurement includes process startup with warmed precomp;
the replay measurement excludes startup, schema creation, event appends and the
first load. Outputs agree between versions.

| Workload | Before median (s) | After median (s) | Elapsed-time change |
| --- | ---: | ---: | ---: |
| 200 ordinary projection loads, ten facts, alternating IDs | 2.119 | 1.109 | −47.6% |
| Full school demo | 17.375 | 18.481 | +6.4% |

The cache improves repeated projection queries in this measurement, but does
not improve the complete school workflow: that workload regressed. These
results do not establish a cause for the end-to-end regression.
[Raw samples and methodology](../examples/school/query-cache-comparison.json)
are retained separately from the earlier storage measurements.

To repeat the ordinary-load workload in each checkout:

```sh
raku -Ilib tools/benchmark-projection-queries.raku --iterations=200 --events=10
```

## PostgreSQL native MRO

A separate comparison keeps the projection query caches enabled on both sides
and changes PostgreSQL MRO storage from delimited text/`LIKE` to native `text[]`
with GIN membership. ORM SELECTs render the compatibility string in PostgreSQL,
avoiding client-side array parsing for ordinary model reads. Other drivers keep
text storage.

These are medians of five alternating samples after one warmup per version,
using the same local PostgreSQL server, Red 0.2.7 and Raku/MoarVM 2026.09.
No test jobs ran concurrently. Counts, replay totals and school stdout agree.

| Workload | Before (s) | After (s) | Elapsed-time change |
| --- | ---: | ---: | ---: |
| 100 selective count queries over 50,000 events | 0.2984 | 0.0167 | −94.4% (17.9×) |
| 10 projection loads, 50 matching events per load | 0.3986 | 0.3637 | −8.8% |
| 100 real journal appends | 0.3854 | 0.3991 | +3.6% |
| Full school demo on Pg | 18.4422 | 18.1018 | −1.8% |

The selective workload matches 0.1% of the original history. Its EXPLAIN shows
GIN bitmap access; this does not imply index use for every workload or small
table. The GIN occupied 2,973,696 bytes (2.84 MiB) after loading the dataset and
performing the appends. The append measurement includes both array handling and
index maintenance; it does not isolate their individual costs. The school change
is small compared with the selective-query improvement.

[Raw samples, EXPLAIN plans, source hashes and methodology](../examples/school/pg-mro-comparison.json)
are retained. Repeat the isolated workload against a local server with:

```sh
PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres \
  raku -Ilib tools/benchmark-mro.raku --database=postgres \
    --rows=50000 --queries=100 --appends=100
```

Each run creates and removes its own schema. See the
[PostgreSQL migration instructions](configuration.md#postgresql-mro-storage)
before upgrading an existing store.


## Combined decision plans

The decision-model now composes its combined predicate, domain exclusions,
binding paths and counter dependency recipes once per ordered projection list.
Subsequent calls bind fresh IDs directly, without rebuilding the OR expression
or rescanning the compiled predicates. Lists containing unsupported runtime
constraints retain the existing inference path. Events, reconstructed state and
counter versions remain execution-local and are read on every call.

The full school demo on SQLite in memory, with flow tracing enabled, changed
from **16.8737 s to 8.0800 s**, a **52.1% elapsed-time reduction (2.09×)**.
These are medians of five alternating samples after one warmup per version on
the same machine, using Red 0.2.7 and Raku/MoarVM 2026.09. No test workloads ran
concurrently. The measurement includes process startup, schema creation and the
complete demo; all outputs agree. This comparison isolates the combined-plan
change, with the earlier query and MRO work present in both versions.

[Raw samples and source hashes](../examples/school/decision-plan-comparison.json).
This is a SQLite result; PostgreSQL correctness was verified separately, but no
PostgreSQL speedup is inferred from these timings.


## Storage hydration and event conversion descriptors

Complete rows of the original storage models use ordered inflators prepared
from column metadata, avoiding a descriptor hash copy and arity decision for
each value. Partial and structural rows keep their previous paths. The current
driver still inflates each value; the plan captures no connection or row data.
Successful event-class resolutions and metadata attributes are cached within
the process. Failed resolutions are not cached, so later-loaded classes remain
available. Each conversion still constructs a fresh object and runs its normal
BUILD/TWEAK hooks before attaching the current StoredEvent metadata.

Measured with Red 0.2.7 and Raku/MoarVM 2026.09, SQLite in memory, five alternating
samples after one warmup per version, without concurrent test workloads:

| Workload | Before (s) | After (s) | Elapsed-time change |
| --- | ---: | ---: | ---: |
| 2,000 complete-row hydrations, excluding SQL | 0.8294 | 0.7330 | −11.6% |
| 2,000 domain-event conversions, excluding SQL | 0.0350 | 0.0322 | −8.0% |
| Full school demo, including startup and tracing | 7.4767 | 7.4363 | −0.54% |

These results isolate this change, with combined decision plans enabled in both
versions. The school difference is small and the after samples vary noticeably;
this measurement does **not** establish a meaningful end-to-end speedup. The
isolated conversion benchmark uses a small event payload and does not predict
constructor costs for arbitrary domain classes.

[Raw samples, source hashes and methodology](../examples/school/hydration-comparison.json).
Reproduce the isolated workload with:

```sh
raku -Ilib tools/benchmark-event-materialization.raku --iterations=2000
```


## Command claims reuse their returned row

A successful command claim now uses `UPDATE ... RETURNING *` to refresh its
in-memory fields, including enums, nullable values and JSON results. It no longer
needs a second SELECT. The initial refresh remains, and an unsuccessful claim
still reads the current record to observe another executor's result or state.
Scheduling, transaction boundaries and retry rules are unchanged.

Measured on SQLite in memory with Red 0.2.7 and Raku/MoarVM 2026.09:

| Workload | Before (s) | After (s) | Elapsed-time change |
| --- | ---: | ---: | ---: |
| Execute 100 persisted commands | 1.7705 | 1.5170 | −14.3% |
| Full school demo, including startup and tracing | 6.8805 | 6.6099 | −3.9% |

The command workload excludes setup and submission, uses handlers without event
appends, and disables flow tracing. Command SELECTs drop from **200 to 100**, with
100 claims and identical results in both versions. The school output also agrees.
These are medians of five alternating samples after one warmup per version,
using equivalent isolated source copies and warmed precompilation caches. No test
workloads ran concurrently. PostgreSQL concurrency and retry correctness were
verified separately; these performance figures are SQLite results.

[Raw samples, source hashes and methodology](../examples/school/command-claim-comparison.json).
Reproduce the isolated workload with:

```sh
raku -Ilib tools/benchmark-command-claims.raku --iterations=100
```


## Combined aggregate snapshot and replay reads

Standard aggregate loads on SQLite and PostgreSQL now use one cached CTE to
select the latest snapshot and its replay tail. The initial snapshot is returned
first; replay records follow by global ID after `COALESCE(replay_cursor, id)`.
Snapshot records encountered during replay retain their metadata/accounting
behavior instead of being passed to domain APPLY methods. PostgreSQL returns
the logical string MRO representation. No schema migration is required.

The query uses the existing driver SQL cache and physical prepared-statement
lifecycle. SQLite EXPLAIN tests verify an indexed replay lookup by stream,
without scanning the complete event history. Every load still reads current
rows and constructs fresh on-demand state; snapshots, payloads, IDs and versions
are not cached by this optimization.

Explicit restore/replay calls and custom or wrapped reconstruction methods
keep their original behavior. Projections, sagas and other drivers keep their
existing reconstruction paths. Cold retained loads avoid an immediate redundant
replay of the instance just reconstructed; existing retained instances preserve
their transactional refresh and checkpoint checks.

Measured on SQLite in memory with Red 0.2.7 and Raku/MoarVM 2026.09:

| Workload | Before (s) | After (s) | Elapsed-time change |
| --- | ---: | ---: | ---: |
| 200 on-demand aggregate loads across 10 streams | 1.5212 | 0.2894 | −81.0% (5.26×) |
| Full school demo, including startup and tracing | 6.4848 | 5.7741 | −11.0% |

The isolated workload has one post-snapshot event per stream and excludes setup;
instances are reconstructed for every load, while query caches are warm. These
are medians of five alternating samples after one warmup per version. Both
versions ran from equivalent isolated source copies with identical configuration
and warmed precompilation caches, without concurrent test workloads. Checksums
and school stdout agree. PostgreSQL correctness and concurrency were tested
separately; the speedups above are SQLite measurements.

[Raw samples, source hashes and methodology](../examples/school/aggregate-load-comparison.json).
Reproduce the isolated workload with:

```sh
raku -Ilib tools/benchmark-aggregate-loads.raku --iterations=200 --streams=10
```

## Command INSERT SQL cache experiment (not retained)

A prototype cached the `StoredCommand` INSERT layout by included-column mask,
with a 128-entry LRU per driver context shared by transaction clones. SQL and
column descriptors were reused; values were deflated for each execution. Red's
object/AST construction, create hooks, notifications, hydration and transaction
handling remained in place. SQLite write statements were not cached; PostgreSQL
continued using its existing prepared-statement cache.

The initial implementation and a revision reducing metadata checks both failed
the performance acceptance criterion. Revised medians:

| Workload | Without cache (s) | With cache (s) | Elapsed-time change |
| --- | ---: | ---: | ---: |
| 500 command submissions, without execution | 1.4511 | 1.4461 | −0.35% |
| Full school demo, including startup and tracing | 5.8655 | 5.8848 | +0.33% |

These small differences do not establish a useful speedup. The production changes
were removed; the earlier aggregate/read optimizations remain in place. Each
comparison used five alternating samples after one warmup per version, isolated
source copies, Red 0.2.7 and SQLite in memory, without concurrent test workloads.
Command counts, generated-ID checksums and school output matched. The initial
prototype passed command/savepoint/storage/decision/aggregate tests on SQLite,
command conflict/decision/storage tests on PostgreSQL, and the cache regression
test on both databases and RakuAST. The revised prototype passed all 59 SQLite
cache assertions, including concurrent binding isolation.

[Raw samples, source hashes and the rejected prototype patch](../examples/school/command-insert-comparison.json).
Reproduce the command submission workload with:

```sh
raku -Ilib tools/benchmark-command-inserts.raku --iterations=500
```

## Decision-model snapshot reads

Measured on 2026-10-21 with Rakudo 2026.09, Red 0.2.7 and in-memory SQLite.
Five alternating samples follow one warmup per version/workload, in isolated
source copies with warmed precompilation caches and no concurrent tests. The
previous Decision implementation was reconstructed by reversing only the snapshot
feature. The artifact includes that exact source, current library hashes and raw
samples: [decision-snapshot-comparison.json](../examples/school/decision-snapshot-comparison.json).

| Workload | Previous median | Snapshot-aware median | Change |
| --- | ---: | ---: | ---: |
| 50 empty decisions | 0.08176 s | 0.09574 s | +17.1% (+0.28 ms/decision) |
| 50 decisions, 100 historical facts + 2 new facts per identity, no snapshots | 6.05168 s | 6.26174 s | +3.5% |
| Same history with existing snapshots covering the first 100 facts | 6.03417 s | 0.30099 s | −95.0% (20.05× faster) |
| Complete school demo, including startup/schema/tracing | 5.50208 s | 5.51994 s | +0.3%, within observed sample variation |

The isolated workload uses four identities and two projection types per decision;
setup and checkpoint creation are outside the timer. Both versions return the
same checksum. Existing checkpoints reduce APPLY executions from 10,200 to 200.
Every school run returns the same output and 40 active enrollments. These are
SQLite measurements; PostgreSQL correctness/concurrency tests do not establish a
PostgreSQL performance gain.

Reproduce a snapshot-aware sample with:

```sh
raku -Ilib tools/benchmark-decision-snapshots.raku
raku -Ilib tools/benchmark-decision-snapshots.raku --/checkpoint
raku -Ilib tools/benchmark-decision-snapshots.raku --history=0 --tail=0 --/checkpoint
```

The implementation measured above reads checkpoints and replay tails in separate
queries. When no useful checkpoint exists, the first query adds work without
saving replay. The subsequent implementation combines these reads into a single
SELECT with a checkpoint CTE and per-projection cursor predicates, returning
checkpoints followed by the required union of fact tails. Counter guards continue
covering the complete domain predicates, and repeated positions retain isolated
nested state.

## One SELECT for decision checkpoints and replay tails

The unified read uses positional checkpoint CTEs and cursor subqueries inside the
same statement. Snapshot and event payloads have the same column layout; Pg
normalizes native MRO arrays and JSONB to the ORM's SELECT representations. The
latest checkpoint lookup uses the existing `(class, stream, id)` index with a
descending `LIMIT 1`. Checkpoint metadata and domain facts therefore come from
one statement snapshot. Counter reads and optimistic append validation retain
their existing flow.

The follow-up comparison uses the exact preceding two-query implementation,
with the same runtime, SQLite workload, five alternating samples, isolated source
copies, warmup and setup exclusions described above. No tests ran concurrently.
The source versions and raw samples are recorded in
[decision-union-comparison.json](../examples/school/decision-union-comparison.json).

| Workload | Two SELECTs | Unified SELECT | Change |
| --- | ---: | ---: | ---: |
| 50 empty decisions | 0.09580 s | 0.10884 s | +13.6% (+0.26 ms/decision) |
| 50 decisions with 100 checkpointed facts and 2 tail facts per identity | 0.30294 s | 0.28008 s | −7.5% |
| Complete school demo | 5.54046 s | 5.51014 s | −0.5%, effectively unchanged |

The number of APPLY executions and final state agree between versions. Fewer
statements improve the checkpointed workload, but CTE processing costs more for
empty decisions in this in-memory SQLite test. Reducing statement count alone
does not establish a universal latency improvement, or a PostgreSQL timing gain.
Correctness checks cover the 69-file main suite, 13 PostgreSQL integration files,
and RakuAST replay tests, including nested/repeated identities, isolated mutable
snapshot containers and concurrent optimistic decisions.

## Reusing SQLite counter statements

Counter reads and guarded writes now lease native prepared statements from the
same bounded pool used by projection reads. The pool belongs to the physical
SQLite connection and holds at most 128 idle statements across both uses. Each
execution binds current keys, increments and expected versions, drains its rows,
and finishes the cursor before returning the handle. Failed executions discard
the handle. Initialization and maintenance keep their previous execution path;
PostgreSQL retains its driver's existing preparation cache.

The optimization passed its acceptance gate: both isolated counter medians
improved by at least 5%, all five paired counter samples favored the change,
and the school median stayed within the 2% regression limit. Measurements use
Rakudo 2026.09, Red 0.2.7 and in-memory SQLite, isolated before/after source copies,
one warmup and five alternating samples, with no concurrent tests.

| Workload | Before | Cached statements | Change |
| --- | ---: | ---: | ---: |
| 1,000 reads of eight counters | 0.37183 s | 0.31027 s | −16.6% |
| 1,000 guarded writes of eight counters | 1.08853 s | 0.89857 s | −17.5% |
| 50 empty decisions | 0.11155 s | 0.09051 s | −18.9% |
| Complete school demo | 5.48988 s | 5.48608 s | −0.07%, effectively unchanged |

Counter timing excludes setup and binds current expected versions on each write.
School includes startup, schema creation and tracing. Final versions, checksums
and school output agree between versions. These results do not establish a
PostgreSQL timing improvement.

Run `raku -Ilib tools/benchmark-counter-statements.raku --kind=read` or
`--kind=write` to reproduce the individual workloads. Raw samples, source hashes,
the implementation diff and acceptance criteria are in
[counter-statement-comparison.json](../examples/school/counter-statement-comparison.json).
Validation passed all 70 main test files, 13 PostgreSQL integration files and
the selected RakuAST template/checkpoint/counter tests. The new counter tests
cover fresh binds, optimistic conflicts, rollback, preparation/execution errors,
eviction, teardown and separate physical connections.


## Prepared stream existence reads

`School.ensure` now uses the internal `storage-stream-exists` helper instead of
building a Red filter and structural projection for every command. The helper
selects one ID with the same exact class/stream predicate and `LIMIT 1`, binding
both strings. SQLite uses `?` placeholders and the existing bounded native
statement pool; Pg uses `$1`/`$2` and its driver's statement cache.

Every call still reads the database in its current transaction. No positive or
negative existence results are cached. Initial snapshots, command execution and
the unique `(stream, version)` guard retain their previous behavior; the helper
does not make check-then-create atomic.

Measured locally on 2026-10-21 with Red 0.2.7, Rakudo 2026.09, SQLite in memory,
flow tracing enabled and warmed precomp. One warmup per variant, followed by
five alternating full-process pairs without concurrent test jobs:

| Complete school demo | Before | After | Change |
| --- | ---: | ---: | ---: |
| Median of five processes | 5.97286 s | 4.54215 s | -24.0% |

All five pairs improved. Every run produced the same stdout, including both
business rejections and 40 active enrollments. Both variants used isolated
copies of School/main and the same final Storage implementation; the only
behavioral difference was the existence expression. These are SQLite timings;
no Pg speedup is claimed.

The new stream-existence tests passed on SQLite and Pg, covering current binds,
quoted values, class/stream isolation, visibility after append, commit/rollback,
and SQLite preparation reuse and separate databases. School behavior/CLI,
aggregate loads, entity cache and counter-statement tests passed on SQLite;
concurrent school decisions passed on Pg. The new test also passed with RakuAST.

[Raw samples, source hashes and validation](../examples/school/stream-existence-comparison.json).


## Reusing committed decision reconstructions

Decision-model can now reuse detached committed projection state from the same
bounded pool as cached entities. Bases include a cursor, checkpoint version and
the dependency counters observed before reconstruction. Every decision still
reads current counters and latest checkpoints. The combined SQL uses the cached
cursor only while the checkpoint version matches, then fetches the union of
required tails. Changed guard counts must be completely covered by the fetched
event tags; a gap discards bases and repeats full reconstruction. This catches
lower-ID late commits and conservatively handles guard predicates wider than
selected facts. Append/CAS protection is unchanged.

Bases are captured before calling the user block and published only after commit.
Savepoint and transaction rollback discard publication. Repeated positions,
nested decisions and public cached entity references do not share mutable state
with these bases. Unsupported mutable domain objects, cycles, runtime query
fallbacks, OnDemand and Retained views reconstruct normally.

Admission is selective: at least four applied facts since the checkpoint are
required. Unconditional admission was rejected: although it reduced repeated
historical APPLY by 96%, it regressed the complete school demo by 6.2% and empty
decisions by 89%. Tiny one-off views added copy overhead and displaced ordinary
entities from the shared pool. The selective policy keeps the existing capacities
and eviction/snapshot policy; it does not change ordinary entity admission.

Measured with Red 0.2.7, Rakudo 2026.09 and SQLite in memory, using exact isolated
before/after library trees, one warmup per workload/variant and five alternating
pairs without concurrent tests:

| Workload | Before median | After median | Change |
| --- | ---: | ---: | ---: |
| Complete school demo, including startup/schema/tracing | 5.06665 s | 4.87607 s | -3.8% |
| 50 warmed decisions, two views, 100 historical + 2 tail facts per identity | 6.35341 s | 0.24786 s | -96.1% |
| 50 empty decisions | 0.11171 s | 0.13821 s | +23.7% |

School and history improved in all five pairs. The history benchmark executed
10,200 historical APPLY calls before and zero during timed reads after warmup.
The empty workload still pays about **0.53 ms extra per decision**;
this optimization is useful for repeated historical reconstruction, with a modest
school improvement rather than a universal speedup. Microbench times exclude
seed/warmup; school timings include the complete process. Results/checksums and
school stdout matched, including both rejections and 40 active enrollments.
No PostgreSQL speedup is claimed.

Validation covers cold/hot reads, incremental replay, checkpoint replacement,
mutable-state isolation, repeated and nested decisions, rollback/savepoints,
release/capacity eviction, conservative guard fallback and lower-ID gap recovery.
A PostgreSQL worker test also commits a matching fact after a warm read and
confirms that the subsequent append still fails CAS and rolls back its own fact.

[Raw samples, before/after source hashes and rejected prototype](../examples/school/decision-state-comparison.json).

The 72-file main suite completed successfully, with affected cases repeated after
the selective-admission adjustment. Final focused checks passed for school,
decisions, entity cache and snapshots; five Pg files and three RakuAST files
also passed. `git diff --check` passed.
