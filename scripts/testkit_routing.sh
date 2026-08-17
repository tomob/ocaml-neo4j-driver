#!/usr/bin/env bash
#
# Run the TestKit stub routing suite (tests.stub.routing) against the locally
# built testkit backend. No Neo4j server is needed: the stub servers run
# in-process inside the Python harness.
#
# The routing suite has one class per Bolt version (v3 / v4x2 / v4x3 / v4x4 /
# v5x0). Only RoutingV4x4 and RoutingV5x0 actually run: their required features
# (Feature:Bolt:4.4 / 5.0) are reported by the backend. The v3 / v4x2 / v4x3
# classes are skipped because the backend does not report Feature:Bolt:3.0 /
# 4.2 / 4.3.
#
# Configuration via environment variables (defaults shown):
#   NEO4J_TESTKIT_DIR        path to a neo4j-drivers/testkit checkout (required)
#   TESTKIT_BACKEND_PORT=9876
#   BACKEND_BINARY=...       override the built backend executable (default:
#                            _build/default/testkitbackend/testkitbackend.exe)
#   SUITE=...                the test modules to run (default:
#                            "tests.stub.routing.test_routing_v4x4 tests.stub.routing.test_routing_v5x0")
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

NEO4J_TESTKIT_DIR="${NEO4J_TESTKIT_DIR:?set NEO4J_TESTKIT_DIR to the testkit checkout}"
PY="${NEO4J_TESTKIT_DIR}/.venv/bin/python"
TESTKIT_BACKEND_PORT="${TESTKIT_BACKEND_PORT:-9876}"
BACKEND_BINARY="${BACKEND_BINARY:-${REPO_ROOT}/_build/default/testkitbackend/testkitbackend.exe}"
SUITE="${SUITE:-tests.stub.routing.test_routing_v4x4 tests.stub.routing.test_routing_v5x0}"

die() {
  echo "error: $*" >&2
  exit 1
}

# shellcheck source=lib/testkit_backend.sh
source "${REPO_ROOT}/scripts/lib/testkit_backend.sh"

[ -x "$PY" ] || die "no venv python at $PY (install the testkit dependencies first)"
[ -d "$NEO4J_TESTKIT_DIR/nutkit" ] || die "NEO4J_TESTKIT_DIR does not look like a testkit checkout"

backend_pid=""
cleanup() {
  if [ -n "${backend_pid}" ]; then
    kill "${backend_pid}" >/dev/null 2>&1 || true
    wait "${backend_pid}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

testkit_backend_start

echo "=== Running the TestKit stub routing suite ==="
cd "${NEO4J_TESTKIT_DIR}"
export PYTHONPATH="${NEO4J_TESTKIT_DIR}"
export TEST_DRIVER_NAME=ocaml
export TEST_BACKEND_HOST=127.0.0.1
export TEST_BACKEND_PORT="${TESTKIT_BACKEND_PORT}"
"${PY}" -m unittest ${SUITE}
