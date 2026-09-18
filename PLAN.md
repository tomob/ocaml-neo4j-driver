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

### Phase A9 — High-level API — Partially done
Done: `Driver.verify_authentication`, TELEMETRY telemetry, notification filtering, impersonation
(auto-commit and transactions), idempotent auto-commit retries, `disable_auto_commit_retries`.

Remaining (library surface only — the logic already lives in `testkitbackend/commands.ml`):
- `Driver.execute_query` + `EagerResult` (keys/records/summary).
- `Driver.verify_connectivity`.
- `Driver.supports_multi_db`.
- `warn_notification_severity` (warnings at the calling-code level) — not implemented anywhere yet.

### Phase A10 — TLS trust options (T1 done, T2-T6 planned)
The `tests.tls` cases that still skip today: custom CA trust anchors, mTLS client certificates
(single, rotation/provider and password-protected keys) and the explicit
`encryption`/`trusted_certificates` security config.

**Library surface**
- `Tls_client` gains a rich `trust` (`System | Trust_all | Custom of X509.Certificate.t list`) and an
  optional client certificate (`{ chain; key }` behind a `unit -> client_certificate` provider, so the
  certificate is fetched per handshake and rotation works). `wrap` builds the authenticator from the
  trust (System → `Ca_certs.authenticator ()`, Trust_all → accept-all, Custom →
  `X509.Authenticator.chain_of_trust ~time:(Ptime_clock.now) certs`) and passes the client
  certificate to `Tls.Config.client` (the `Single` variant carrying chain + key).
- `Transport.tls_mode` (`Plain | Secure of Tls_client.config`) carries the trust and the optional
  client certificate; `Conn.config` gains `encryption : Config.encryption`,
  `trusted_certificates : Config.trusted_certificates option` and
  `client_certificate : client_certificate option`.
- `Config.pool_config` (or a sibling security record) carries the same fields, validated by
  `make_pool_config`. `Conn.tls_of_config` resolves the effective mode: scheme default (`bolt`/`neo4j`
  plain, `+s` system CAs, `+ssc` trust all), overridden by `encryption` (`Default | Enabled | Disabled`)
  and `trusted_certificates`. Any explicit config with a `+s`/`+ssc` scheme, or `Disabled` with custom
  CAs, is a `Configuration_error` mentioning "encryption"/"trust".
- `Driver.connect` takes `?encryption`, `?trusted_certificates`, `?client_certificate`; `Driver.t`
  stores the resolved `encrypted` flag and `Driver.is_encrypted : t -> bool` reports it (TestKit
  `CheckDriverIsEncrypted`). `Detail:ClosedDriverIsEncrypted` later, by keeping the record after
  `close`.

**Encrypted private keys — local helper.** `x509` does not support encrypted keys at all
(`Private_key.decode_pem` has no password; the changelog says "PKCS8 … only unencrypted keys so far",
unchanged through 1.2.0), and the testkit fixtures are legacy OpenSSL PEM (`Proc-Type: 4,ENCRYPTED`,
`DEK-Info: AES-256-CBC,<iv>`). A small local helper decrypts them: `EVP_BytesToKey(MD5, password,
salt = iv[0..7], 1)` → key/IV, AES-256-CBC decrypt (`mirage-crypto`), then
`X509.Private_key.decode_pem` on the resulting `RSA PRIVATE KEY` PEM. `mirage-crypto` (+ `digestif`)
are already in the `tls-eio` dependency closure, so no new runtime dependency.

**TestKit backend**
- `NewDriver` parses `encrypted`, `trustedCertificates` (`None` = system / `[]` = trust all /
  `[paths]` = custom) and `clientCertificate` (`{certfile,keyfile,password}`) or a
  `clientCertificateProviderId`; relative certificate paths resolve against `TESTKIT_TLS_CERTS_DIR`
  (set by `testkit_tls.sh`) instead of relying on the driver CWD.
- Client-certificate provider: `NewClientCertificateProvider` / `ClientCertificateProviderClose`
  commands and the `ClientCertificateProviderRequest`/`Completed` round-trip (mirror the auth-token
  managers); a `has_update = false` reply reuses the cached certificate.
- `CheckDriverIsEncrypted` → `DriverIsEncrypted { encrypted }` via `Driver.is_encrypted`.
- Features: `Feature:API:SSLConfig`, `Feature:API:SSLClientCertificate`,
  `Feature:API:Driver:IsEncrypted`.
- Harness patch: `tests/tls/test_explicit_options.py` hard-fails for any driver not in
  `["javascript","java","dotnet"]`; add `"ocaml"` with the expected "encryption"/"trust" message
  substrings (same practice as the existing `ocaml` mappings in the testkit checkout).

**Order of work** (each step unlocks tests, verifiable with `scripts/testkit_tls.sh`)
1. **T1 — explicit security config + `is_encrypted`** — **Done**: `Tls_client.trust`
   (`System | Trust_all | Custom`), `Transport.tls_mode` (`Plain | Secure of Tls_client.config`),
   `Conn.config` fields + `Conn.tls_of_config` (scheme default, explicit `encryption`/
   `trusted_certificates` overrides with custom-CA PEM loading, conflict validation like the Python
   driver), `Driver.connect ?encryption ?trusted_certificates`, `Driver.is_encrypted`, the TestKit
   `CheckDriverIsEncrypted` command and `Feature:API:Driver.IsEncrypted`. Unit tests cover the
   scheme defaults, the overrides, the conflicts and the CA loading; `scripts/testkit_tls.sh` now
   executes the `is_encrypted` tests (25 skips, was 31). The trust-config tests stay skipped until
   `Feature:API:SSLConfig` is advertised (T5).
2. **T2 — custom CA files**: load PEM bundles (`X509.Certificate.decode_pem_multiple`) into
   `Trust_custom`; unit-test accept/reject. Unlocks `TestTrustCustomCertsConfig`.
3. **T3 — client certificates (plain key)**: mTLS handshake, present/absent cases.
4. **T4 — encrypted private keys**: the local legacy-PEM helper (`pem_key.ml`). Completes
   `test_s_and_client_certificate_present` / `test_ssc_and_client_certificate_present`.
5. **T5 — TestKit plumbing**: provider commands, the `TESTKIT_TLS_CERTS_DIR` cert-path plumbing,
   advertise `Feature:API:SSLConfig` (which activates `TestTrustSystemCertsConfig`,
   `TestTrustAllCertsConfig`, `test_secure_server_explicitly_disabled_encryption` and
   `test_explicit_options`), the harness patch, `testkit_tls.sh` envs/mounts. Completes the
   provider/rotation and explicit tests.
6. **T6 — docs + CI**: `README.md`, `usage.mld`/`docs/usage.md`, `scripts/README.md`, and
   `testkit_tls.sh` reporting the fully executed TLS suite.

**Risks**
- The legacy-PEM decryption is the only non-trivial crypto work; it is well specified (EVP_BytesToKey
  MD5 + AES-CBC) and unit-testable against the committed testkit fixtures. Keeping it local avoids an
  `x509` API dependency (upstream has no encrypted-key support).
- Relative `trusted_certificates` paths depend on the testkit driver CWD; pin them with
  `TESTKIT_TLS_CERTS_DIR`.
- `test_explicit_options` needs the harness patch; without it the test fails for `ocaml` by design.

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
  `Feature:API:SSLSchemes` + `Feature:TLS:1.2`/`1.3` and the script adds the testkit root CA via
  `OCAML_EXTRA_CA_CERTS`. Custom-CA (`API:SSLConfig`) and client-certificate
  (`API:SSLClientCertificate`) tests still skip; they are Phase A10.

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

1. **Phase A9** — expose `execute_query`/`EagerResult`, `verify_connectivity`, `supports_multi_db`
   and `warn_notification_severity` in the public library API.
2. **Phase A10 (TLS)** — custom CA trust anchors, mTLS client certificates (incl. password-protected
   keys) and the explicit `encryption`/`trusted_certificates` config (T1 done).
3. **Config wiring** — `connection_write_timeout`, `keep_alive` (and `pool_config.connection_timeout`).
4. **`neodriver_lwt` / `lib/lwt`** — second backend (the `transport.mli` interface is ready).
5. **B10** — TestKit CI job + server-version matrix.
6. **C5** — manual GitHub Pages repository setting.
7. **Docs drift** — `README.md`, `docs/usage.md` and `lib/neodriver/usage.mld` still list done
   features as "not yet implemented" (notification filtering, telemetry, auto-commit impersonation,
   `fetch_size`, wired `connection_timeout`, `neo4j://`).

## Risks and open decisions

1. **`tls-eio` maturity** — resolved: 2.0.4 is usable (needs `Mirage_crypto_rng_unix.use_default ()`).
2. **Package names** — `neo4j_bolt` is taken by the reference repo; this project uses the
   `neodriver_*` prefix.
3. **Version coverage** — design for Bolt 3–6 (state machine + feature gates); all target versions
   (3.0, 4.2–4.4, 5.0–5.8, 6.0–6.1) are implemented.
