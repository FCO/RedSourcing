# Pio: a small event-sourced microblog

Run from the repository root:

```sh
raku -Ilib examples/microblog/main.raku
```

Open **http://127.0.0.1:3090/**. Choose Ana, Bruno or Clara, publish a message,
follow someone, and open their profile. Other tabs update through SSE. User
selection is for demonstration: there are no passwords or authorization checks.

The default store is `examples/microblog/microblog.db`, resolved through
`red-sourcing-defaults` and the local configuration. Seed runs once per user;
restarting preserves tweets and follow/unfollow choices. Ctrl+C stops HTTP and
the controller without removing the database.

```sh
raku -Ilib examples/microblog/main.raku --port=3091 --database=/tmp/pio.db
raku -Ilib examples/microblog/main.raku --application=another-community
# Empty store, for exercising registration:
raku -Ilib examples/microblog/main.raku --/seed --database=/tmp/pio-empty.db
```

## How the entities fit together

| Entity | Identity | Responsibility |
| --- | --- | --- |
| `User` aggregate | application + user | Publish, follow, unfollow; keep business rules |
| `Accounts` aggregate | application | Reserve user IDs and create User aggregates atomically |
| `TweetIndex` projection | application | Transactional APPLY materializes tweets in SQL; declares the managed HTTP service |
| `UserTweets` projection | application + user | Query an author's tweets from that table |
| `UserTimeline` projection | application + user | Reconstruct follows; query the same table for a feed |
| `Directory` projection | application | Reconstruct public user names |

`TweetIndex` is registered before seed or application commands run. Its APPLY
uses Red `.^find` / `.^create` inside the event-emission transaction, including
its checkpoint. Existing rows are validated on replay; the unique application/tweet
key remains the final database guard. A conflicting payload raises an error. An index failure rolls back the source publication.

Tweets live in the indexed `microblog_tweet` table, not in arrays or snapshots.
Both reader projections build their page queries with Red (`grep`, `sort` and
`head`). Author filters, cursor ordering and LIMIT execute in SQL. In-memory
fallback is disabled for these queries so paging cannot load the whole table.
The default page is 50 tweets, with a maximum of 100; a page includes a `next`
cursor when more results exist. Timeline includes self and current follows,
including tweets published before following. Unfollow immediately changes future
queries. Ordering uses the publication's journal ID, not the wall clock.

Follows and user names still occupy entity state; this demonstration does not
claim constant memory as the number of users or follows grows. The entity cache
limits resident instances. Index reconstruction reads journal IDs in batches of
500 rather than loading the journal into memory.

`TweetIndex.serve` gives the block of endpoints from `Microblog::HTTP` to
`$runtime.http`. Queries use `is query` methods/accessors on the entity proxies;
writes call User or Accounts commands on their proxies. Request processing binds
the service context automatically; the SSE timer uses `$runtime.bind`. The executor owns the connection and validates the service generation.
Projection services keep lifecycle controls in an infrastructure aggregate, not
in their projection stream. Sockets and promises are never snapshotted.

SSE sends the initial timeline and only sends another timeline when its data
changes. It checks once per second, sends a heartbeat every 15 seconds, and
renews service activity every 30 seconds while connected. Disconnect cancels the
polling Supply. The browser reuses tweet elements, preserving the list when no
data changed. The service idle timeout is one hour.

Queries are also available outside services, for example:

```raku
Directory.^with-ids(:application-id<microblog>).list;
UserTweets.^with-ids(:application-id<microblog>, :user-id<ana>).page(:limit(10));
```

## API

```sh
curl http://127.0.0.1:3090/api/users
curl -H 'Content-Type: application/json' \
  -d '{"id":"dani","name":"Dani"}' http://127.0.0.1:3090/api/users
curl -H 'Content-Type: application/json' \
  -d '{"text":"Hello, Pio!"}' http://127.0.0.1:3090/api/users/ana/tweets
curl -X POST http://127.0.0.1:3090/api/users/ana/following/clara
curl -X DELETE http://127.0.0.1:3090/api/users/ana/following/bruno
curl 'http://127.0.0.1:3090/api/users/ana/tweets?limit=10'
curl 'http://127.0.0.1:3090/api/users/ana/timeline?limit=10'
# Use the previous response's next value:
curl 'http://127.0.0.1:3090/api/users/ana/timeline?before=123&limit=10'
curl -N http://127.0.0.1:3090/api/users/ana/events
```

Registration/publication returns 201. Invalid business input returns 400; missing
users return 404. Names have 1–80 characters and tweets 1–280 characters after
trimming. User IDs have 1–40 ASCII letters, digits, underscores or hyphens.
Follow/unfollow are idempotent. UI content is inserted as text, including tweets
containing HTML.

## Rebuild and PostgreSQL

Stop writers before rebuilding. This uses Red to delete the selected application's rows and read the journal
in batches, rebuilding from publication events in one transaction, without changing the journal or
other applications' rows. It does not start HTTP:

```sh
raku -Ilib examples/microblog/main.raku --rebuild
```

Use a separate configuration file for Pg, with `driver`, `database` and
`connection` settings as in the other examples:

```sh
raku -Ilib examples/microblog/main.raku --file=/path/to/pg.rakuconf
```

For existing event stores predating managed services, apply the
[service migration](../../docs/services.md#existing-stores-and-migration) first.
The example creates its own read table and indexes. Pg is tested with separate
processes taking ownership; this example supplies one logical HTTP listener,
not distributed routing or authentication.

## Verification

The focused tests are `t/79-projection-services.rakutest`,
`t/80-microblog.rakutest`, `t/81-microblog-http.rakutest` and
`t/82-projection-service-ownership-pg.rakutest`. The first two also run against Pg
when `RED_SOURCING_TEST_PG_DATABASE` and the normal libpq environment are set;
the Pg ownership test otherwise skips. Each Pg test uses an isolated schema.

The proxy/query follow-up is recorded separately in
[query-validation.json](query-validation.json), including `t/83-query-proxies.rakutest`
and `t/84-proxy-service-context.rakutest`. It is a focused regression run, not a
rerun of the entire suite.

The earlier recorded run used Red 0.2.7 and Rakudo 2026.09. Focused tests passed in
SQLite, Pg and RakuAST, including HTTP/SSE and multiprocess ownership. The full
suite passed 80 of 82 files after an isolated rerun of commerce
(the parallel run exceeded its 360-second limit). The two installation failures
are compiler warnings reproduced on the unchanged pre-service baseline. See
[validation.json](validation.json) for the results and source hashes.

A reproducible [performance comparison of Red and manual SQL](PERFORMANCE.md)
records publication and paged-read costs in SQLite and Pg, plus the cost of
query dispatch through entity proxies.
