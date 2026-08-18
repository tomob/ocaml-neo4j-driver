#!/usr/bin/env bash
#
# Run TestKit stub suites (tests.stub.*) against the locally built testkit
# backend. No Neo4j server is needed: the stub servers run in-process inside
# the Python harness.
#
# Usage:
#   scripts/testkit_stub.sh [OPTION...] [SUITE ...]
#
# With no SUITE arguments every stub suite runs (`python -m tests.stub.suites`);
# otherwise each argument is a test module, class or single test, e.g.:
#   scripts/testkit_stub.sh tests.stub.routing.test_routing_v5x0
#   scripts/testkit_stub.sh tests.stub.routing.test_routing_v4x4 \
#     tests.stub.routing.test_routing_v5x0
#   scripts/testkit_stub.sh tests.stub.summary.test_summary tests.stub.retry.test_retry
#   scripts/testkit_stub.sh \
#     tests.stub.routing.test_routing_v4x4.RoutingV4x4.test_should_retry_read_tx_until_success_on_no_connection
#
# The SUITE environment variable is an alternative to positional arguments
# (space-separated modules); positional arguments take precedence.
#
# Configuration via environment variables (defaults shown):
#   NEO4J_TESTKIT_DIR        path to a neo4j-drivers/testkit checkout (required)
#   TESTKIT_BACKEND_PORT=9876
#   BACKEND_BINARY=...       override the built backend executable (default:
#                            _build/default/testkitbackend/testkitbackend.exe)
#   SUITE=...                test modules to run (alternative to arguments)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PY="${NEO4J_TESTKIT_DIR:+${NEO4J_TESTKIT_DIR}/.venv/bin/python}"
TESTKIT_BACKEND_PORT="${TESTKIT_BACKEND_PORT:-9876}"
BACKEND_BINARY="${BACKEND_BINARY:-${REPO_ROOT}/_build/default/testkitbackend/testkitbackend.exe}"

usage() {
  cat <<'EOF'
Usage: testkit_stub.sh [OPTION...] [SUITE ...]

Run TestKit stub suites (tests.stub.*) against the locally built testkit
backend. With no SUITE arguments, every stub suite runs.

Options:
  -h, --help          show this help and exit
  -l, --list-suites   list all available stub test modules and exit

SUITE arguments are test modules / classes / single tests, e.g.:
  tests.stub.routing.test_routing_v5x0
  tests.stub.routing.test_routing_v4x4 tests.stub.routing.test_routing_v5x0
  tests.stub.summary.test_summary tests.stub.retry.test_retry
  tests.stub.routing.test_routing_v4x4.RoutingV4x4.test_should_retry_read_tx_until_success_on_no_connection

The SUITE environment variable is an alternative to positional arguments
(space-separated modules); positional arguments take precedence.

Environment:
  NEO4J_TESTKIT_DIR        path to a neo4j-drivers/testkit checkout (required)
  TESTKIT_BACKEND_PORT=9876
  BACKEND_BINARY=...       override the built backend executable
  SUITE=...                test modules to run (alternative to arguments)
EOF
}

list_suites() {
  NEO4J_TESTKIT_DIR="${NEO4J_TESTKIT_DIR:?set NEO4J_TESTKIT_DIR to the testkit checkout}"
  [ -d "$NEO4J_TESTKIT_DIR/tests/stub" ] \
    || die "NEO4J_TESTKIT_DIR does not look like a testkit checkout"
  find "$NEO4J_TESTKIT_DIR/tests/stub" -name "test_*.py" \
    | sed 's|^.*/tests/stub/|tests.stub.|; s|/|.|g; s|\.py$||' \
    | sort
}

die() {
  echo "error: $*" >&2
  exit 1
}

# Parse options first (so --help/--list-suites work without the backend).
suites=()
for arg in "$@"; do
  case "$arg" in
    -h | --help)
      usage
      exit 0
      ;;
    -l | --list-suites)
      list_suites
      exit 0
      ;;
    -*) die "unknown option: $arg (try '$0 --help')" ;;
    *) suites+=("$arg") ;;
  esac
done

NEO4J_TESTKIT_DIR="${NEO4J_TESTKIT_DIR:?set NEO4J_TESTKIT_DIR to the testkit checkout}"
[ -n "$PY" ] || die "no venv python at $PY (install the testkit dependencies first)"
[ -x "$PY" ] || die "no venv python at $PY (install the testkit dependencies first)"
[ -d "$NEO4J_TESTKIT_DIR/nutkit" ] || die "NEO4J_TESTKIT_DIR does not look like a testkit checkout"

# shellcheck source=lib/testkit_backend.sh
source "${REPO_ROOT}/scripts/lib/testkit_backend.sh"

backend_pid=""
cleanup() {
  if [ -n "${backend_pid}" ]; then
    kill "${backend_pid}" >/dev/null 2>&1 || true
    wait "${backend_pid}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

testkit_backend_start

if [ "${#suites[@]}" -eq 0 ] && [ -n "${SUITE:-}" ]; then
  read -r -a suites <<< "${SUITE}"
fi

echo "=== Running the TestKit stub suite(s) ==="
cd "${NEO4J_TESTKIT_DIR}"
export PYTHONPATH="${NEO4J_TESTKIT_DIR}"
export TEST_DRIVER_NAME=ocaml
export TEST_BACKEND_HOST=127.0.0.1
export TEST_BACKEND_PORT="${TESTKIT_BACKEND_PORT}"
if [ "${#suites[@]}" -eq 0 ]; then
  "${PY}" -m tests.stub.suites
else
  "${PY}" -m unittest "${suites[@]}"
fi
