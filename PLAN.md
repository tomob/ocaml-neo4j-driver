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
- Per-version feature gates: `supports_multiple_results`, `supports_multiple_databases`, `supports_re_auth`, `supports_notification_filtering`, `supports_ssr`, `supports_telemetry` → a `capabilities` variant. **Done** (commit "step A3-4"): `capabilities.ml` (pure — `Capabilities.of_version` with the Python-driver thresholds: multiple results/databases 4.0+, re-auth 5.1+, notification filtering 5.2+, ROUTE (ssr) 4.3+, TELEMETRY 5.4+); `conn.ml` uses it instead of the ad-hoc `supports_re_auth` and exposes `Conn.capabilities`. Unit-tested (`test_capabilities`).
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

- **`result.ml`**: lazy streaming (in Eio: direct iteration), `consume/single/fetch/peek/value(s)/data`, states `_attached/_streaming/_exhausted`, semantics after transaction close. Backend: `ResultSingle`/`ResultSingleOptional`.
- **`summary.ml`**: `SummaryCounters`, `plan/profile`, `query_type`, `result_available_after/consumed_after` (`t_first/t_last`), **`gql_status_objects`** polyfilled from legacy notifications, `ServerInfo` (address/agent/protocol_version).

### Phase A6 — Pool

- `pool.ml`: address→queue mapping + reservation counter, `max_connection_pool_size`, waiting on `Eio.Semaphore`/mutex+cond with `connection_acquisition_timeout`, release with RESET (or kill for defunct), **liveness check**, `max_connection_lifetime`/`stale`, `deactivate`, **`IncompleteCommit`** (ambiguous commit).

### Phase A7 — Routing + home db + SSR

- **ROUTE** (`0x66`) with routing_context/bookmarks/db; fallback to the procedures `dbms.routing.getRoutingTable` (Bolt 4.0) and `dbms.cluster.routing.getRoutingTable` (Bolt 3).
- `routing_table.ml` per database: `routers/readers/writers` + TTL + `is_fresh`, refresh under lock, "initial address first" rediscovery, **load balancing** on the least-loaded address.
- Error reactions: `ServiceUnavailable/DatabaseUnavailable → deactivate`; `NotALeader/ForbiddenOnReadOnlyDatabase → remove writer`.
- Home db cache (TTL, keyed by `impersonated_user`/token), `ssr.enabled` hint, pinning after the first result, fallback when SSR is unavailable.

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

---

## Risks and open decisions

1. **Maturity of `tls-eio`** (in Phase A2) — the most serious risk. Decision: check its state; if problematic, use `ocaml-tls` with a custom adapter or defer TLS behind the rest of the transport (MVP on `bolt://`).
2. **Package names**: the opam name `neo4j_bolt` is already published (reference repo), so this project uses the `neodriver_*` prefix (`neodriver_packstream`, `neodriver_core`, `neodriver_eio`).
3. **Version coverage**: design for Bolt 3–6 from the start (state machine + feature gates), but the MVP in Phase A3 may only support 4.4/5.x, with the rest added iteratively.
