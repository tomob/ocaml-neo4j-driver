# ocaml-neo4j-driver

Pure OCaml Neo4j client library (full cluster driver), built as a new project
using [jeong-sik/ocaml-neo4j-bolt](https://github.com/jeong-sik/ocaml-neo4j-bolt)
(MIT) as a reference implementation and modelled on the architecture of the
Neo4j Python driver.

See [PLAN.md](./PLAN.md) for the full implementation plan.

## Packages

| Package              | Description                                                     |
|----------------------|-----------------------------------------------------------------|
| `neodriver_packstream` | PackStream binary serialization (pure, no async dependencies)  |
| `neodriver_core`       | Transport-agnostic core logic (errors, config, hydration, ...) |
| `neodriver_eio`        | Eio (direct-style, OCaml 5) backend                             |

## Build

```sh
dune build
dune runtest
```

Requires OCaml >= 5.0 and dune >= 3.13.

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
