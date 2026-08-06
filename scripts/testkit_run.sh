#!/usr/bin/env bash
#
# Run the TestKit integration suite: start Neo4j (as scripts/integration.sh does),
# start the testkit backend, then run the testkit harness from NEO4J_TESTKIT_DIR.
#
# Configuration via environment variables (defaults shown):
#   NEO4J_TESTKIT_DIR   path to a neo4j-drivers/testkit checkout (required)
#   NEO4J_HOST_PORT=7687
#   NEO4J_USER=neo4j
#   NEO4J_PASS=testpassword
#   TESTKIT_BACKEND_PORT=9876
#   TESTKIT_VERSION=6.1      # passed to tests.neo4j.suites / TEST_NEO4J_VERSION
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

NEO4J_TESTKIT_DIR="${NEO4J_TESTKIT_DIR:?set NEO4J_TESTKIT_DIR to the testkit checkout}"
PY="${NEO4J_TESTKIT_DIR}/.venv/bin/python"
NEO4J_HOST_PORT="${NEO4J_HOST_PORT:-7687}"
NEO4J_USER="${NEO4J_USER:-neo4j}"
NEO4J_PASS="${NEO4J_PASS:-testpassword}"
TESTKIT_BACKEND_PORT="${TESTKIT_BACKEND_PORT:-9876}"
TESTKIT_VERSION="${TESTKIT_VERSION:-6.1}"

die() {
  echo "error: $*" >&2
  exit 1
}

[ -x "$PY" ] || die "no venv python at $PY (install the testkit dependencies first)"
[ -d "$NEO4J_TESTKIT_DIR/nutkit" ] || die "NEO4J_TESTKIT_DIR does not look like a testkit checkout"

backend_pid=""
cleanup() {
  if [ -n "${backend_pid}" ]; then
    kill "${backend_pid}" 2>/dev/null || true
  fi
  "${REPO_ROOT}/scripts/integration.sh" down
}
trap cleanup EXIT

echo "=== Starting Neo4j ==="
"${REPO_ROOT}/scripts/integration.sh" up

echo "=== Starting the testkit backend on port ${TESTKIT_BACKEND_PORT} ==="
dune build >/dev/null
TESTKIT_BACKEND_PORT="${TESTKIT_BACKEND_PORT}" "${REPO_ROOT}/_build/default/testkitbackend/testkitbackend.exe" &
backend_pid=$!

for _ in $(seq 1 100); do
  if (exec 3<>"/dev/tcp/127.0.0.1/${TESTKIT_BACKEND_PORT}") 2>/dev/null; then
    exec 3>&- 3<&-
    break
  fi
  sleep 0.1
done

echo "=== Running the TestKit suite (${TESTKIT_VERSION}) ==="
cd "${NEO4J_TESTKIT_DIR}"
export PYTHONPATH="${NEO4J_TESTKIT_DIR}"
export TEST_DRIVER_NAME=ocaml
export TEST_BACKEND_HOST=127.0.0.1
export TEST_BACKEND_PORT="${TESTKIT_BACKEND_PORT}"
export TEST_NEO4J_HOST=127.0.0.1
export TEST_NEO4J_PORT="${NEO4J_HOST_PORT}"
export TEST_NEO4J_USER="${NEO4J_USER}"
export TEST_NEO4J_PASS="${NEO4J_PASS}"
export TEST_NEO4J_SCHEME=bolt
export TEST_NEO4J_VERSION="${TESTKIT_VERSION}"
export TEST_NEO4J_EDITION=community
export TEST_NEO4J_DEFAULT_DB=neo4j
"${PY}" -m tests.neo4j.suites "${TESTKIT_VERSION}" local
