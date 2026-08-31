#!/usr/bin/env bash
#
# Run the TestKit integration suite with the same network topology as the Python
# harness: Neo4j runs in one container and the testkit backend in a separate
# container (built from the repo's Dockerfile), both on a dedicated docker
# network. The testkit harness runs on the host.
#
# Usage:
#   scripts/testkit_run.sh [OPTION...] [SUITE ...]
#
# With no SUITE arguments the whole neo4j suite runs
# (`python -m tests.neo4j.suites`); otherwise each argument is run in its own
# process (a test module / class / single test) against one Neo4j container
# and one backend container, e.g.:
#   scripts/testkit_run.sh tests.neo4j.test_authentication
#   scripts/testkit_run.sh tests.neo4j.test_authentication \
#     tests.neo4j.test_bookmarks
#
# The SUITE environment variable is an alternative to positional arguments
# (space-separated modules); positional arguments take precedence.
#
# Configuration via environment variables (defaults shown):
#   NEO4J_TESTKIT_DIR        path to a neo4j-drivers/testkit checkout (required)
#   NEO4J_HOST_PORT=7687     host port mapped to the Neo4j Bolt port
#   NEO4J_USER=neo4j
#   NEO4J_PASS=testpassword
#   NEO4J_EDITION=community   # reported as TEST_NEO4J_EDITION (aura/enterprise enable features like vectors)
#   NEO4J_URI=                # external Neo4j URI (scheme://host[:port]); when set, no local container is started
#   TESTKIT_BACKEND_PORT=9876
#   TESTKIT_VERSION=2026.06 # the real Neo4j server version (agent "Neo4j/2026.06") passed to tests.neo4j.suites / TEST_NEO4J_VERSION
#   TESTKIT_NETWORK=neo4j-testkit-net
#   TESTKIT_BACKEND_IMAGE=ocaml-neo4j-testkit-backend
#   SUITE=...                # test modules to run (alternative to arguments)
#   TESTKIT_MODULE_TIMEOUT=600  # per-module timeout in seconds (0 = no limit)
#   TESTKIT_VERBOSITY=1      # unittest verbosity for the per-module runs
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: testkit_run.sh [OPTION...] [SUITE ...]

Run the TestKit neo4j suites against a live Neo4j (local container unless
NEO4J_URI is set) with the backend in a container. With no SUITE arguments the
whole suite runs via tests.neo4j.suites; otherwise each SUITE argument is run
in its own process (per-module loop, one container/backend).

Options:
  -h, --help          show this help and exit
  -l, --list-suites   list all available neo4j test modules and exit

SUITE arguments are test modules / classes / single tests, e.g.:
  tests.neo4j.test_authentication
  tests.neo4j.test_authentication tests.neo4j.test_bookmarks

The SUITE environment variable is an alternative to positional arguments
(space-separated modules); positional arguments take precedence.

Environment:
  NEO4J_TESTKIT_DIR        path to a neo4j-drivers/testkit checkout (required)
  NEO4J_HOST_PORT=7687     host port mapped to the Neo4j Bolt port
  NEO4J_USER=neo4j
  NEO4J_PASS=testpassword
  NEO4J_EDITION=community
  NEO4J_URI=               external Neo4j URI (scheme://host[:port])
  TESTKIT_BACKEND_PORT=9876
  TESTKIT_VERSION=2026.06
  TESTKIT_NETWORK=neo4j-testkit-net
  TESTKIT_BACKEND_IMAGE=ocaml-neo4j-testkit-backend
  SUITE=...                test modules to run (alternative to arguments)
  TESTKIT_MODULE_TIMEOUT=600  per-module timeout in seconds (0 = no limit)
  TESTKIT_VERBOSITY=1      unittest verbosity for the per-module runs
EOF
}

list_suites() {
  NEO4J_TESTKIT_DIR="${NEO4J_TESTKIT_DIR:?set NEO4J_TESTKIT_DIR to the testkit checkout}"
  [ -d "$NEO4J_TESTKIT_DIR/tests/neo4j" ] \
    || die "NEO4J_TESTKIT_DIR does not look like a testkit checkout"
  find "$NEO4J_TESTKIT_DIR/tests/neo4j" -name "test_*.py" \
    | sed 's|^.*/tests/neo4j/|tests.neo4j.|; s|/|.|g; s|\.py$||' \
    | sort
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
PY="${NEO4J_TESTKIT_DIR}/.venv/bin/python"
NEO4J_HOST_PORT="${NEO4J_HOST_PORT:-7687}"
NEO4J_USER="${NEO4J_USER:-neo4j}"
NEO4J_PASS="${NEO4J_PASS:-testpassword}"
NEO4J_EDITION="${NEO4J_EDITION:-community}"
NEO4J_URI="${NEO4J_URI:-}"
TESTKIT_BACKEND_PORT="${TESTKIT_BACKEND_PORT:-9876}"
TESTKIT_VERSION="${TESTKIT_VERSION:-2026.06}"
TESTKIT_NETWORK="${TESTKIT_NETWORK:-neo4j-testkit-net}"
TESTKIT_BACKEND_IMAGE="${TESTKIT_BACKEND_IMAGE:-ocaml-neo4j-testkit-backend}"
TESTKIT_MODULE_TIMEOUT="${TESTKIT_MODULE_TIMEOUT:-600}"
TESTKIT_VERBOSITY="${TESTKIT_VERBOSITY:-1}"

# An external Neo4j URI (scheme://host[:port]) runs the suite against a
# server the script does not manage: no local container is started and the
# backend reaches it through the host network.
if [ -n "${NEO4J_URI}" ]; then
  if [[ "${NEO4J_URI}" =~ ^([a-zA-Z][a-zA-Z0-9+.-]*)://([^/:]+)(:([0-9]+))?$ ]]; then
    NEO4J_SCHEME="${BASH_REMATCH[1]}"
    NEO4J_HOST="${BASH_REMATCH[2]}"
    NEO4J_BOLT_PORT="${BASH_REMATCH[4]:-7687}"
    external=1
  else
    die "cannot parse NEO4J_URI '${NEO4J_URI}' (expected scheme://host[:port])"
  fi
else
  NEO4J_SCHEME=bolt
  NEO4J_HOST=""
  NEO4J_BOLT_PORT=7687
  external=0
fi

[ -x "$PY" ] || die "no venv python at $PY (install the testkit dependencies first)"
[ -d "$NEO4J_TESTKIT_DIR/nutkit" ] || die "NEO4J_TESTKIT_DIR does not look like a testkit checkout"
docker_available() { command -v docker >/dev/null 2>&1; }
docker_available || die "docker not found"

backend_container="testkit-backend"
cleanup() {
  docker rm -f "${backend_container}" >/dev/null 2>&1 || true
  if [ "${external}" -eq 0 ]; then
    NEO4J_NETWORK="${TESTKIT_NETWORK}" "${REPO_ROOT}/scripts/integration.sh" down
    docker network rm "${TESTKIT_NETWORK}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [ "${external}" -eq 0 ]; then
  echo "=== Network ==="
  docker network create "${TESTKIT_NETWORK}" >/dev/null 2>&1 || true

  echo "=== Starting Neo4j ==="
  NEO4J_NETWORK="${TESTKIT_NETWORK}" "${REPO_ROOT}/scripts/integration.sh" up

  neo4j_ip="$(
    docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
      "${NEO4J_CONTAINER:-neo4j-test}"
  )"
  [ -n "$neo4j_ip" ] || die "could not determine the Neo4j container IP"
else
  echo "=== Using the external Neo4j at ${NEO4J_URI} ==="
  neo4j_ip="${NEO4J_HOST}"
fi

echo "=== Building the testkit backend image ==="
docker build -t "${TESTKIT_BACKEND_IMAGE}" .

echo "=== Starting the testkit backend in a container (port ${TESTKIT_BACKEND_PORT}) ==="
if [ "${external}" -eq 1 ]; then
  # Host networking lets the backend reach the external server whether it is
  # on the host's localhost or a routable address.
  docker run -d --name "${backend_container}" \
    --network host \
    "${TESTKIT_BACKEND_IMAGE}" >/dev/null
else
  docker run -d --name "${backend_container}" \
    --network "${TESTKIT_NETWORK}" \
    -p "${TESTKIT_BACKEND_PORT}:9876" \
    "${TESTKIT_BACKEND_IMAGE}" >/dev/null
fi

for _ in $(seq 1 100); do
  if (exec 3<>"/dev/tcp/127.0.0.1/${TESTKIT_BACKEND_PORT}") 2>/dev/null; then
    exec 3>&- 3<&-
    break
  fi
  sleep 0.1
done

if [ "${#suites[@]}" -eq 0 ] && [ -n "${SUITE:-}" ]; then
  read -r -a suites <<< "${SUITE}"
fi

export PYTHONPATH="${NEO4J_TESTKIT_DIR}"
export TEST_DRIVER_NAME=ocaml
export TEST_BACKEND_HOST=127.0.0.1
export TEST_BACKEND_PORT="${TESTKIT_BACKEND_PORT}"
export TEST_NEO4J_HOST="${neo4j_ip}"
export TEST_NEO4J_PORT="${NEO4J_BOLT_PORT}"
export TEST_NEO4J_USER="${NEO4J_USER}"
export TEST_NEO4J_PASS="${NEO4J_PASS}"
export TEST_NEO4J_SCHEME="${NEO4J_SCHEME}"
export TEST_NEO4J_VERSION="${TESTKIT_VERSION}"
export TEST_NEO4J_EDITION="${NEO4J_EDITION}"
export TEST_NEO4J_DEFAULT_DB=neo4j

run_module() {
  local mod="$1"
  echo "=== ${mod} ==="
  if [ "${TESTKIT_MODULE_TIMEOUT}" = "0" ]; then
    TESTKIT_VERBOSITY="${TESTKIT_VERBOSITY}" \
      "${PY}" "${REPO_ROOT}/scripts/lib/testkit_module_result.py" "${mod}"
  else
    timeout -k 30 "${TESTKIT_MODULE_TIMEOUT}" \
      "${PY}" "${REPO_ROOT}/scripts/lib/testkit_module_result.py" "${mod}"
  fi
}

if [ "${#suites[@]}" -gt 0 ]; then
  echo "=== Running the TestKit neo4j suite per module (${TESTKIT_VERSION}) ==="
  failed=0
  for mod in "${suites[@]}"; do
    set +e
    run_module "${mod}"
    rc=$?
    set -e
    if [ "${rc}" -eq 124 ]; then
      echo "!!! module timed out after ${TESTKIT_MODULE_TIMEOUT}s: ${mod}" >&2
      failed=1
    elif [ "${rc}" -ne 0 ]; then
      echo "!!! module failed: ${mod}" >&2
      failed=1
    fi
  done
  exit "${failed}"
fi

echo "=== Running the TestKit suite (${TESTKIT_VERSION}) ==="
cd "${NEO4J_TESTKIT_DIR}"
"${PY}" -m tests.neo4j.suites "${TESTKIT_VERSION}" local
