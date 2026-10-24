# Microblog: Red versus manual SQL

Measured with Red 0.2.7 and Rakudo 2026.09. The current Red implementation is slower in this local workload, particularly when reading a page of an author's tweets.

Each value below is milliseconds per operation: the median of five batch averages. Both variants use the same current framework, schema and business commands. The manual SQL baseline is reconstructed from the earlier `tweet-page` and `TweetIndex.APPLY` implementations in a temporary module copy; the application code is unchanged.

| Operation | SQLite SQL | SQLite Red | Ratio | Pg SQL | Pg Red | Ratio |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Publish a tweet | 74.44 | 105.85 | 1.42× | 61.36 | 81.87 | 1.33× |
| Author page | 6.53 | 127.42 | 19.51× | 8.39 | 139.76 | 16.65× |
| Timeline page | 51.96 | 171.58 | 3.30× | 48.99 | 181.10 | 3.70× |
| Timeline cursor page | 52.05 | 182.07 | 3.50× | 48.43 | 185.37 | 3.83× |

## Method

- Separate long-lived processes and disposable stores; SQLite uses a file, Pg uses isolated schemas on a local server.
- Seed three users/tweets, then 300 historical publications distributed across the three authors. The timeline follows both other authors.
- Warm up with five publications and 20 reads of each kind before timing.
- Five alternating SQL/Red pairs. Each batch publishes 20 tweets, then reads 20 author pages, 20 timeline pages and 20 cursor pages. Pages contain 50 tweets.
- Each round grows both stores equally. The normalized final cursor-page contents must match across variants.
- Fixture creation, process startup, compilation, warmup and SQL profiling are excluded from timings.
- Measurements include aggregate commands and projection reconstruction. HTTP, Cro, browser rendering and the service-context queue are excluded.

## What the SQL counters show

Each author/timeline page executes one SELECT against the tweet table in both implementations. The counters also observe the framework queries used to reconstruct the projection. Thus the reading regression occurs despite the same number of tweet-table queries. Query construction/execution in Red and model materialization are candidates for profiling; this run does not isolate those costs or database query-plan costs.

On SQLite, publication uses three tweet-table SELECTs with Red versus one with manual SQL, plus one INSERT in either case. The observed total statement counts are 15 versus 13 per publication. On Pg, both use one tweet-table SELECT and one INSERT; the observed total is 14 in either case. Transaction commands issued outside the instrumented prepare/execute path are not counted.

The separate statement profile runs three operations of each kind after timing. Its cursor counts include an extra untimed lookup for the cursor.

These are local measurements, not production latency or concurrency claims. The process and machine may have other activity; alternating order and medians reduce ordering noise. Raw samples, configuration, counters and source hashes are in [performance.json](performance.json).

## Reproduce

From the repository root, with the project dependencies available:

```sh
python3 tools/benchmark-microblog.py --driver=SQLite --publish=20 --reads=20 \
  --output=/tmp/microblog-sqlite.json

# Existing disposable Pg database; uses isolated temporary schemas.
PGHOST=/path/to/socket PGPORT=5432 PGUSER=postgres \
python3 tools/benchmark-microblog.py --driver=Pg --database=postgres \
  --publish=20 --reads=20 --output=/tmp/microblog-pg.json
```

Use `--raku=/path/to/raku-or-wrapper` to select the compiler and dependency environment. The recorded run used a wrapper pinning Red 0.2.7 and Rakudo 2026.09. Neither benchmark accesses the running example's database or opens an HTTP listener.

## Entity proxy query API

The new API is compared separately with the existing JSON-based service helper.
All three modes use the same live service executor, fixed store, projection and
query. `typed-direct` calls the executor's typed query operation directly;
`proxy` reaches that same operation through the entity proxy. Both preserve Raku
types and copy detached results. `legacy-json` calls `ServiceContext.read` and
keeps its existing JSON conversion contract.

Milliseconds per operation, median of five batch averages:

| Driver / query | Legacy JSON helper | Typed executor directly | Entity proxy |
| --- | ---: | ---: | ---: |
| SQLite / Directory.list | 104.10 | 102.33 | 102.71 |
| SQLite / UserTweets.page | 243.95 | 251.70 | 259.11 |
| Pg / Directory.list | 136.16 | 133.99 | 123.23 |
| Pg / UserTweets.page | 286.04 | 306.81 | 294.01 |

This change simplifies calls and preserves types; it does not optimize the Red
page query. The differences fluctuate across modes and are too small and noisy
to claim a proxy speedup. Every mode executes the same number of SQL statements:
four per directory read and five per author-page read in SQLite; three and
four respectively in Pg. Each author page includes one tweet-table SELECT. The proxy adds no SQL statement.

The fixture has three users and 153 tweets; the author page contains 50 tweets.
Each mode/query warms up ten calls, then runs five rounds of twenty calls with
rotating mode order. Timings include mailbox waiting, generation validation,
projection reconstruction and return-value copying; compilation, fixture setup,
HTTP and the later SQL counters are excluded. Other machine activity and the
controller can affect these local measurements. Samples and counters are in
[proxy-performance.json](proxy-performance.json).

```sh
raku -Ilib tools/benchmark-proxy-queries.raku --driver=SQLite \
  --output=/tmp/proxy-sqlite.json
PGHOST=/path/to/socket PGPORT=5432 PGUSER=postgres \
  raku -Ilib tools/benchmark-proxy-queries.raku --driver=Pg \
  --database=postgres --output=/tmp/proxy-pg.json
```

## Red/SQL comparison repeated after the proxy change

The earlier five-pair benchmark was repeated with the same configuration
(300 historical publications, twenty publications and twenty reads per kind in
each batch). These calls exclude the service mailbox and use loaded projection
methods. This checks the domain paths separately from proxy dispatch above.
Normalized cursor-page contents matched between SQL and Red on every pair.

| Operation | SQLite SQL | SQLite Red | Pg SQL | Pg Red |
| --- | ---: | ---: | ---: | ---: |
| Publish a tweet | 82.99 | 106.85 | 93.18 | 100.96 |
| Author page | 8.05 | 156.88 | 9.09 | 175.96 |
| Timeline page | 52.92 | 205.84 | 54.34 | 227.58 |
| Timeline cursor page | 51.08 | 204.99 | 59.36 | 223.75 |

Values are milliseconds per operation. The Red page-query cost remains visible.
The earlier and later sessions vary substantially even on the unchanged SQL
baseline, so this is not evidence of a precise before/after regression caused by
the proxy feature. The direct-versus-proxy experiment above is the relevant
comparison for dispatch overhead. Raw samples, counters and source hashes for
the repeated domain benchmark are in
[performance-followup.json](performance-followup.json).
