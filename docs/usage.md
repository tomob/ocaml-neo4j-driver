# Usage

This guide walks through the driver's main API. If you have not connected yet,
start with the [quickstart](quickstart.md). The [examples](../examples/)
directory contains runnable programs, and the full signatures live in the
generated API documentation (`dune build @doc`, then open
`_build/default/_doc/_html/index.html`).

## Packages and what to open

`open Neodriver` exposes the whole driver: `Driver`, `Conn`, `Session`, `Tx`,
`Neo4jResult`, `Summary`, and the core types `Errors`, `Config`, `Addressing`,
`Values`, `Temporal`, `Hydration` and `Packstream`. Programs also need the
`eio_main` library for the `Eio_main.run` entry point.

## Connecting

```ocaml
let driver =
  Driver.connect ~uri:"bolt://localhost:7687"
    ~auth:(Conn.basic_auth ~credentials:"password" ())
    net clock sw
let session = Driver.session driver
```

- `Driver.connect` parses the URI and returns a **pool-backed** `Driver.t`:
  the server is contacted only on the first query. `Driver.session` returns a
  session that borrows a connection from the pool on first use and returns it
  (with a RESET) on close.
- `Conn.basic_auth` builds the authentication token (default principal
  `neo4j`; only the `basic` scheme is supported).
- `?user_agent`, `?connection_timeout` (seconds, default 30.0) and `?pool_config`
  (a `Config.pool_config`: pool size, connection lifetime, liveness check and
  the connection acquisition timeout) tune the driver; `Driver.session` takes
  the session's `?config` (a `Session.config`).
- The `sw` switch must outlive the sessions (it hosts the pool's connection
  attempts).
- `?resolver` replaces address lookup (useful for custom DNS resolution).

### Schemes and TLS

| Scheme         | TLS                                                     |
|----------------|---------------------------------------------------------|
| `bolt://`      | none (plain)                                            |
| `bolt+s://`    | TLS, certificate validated against the OS trust store   |
| `bolt+ssc://`  | TLS, any certificate accepted (self-signed allowed)     |

`neo4j://` (routing) is not implemented: a `neo4j://` URI fails on first use
with a `Service_unavailable` error.

## Sessions

`Session.run` sends an auto-commit query and returns a lazily streamed
`Neo4jResult.t`:

```ocaml
match Session.run session ~query:"RETURN 1 AS n" ~parameters:[] with
| Ok result -> (
    match Neo4jResult.values result with
    | Ok [ [ Values.Int n ] ] -> Printf.printf "n = %Ld\n" n
    | _ -> ())
| Error error -> failwith (Errors.to_string error)
```

- Parameters are a `(string * Values.t) list`.
- `Neo4jResult.values` drains the result into `Values.t list list` (one list
  per record). `Neo4jResult.consume` drains and returns the `Summary`;
  `next`, `peek` and `fetch` iterate without consuming everything.
- The session's bookmarks are updated automatically once an auto-commit result
  is consumed; read them with `Session.last_bookmarks` and seed them via
  `Session.config`'s `bookmarks`.
- `Session.config` (base `Session.default_config`) also selects the `database`
  and the transaction retry settings.

## Transactions

### Explicit

```ocaml
let conn =
  match Session.conn session with Ok conn -> conn | Error error -> failwith (Errors.to_string error)
in
let hydration = Conn.hydration conn in
match Session.begin_transaction session with
| Ok tx -> (
    match
      Tx.run tx ~hydration ~query:"CREATE (:Person {name: $name})"
        ~parameters:[ ("name", Values.String "Alice") ]
    with
    | Ok result -> (
        match Neo4jResult.consume result with
        | Ok _ -> (
            match Tx.commit tx with
            | Ok _ -> ()
            | Error error ->
                ignore (Tx.rollback tx);
                failwith (Errors.to_string error))
        | Error error ->
            ignore (Tx.rollback tx);
            failwith (Errors.to_string error))
    | Error error ->
        ignore (Tx.rollback tx);
        failwith (Errors.to_string error))
| Error error -> failwith (Errors.to_string error)
```

- `Tx.run` needs a hydration scope, obtained with
  `Conn.hydration (Session.conn session)`.
- `Tx.commit` applies the writes and returns the bookmark (`string option`);
  `Tx.rollback` discards them. A session can hold only one open transaction.

### Managed (with retry)

```ocaml
let conn =
  match Session.conn session with Ok conn -> conn | Error error -> failwith (Errors.to_string error)
in
let hydration = Conn.hydration conn in
let created = ref 0 in
let work tx =
  match
    Tx.run tx ~hydration ~query:"CREATE (:Person {name: $name})"
      ~parameters:[ ("name", Values.String "Bob") ]
  with
  | Ok result -> (
      match Neo4jResult.consume result with
      | Ok summary ->
          created := summary.counters.nodes_created;
          Ok ()
      | Error error -> Error (Session.Driver error))
  | Error error -> Error (Session.Driver error)
in
match Session.execute session ~mode:Config.Write work with
| Ok () -> Printf.printf "created %d node(s)\n" !created
| Error (Session.Driver error) -> failwith (Errors.to_string error)
| Error Session.Client -> failwith "the application aborted the transaction"
```

- `Session.execute` runs `work` inside a transaction and commits it on `Ok`.
  Failures that `Errors.is_retryable` treats as retryable are retried (with a
  jittered backoff) until `max_transaction_retry_time` runs out; `Error
  (Session.Driver e)` retries when retryable, `Error Session.Client` never
  does.
- The work callback returns `(unit, Session.failure) result`, so return query
  data through a ref, as above.

## Authentication

Only `basic`. For Bolt >= 5.1 the token is sent via a separate LOGON message
after HELLO; older versions inline it in HELLO. `Conn.re_auth conn auth`
re-authenticates when the token changes, and `Conn.logon`/`Conn.logoff` manage
the authenticated state directly.

## Value types

`Values.t` is a plain variant, so parameters are built explicitly — there is
no implicit conversion from OCaml data. The common cases:

| OCaml value                     | `Values.t`                                        |
|---------------------------------|---------------------------------------------------|
| `true` / `false`                | `Values.Bool b`                                   |
| `42L`                           | `Values.Int n` (an `int64`)                       |
| `3.14`                          | `Values.Float f`                                  |
| `"hello"`                       | `Values.String s`                                 |
| a list of values                | `Values.List [ Values.Int 1L; Values.Int 2L ]`    |
| a record                        | `Values.Map [ ("key", value); ... ]`              |
| `None` (an absent value)        | `Values.Null`                                     |

Integers are `int64` — use `42L`, not `42`. `Null` is also how you represent
`None` inside a `List` or `Map`.

Graph, spatial, temporal and vector values are built through their types:

```ocaml
let born = Temporal.DateTime.of_ymd_hms (1990, 5, 17) (12, 0, 0) 0 |> Option.get in
let home = Values.Point { srid = 4326; x = 21.0122; y = 52.2297; z = None } in
let params =
  [
    ("name", Values.String "Alice");
    ("born", Values.DateTime born);
    ("home", home);
    ("tags", Values.List [ Values.String "admin"; Values.String "staff" ]);
    ("meta", Values.Map [ ("active", Values.Bool true) ]);
  ]
```

A small helper makes converting a custom record convenient:

```ocaml
let person_to_values { name; age; tags } =
  Values.Map
    [
      ("name", Values.String name);
      ("age", Values.Int age);
      ("tags", Values.List (List.map (fun t -> Values.String t) tags));
    ]
```

Reading values back is pattern matching:

```ocaml
match value with
| Values.Int n -> Printf.printf "int %Ld\n" n
| Values.String s -> Printf.printf "string %s\n" s
| Values.List items -> List.iter print_value items
| Values.Map fields -> List.iter (fun (k, v) -> ...) fields
| Values.Node node -> Printf.printf "%s\n" (String.concat "," node.labels)
| Values.Broken b -> (* the driver could not decode it *)
| _ -> ()
```

`Values.to_string` renders any value for logging. The graph types (`Node`,
`Relationship`, `Path`) are typically read from results, not sent as
parameters.

`Temporal` provides `Date`, `Time`, `DateTime` and `Duration`. Named time
zones resolve through the embedded IANA database (1970-2040) with an LMT
fallback before 1970; `DateTime.of_ymd_hms`, `to_ymd_hms` and
`offset_seconds` handle the wall-clock/epoch conversions. `Hydration`
converts between PackStream and `Values.t`; you rarely touch it directly.

## Errors

`Session.run`, `Tx.run` and friends return `(_, Errors.t) result`. `Errors.t`
covers server errors (`Neo4j of { code; message; classification }`),
`Service_unavailable`, `Transaction_error`, `Configuration_error` and more.
`Errors.to_string` renders a message; `Errors.is_retryable` tells you whether
a failure is worth retrying.

## Configuration

### `Driver.connect` options

- `uri` (required) — e.g. `bolt://localhost:7687`, `bolt+s://host:7687`,
  `bolt+ssc://host:7687` (`neo4j://` not supported yet).
- `auth` (required) — from `Conn.basic_auth ?principal ?credentials ()`
  (principal defaults to `neo4j`, credentials to the empty string).
- `?user_agent` — the HELLO user agent (default `Conn.default_user_agent`).
- `?connection_timeout` (seconds) — bounds each connection attempt and its
  subsequent reads/writes (default 30.0; `infinity` disables the deadline).
- `?pool_config` — a `Config.pool_config` (pool size, connection lifetime,
  liveness check, connection acquisition timeout; see below).
- `?resolver` — `Addressing.t -> (Addressing.t list, Errors.t) result`;
  replaces the address lookup, each returned address being tried in turn.

### Session settings (`Session.config`)

`Driver.session` takes the session configuration; base it on
`Session.default_config` and update only what you need:

```ocaml
let config = { Session.default_config with database = Some "mydb"; bookmarks = [ "bm-1" ] } in
Driver.session ~config driver
```

| Field                        | Meaning                                                        | Honored? |
|------------------------------|----------------------------------------------------------------|----------|
| `database`                   | database selected in RUN/BEGIN                                | yes      |
| `access_mode`                | `Read` / `Write`, sent in BEGIN for explicit and managed transactions | yes (explicit/managed) |
| `bookmarks`                  | initial bookmarks, sent in RUN/BEGIN                          | yes      |
| `impersonated_user`          | user to impersonate, sent in BEGIN                            | yes (explicit/managed) |
| `max_transaction_retry_time` | retry budget of `Session.execute` (default 30.0 s)            | yes      |
| `initial_retry_delay`        | first backoff of `Session.execute` (default 1.0 s)            | yes      |
| `retry_delay_multiplier`     | backoff growth (default 2.0)                                  | yes      |
| `retry_delay_jitter_factor`  | backoff jitter (default 0.2)                                  | yes      |
| `fetch_size`                 | stream batch size hint                                        | accepted, not yet applied |

### Query and transaction options

`Session.run`, `Session.begin_transaction` and `Session.execute` accept:

- `?timeout` (seconds) — the transaction timeout, sent as `tx_timeout`.
- `?metadata` — a `(string * Values.t) list` sent as `tx_metadata`.
- `Session.execute` additionally takes the required `mode:Config.access_mode`
  (or leave it out and set the session's `access_mode`).

### Validated config records (`Config`)

`Config.make_workspace_config` and `Config.make_pool_config` build their
records with validation (a `Configuration_error` on out-of-range values):

- `make_workspace_config`: `max_transaction_retry_time`, `initial_retry_delay`,
  `retry_delay_multiplier`, `retry_delay_jitter_factor`, `fetch_size`,
  `database`, `impersonated_user`, `disable_auto_commit_retries`.
- `make_pool_config`: `max_connection_lifetime`, `liveness_check_timeout`,
  `max_connection_pool_size`, `connection_acquisition_timeout`,
  `connection_timeout`, `connection_write_timeout`, `keep_alive`,
  `telemetry_disabled`.

The pool honors `max_connection_pool_size`, `connection_acquisition_timeout`,
`max_connection_lifetime` and `liveness_check_timeout` (a RESET on reuse);
`connection_timeout`, `connection_write_timeout`, `keep_alive` and
`telemetry_disabled` are not wired yet, and `disable_auto_commit_retries` has
no effect for now.

## Not yet implemented

- Routing: `neo4j://`, server-side routing, home database.
- Impersonation on auto-commit queries (it works in transactions via the BEGIN
  extra).
- Notification filtering and telemetry.
- The high-level API (`execute_query`, `verify_connectivity`, phase A9) and
  bookmark/auth managers (phase A8).

See [PLAN.md](../PLAN.md) for the full roadmap.
