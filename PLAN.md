# Neo4j OCaml Driver — Audit Plan

Actionable plan for the `ocaml-neo4j-driver` packages, derived from the ponytail audit
of 2026-10-09. It replaces the earlier phase-based roadmap; that history is in the git
log.

Assumed load: an application or agent talking to one Neo4j server or cluster, a single
Eio domain, a handful of concurrent users within the process.

Priorities:
- **Must fix** — correctness or security; can break, or be abused, at the expected load.
- **Should fix** — a real risk, a missing test, or code that should not exist.
- **Nice to have** — small correctness, robustness and clean-up wins.

Each item states the concrete problem, the fix and how to verify it.

---

## Must fix

### 1. Bound the Bolt manifest handshake count — `lib/eio/handshake.ml` — done

**Done.** `negotiate_manifest` rejects a `count` above `max_offerings` (64) with
`Service_unavailable`, and `read_varint` errors once `shift >= 63` instead of growing it
without bound. Covered by `manifest_too_many` and `manifest_oversized_varint` in
`test/test_handshake.ml` (mock server).

**Problem.** During version negotiation a server can answer with a manifest (last byte
`0xFF`) whose offering count is a varint controlled entirely by the server.
`read_varint` (`handshake.ml:35-43`) grows its shift without bound, and
`read_offerings [] count` (`handshake.ml:61-74`) allocates one triple per offering,
reading 4 bytes each. A malicious or broken server can advertise `count = 2^40` and
trickle the bytes, exhausting the driver's memory — a denial of service. Reachable on
plain `bolt://` by a man in the middle, and by any server the user was persuaded to
connect to.

**Fix.**
- Reject a manifest `count` above a small constant (for example 64 offerings) with
  `Errors.Service_unavailable`.
- Bound `read_varint`: stop with an error once `shift >= 64` (or after a small byte
  cap).

**Verify.** Unit test in `test/test_handshake.ml` with the mock server: a manifest whose
`count` is over the cap, and a run of continuation bytes, both return an `Error` instead
of allocating; a normal manifest still negotiates.

---

## Should fix

### 2. Remove the non-standard Struct8/Struct16 markers — `lib/packstream/packstream.ml` — done

**Done.** `marker_struct_8`/`marker_struct_16` and their `pack`/`unpack` branches are
gone; `unpack` now reports `0xDC`/`0xDD` as `Unknown_marker`, and `pack` raises
`Invalid_argument` for a `Structure` with more than 15 fields. Covered by
`reserved_struct_markers` in `test/test_packstream.ml`.

**Problem.** `pack` and `unpack` handle a `Structure` with 16 or more fields using the
markers `0xDC`/`0xDD` (`packstream.ml:51-52`, `:260-276`, `:357-362`). PackStream
defines only tiny structures (`0xB0`-`0xBF`, at most 15 fields); `0xDC`/`0xDD` are
reserved (they are MessagePack array markers). Worse, `pack` writes
`[marker][size][tag]` while `unpack` reads `[marker][tag][size]`, so even this invented
format does not round-trip. No Bolt value has 16 or more fields, so the code is dead and
untested (`test_packstream.ml:72` covers only tiny structs) and non-conformant: a
reserved `0xDC` byte is accepted rather than reported as `Unknown_marker`.

**Fix.** Delete `marker_struct_8`, `marker_struct_16` and their `pack`/`unpack`
branches. Keep tiny structures, and treat `0xDC`/`0xDD` as `Unknown_marker`.

**Verify.** `dune runtest`; add a packstream test asserting that unpacking `0xDC`
returns `Unknown_marker`.

---

## Nice to have

### 3. Evict expired home-database cache entries — `lib/eio/cluster.ml` — done

**Done.** `home_db_of` drops a lapsed entry on lookup, and `set_home_db` sweeps expired
entries before inserting, so the map stays bounded. Covered by `home_db_cache_is_bounded`
in `test/test_cluster.ml` (a test-support `Cluster.home_db_cache_size` reads the size).

**Problem.** `home_dbs` maps a session identity (`imp_user` plus auth) to a home
database. Entries are replaced on refresh but never removed when their TTL lapses, so a
driver serving many distinct impersonated users grows the map without bound.

**Fix.** On lookup, drop the stale entry; optionally sweep expired keys when storing.

**Verify.** Unit test: a `home_db_cache_ttl` of 0 (or a clock jump) drops the entry.

### 4. Clamp the routing-table TTL received from the server — `lib/core/routing_table.ml:52` — done

**Done.** `clamp_ttl` maps a non-positive TTL to 1 second and caps a value too large for
an OCaml int at `max_int` (instead of wrapping to a negative via `Int64.to_int`). Covered
by `parse_clamps_ttl` in `test/test_routing_table.ml`. One cluster test
(`acquire_falls_back_to_next_router`) used `ttl = 0` to force an immediate re-resolve; it
now caches the table under a home database so the second acquire re-resolves without
relying on that.

**Problem.** `ttl_seconds = Int64.to_int ttl` is unvalidated. A TTL of 0 or less makes
`fresh_table` (`cluster.ml`) treat the table as always expired, so every acquire issues a
fresh ROUTE — extra load, worst of all from a misbehaving server.

**Fix.** Clamp to a minimum of 1 second (and reject absurd values).

**Verify.** Unit test: `Routing_table.parse` with `ttl = 0` yields a table whose
`ttl_seconds` is at least 1.

### 5. Reject out-of-range ports when parsing — `lib/core/addressing.ml:35-40`

**Problem.** `parse_port` accepts any `int >= 0`, so `host:99999999` (for example from a
routing table) is accepted and fails only at connect time with a confusing error.

**Fix.** Reject `port > 65535` with a `Configuration_error` at parse time.

**Verify.** Unit test in `test/test_addressing.ml`: `parse "host:99999999"` is `Error`.

### 6. Do not release a pool permit twice after the pool is closed — `lib/eio/pool.ml:331-336`

**Problem.** `release` guards against a double release in the open branch (the `Skip`
case), but the `t.closed` branch unconditionally calls `Eio.Semaphore.release`. Releasing
the same connection twice while the pool is closed pushes the permit count above
`max_connection_pool_size`, corrupting `in_use_count`.

**Fix.** Apply the same "already released" guard in the closed branch (or skip the permit
release when closed).

**Verify.** Unit test: connect, `Pool.close`, then `release` the same connection twice —
the semaphore value never exceeds the pool size.

### 7. Treat a vector whose byte length does not match its dtype as broken — `lib/core/values.ml:79`

**Problem.** `vector_length = Bytes.length v.data / dtype_size` truncates when the server
sends a byte length that is not a multiple of the dtype width, silently reporting a short
vector instead of a `Broken` value.

**Fix.** In hydration, mark the vector `Broken` when `Bytes.length data mod dtype_size <>
0`.

**Verify.** Unit test: a vector struct with a trailing partial element hydrates to
`Broken`.

### 8. Update the README feature list — `README.md:43,54`

**Problem.** The Bolt version list ends at 6.0 (UUID / Bolt 6.1 is missing) and the auth
line mentions only basic authentication, though the driver ships token management
(bearer and custom schemes).

**Fix.** List 6.1 and the auth managers.

---

## Notes

- The earlier, phase-based roadmap was removed from this file on 2026-10-09; it remains
  in the git history.
- Source: the ponytail audit of 2026-10-09.
- Not audited in depth: `temporal.ml` / `tz_lmt.ml`, the full `conn.ml`, all of
  `cluster.ml`, `testkitbackend/commands.ml`, `pem_key.ml` and `tls_client.ml`.
