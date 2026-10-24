# Managed room service

From the repository root:

```sh
raku -Ilib examples/services/room.raku
```

Expected output:

```text
Messages: Hello, Portable state
Service: stopped
```

The aggregate implements `serve`; a built-in saga controls its lifecycle through
an internal service adapter. A Supplier is the simulated transport. Its callback
uses `$runtime.bind(...)` to capture the service context, then calls commands
on `$runtime.proxy` to record messages with the current ownership fence. Activity
is renewed explicitly. Cleanup closes the subscription. Promises, subscriptions and callbacks stay in memory.

This example uses a temporary SQLite file and one executor. The runtime's background
loop wakes for context requests instead of waiting for the periodic timer pass.
For a persistent application, select a file/Pg store, apply the migration to old
stores, and start the optional runtime from the application's bootstrap.
See [managed services](../../docs/services.md) for restart, ownership and limits.

## Real HTTP service

```sh
raku -Ilib examples/services/http.raku --port=3080
```

The aggregate's `is service` method passes a block of Cro endpoints to `$runtime.http`,
which builds `route` internally, starts Cro, acknowledges readiness and closes
the server on stop. The process waits
until Ctrl+C/SIGTERM, then stops the service and runtime. Each successful request
renews the one-hour idle timeout. Startup uses `red-sourcing-defaults` with a
temporary SQLite file; data is removed when the example exits.

```sh
curl -H 'Content-Type: application/json' \
  -d '{"text":"Hello"}' http://127.0.0.1:3080/messages
curl http://127.0.0.1:3080/messages
```

`POST /messages` returns `201` with the message count. `GET /messages` returns
the room and its persisted messages. Writes use the fenced aggregate command;
reads use the `messages is query` accessor on the same proxy. The HTTP helper
binds request processing to the service context automatically. Cleanup closes
the HTTP listener.
