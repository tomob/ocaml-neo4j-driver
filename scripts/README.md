# TestKit run scripts

To run **every test in the project** (unit tests, the TestKit stub and neo4j
suites, and the integration tests) in one go, use
[`run_all_tests.sh`](#running-everything). The individual harness scripts
below drive the Neo4j TestKit suites (`tests.neo4j.suites` / `tests.stub.*`)
against a real Neo4j server or the in-process stub servers.

Two scripts run the TestKit integration suite (`tests.neo4j.suites`)
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
suite in one process; pass test modules as arguments and each one is run in its
**own process** (isolated runs, one backend for the whole loop), e.g. the
routing suites:

```sh
scripts/testkit_stub.sh tests.stub.routing.test_routing_v4x4 tests.stub.routing.test_routing_v5x0
```

The same per-module loop mode is available in `testkit_run_locally.sh`
(container up once, then one process per module).

Use `--help` for the full usage and `--list-suites` to enumerate every available
test module. The stub harness is the only way to exercise the
`GetRoutingTable` / `ForcedRoutingTableUpdate` commands and the
`Backend:RTFetch` / `Backend:RTForceUpdate` features; the `tests.neo4j` suites
do not select those tests.

## Running everything

`scripts/run_all_tests.sh` (also reachable as `dune build @test-all`) runs the
whole project test suite and prints a PASS/SKIP/FAIL/ERROR report:

1. **unit** — `dune runtest` + `scripts/backend_smoke.sh`,
2. **stub** — every `tests.stub.*` module, one process per module,
3. **neo4j** — every `tests.neo4j.*` module, one process per module (local
   Neo4j container up once for the whole phase),
4. **integration** — `scripts/integration.sh run-integration` (plain + TLS).

```sh
export NEO4J_TESTKIT_DIR=/path/to/neo4j-drivers/testkit
scripts/run_all_tests.sh            # every phase above
scripts/run_all_tests.sh --no-docker   # unit + stub only (no Neo4j needed)
scripts/run_all_tests.sh --unit --stub # explicit phase selection
scripts/run_all_tests.sh --check      # dune build @fmt + @doc
```

Each TestKit module run is time-bounded (`TESTKIT_MODULE_TIMEOUT`, default
600 s; `0` disables it) so a single hanging test cannot block the whole run.
The final report lists, per module and per phase, the numbers of passed,
skipped, failed and errored tests (a timed-out module is reported as
`TIMEOUT` and counted as an error), the failed modules, and the log files
under `_build/logs/run-all/`.

Notes:

- Per-module runs use the standard `unittest` result class instead of the
  harness's `tests.testenv.test_kit_basic_test_result`, so the reported skip
  counts can differ slightly from a single `tests.neo4j.suites` run.
  `expectedFailure`/`unexpectedSuccess` are not distinguished and count as
  passed.
- Phases run sequentially; the neo4j phase requires the host's port 7687 to be
  free (the resolver test, see [Pitfalls](#pitfalls)).
- `--stop-on-error` aborts the remaining phases after the first failure.
- If a phase's prerequisites are missing (docker, `NEO4J_TESTKIT_DIR`), the
  phase is reported as `ERROR` and the rest continues.
- The stub/neo4j phases can take a while (one process per module; a failing
  test that waits out its server timeout can add ~30 s per occurrence), so
  they are best run overnight or while iterating on a single module first.

## Prerequisites

- `docker` (for the Neo4j container; not needed for `testkit_stub.sh`).
- A checkout of `neo4j-drivers/testkit` with its virtualenv installed.
- The `neodriver` packages built (`dune build`).

## Running

```sh
export NEO4J_TESTKIT_DIR=/path/to/neo4j-drivers/testkit

# Local backend (recommended for development)
scripts/testkit_run_locally.sh

# Same, but one process per test module (container up once for the whole run)
scripts/testkit_run_locally.sh -l                       # list the modules
scripts/testkit_run_locally.sh tests.neo4j.test_authentication \
  tests.neo4j.test_bookmarks

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
| `SUITE` | (unset) | space-separated test modules, alternative to positional arguments (testkit scripts) |
| `TESTKIT_MODULE_TIMEOUT` | `600` | per-module timeout in seconds in the loop mode (`0` = no limit) |
| `TESTKIT_VERBOSITY` | `1` | `unittest` verbosity for the per-module runs |
| `TESTKIT_PHASE_TIMEOUT` | `3600` | whole-phase safety net in `run_all_tests.sh` (`0` = off) |
| `LOG_DIR` | `_build/logs/run-all` | phase log directory for `run_all_tests.sh` |

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
