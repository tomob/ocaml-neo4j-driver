# Neo4j OCaml Driver — Implementation Plan

Plan for a pure OCaml Neo4j client library (full cluster driver), built as a **new project** using [ocaml-neo4j-bolt](https://github.com/jeong-sik/ocaml-neo4j-bolt) as a reference implementation (MIT). Modeled on the architecture of the Neo4j Python driver.

## Established decisions

- **New project** → clean architecture from scratch, but we port the clean `packstream.ml` from the reference repo (MIT) — that saves time, and the code needs fixes anyway (marker validation, error handling).
- **Eio-first** → core logic written in **direct style** (no monads): functions take `sw`/`net`/`clock` from `Eio.Stdenv`. Instead of an IO functor, we keep a narrow transport interface (`transport.mli`), so Lwt can later be a second adapter — but we don't over-engineer it at the start.
- **Full cluster driver** → the ordering must first deliver a correct single client, then cluster reliability.
- **TestKit from the start** → the TestKit backend is a **separate parallel track** (Track B), built incrementally alongside the growing API. This forces early stabilization of the public API surface (TestKit requires specific commands).

## Project structure (dune/opam)

```
ocaml-neo4j-driver/            # this repo
  lib/packstream/              # neodriver_packstream — pure, no dependencies
    packstream.mli/.ml
  lib/core/                    # neodriver_core — shared, transport-agnostic
    errors.mli/.ml             # error taxonomy + retryable
    config.mli/.ml             # driver/session/tx config + defaults
    addressing.mli/.ml         # Address, URI parse (bolt://, neo4j://, routing context)
    hydration.mli/.ml          # Bolt tags ↔ OCaml values
    values.ml                  # Node/Rel/Path/Point/Date/Time/DateTime/Duration/Vector/Unsupported
    state.ml                   # client state machine (READY/STREAMING/TX/FAILED/AUTHENTICATION)
    summary.ml                 # ResultSummary, counters, GQL notifications
  lib/eio/                     # neodriver_eio — Eio backend
    neodriver_eio.ml           # root module (curated public interface)
    transport_eio.ml           # read/write/connect/shutdown + deadline
    conn.ml                    # single Bolt connection
    pool.ml                    # pool
    routing.ml                 # routing table, ROUTE, load balancing
    session.ml, result.ml, tx.ml, driver.ml
  lib/neodriver/               # neodriver — convenience aggregator
    neodriver.ml               # friendly names: Neodriver.Packstream/Errors/Config/Driver
  lib/lwt/                     # (later) neodriver_lwt
  testkitbackend/              # Track B — JSON-over-stdio server (analog of testkitbackend/)
  test/                        # alcotest per module
```

---

## TRACK A — Library core

### Phase A0 — Foundations

- Repo initialization: `dune-project` (lang 3.13+, `ocaml >= 5.2.0`), opam packages (`neodriver_packstream`, `neodriver_core`, `neodriver_eio`, `neodriver`; later `neodriver_lwt`), CI (OCaml 5.2–5.5 matrix, `ocamlformat` lint). **Done** (commit "step A0-1").
- **`errors.ml`** (modeled on `exceptions.py`): type
  `type error = ...` with constructors for client errors (`ClientError`, `TransientError`, `DatabaseError`, `ServiceUnavailable`, `SessionExpired`, `PoolTimeout`, ...) and `of_neo4j_code : code:string -> message:string -> t`. This is the anchor for retry/deactivation/re-auth. Includes the `classification`/`specific` sub-types, the `_ERROR_REWRITE_MAP` port, `is_retryable`, `unauthenticates_all_connections`, `has_security_code` and `is_fatal_during_discovery`. **Done** (commit "step A0-2").
- **`config.ml`**: records with defaults `{connection_acquisition_timeout=60.; max_transaction_retry_time=30.; initial_retry_delay=1.; retry_delay_multiplier=2.; retry_delay_jitter_factor=0.2; fetch_size=1000; max_pool_size=100; max_connection_lifetime=3600; ...}` plus validated `make_*` constructors returning `(t, Errors.t) result`. **Done** (commit "step A0-2").
- **`addressing.ml`**: `Address` + `parse_uri` (extended with `neo4j://`, `+s/+ssc`, routing context from the query string), default ports, `ResolvedAddress` carrying the unresolved host (for SNI). Returns `result`; includes percent-decoding of the routing context. **Done** (commit "step A0-3").
- **Deadline**: `deadline.ml` (monotonic via Mtime + min-timeout) — one unified timing mechanism. **Done** (commit "step A0-3").

### Phase A1 — PackStream + hydration (port of reference, improvements)

- Port `packstream.ml` → `neo4j_packstream` with fixes: marker validation → `ProtocolError` instead of `failwith`, bounds, a safe `unpack` with depth/size limits. **Done** (commit "step A1-1"): `unpack` returns `(value, error) result`, `max_depth` limit (default 256), containers built incrementally, 16/32-bit lengths read as unsigned, dedicated `error` type + `.mli`.
- **`values.ml` + `hydration.ml`** (modeled on `_codec/hydration/`):
  - tag descriptors: `N/R/r/P` → Node/Rel/Path; `X/Y` → Point (SRID 4326/4979/7203/9157); `D/T/t/F/f/d` → Date/Time/DateTime; `I/i` (offset / zone name, Bolt 5.2+); `E` → Duration; `V` → Vector; `?` → UnsupportedType.
  - Node deduplication by `element_id` per result (per-query graph), like `_GraphHydrator`. **Done** (commit "step A1-3"): `hydration.ml` with per-version tags (`F/f` vs `I/i`, `V`/`?` for Bolt 6), per-query graph dedup + label/property merge, `Broken` propagation, `hydrate`/`dehydrate`.
  - value types: `Date/Time/DateTime/Duration` on nanoseconds + ISO-8601 + conversion to/from `Ptime`; `Point` with SRID registry; `Vector` (big-endian bytes). **Done** (commit "step A1-2"): `temporal.ml` (full Date/Time/DateTime/Duration, named zones opaque) + `values.ml` (`t` with Node/Rel/Path/Point/Vector/Unsupported/Broken, `legacy_id` kept).
  - a `Broken` variant (analog of `BrokenHydrationObject`) propagated through lists/maps. **Done** (A1-2/A1-3): `Values.Broken` + propagation in `hydration.ml`; surfacing as a record-access error belongs to Phase A4 (Result layer).

### Phase A2 — Eio transport + handshake + TLS

- **`transport_eio.ml`**: `Eio.Net` + fibers, `SO_KEEPALIVE`, reads/writes with deadlines, 16 KiB chunks + `0x0000`, coalescing. **Done** (commit "step A2-1"): `transport.ml` (TCP via `Eio.Net`, deadline-bounded reads/writes, chunk framing + NOOP skip), `handshake.ml` (v1 + manifest `0xFF`, highest supported version), `conn.ml` (`Conn.connect`, TLS schemes rejected until A2-2). `SO_KEEPALIVE` deferred (Eio's portable Net API does not expose socket options).
- **Handshake**: v1 (proposing Bolt 3/4/5) **and manifest `0xFF`** (Bolt 5.4+ and 6.0/6.1) — selecting the highest supported version within the server's range; negotiation in `handshake.ml`. **Done** (commit "step A2-1"), unit-tested via a mock server; integration handshake test gated on `TEST_NEO4J_*` env vars.
- **TLS via `tls-eio`**: trust modes (system CAs / custom CAs / TrustAll), **hostname verification + SNI from the unresolved host**, TLS ≥ 1.2, mTLS with client certificate. **Done** (commit "step A2-2"): `tls_client.ml` (Verify = system CAs via `ca-certs`, TrustAll = no validation), `transport.ml` gains `?tls` (`Plain | Verify host | Trust_all host`), `conn.ml` maps `bolt://`→Plain, `bolt+s://`→Verify, `bolt+ssc://`→TrustAll; TLS ≥ 1.2 enforced, SNI + hostname verification via `Domain_name`. Unit-tested with a mock TLS server (`Tls_eio.server_of_flow` + committed self-signed fixture); integration-tested against a real Neo4j container with the Bolt SSL policy enabled (`tls_level=OPTIONAL`). Custom CAs and mTLS client certificates are **deferred** (no config surface yet). ⚠️ **Risk resolved**: `tls-eio` 2.0.4 is usable (needs `Mirage_crypto_rng_unix.use_default ()`).
- **Address iteration**: `getaddrinfo`, trying all addresses (IPv4+IPv6), error aggregation (the `ExceptionGroup` equivalent — in OCaml a chained record `{last; all}`), timeouts clamped to the deadline. **Done** (commit "step A2-3"): `transport.ml` resolves every `getaddrinfo_stream` address and tries each in turn under a single `Eio.Time.Timeout.t` deadline; on total failure it aggregates all errors into `Errors.failures` (`{ last; all }`) and reports a Python-style `Service_unavailable` ("Couldn't connect to <addr> (resolved to <addrs>):\n<errors>", built by `Addressing.connect_failure_message`). Unit-tested (`connect_failure_message`, closed-port aggregation). **Phase A2 complete.**

### Phase A3 — Single connection: HELLO, auth, state machine

- HELLO with `user_agent`/`bolt_agent`/`routing`; inline auth (≤5.0) and **`LOGON/LOGOFF`** (≥5.1). **Done** (commit "step A3-1"): `bolt.ml` (message layer — `send`/`recv`/`respond` with SUCCESS/FAILURE/IGNORED interpretation, plus `hello`/`logon`/`logoff`), `conn.ml` (`auth`/`user_agent` in the config; `connect` authenticates — inline auth for ≤5.0, HELLO+LOGON for ≥5.1; `bolt_agent` header for 5.3+; `logon`/`logoff` gated on `supports_re_auth`). Unit-tested via a mock Bolt session server; integration-tested against a live Neo4j (auth OK + wrong-password rejection).
- **State machine** (`state.ml`): `CONNECTED/READY/STREAMING/TX_READY|TX_STREAMING/FAILED/AUTHENTICATION`, `IGNORED` handling, **automatic RESET after FAILURE**. **Done** (commit "step A3-2"): `state.ml` (pure server-state machine — `server_transition` with `?re_auth` (Bolt ≥5.1 vs ≤5.0) and `?has_more` for streaming, `failed`/`ready`); `conn.ml` tracks the server state, routes every request through `Conn.request` (auto-RESET when `Failed`, on any non-SUCCESS response the state becomes `Failed`, so `IGNORED` is handled too), adds `Conn.reset` and `server_state`; `Conn.version` replaces the exposed record fields (`t` is now abstract). Unit-tested (transition tables; state across logoff/logon; FAILURE→Failed→auto-RESET with the wire order HELLO, LOGON, LOGON, RESET, LOGOFF; IGNORED→Failed; reset round-trip).
- **RUN/PULL/DISCARD**: streaming PULL with `fetch_size` and `has_more`, `DISCARD` of the remainder, `qid` (multiple results). **Done** (commit "step A3-3"): `bolt.ml` gains `run_tag`/`pull_tag`/`discard_tag`/`record_tag`, `recv_fields`, and `run`/`pull`/`discard` (PULL/DISCARD collect the RECORD messages up to the summary — a RECORD carries its values as one List field); `conn.ml` adds `Conn.run` (dehydrated parameters, `mode`/`db` extras, returns `fields`/`qid`), `Conn.pull` (hydrated records + `has_more`, streaming with a fetch size and repeated PULLs) and `Conn.discard`; the shared `Conn.request` now tracks `has_more` so the state stays `Streaming` between PULLs. Unit-tested via the mock server (single record, streamed batches, qid on the wire, DISCARD, FAILURE→auto-RESET) and integration-tested against a live Neo4j (`RETURN 1`, `UNWIND [1..5]` streamed with `n=2`, DISCARD of a large result).
- Per-version feature gates: `supports_multiple_results`, `supports_multiple_databases`, `supports_re_auth`, `supports_notification_filtering`, `supports_ssr`, `supports_connection_context` (routing context in HELLO: Bolt 4.1+), `supports_telemetry` → a `capabilities` variant. **Done** (commit "step A3-4"): `capabilities.ml` (pure — `Capabilities.of_version` with the Python-driver thresholds: multiple results/databases 4.0+, re-auth 5.1+, notification filtering 5.2+, ROUTE (ssr) 4.3+, TELEMETRY 5.4+); `conn.ml` uses it instead of the ad-hoc `supports_re_auth` and exposes `Conn.capabilities`. Unit-tested (`test_capabilities`).
- **Re-auth on a connection** (LOGON/LOGOFF when the token changes) — integration point for the pool. **Done** (commit "step A3-5"): `Conn` tracks `current_auth`; `Conn.re_auth` (LOGOFF+LOGON when the token differs, returns whether it changed; no-op for the same token) and `Conn.mark_unauthenticated` (clears the current token). Unit-tested via the mock (same-token no-op, changed-token LOGOFF+LOGON on the wire, re-auth after `mark_unauthenticated`). **Phase A3 complete.**

### Phase A5 — Sessions and transactions + retry

> **Ordering**: moved ahead of A4 so the TestKit suite can pass as early as possible — transaction
> commands (`SessionBeginTransaction`, `SessionReadTransaction`, `SessionWriteTransaction`) account
> for ~173 of the ~196 current testkit errors, while A4's full Result/summary API unblocks almost no
> testkit tests (`ResultSingle`/`ResultSingleOptional` are feature-skipped and the summary tests are
> transaction-gated anyway). A5 does not depend on A4 (results use the A3 RUN/PULL path; retry uses
> `error.retryable`).

- **A5a — explicit transactions**. **Done** (commit "step A5a"): `lib/eio/tx.ml` with
  `begin_transaction/commit/rollback/close` and per-transaction state (`Open`/`Failed`/`Closed` —
  operations on a failed transaction fail fast, rollback recovers the connection with a RESET);
  session bookmarks tracked and reported (`SessionLastBookmarks`), captured from the COMMIT
  metadata (explicit) and the PULL summary (auto-commit); auto-commit `session.run` carries the
  session's `access_mode`/`database`/`bookmarks`/`timeout`/`tx_metadata`. The backend gives each
  session its own lazy connection (two sessions can hold concurrent transactions, e.g.
  `test_tx_timeout`). Backend commands: `SessionBeginTransaction` (rejects a second transaction
  while one is open), `TransactionRun`, `TransactionCommit`, `TransactionRollback`, `TransactionClose`,
  `SessionLastBookmarks`. Auto-commit retry (`disable_auto_commit_retries`) is deferred: no TestKit
  test exercises it and it needs connection rotation (A6).
- **A5b — managed transactions + retry**. **Done** (commit "step A5b"): `lib/eio/session.ml` with
  `Session.run` (auto-commit, bookmark capture), `begin_transaction`, `execute` (managed unit of
  work) and `last_bookmarks`; the session owns its lazy connection and bookmarks. `execute` runs the
  retry loop within the `max_transaction_retry_time` budget (configurable via the TestKit
  `maxTxRetryTimeMs`), jittered backoff (1s initial, x2, 0.2 jitter), decision via
  `error.retryable`; between attempts the connection is recovered with a RESET; a client
  (application) failure rolls back without retrying. Backend commands:
  `SessionReadTransaction`/`SessionWriteTransaction` with the full `RetryableTry`/`RetryableDone`/
  `RetryablePositive`/`RetryableNegative` protocol: driver errors carry an `id` (stored in a backend
  table) which `RetryableNegative` references back; nested managed transactions (a unit of work
  calling `execute_*` on another session) are handled recursively. Also `CheckMultiDBSupport`.
  Unit tests cover commit/bookmark, retry on transient failures, no-retry on client errors and the
  explicit-transaction guard. TestKit: 53 -> ~97 passing; the remaining errors are pre-existing A2
  (named-timezone temporal round-trips) and A4 (Result/summary) limitations.
- **⚠️ Checkpoint**: after A5 we have a full, correctly streaming single-connection client — the best first release.

### Phase A4 — Result + summary + notifications

- **`neo4j_result.ml`**: lazy streaming (in Eio: direct iteration), `consume/single/fetch/peek/value(s)/data`, states `_attached/_streaming/_exhausted`, semantics after transaction close. Backend: `ResultSingle`/`ResultSingleOptional`. **Done** (commit "step A4-5"): `lib/eio/neo4j_result.ml` wraps a `Conn.stream` + cursor over `next/peek/fetch/values/data/consume/single/single_optional` (deferred server failure surfaced as `Error`); `Session.run`/`Tx.run` now return a `Neo4jResult.t` and the auto-commit bookmark is captured by the stream's `on_complete` hook (so `Session.pull` is gone); the backend holds a `Neo4jResult.t` and delegates every Result handler to it.
- **`summary.ml`**: `SummaryCounters`, `plan/profile`, `query_type`, `result_available_after/consumed_after` (`t_first/t_last`), **`gql_status_objects`** polyfilled from legacy notifications, `ServerInfo` (address/agent/protocol_version). **Done** (commit "step A4-5"): `lib/eio/summary.ml` builds the summary from a completed stream and **hydrates** plan/profile/notifications/gql statuses into `Values.t` (hiding PackStream); the backend's TestKit `Summary` JSON is now serialized from `Summary.t` (`values_to_plain`/`gql_status_json`/`counters_json`). TestKit: 111 -> 113 OK.

### Phase A6 — Pool

- `pool.ml`: address→queue mapping + reservation counter,
`max_connection_pool_size`, waiting on `Eio.Semaphore`/mutex+cond with
`connection_acquisition_timeout`, release with RESET (or kill for defunct),
**liveness check**, `max_connection_lifetime`/`stale`, `deactivate`,
**`IncompleteCommit`** (ambiguous commit). **Done** (commit "step A6"):
`lib/eio/pool.ml` implements a bounded single-address pool (a `Mutex` + FIFO
idle queue + `Eio.Semaphore` of `max_connection_pool_size`, `acquire` bounded
by `connection_acquisition_timeout` via `Eio.Time.Timeout.run_exn`, lifetime /
liveness checks on reuse, `release` with RESET, closing defunct connections;
address-level deactivation deferred to routing). `Driver` is now pool-backed:
`Driver.connect` returns a `Driver.t`, `Driver.session` borrows a connection
(returned with a RESET on close) and `Driver.close` closes the pool;
`Session.create` gained a `release` callback. `Tx.commit` surfaces
`Errors.Incomplete_commit` when a connection is lost mid-commit (a server
FAILURE is a known outcome). The TestKit backend migrates to `Driver.t`
(NewDriver/NewSession/DriverClose/driver-level ops via the pool). Public API
ripple (quickstart/usage/README/examples/test_driver) updated. Unit tests
(`test_pool.ml` on the mock: reuse, defunct, lifetime, liveness, acquisition
timeout) and integration tests (`test_integration/test_pool.ml`: sessions
sharing the pool, reuse, pool-size bound with concurrent sessions, pool
  close). Fixes a nested-result regression from the batched-PULL refactor
  (`Neo4jResult` now reads the stream's shared buffer again). TestKit stays OK
  (119, 7 skipped).

### Phase A6.5 — Unblock the remaining TestKit skips (UUID + vector) — Done

The local TestKit suite (`tests.neo4j.suites`, real server) previously skipped
12 tests: 8 feature-gated (5 UUID + 3 vector — the backend did not report
`Feature:API:Type.UUID` / `Feature:API:Type.Vector`) and 4 multi-db runtime
skips on the community edition (a server limitation, not driver code).

- **Vector (3 tests) — Done**: `Values.Vector` round-trip (the dtype marker is
  a single `BYTES` byte, not an `INT`, on the wire), `CypherVector`
  encode/decode in `testkitbackend/testkit_values.ml`, and
  `Feature:API:Type.Vector` reported. They run when the harness claims a
  vector-capable edition (`NEO4J_EDITION=aura` or an enterprise server); the
  community edition keeps skipping them (server limitation).
- **UUID (5 tests) — Done**: `Values.Uuid` (canonical hyphenated string) +
  `Packstream.Uuid` (marker `0xE0`, 16 big-endian bytes, Bolt 6.1),
  hydration/dehydration, `CypherUUID` encode/decode in
  `testkitbackend/testkit_values.ml`, and `Feature:API:Type.UUID` +
  `Feature:Bolt:6.1` reported. The local server only offers Bolt 6.0 unless
  the preview is enabled: `scripts/integration.sh` sets
  `NEO4J_BOLT_MAX_VERSION=6.1` plus the internal UUID preview flags
  (`internal.cypher.uuid_type.enabled`, `internal.dbms.latest.*`), matching the
  TestKit runner. Note: the server's aligned store format cannot commit UUID
  properties; `test_uuid_stored_on_node` writes and reads back inside a
  transaction and rolls back.
- **Multi-db (4 tests)**: out of scope for driver code — they require a server
  with multiple databases (enterprise edition); they stay skipped in the
  community-based local run.

The 8 feature-gated skips now pass: local TestKit is **OK (skipped=7)** on the
community edition (3 vector + 4 multi-db) and **OK (skipped=4)** with
`NEO4J_EDITION=aura` (only multi-db). See `scripts/README.md` for how to run
each configuration (including an external enterprise server via `NEO4J_URI`
for the multi-db tests).

### Phase A7 — Routing + home db + SSR

**Minimal routing — Done** (commit "Add minimal routing (phase A7)"): [neo4j://] (and
its [+s]/[+ssc] variants) drivers now route:

- **ROUTE** (`0x66`) with routing_context/bookmarks/db (+[imp_user] on Bolt 4.4+; the Bolt 4.3 form
  sends the database directly). `State.Route` (Ready -> Ready); `Conn.route` returns the [rt]
  value. Enables the [neo4j://] TLS variants in `Conn.tls_of_scheme`.
- **`routing_table.ml`** (core): `{ttl_seconds; routers; readers; writers}` parsed from the [rt]
  metadata, least-loaded `pick` per role (fewest in-use connections, deterministic tie-break).
- **`cluster.ml`** (eio): per-database routing tables (fetched over ROUTE on demand, cached with
  the server TTL, refreshed under a lock), a pool per cluster address and least-loaded address
  selection by access mode (readers for [Read], writers for [Write]). `Driver` uses a [Cluster]
  for [neo4j://] URIs; `Session.connect` now carries the session's [access_mode]/[database].
- Integration test: `neo4j://` against the local standalone server (its routing table lists the
  single server in every role) — read + write through the routed driver. Unit tests for the ROUTE
  wire message (mock), `routing_table` parsing/pick and the state transition.
- **Load balancing — Done** (replaces the initial round-robin): `Cluster.acquire` selects the
  least-loaded address of the role — the pool with the fewest checked-out connections
  (`Pool.in_use_count`, derived from the acquisition semaphore) — with a deterministic tie-break
  (first in the routing-table order). `Routing_table.pick` became `Routing_table.least_loaded`;
  the per-(database, mode) round-robin counters were removed. Unit tests cover the core selection
  (`test_routing_table.ml`), the pool count (`test_pool.ml`) and the cluster behaviour across
  readers (`test_cluster.ml`).
- **Address deactivation — Done** (modeled on the Python driver): a failed server is dropped from
  the cluster until a refresh re-lists it. `Cluster.deactivate` removes the address from every
  routing table and closes its pool; `Cluster.on_write_failure` drops it from the [writers] of one
  database only (NotALeader / read-only failure). `Conn` gained an `on_error` callback (installed
  on pool connections) reported on failed requests — the cluster filters it: `ServiceUnavailable`
  / `DatabaseUnavailable` → `deactivate`, `NotALeader` / `ForbiddenOnReadOnlyDatabase` →
  `on_write_failure` (keyed by the connection's last database). During discovery a router that
  fails to connect, answers ROUTE with a non-fatal error or returns a table without routers or
  readers is deactivated in favour of the next router; errors fatal during discovery
  (`is_fatal_during_discovery`) abort the fetch immediately. A table is fresh only when it still
  has routers and an address for the requested mode (an emptied role forces a refresh), and a
  failed `Pool.acquire` (server down) deactivates the address and retries within the acquisition
  timeout. `Routing_table.remove_address` / `remove_writer` are the pure core helpers.
- **Procedure fallback — Done**: `Conn.route` falls back to the routing procedure on Bolt 3 /
  4.0–4.2 (gated by the new `Capabilities.supports_route_message`, same 4.3 threshold as
  `supports_ssr`): Bolt 3 runs `CALL dbms.cluster.routing.getRoutingTable($context)` (no db, no
  bookmarks); Bolt 4.0–4.2 runs `CALL dbms.routing.getRoutingTable($context)` (default database) or
  `CALL dbms.routing.getRoutingTable($context, $database)` on the `system` database. The single
  returned record is zipped with its RUN `fields` into the same `{ttl; servers}` shape as the
   ROUTE `rt`, so `Routing_table.parse` works unchanged. `imp_user` (Bolt < 4.3) and a `database`
   on Bolt 3 are `ConfigurationError`. Unit tests cover the procedure wire messages (RUN/PULL
   instead of ROUTE, mock) and a cluster acquire through a Bolt 4.2 router.
- **Server-side routing (SSR) — Done**: routed drivers send the routing context in HELLO (the
  `routing` field, Bolt 4.1+, gated by the new `Capabilities.supports_connection_context`; `None`
  for direct `bolt*` drivers, `Some ctx` — including `Some []` → `routing: {}` — for `neo4j*`);
  the server's `ssr.enabled` hint is parsed from the HELLO response (`Conn.ssr_enabled`); an [rt]
  routing table returned in an auto-commit RUN response (server-side routing) is consumed by the
  session (`?on_rt`, wired to `Cluster.update_table`, which replaces the cached table) — gated on
  `Conn.ssr_enabled`. Unit tests cover the HELLO wire variants (4.0 vs 4.1+, Some vs None), the
  hint parsing, the `rt` capture and the cluster table update (mock).
- **Home-db cache — Done** (keyed by `impersonated_user`, TTL via the new
  `Config.pool_config.home_db_cache_ttl`, default `infinity` like Python): the routing table now
  carries its `database` (`Routing_table.database`, parsed from the `rt` [db] field — the server's
  home database). A default-database (`database = None`) routed session resolves its effective
  database to the home database: a ROUTE is sent with the session's `imp_user` (`Conn.route
  ?imp_user`, Bolt 4.4+), the returned [db] is cached per impersonated user and the table is
  aliased under the home database, so later default-database sessions reuse both without a ROUTE.
  `Cluster.acquire` now returns the effective database and `Session`'s `connect` reports it; RUN
  and BEGIN send it as `db` (TestKit homedb wire behaviour) and SSR `update_table` (`?imp_user`)
  seeds the cache too. Unit tests cover the resolution/caching, TTL expiry, per-user keys, the
  `imp_user` ROUTE extra and the session RUN db (mock).
- **TestKit routing backend — Done** (the last deferred A7 item): the backend now reports
  `Backend:RTFetch` / `Backend:RTForceUpdate` and serves `GetRoutingTable` /
  `ForcedRoutingTableUpdate`. `Cluster.fetch_table` threads `~bookmarks` to the ROUTE request, and
  two new test-support APIs back the commands: `Cluster.routing_table_of` (the cached table under
  the lock, no fetch) and `Cluster.force_routing_table_update` (a fresh fetch via the routers
  bypassing the freshness/negative-cache checks, stored as a normal `Ok` resolution, bounded by the
  acquisition timeout); `Driver.get_routing_table` / `Driver.force_routing_table_update` delegate
  to the cluster ([None] / an error for direct `bolt://` drivers). The `RoutingTable` response
  matches the Python backend 1:1 (requested database with `ttl:0` and empty roles when nothing is
  cached; the table's `database`, TTL and role addresses otherwise). The stub routing suite
  (`scripts/testkit_stub.sh tests.stub.routing.test_routing_v4x4 tests.stub.routing.test_routing_v5x0`,
  no Neo4j needed) runs `RoutingV4x4`/`RoutingV5x0`. Unit tests
  cover the cached-table read, a forced update (ROUTE bookmarks on the wire, the stored table, the
  refreshed readers) and a failed forced update storing nothing. **A7 is now 100% done.**

  Running the stub suite (the first time it is exercised) surfaced and fixed four real driver
  conformance gaps: the routing context now carries the cluster's own `address` key (as the Python
  driver adds at pool creation; the stub scripts match on it), an auto-commit RUN sends the
  session's `mode` and omits an empty `bookmarks` key, `Conn.last_database` is recorded by BEGIN
  (so a NotALeader inside a transaction removes the writer from the right database) and the pool
  RESETs a connection on release regardless of its state (failed connections are recovered, not
  closed). Remaining stub-suite failures are pre-existing driver gaps outside this item (fast-fail
  vs retry on interrupted connections, resolver-based rediscovery, system-bookmark routing,
  multi-db/leader-switch scenarios); `scripts/testkit_stub.sh` (no arguments runs every
  `tests.stub.*` suite, or pass modules explicitly) is the harness for iterating on them.

**Deferred (follow-ups):**

### Phase A8 — Bookmarks and auth management

- `bookmarks.ml` (immutable set + union), `last_bookmarks`, `bookmark_manager` (supplier/consumer) with a default implementation.
- **Auth managers**: `static/basic/bearer` with refresh on `Unauthorized`/`TokenExpired` + `ExpiringAuth`; `handle_security_exception` via `on_neo4j_error` on the pool; `_unauthenticates_all_connections`.

### Phase A9 — High-level API

- `execute_query` + `EagerResult` (records/summary/keys), `verify_connectivity`, `verify_authentication`, `supports_multi_db`, `TELEMETRY` telemetry, `warn_notification_severity` (warnings at the calling code level).

---

## TRACK B — TestKit (parallel with Phase A3)

The TestKit backend is a **separate parallel track** (started alongside Phase A3, revising the earlier
"after A5" checkpoint): a JSON-over-TCP server that translates TestKit commands onto the **public
library API**, forcing early API-surface stability. Conformance is enabled gradually via feature
gating (the `test_subtest_skips.ml` analog).

- **Phase B0a** — scaffold (parallel with A3, no DB access yet). **Done** (commit "step B0a"):
  - `testkitbackend/` dune executable `testkitbackend` (`neodriver` + `yojson` + `eio`/`eio_main`);
    `yojson` is a backend-only dependency, not part of the public opam packages.
  - `backend.ml`: an Eio **TCP server on port 9876** (the TestKit harness connects over TCP, not
    stdio) — reads `#request begin` / JSON / `#request end` lines, dispatches on `request["name"]`,
    writes `#response begin\n{json}\n#response end\n`; unknown commands → `BackendError { msg }`.
  - `commands.ml`: `StartTest` → `RunTest`, `GetFeatures` → `FeatureList { features }`,
    `NewDriver`/`DriverClose` → `Driver { id }`, `NewSession`/`SessionClose` → `Session { id }`
    (config-only, no connection; the URI is validated with `Addressing.parse_uri`, basic auth only).
  - `features.ml`: reported TestKit features (empty for now — the harness skips everything else).
  - `testkit_values.ml`: `Values.t` → TestKit JSON encoding (`CypherNode`/`CypherRelationship`/
    `CypherPath`/`CypherPoint`/`CypherDate`/`CypherTime`/`CypherDateTime`/`CypherDuration` + scalars),
    modeled on `totestkit.py`.
  - Tests: `testkitbackend/test_values.ml` (pure value-encoding unit tests, run under
    `dune runtest`) + `scripts/backend_smoke.sh` (spawns the backend and drives it over TCP as the
    harness does).
  - Harness: `neo4j-drivers/testkit` cloned into the sandbox and its dependencies installed. A live
    harness run additionally needs a driver Docker image + a `testkit/backend.py` glue that spawns
    our binary; that is part of B0b/B10 (with an empty feature list every test would be skipped
    anyway). The protocol is validated by `backend_smoke.sh`.
- **Phase B0b** — query path. **Done** (commit "step B0b"): `NewDriver` holds a **lazily created connection** (via `Conn`, one per driver, no pool) and `DriverClose` closes it; `VerifyConnectivity` / `GetServerInfo` connect on demand; `SessionRun` decodes `params`/`txMeta` (new `testkit_values.of_yojson` decoder, round-trip tested), runs RUN+PULL and stores the result (fields/records/summary/cursor); `ResultNext`/`ResultPeek`/`ResultList` stream records (`Record`/`NullRecord`/`RecordList`); `ResultConsume` returns a minimal `Summary` (serverInfo, counters from PULL `stats`, queryType, database, query,   available/consumed-after). `Conn.pull` now returns the PULL summary metadata (not just `has_more`), `Conn.run` gained `?metadata` (tx_metadata) and `Conn.server_agent` reads the HELLO agent. **Custom resolver**: `Conn.connect ?resolver` passes the address to the resolver and tries each returned address in turn (`Conn.address` reports the connected one); the backend implements the TestKit `ResolverResolutionRequired`/`ResolverResolutionCompleted` protocol with a silent handler. Features enlarged (Bolt 4.4/5.x/6.x + implemented API). Against a live Neo4j (2026.06): **13 tests pass** (authentication, basic/streamed queries, iteration, session reuse, long strings, regex params, tx_metadata echo, **custom resolver**). The testkit runner now mirrors the Python harness topology: the backend runs **in a container** (built from the repo's `Dockerfile`) and Neo4j in a **separate container** on a dedicated docker network, so the resolver's "unreachable" first address (`127.100.200.42`) is the backend container's own loopback and is rejected as the test expects. The remaining errors are transaction commands (`SessionBeginTransaction`/`SessionReadTransaction`/`SessionWriteTransaction`), which are **Phase B1**.
- **Phases B1–B5**: extending command coverage as the API matures: transactions
  (RetryablePositive/Negative, TxBegin/Commit/Rollback), sessions (`SessionBeginTransaction`,
  `SessionLastBookmarks`, access mode), routing (`NewDriver` with `neo4j://`, `DriverSession`...),
  auth-token/bookmark/fake-time managers.
- **Phase B10**: full conformance (the full testkit suite on a server matrix 4.x/5.x/6.x) + CI
  running the backend in containers.

**Principle**: the TestKit backend translates commands onto the **public library API** → forces API surface stability from the start. TestKit feature gating (the `test_subtest_skips.ml` analog) lets conformance be enabled gradually, phase by phase.

### Phase B11 — All `tests.stub.*` suites green

`scripts/testkit_stub.sh` (added 2026-08, replacing `testkit_routing.sh`) runs the stub suites
against the locally built backend: with no arguments the whole `tests.stub` suite
(`python -m tests.stub.suites`, 1607 tests), or pass test modules/classes/tests as arguments
(`--help` / `--list-suites` enumerate them). No Neo4j server is needed.

Baseline (measured 2026-08-18; two batches, full-suite-in-one-go is impractical because `summary`
is pathologically slow):

- **Green**: `routing` v4x4+v5x0 (279), `basic_query` (6), `bookmarks` v4/v5 (11), `retry` +
  `retry_clustering` (14), `session_run_parameters` (15), `driver_execute_query` (15), and (mostly
  feature-skipped) `transport`, `server_side_routing`, `optimizations`, `idempotent_retries`,
  `notifications_config`, `configuration_hints`.
- **Recurring backend/driver gaps**:
  - backend `NewDriver` rejects non-`basic` auth (`unsupported auth scheme "bearer"`) → `errors`,
    `authorization`;
  - result lifecycle (`unknown result` on double `consume()`, `TimeoutError` hangs on
    `result.consume()` / session close with a pending stream) → `versions`, `session_run`,
    `tx_run`, `tx_lifetime`;
  - no GOODBYE on connection close (Bolt ≥ 4.4) + disconnect-detection step mismatches →
    `disconnects`;
  - negative `tx_timeout` not rejected → `tx_begin_parameters`;
  - default-db home resolution double-ROUTE and stale connections keeping stub servers alive
    ("Address already in use" cascade) → `connectivity_check.test_get_server_info`.

Order of work (least → most effort):

1. **Result lifecycle** in the backend (`ResultConsume`/`Discard`/session/tx close must answer
   immediately, never hang) → `versions`, `session_run`, `tx_lifetime`, `tx_run`.
2. **Auth schemes** in `NewDriver` (`basic`/`bearer`/`none` + `authToken`) → `errors`, then
   `authorization`.
3. **GOODBYE on close** (Bolt ≥ 4.4) + disconnect-detection semantics → `disconnects`.
4. **`tx_timeout < 0` validation** → `tx_begin_parameters`.
5. **`connectivity_check`/get_server_info**: no double ROUTE for `database:None`, close
   connections so stub servers shut down between tests.
6. **Measure + fix the big modules**: `summary` (128, run alone), `homedb` (48), `iteration`
   (56), `datatypes` (31), `driver_parameters` (40), `notifications_config`.
7. **`authorization`** (71) last (depends on 2; may need auth-manager features).

Final: `scripts/testkit_stub.sh` → `OK (skipped=<feature-skips>)`, 0 failures; `dune runtest`
(167) stays green.

---

## TRACK C — Documentation and developer enablement

Making the driver easy to pick up and use: a user-facing entry point, rendered
API documentation, a quickstart, usage documentation, runnable examples and a
hosted documentation site. Track C is largely independent of the remaining
Phase A work and documents the current state of the API honestly (routing,
impersonation, notifications, telemetry and the high-level `execute_query` are
not yet implemented).

- **Phase C0 — user-facing API** (prerequisite for the docs): replace the
  placeholder `Driver` with a real entry point:
  `Neodriver_eio.Driver.connect ~uri ~auth ?user_agent ?connection_timeout ?config net clock sw
  -> (Session.t, Errors.t) result` (parses the URI, builds the `Conn.config`, wires the Eio
  resources into a ready `Session`, rejects `neo4j://` until routing exists), plus
  `Conn.basic_auth ?principal ?credentials ()` and extending the `Neodriver` aggregator with
  `Conn`/`Session`/`Tx`/`Transport`/`Bolt`/`State` aliases so `open Neodriver` covers the whole API.
  **Done** (commit "step C0"): `Driver.connect` parses the URI via `Addressing.parse_uri` (errors
  returned as `Configuration_error`), builds `Conn.config` (`?connection_timeout` default 30.0,
  `?user_agent` default `Conn.default_user_agent`) and a `Session.config` (`?config`, base
  `Session.default_config`) and returns a lazily connecting `Session.t` (no pool; one session per
  driver). `neo4j://` is **not** rejected eagerly — it fails on first use from `Conn.connect`
  (`Service_unavailable "Routing (neo4j://) is not supported yet"`). `Conn.basic_auth` defaults to
  principal `neo4j` / empty credentials. The `Neodriver` aggregator now re-exports
  `Conn`/`Session`/`Tx`/`Transport`/`Bolt`/`State` (plus `Neo4jResult`/`Summary`/`Driver`). Unit
  tested (`test_driver.ml`: basic_auth, bad URI, lazy neo4j:// rejection, connect+run on the mock,
  session config flowing into the RUN extra); TestKit unchanged (OK, 7 skipped).
- **Phase C1 — API documentation (odoc)**: audit all `.mli` files (public declarations must carry
  a doc comment) and document the new API; add odoc index pages (a top-level `index.mld` and one
  per package) so `dune build @doc` produces a browsable site with a landing page; keep
  `dune build @doc` clean (the CI already runs it on every push). **Done** (commit "step C1"): every
  `.mli` header comment is now an odoc module doc (`(** ... *)`), the previously undocumented
  `Summary` types (`counters`/`server_info`/`t`) carry doc comments, and the stale `Driver`
  description in `neodriver_eio.mli` is refreshed. Per-package `index.mld` landing pages (wired with
  `(documentation (package ...))` stanzas) were added: the `neodriver` page is the project landing
  with a quickstart (`Driver.connect` + `Session.run`) and links to every module; `core`/`eio`/
  `packstream` pages list their modules. Note: dune auto-generates the top-level `index.html`
  (package list), so the project landing page lives in the `neodriver` package index rather than a
  root `index.mld` (dune has no hook for the top-level page). `dune build @doc` is warning-free.
- **Phase C2 — quickstart** (`docs/quickstart.md`): adding the driver as a dependency (opam
  `opam install neodriver neodriver_eio`, pinning for local development; dune
  `(libraries neodriver neodriver_eio eio_main)`), plus a minimal program: connect with
  `Driver.connect` and run a simple `RETURN` query. **Done** (commit "step C2"):
  `docs/quickstart.md` covers prerequisites, adding the dependency (opam install, local pinning,
  the `dune` stanza), a minimal `hello.ml` (connect + `RETURN 1 AS n`, validated to compile) and
  explains the lazy session, `Conn.basic_auth`, `Neo4jResult.values`/`consume`, the `sw` switch
  lifetime and the unsupported `neo4j://`. The README links to the quickstart.
- **Phase C3 — usage documentation** (`docs/usage.md`): the packages and what to open; connecting
  (`Conn.config`, the TLS schemes `bolt://` / `bolt+s` / `bolt+ssc`, `neo4j://` not yet supported);
  sessions (`Session.run`, access modes, bookmarks); explicit transactions (`Tx`) and managed
  transactions (`Session.execute` with retry and `max_transaction_retry_time`); authentication
  (basic only; LOGON vs inline auth by Bolt version); the `Values`/`Temporal`/`Hydration` types;
  error handling (`Errors.t`, `is_retryable`); configuration (timeouts, retry, fetch size); and an
  honest "not yet implemented" list. **Done** (commit "step C3"): `docs/usage.md` covers what to
  open (`open Neodriver`), connecting (schemes/TLS, `neo4j://` unsupported, lazy session), sessions
  (`Session.run`, bookmarks), explicit and managed transactions (with the `Session.conn`/`Conn.hydration`
  pattern and a data-return-via-ref example), authentication (LOGON vs inline HELLO), value types,
  error handling, configuration (with the honest note that `fetch_size` is not yet applied and the
  pool is unimplemented) and a "not yet implemented" list. The three main snippets were validated to
  compile. Links to `examples/` (created in C4) and the usage page.
- **Phase C4 — example programs** (`examples/`, modelled on
  `neo4j-examples/python-driver-examples`): a shared `common.ml` (env config `NEO4J_URI`/
  `NEO4J_USER`/`NEO4J_PASSWORD` + an `Eio_main` wrapper) and self-contained programs — `connect.ml`,
  `run_cypher.ml`, `create.ml`, `transaction.ml` (explicit Tx), `managed_transaction.ml`
  (managed + bookmarks) — built inside the workspace (compiled by `dune build`, run via
  `dune exec`), each described in `examples/README.md`. **Done** (commit "step C4"): `examples/`
  has a shared `common.ml` (env config with defaults `bolt://localhost:7687`/`neo4j`/empty password,
  an `Eio_main` wrapper with `Session.close`, a `hydration` helper and a minimal CSV reader) and
  five programs. `create.ml` mirrors the Python `create_data` example: it reads
  `examples/data/employees.csv` (vendored from the reference) and issues one `MERGE` per row
  building `Person`/`Company`/`Location` with `WORKS_AT`/`LIVES_IN`. All five were built by `dune
  build` and **run against a live Neo4j** (`integration.sh up`), printing the server info, the
  created-node counters, the joined rows, the committed transaction and the managed-transaction
  bookmarks. `examples/README.md` documents each program.
- **Phase C5 — GitHub Pages + automatic documentation**: a `deploy-docs.yml` workflow that builds
  `@doc` on `main` and publishes `_build/default/_doc/_html/` through the Pages artifact API
  (`actions/configure-pages` / `upload-pages-artifact` / `deploy-pages`). Requires the repository
  setting Pages → Source = "Deploy from a GitHub Actions" (a manual repo setting, not a file).
  The existing `ci.yml` keeps verifying `dune build @doc` on every push/PR. The `neodriver`
  package landing page (`index.mld`) links to the quickstart via the GitHub blob URL — **to be
  re-pointed at the GitHub Pages docs site once C5 deploys it**. **Done** (commit "step C5"):
  `.github/workflows/deploy-docs.yml` builds `@doc` on pushes to `main` (plus manual dispatch) with
  `ocaml/setup-ocaml` + `opam install . --deps-only` + `odoc`, stages the site (`.nojekyll`, plus
  `docs/*.md` copied under `docs/`) and deploys via `actions/configure-pages@v5`,
   `upload-pages-artifact@v3` and `deploy-pages@v4` (two jobs: build + deploy with the
   `github-pages` environment). The only remaining step is the
   manual repository setting Pages → Source = "Deploy from a GitHub Actions".

- **Release prep (opam + docs site)**: the four `*.opam` files pass `opam lint` with a proper
  maintainer, `homepage`, `doc` (the Pages site), `bug-reports`, `dev-repo` and license; the
  `dune-project` dependencies were cleaned up (unused `fmt`/`logs` dropped from `neodriver_core`,
  `cstruct` added to `neodriver_eio`, the doubled `dune` constraint resolved). The odoc site now
  has rendered `quickstart`/`usage` pages (odoc `.mld`, converted from `docs/*.md`, tables as
  lists) linked from the `neodriver` landing page, which was enriched with the README content
  (features, packages, docs links, TestKit note); the top-level `index.html` (which dune hardcodes
  as a package list) is replaced at deploy time by a meta-refresh redirect to the `neodriver`
  landing, so the Pages homepage shows the README-derived content.

- **Phase C6 — README polish**: restructure `README.md` into badges (CI, docs), prerequisites,
  a quickstart snippet linking to `docs/quickstart.md`, documentation/examples links, an honest
  features/status section (what works vs. planned, pointing at `PLAN.md`), the TestKit conformance
  note and the license. **Done** (commit "step C6"): `README.md` now has CI / docs / OCaml / license
  badges, a compiled-and-checked quickstart snippet linking to `docs/quickstart.md`, a features
  section (Bolt 3.0 / 4.2-4.4 / 5.0-5.8 / 6.0, TLS schemes, lazy streaming results, explicit and
  managed transactions, bookmarks, named-zone temporal types, basic auth; a not-yet-implemented
  list pointing at `PLAN.md`), the four-package table (including the `neodriver` aggregator),
  documentation/examples links (quickstart, usage, examples, the Pages API reference), the TestKit
  conformance note (119/126, 7 skipped), the corrected prerequisites (OCaml >= 5.2, dune >= 3.13)
  and the MIT license. The original reference-implementation paragraph is kept.

---

## Risks and open decisions

1. **Maturity of `tls-eio`** (in Phase A2) — the most serious risk. Decision: check its state; if problematic, use `ocaml-tls` with a custom adapter or defer TLS behind the rest of the transport (MVP on `bolt://`).
2. **Package names**: the opam name `neo4j_bolt` is already published (reference repo), so this project uses the `neodriver_*` prefix (`neodriver_packstream`, `neodriver_core`, `neodriver_eio`).
3. **Version coverage**: design for Bolt 3–6 from the start (state machine + feature gates), but the MVP in Phase A3 may only support 4.4/5.x, with the rest added iteratively.
