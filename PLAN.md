# Neo4j OCaml Driver — Implementation Plan

Plan for a pure OCaml Neo4j client library (full cluster driver), built as a **new project** using
[ocaml-neo4j-bolt](https://github.com/jeong-sik/ocaml-neo4j-bolt) as a reference (MIT) and modelled
on the architecture of the Neo4j Python driver.

## Established decisions

- **New project** → clean architecture; port the clean `packstream.ml` (MIT) and fix it (marker
  validation, error handling).
- **Eio-first** → core logic in **direct style** (no monads); a narrow `transport.mli` so Lwt can be
  a second adapter later.
- **Full cluster driver** → a correct single client first, then cluster reliability.
- **TestKit from the start** → a separate parallel track (Track B) that forces early public API
  stability.

## Project structure (dune/opam)

```
ocaml-neo4j-driver/
  lib/packstream/    neodriver_packstream — pure, no dependencies
  lib/core/          neodriver_core — errors, config, addressing, hydration, values,
                     state, summary, auth/bookmark managers, routing table
  lib/eio/           neodriver_eio — transport, handshake, TLS, conn, bolt, tx,
                     session, pool, cluster, result, summary, driver
  lib/neodriver/     neodriver — friendly aggregator (open Neodriver)
  lib/lwt/           (later) neodriver_lwt
  testkitbackend/    Track B — TestKit JSON backend
  test/              alcotest per module (+ test/test_integration/)
  examples/  docs/  scripts/  benchmarks/
```

---

## TRACK A — Library core

### Phase A0 — Foundations — Done
`errors.ml` (taxonomy, `is_retryable`, `_ERROR_REWRITE_MAP` port), `config.ml` (validated builders
and defaults), `addressing.ml` (`bolt://`/`neo4j://` + `+s`/`+ssc`, routing context, percent
decoding), `deadline.ml` (monotonic, min-timeout).

### Phase A1 — PackStream + hydration — Done
Ported `packstream.ml` (marker validation → `ProtocolError`, bounds, depth/size limits); `values.ml`
(Node/Rel/Path/Point/Vector/UUID/Unsupported/Broken), `hydration.ml` (per-version tags, per-query
graph dedup, `Broken` propagation), `temporal.ml` (Date/Time/DateTime/Duration, named zones).

### Phase A2 — Eio transport + handshake + TLS — Done
TCP transport with deadlines, chunk framing + NOOP skip, coalescing; handshake v1 + manifest `0xFF`
(highest common version); TLS `bolt+s://` (system CAs + hostname verification + SNI) and
`bolt+ssc://` (TrustAll); `getaddrinfo` address iteration with aggregated connect errors.
Deferred: custom CA trust anchors and mTLS client certificates (`tls_client.ml`); `SO_KEEPALIVE`
(not exposed by Eio's portable `Net` API).

### Phase A3 — Single connection — Done
HELLO/LOGON/LOGOFF (inline auth ≤ 5.0, LOGON/LOGOFF ≥ 5.1, `bolt_agent` ≥ 5.3), server state
machine with automatic RESET after FAILURE/IGNORED, RUN/PULL/DISCARD streaming (`fetch_size`,
`has_more`, `qid`), per-version `Capabilities`, connection re-auth (`re_auth`/`mark_unauthenticated`).

### Phase A5 — Sessions and transactions + retry — Done
`tx.ml` (explicit transactions with `Open`/`Failed`/`Closed`), `session.ml` (auto-commit + managed
transactions with the jittered retry budget), bookmarks captured from COMMIT/PULL summaries.

### Phase A4 — Result + summary + notifications — Done
`neo4j_result.ml` (lazy streaming: `next`/`peek`/`fetch`/`values`/`data`/`consume`/`single`),
`summary.ml` (counters, plan/profile, query type, `t_first`/`t_last`, GQL status objects, server
info), notification filtering.

### Phase A6 — Pool — Done
Bounded single-address pool (`Eio.Semaphore`, FIFO idle queue, acquisition timeout,
lifetime/liveness checks, release with RESET), `IncompleteCommit`, pool-backed `Driver`.

### Phase A6.5 — Vector + UUID — Done
`Values.Vector` (dtype marker is a single BYTES byte) and `Values.Uuid` (marker `0xE0`, 16 BE bytes,
Bolt 6.1); TestKit features + Cypher encode/decode. Multi-db tests still need an enterprise server
(server limitation, not driver code).

### Phase A7 — Routing + home db + SSR — Done
ROUTE (`0x66`) with the procedure fallback for Bolt 3 / 4.0–4.2; `routing_table.ml`; `cluster.ml`
(per-database tables with TTL, per-address pools, least-loaded selection, address deactivation,
negative cache, single-flight fetches); SSR (routing context in HELLO, `rt` in RUN responses);
home-db cache (keyed by impersonated user, `home_db_cache_ttl`); routed-only guessed-database
pinning; TestKit `Backend:RTFetch`/`RTForceUpdate`.

### Phase A8 — Auth management — Done
`Auth_manager` (static/basic/bearer over `ExpiringAuth`), pool/cluster re-auth on rotation,
`AuthorizationExpired` mark-all, session-level auth (user switching, Bolt ≥ 5.1), TestKit
auth-token managers + `Feature:Auth:Managed`; `Backend:MockTime` fake-time providers.

### Phase A8 — Bookmarks — Done
`Bookmarks` (immutable, first-seen-order set) and `Bookmark_manager` (built-in + custom); sessions
seed RUN/BEGIN/ROUTE from the manager and hand the committed bookmark back; TestKit
`NewBookmarkManager`.

### Phase A9 — High-level API — Done
`Driver.execute_query` (+ `EagerResult` keys/records/summary), `Driver.verify_connectivity` and
`Driver.supports_multi_db`, backed by the driver's implicit `execute_query_bookmark_manager`; the
TestKit backend now calls these instead of re-implementing them. `warn_notification_severity` (the
Python driver's native-warning emission) is intentionally not implemented in OCaml — there is no
equivalent `warnings` mechanism; notifications are available on `Summary.notifications` and logged
through `Log.notifications`. Also done here: `Driver.verify_authentication`, TELEMETRY telemetry,
notification filtering, impersonation (auto-commit and transactions), idempotent auto-commit
retries, `disable_auto_commit_retries`.

### Phase A10 — TLS trust options — Done
Custom CA trust anchors, the explicit `encryption`/`trusted_certificates` security config and mTLS
client certificates (including password-protected legacy-OpenSSL-PEM keys via the local `Pem_key`
helper, and rotation through a `client_certificate_provider`). The backend reports
`Feature:API:SSLConfig`, `Feature:API:SSLClientCertificate` and `Feature:API:Driver:IsEncrypted`,
and `scripts/testkit_tls.sh` runs the whole `tests.tls` suite green (43 tests, 0 skips).

---

## TRACK B — TestKit

JSON-over-TCP backend translating commands onto the **public library API**.

- **B0a scaffold / B0b query path** — Done (TCP server, driver/session lifecycle, RUN/PULL, result
  iteration, summary, custom resolver, features).
- **B1–B5 command coverage** — Done (transactions + retry protocol, sessions, routing, auth-token /
  bookmark / fake-time managers).
- **B10 full conformance** — **Remaining**: server matrix (Bolt 4.x/5.x/6.x) and a CI job running the
  backend in containers (`ci.yml` currently only builds/tests/docs).
- **B11 all `tests.stub.*` green** — Done (59 modules, 0 failures, 0 errors).
- **TLS suites** — `scripts/testkit_tls.sh` runs `tests.tls.*` (Go TLS server, host or container
  backend) and `run_all_tests.sh --tls` adds the phase; the backend reports
  `Feature:API:SSLSchemes` + `Feature:API:SSLConfig` + `Feature:API:SSLClientCertificate` +
  `Feature:TLS:1.2`/`1.3` and the script adds the testkit root CA via `OCAML_EXTRA_CA_CERTS`. The
  whole TLS suite is green (**0 skips**, 43 tests).

Current real-server state: `OK (skipped=7)` on community (3 vector + 4 multi-db),
`OK (skipped=4)` with `NEO4J_EDITION=aura`.

---

## TRACK C — Documentation and developer enablement

- **C0 user-facing API** (`Driver.connect`, `Conn.basic_auth`, aggregator aliases) — Done.
- **C1 API documentation (odoc, per-package index pages, `dune build @doc` clean)** — Done.
- **C2 quickstart** (`docs/quickstart.md`) — Done.
- **C3 usage documentation** (`docs/usage.md`) — Done.
- **C4 example programs** (`examples/`) — Done.
- **C5 GitHub Pages + auto docs** (`deploy-docs.yml`) — Done; the only remaining step is the manual
  repository setting Pages → Source = "Deploy from a GitHub Actions".
- **C6 README polish** — Done.
- **C7 logging (Python parity, `NEO4J_LOG_LEVEL`/`NEO4J_LOG_SCOPES`)** — Done.
- **Release prep** (opam lint, docs site) — Done.

---

## Remaining work (summary)

1. **Phase A10 (TLS)** — done: custom CA trust anchors, the explicit
   `encryption`/`trusted_certificates` config, mTLS client certificates (incl. password-protected
   keys and rotation) and the fully-green `tests.tls` suite.
2. **Config wiring** — `connection_write_timeout`, `keep_alive` (and `pool_config.connection_timeout`).
3. **`neodriver_lwt` / `lib/lwt`** — second backend (the `transport.mli` interface is ready).
4. **B10** — TestKit CI job + server-version matrix.
5. **C5** — manual GitHub Pages repository setting.

## Risks and open decisions

1. **`tls-eio` maturity** — resolved: 2.0.4 is usable (needs `Mirage_crypto_rng_unix.use_default ()`).
2. **Package names** — `neo4j_bolt` is taken by the reference repo; this project uses the
   `neodriver_*` prefix.
3. **Version coverage** — design for Bolt 3–6 (state machine + feature gates); all target versions
   (3.0, 4.2–4.4, 5.0–5.8, 6.0–6.1) are implemented.
