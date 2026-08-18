# TestKit run scripts

Two scripts run the Neo4j TestKit integration suite (`tests.neo4j.suites`)
against a real Neo4j server:

- `testkit_run_locally.sh` — the testkit backend is built with `dune` and runs
  on the host (fastest for iterating on the driver). Requires `docker` for the
  Neo4j container only.
- `testkit_run.sh` — mirrors the Python harness topology: the backend runs in a
  container (built from the repo's `Dockerfile`) on the same docker network as
  Neo4j. Requires `docker` for both.

Both scripts manage a Neo4j container (`scripts/integration.sh`), run the
harness on the host, and tear everything down afterwards.

A third script, `testkit_stub.sh`, runs the **stub suites** (`tests.stub.*`)
against the locally built backend with **no Neo4j server** (the stub servers run
in-process inside the Python harness). With no arguments it runs every stub
suite; pass test modules as arguments to run a subset, e.g. the routing suites:

```sh
scripts/testkit_stub.sh tests.stub.routing.test_routing_v4x4 tests.stub.routing.test_routing_v5x0
```

Use `--help` for the full usage and `--list-suites` to enumerate every available
stub test module. The stub harness is the only way to exercise the
`GetRoutingTable` / `ForcedRoutingTableUpdate` commands and the
`Backend:RTFetch` / `Backend:RTForceUpdate` features; the `tests.neo4j` suites
do not select those tests.

## Prerequisites

- `docker` (for the Neo4j container; not needed for `testkit_stub.sh`).
- A checkout of `neo4j-drivers/testkit` with its virtualenv installed.
- The `neodriver` packages built (`dune build`).

## Running

```sh
export NEO4J_TESTKIT_DIR=/path/to/neo4j-drivers/testkit

# Local backend (recommended for development)
scripts/testkit_run_locally.sh

# Backend in a container
scripts/testkit_run.sh

# Stub suites (no Neo4j needed)
scripts/testkit_stub.sh tests.stub.routing.test_routing_v4x4 tests.stub.routing.test_routing_v5x0
```

With the default configuration the suite is fully green:

```
Ran 126 tests in ~50s
OK (skipped=7)
```

The 7 skips are all **server-side limitations** of the local community server,
not driver gaps:

- 3 vector tests — vectors are only reported when the harness claims a
  vector-capable edition (see below).
- 4 multi-db tests — need an enterprise server with multiple databases.

## Configuration

All settings are environment variables (defaults shown in each script's header):

| Variable | Default | Meaning |
|---|---|---|
| `NEO4J_TESTKIT_DIR` | — (required) | path to the testkit checkout |
| `NEO4J_EDITION` | `community` | edition the harness assumes: `community`, `aura`, or `enterprise` |
| `NEO4J_URI` | (unset) | external Neo4j URI `scheme://host[:port]`; when set, no local container is started |
| `NEO4J_USER` / `NEO4J_PASS` | `neo4j` / `testpassword` | server credentials |
| `NEO4J_HOST_PORT` | `17687` (local) / `7687` (container) | host port mapped to the Neo4j Bolt port |
| `TESTKIT_VERSION` | `2026.06` | server version reported to the harness (`TEST_NEO4J_VERSION`) |
| `TESTKIT_BACKEND_PORT` | `9876` | port the testkit backend listens on |
| `BACKEND_BINARY` | `_build/default/testkitbackend/testkitbackend.exe` | backend executable override (local script) |
| `TESTKIT_BACKEND_IMAGE` | `ocaml-neo4j-testkit-backend` | backend image name (container script) |

### Enabling the vector tests (`NEO4J_EDITION=aura`)

The vector round-trip is implemented (`Values.Vector`, PackStream structure
tag `0x56`), but the local community server does not report vector support, so
the harness skips the tests. Setting `NEO4J_EDITION=aura` makes the harness
believe the server supports vectors (the local container is still community;
this only unlocks the gating):

```sh
NEO4J_EDITION=aura scripts/testkit_run_locally.sh
# OK (skipped=4) — only the multi-db tests remain skipped
```

### Enabling the UUID tests

UUID (Bolt 6.1) is enabled by default: `scripts/integration.sh` starts the
server with `NEO4J_BOLT_MAX_VERSION=6.1` and the internal UUID preview flags
(`internal.cypher.uuid_type.enabled`, `internal.dbms.latest.*`), which the
TestKit runner itself uses. Without them the server only offers Bolt 6.0 and
rejects the `0xE0` UUID marker.

All five UUID tests pass:

```
test_cypher_created_uuid      ... ok
test_should_echo_uuid         ... ok
test_uuid_in_list             ... ok
test_uuid_in_map              ... ok
test_uuid_stored_on_node      ... ok
```

Note: the server's "aligned" store format cannot **commit** UUID properties
(`DataUnsupportedByStoreFormat`); `test_uuid_stored_on_node` (and the
integration test) write and read the property back inside a transaction and
then roll back.

### External server (`NEO4J_URI`) — multi-db

To exercise the multi-db tests, point the scripts at an external enterprise
server that has multiple databases. When `NEO4J_URI` is set, the scripts do
**not** start or tear down a local container:

```sh
NEO4J_EDITION=enterprise \
NEO4J_URI=bolt://db.example.com:7687 \
NEO4J_USER=neo4j NEO4J_PASS=secret \
TESTKIT_VERSION=<server version> \
scripts/testkit_run_locally.sh
```

Credentials are taken from `NEO4J_USER`/`NEO4J_PASS`, not the URI (a URI
containing `user:pass@` is rejected). `testkit_run.sh` runs its backend
container with `--network host` in external mode so it can reach a host-local
or remote server.

## Pitfalls

- **Port 7687 must be free on the host** for the resolver test
  (`test_custom_resolver`), which expects `127.100.200.42:7687` to be
  unreachable. `testkit_run_locally.sh` therefore maps the container to
  `NEO4J_HOST_PORT=17687`; do not run another Neo4j on the host's 7687 while
  using it.
- With an **external** database bound to the host's 7687, `test_custom_resolver`
  may fail for the same reason (its "must fail" address becomes reachable).
- If a `neo4j-test` container or the `neo4j-testkit-net` network is left over
  from an interrupted run, remove them (`docker rm -f neo4j-test`,
  `docker network rm neo4j-testkit-net`) — the scripts reuse rather than
  recreate them.
