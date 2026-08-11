# ocaml-neo4j-driver

[![CI](https://github.com/tomob/ocaml-neo4j-driver/actions/workflows/ci.yml/badge.svg)](https://github.com/tomob/ocaml-neo4j-driver/actions/workflows/ci.yml)
[![Docs](https://github.com/tomob/ocaml-neo4j-driver/actions/workflows/deploy-docs.yml/badge.svg)](https://tomob.github.io/ocaml-neo4j-driver/)
[![OCaml](https://img.shields.io/badge/OCaml-%E2%89%A55.2-orange)](https://ocaml.org)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

Pure OCaml Neo4j client library (full cluster driver), built as a new project
using [jeong-sik/ocaml-neo4j-bolt](https://github.com/jeong-sik/ocaml-neo4j-bolt)
(MIT) as a reference implementation and modelled on the architecture of the
Neo4j Python driver.

## Quickstart

```ocaml
open Neodriver

let () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let driver =
        match
          Driver.connect ~uri:"bolt://localhost:7687" ~auth:(Conn.basic_auth ())
            (Eio.Stdenv.net env) (Eio.Stdenv.mono_clock env) sw
        with
        | Ok driver -> driver
        | Error error -> failwith (Errors.to_string error)
      in
      let session = Driver.session driver in
      match Session.run session ~query:"RETURN 1 AS n" ~parameters:[] with
      | Ok result -> (
          match Neo4jResult.values result with
          | Ok [ [ Values.Int n ] ] -> Printf.printf "n = %Ld\n" n
          | _ -> ())
      | Error error -> failwith (Errors.to_string error)))
```

The [quickstart](./docs/quickstart.md) covers adding the driver to a dune
project, running this program and what is going on under the hood.

## Features

- Bolt protocol 3.0, 4.2–4.4, 5.0–5.8 and 6.0.
- Plain `bolt://` and TLS `bolt+s://` / `bolt+ssc://` connections.
- Auto-commit queries with lazy streaming results (`Neo4jResult` / `Summary`).
- Explicit and managed transactions with automatic retry.
- A bounded connection pool (`Driver.session` borrows a connection, returned
  with a RESET on close).
- Bookmarks.
- Temporal types with named time zones (embedded IANA database plus an LMT
  fallback before 1970).
- Basic authentication (LOGON after HELLO on Bolt >= 5.1).
- Vector and UUID value types (Bolt 6).
- TestKit conformance: 119 of 126 tests passing (7 skipped — vector on the
  community server and multi-db; 4 skipped with `NEO4J_EDITION=aura`).

Not yet implemented: `neo4j://` routing, notification
filtering, telemetry and the high-level `execute_query`/`verify_connectivity`
API. See [PLAN.md](./PLAN.md) for the roadmap and what each phase delivers.

## Packages

| Package               | Description                                                    |
|-----------------------|----------------------------------------------------------------|
| `neodriver`           | Friendly aggregator: `open Neodriver` exposes the whole API     |
| `neodriver_packstream`| PackStream binary serialization (pure, no async dependencies)   |
| `neodriver_core`      | Transport-agnostic core logic (errors, config, hydration, ...)  |
| `neodriver_eio`       | Eio (direct-style, OCaml 5) backend                              |

## Documentation

- [Quickstart](./docs/quickstart.md) — the first program.
- [Usage](./docs/usage.md) — sessions, transactions, value types, errors.
- [Examples](./examples/) — runnable programs (`dune exec examples/<name>.exe`).
- [API reference](https://tomob.github.io/ocaml-neo4j-driver/) — generated with
  `dune build @doc`.
- [PLAN.md](./PLAN.md) — the implementation plan and status of every phase.

## Build

```sh
dune build
dune runtest
```

Requires OCaml >= 5.2 and dune >= 3.13.

## Integration tests

The integration tests in `test/test_integration/` run only when the
`TEST_NEO4J_*` environment variables point at a live Neo4j instance; otherwise
they are skipped. The easiest way to run them is with the Docker helper
script:

```sh
scripts/integration.sh run              # start Neo4j, run all tests, stop Neo4j
scripts/integration.sh run-integration  # start Neo4j, run only the integration tests, stop Neo4j
scripts/integration.sh up               # start the Neo4j container (no-op if running)
scripts/integration.sh test             # run all tests (container must be up)
scripts/integration.sh integration      # run only the integration tests, plain and TLS (container must be up)
scripts/integration.sh status           # report whether the container is running
scripts/integration.sh down             # stop and remove the container
```

The container is started with the Bolt SSL policy enabled and
`server.bolt.tls_level=OPTIONAL`, so the same port serves both plain `bolt://`
and TLS (`bolt+ssc` / `bolt+s`) connections. The integration pass therefore
runs twice: once plain and once with `TEST_NEO4J_SCHEME=bolt+ssc`, which also
exercises TLS against the container's self-signed certificate (mounted from
`test/fixtures/neo4j-ssl/`). `bolt+s` correctly rejects that self-signed
certificate.

Configuration is via environment variables, e.g. `NEO4J_IMAGE`,
`NEO4J_CONTAINER`, `NEO4J_HOST_PORT`, `NEO4J_USER`, `NEO4J_PASS`,
`NEO4J_SCHEME`, `NEO4J_LOG`.

## License

MIT — see [LICENSE](LICENSE).
