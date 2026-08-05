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
