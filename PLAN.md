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
- Repo initialization: `dune-project` (lang 3.13+, `ocaml >= 5.0`), opam packages (`neodriver_packstream`, `neodriver_core`, `neodriver_eio`, `neodriver`; later `neodriver_lwt`), CI (OCaml 5.0–5.4 matrix, `ocamlformat` lint). **Done** (commit "step A0-1").
- **`errors.ml`** (modeled on `exceptions.py`): type
  `type error = ...` with constructors for client errors (`ClientError`, `TransientError`, `DatabaseError`, `ServiceUnavailable`, `SessionExpired`, `PoolTimeout`, ...) and `of_neo4j_code : code:string -> message:string -> t`. This is the anchor for retry/deactivation/re-auth. Includes the `classification`/`specific` sub-types, the `_ERROR_REWRITE_MAP` port, `is_retryable`, `unauthenticates_all_connections`, `has_security_code` and `is_fatal_during_discovery`. **Done** (commit "step A0-2").
- **`config.ml`**: records with defaults `{connection_acquisition_timeout=60.; max_transaction_retry_time=30.; initial_retry_delay=1.; retry_delay_multiplier=2.; retry_delay_jitter_factor=0.2; fetch_size=1000; max_pool_size=100; max_connection_lifetime=3600; ...}` plus validated `make_*` constructors returning `(t, Errors.t) result`. **Done** (commit "step A0-2").
- **`addressing.ml`**: `Address` + `parse_uri` (extended with `neo4j://`, `+s/+ssc`, routing context from the query string), default ports, `ResolvedAddress` carrying the unresolved host (for SNI). Returns `result`; includes percent-decoding of the routing context. **Done** (commit "step A0-3").
- **Deadline**: `deadline.ml` (monotonic via Mtime + min-timeout) — one unified timing mechanism. **Done** (commit "step A0-3").

### Phase A1 — PackStream + hydration (port of reference, improvements)
- Port `packstream.ml` → `neo4j_packstream` with fixes: marker validation → `ProtocolError` instead of `failwith`, bounds, a safe `unpack` with depth/size limits.
- **`values.ml` + `hydration.ml`** (modeled on `_codec/hydration/`):
  - tag descriptors: `N/R/r/P` → Node/Rel/Path; `X/Y` → Point (SRID 4326/4979/7203/9157); `D/T/t/F/f/d` → Date/Time/DateTime; `I/i` (UTC, Bolt 5.2+); `E` → Duration; `V` → Vector; `?` → UnsupportedType.
  - Node deduplication by `element_id` per result (per-query graph), like `_GraphHydrator`.
  - value types: `Date/Time/DateTime/Duration` on nanoseconds + ISO-8601 + conversion to/from `Ptime`; `Point` with SRID registry; `Vector` (big-endian bytes).
  - a `Broken` variant (analog of `BrokenHydrationObject`) propagated through records.

### Phase A2 — Eio transport + handshake + TLS
- **`transport_eio.ml`**: `Eio.Net` + fibers, `SO_KEEPALIVE`, reads/writes with deadlines, 16 KiB chunks + `0x0000`, coalescing.
- **Handshake**: v1 (proposing Bolt 3/4/5) **and manifest `0xFF`** (Bolt 5.4+ and 6.0/6.1) — selecting the highest supported version within the server's range; negotiation in `handshake.ml`.
- **TLS via `tls-eio`**: trust modes (system CAs / custom CAs / TrustAll), **hostname verification + SNI from the unresolved host**, TLS ≥ 1.2, mTLS with client certificate. ⚠️ **Risk**: maturity of `tls-eio` — verify in Phase A2; fallback: `ocaml-tls` with a custom Eio adapter, or temporarily `ssl`/`lwt_ssl` for the Lwt flavor.
- **Address iteration**: `getaddrinfo`, trying all addresses (IPv4+IPv6), error aggregation (the `ExceptionGroup` equivalent — in OCaml a chained record `{last; all}`), timeouts clamped to the deadline.

### Phase A3 — Single connection: HELLO, auth, state machine
- HELLO with `user_agent`/`bolt_agent`/`routing`; inline auth (≤5.0) and **`LOGON/LOGOFF`** (≥5.1).
- **State machine** (`state.ml`): `CONNECTED/READY/STREAMING/TX_READY|TX_STREAMING/FAILED/AUTHENTICATION`, `IGNORED` handling, **automatic RESET after FAILURE**.
- **RUN/PULL/DISCARD**: streaming PULL with `fetch_size` and `has_more`, `DISCARD` of the remainder, `qid` (multiple results).
- Per-version feature gates: `supports_multiple_results`, `supports_multiple_databases`, `supports_re_auth`, `supports_notification_filtering`, `supports_ssr`, `supports_telemetry` → a `capabilities` variant.
- **Re-auth on a connection** (LOGON/LOGOFF when the token changes) — integration point for the pool.

### Phase A4 — Result + summary + notifications
- **`result.ml`**: lazy streaming (in Eio: direct iteration), `consume/single/fetch/peek/value(s)/data`, states `_attached/_streaming/_exhausted`, semantics after transaction close.
- **`summary.ml`**: `SummaryCounters`, `plan/profile`, `query_type`, `result_available_after/consumed_after` (`t_first/t_last`), **`gql_status_objects`** polyfilled from legacy notifications, `ServerInfo` (address/agent/protocol_version).

### Phase A5 — Sessions and transactions + retry
- `session.ml`: `run` (auto-commit) with `database`, `impersonated_user`, `access_mode`, timeouts, notification filters, bookmarks; auto-commit retry (1 attempt) unless `disable_auto_commit_retries`.
- `tx.ml`: `begin_transaction/commit/rollback/close`, context-manager semantics, consumption of pending results, bookmark capture from COMMIT metadata.
- **Managed transactions**: `execute_read/execute_write` + `unit_of_work` — retry loop within the `max_transaction_retry_time` budget, jittered backoff, decision via `error.retryable`, fresh connection between attempts, `TX_FUNC` telemetry once.
- **⚠️ Checkpoint**: after A5 we have a full, correctly streaming single-connection client — the best first release.

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

## TRACK B — TestKit (parallel, from Phase A0)

- **Phase B0**: `testkitbackend/` scaffold — a JSON-over-stdio server in Eio (`Eio.Flow`), handling the TestKit commands `Start`/`Stop` + `NewDriver`/`CloseDriver` + simple `SessionRun`/`ResultNext`. Install testkit dependencies (`neo4j-drivers/testkit`@`6.x`).
- **Phases B1–B5**: extending command coverage as the API matures: types (Bolt/Node/Relationship/Path/Point/Temporal/Vector), transactions (RetryablePositive/Negative, TxBegin/Commit/Rollback), sessions (`SessionBeginTransaction`, `SessionLastBookmarks`, access mode), routing (`NewDriver` with `neo4j://`, `DriverSession`...).
- **Phase B10**: full conformance (the full testkit suite on a server matrix 4.x/5.x/6.x) + CI running the backend in containers.

**Principle**: the TestKit backend translates commands onto the **public library API** → forces API surface stability from the start. TestKit feature gating (the `test_subtest_skips.ml` analog) lets conformance be enabled gradually, phase by phase.

---

## Risks and open decisions

1. **Maturity of `tls-eio`** (in Phase A2) — the most serious risk. Decision: check its state; if problematic, use `ocaml-tls` with a custom adapter or defer TLS behind the rest of the transport (MVP on `bolt://`).
2. **Package names**: the opam name `neo4j_bolt` is already published (reference repo), so this project uses the `neodriver_*` prefix (`neodriver_packstream`, `neodriver_core`, `neodriver_eio`).
3. **Version coverage**: design for Bolt 3–6 from the start (state machine + feature gates), but the MVP in Phase A3 may only support 4.4/5.x, with the rest added iteratively.
