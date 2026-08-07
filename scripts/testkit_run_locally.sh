#!/usr/bin/env bash
#
# Developer-focused variant of testkit_run.sh: Neo4j still runs in a Docker
# container on a dedicated network, but the testkit backend is built and run
# LOCALLY (no Docker image build, so incremental `dune build` keeps iterations
# fast). The harness runs on the host as usual.
#
# Configuration via environment variables (defaults shown):
#   NEO4J_TESTKIT_DIR        path to a neo4j-drivers/testkit checkout (required)
#   NEO4J_HOST_PORT=17687    host port mapped to the Neo4j Bolt port (NOT 7687:
#                            the testkit resolver test uses 127.100.200.42:7687
#                            as an address that must fail to connect, which
#                            only holds while nothing listens on the host's
#                            loopback port 7687)
#   NEO4J_USER=neo4j
#   NEO4J_PASS=testpassword
#   TESTKIT_BACKEND_PORT=9876
#   TESTKIT_VERSION=6.1      # passed to tests.neo4j.suites / TEST_NEO4J_VERSION
#   TESTKIT_NETWORK=neo4j-testkit-net
#   BACKEND_BINARY=...       # override the built backend executable (default:
#                            # _build/default/testkitbackend/testkitbackend.exe)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

NEO4J_TESTKIT_DIR="${NEO4J_TESTKIT_DIR:?set NEO4J_TESTKIT_DIR to the testkit checkout}"
PY="${NEO4J_TESTKIT_DIR}/.venv/bin/python"
NEO4J_HOST_PORT="${NEO4J_HOST_PORT:-17687}"
NEO4J_USER="${NEO4J_USER:-neo4j}"
NEO4J_PASS="${NEO4J_PASS:-testpassword}"
TESTKIT_BACKEND_PORT="${TESTKIT_BACKEND_PORT:-9876}"
TESTKIT_VERSION="${TESTKIT_VERSION:-6.1}"
TESTKIT_NETWORK="${TESTKIT_NETWORK:-neo4j-testkit-net}"
BACKEND_BINARY="${BACKEND_BINARY:-${REPO_ROOT}/_build/default/testkitbackend/testkitbackend.exe}"

die() {
  echo "error: $*" >&2
  exit 1
}

[ -x "$PY" ] || die "no venv python at $PY (install the testkit dependencies first)"
[ -d "$NEO4J_TESTKIT_DIR/nutkit" ] || die "NEO4J_TESTKIT_DIR does not look like a testkit checkout"
command -v docker >/dev/null 2>&1 || die "docker not found"

backend_pid=""
cleanup() {
  if [ -n "${backend_pid}" ]; then
    kill "${backend_pid}" >/dev/null 2>&1 || true
    wait "${backend_pid}" >/dev/null 2>&1 || true
  fi
  NEO4J_NETWORK="${TESTKIT_NETWORK}" "${REPO_ROOT}/scripts/integration.sh" down
  docker network rm "${TESTKIT_NETWORK}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== Network ==="
docker network create "${TESTKIT_NETWORK}" >/dev/null 2>&1 || true

echo "=== Starting Neo4j ==="
NEO4J_NETWORK="${TESTKIT_NETWORK}" NEO4J_HOST_PORT="${NEO4J_HOST_PORT}" \
  "${REPO_ROOT}/scripts/integration.sh" up

neo4j_ip="$(
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
    "${NEO4J_CONTAINER:-neo4j-test}"
)"
[ -n "$neo4j_ip" ] || die "could not determine the Neo4j container IP"

echo "=== Building the testkit backend (dune) ==="
dune build testkitbackend/testkitbackend.exe
[ -x "$BACKEND_BINARY" ] || die "backend executable not found at $BACKEND_BINARY"

echo "=== Starting the testkit backend locally (port ${TESTKIT_BACKEND_PORT}) ==="
TESTKIT_BACKEND_PORT="${TESTKIT_BACKEND_PORT}" "${BACKEND_BINARY}" &
backend_pid=$!

for _ in $(seq 1 100); do
  if (exec 3<>"/dev/tcp/127.0.0.1/${TESTKIT_BACKEND_PORT}") 2>/dev/null; then
    exec 3>&- 3<&-
    break
  fi
  sleep 0.1
done
kill -0 "${backend_pid}" 2>/dev/null || die "backend exited before the suite ran"

echo "=== Running the TestKit suite (${TESTKIT_VERSION}) ==="
cd "${NEO4J_TESTKIT_DIR}"
export PYTHONPATH="${NEO4J_TESTKIT_DIR}"
export TEST_DRIVER_NAME=ocaml
export TEST_BACKEND_HOST=127.0.0.1
export TEST_BACKEND_PORT="${TESTKIT_BACKEND_PORT}"
export TEST_NEO4J_HOST="${neo4j_ip}"
export TEST_NEO4J_PORT=7687
export TEST_NEO4J_USER="${NEO4J_USER}"
export TEST_NEO4J_PASS="${NEO4J_PASS}"
export TEST_NEO4J_SCHEME=bolt
export TEST_NEO4J_VERSION="${TESTKIT_VERSION}"
export TEST_NEO4J_EDITION=community
export TEST_NEO4J_DEFAULT_DB=neo4j
"${PY}" -m tests.neo4j.suites "${TESTKIT_VERSION}" local
