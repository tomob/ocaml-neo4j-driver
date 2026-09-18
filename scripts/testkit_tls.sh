#!/usr/bin/env bash
#
# Run TestKit TLS suites (tests.tls.*) against the locally built testkit
# backend. No Neo4j server is needed: every test starts the Go TLS server from
# the testkit checkout (testkit/tlsserver) and the driver connects to it over
# bolt+s / bolt+ssc / neo4j+s / neo4j+ssc (or plain schemes, where the test
# asserts the connection fails).
#
# Usage:
#   scripts/testkit_tls.sh [OPTION...] [SUITE ...]
#
# With no SUITE arguments the whole TLS suite runs (`python -m tests.tls.suites`);
# otherwise each argument is run in its own process (a test module / class or a
# single test), e.g.:
#   scripts/testkit_tls.sh tests.tls.test_secure_scheme
#   scripts/testkit_tls.sh tests.tls.test_secure_scheme \
#     tests.tls.test_self_signed_scheme
#
# The SUITE environment variable is an alternative to positional arguments
# (space-separated modules); positional arguments take precedence.
#
# Backend placement (TESTKIT_TLS_BACKEND, or --host/--container):
#   auto (default)  the backend runs on the host when the testkit TLS hostnames
#                   (thehost / thehostbutwrong) resolve, otherwise in a container
#                   built from the repo Dockerfile with
#                   `--add-host thehost:host-gateway` so it can still reach the
#                   host's TLS server. Requires docker in the container case.
#   host            backend on the host; requires the two hostnames in
#                   /etc/hosts, e.g. `127.0.0.1 thehost thehostbutwrong`.
#   container       backend in a container (docker).
#
# The testkit "trusted" root CA is added to the backend trust store through the
# ca-certs OCAML_EXTRA_CA_CERTS variable, so bolt+s / neo4j+s validate the
# testkit server certificates.
#
# Configuration via environment variables (defaults shown):
#   NEO4J_TESTKIT_DIR        path to a neo4j-drivers/testkit checkout (required)
#   TESTKIT_TLS_BACKEND=auto host | container | auto
#   TESTKIT_BACKEND_PORT=9876
#   BACKEND_BINARY=...       backend executable override (host mode; default:
#                            _build/default/testkitbackend/testkitbackend.exe)
#   TESTKIT_BACKEND_IMAGE=ocaml-neo4j-testkit-backend  (container mode)
#   SUITE=...                test modules to run (alternative to arguments)
#   TESTKIT_MODULE_TIMEOUT=600  per-module timeout in seconds (0 = no limit)
#   TESTKIT_VERBOSITY=1      unittest verbosity for the per-module runs
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: testkit_tls.sh [OPTION...] [SUITE ...]

Run the TestKit TLS suites (tests.tls.*) against the locally built backend.
With no SUITE arguments the whole suite runs via tests.tls.suites.

Options:
  -h, --help          show this help and exit
  -l, --list-suites   list all available TLS test modules and exit
  --host              run the backend on the host (the testkit TLS hostnames
                      must resolve; see TESTKIT_TLS_BACKEND below)
  --container         run the backend in a docker container (the hostnames are
                      added via --add-host)

SUITE arguments are test modules / classes / single tests, e.g.:
  tests.tls.test_secure_scheme
  tests.tls.test_secure_scheme tests.tls.test_self_signed_scheme

Environment:
  NEO4J_TESTKIT_DIR        path to a neo4j-drivers/testkit checkout (required)
  TESTKIT_TLS_BACKEND=auto host | container | auto
  TESTKIT_BACKEND_PORT=9876
  BACKEND_BINARY=...       backend executable override (host mode)
  TESTKIT_BACKEND_IMAGE=ocaml-neo4j-testkit-backend
  SUITE=...                test modules to run (alternative to arguments)
  TESTKIT_MODULE_TIMEOUT=600  per-module timeout in seconds (0 = no limit)
  TESTKIT_VERBOSITY=1      unittest verbosity for the per-module runs
EOF
}

list_suites() {
  NEO4J_TESTKIT_DIR="${NEO4J_TESTKIT_DIR:?set NEO4J_TESTKIT_DIR to the testkit checkout}"
  [ -d "$NEO4J_TESTKIT_DIR/tests/tls" ] \
    || die "NEO4J_TESTKIT_DIR does not look like a testkit checkout"
  find "$NEO4J_TESTKIT_DIR/tests/tls" -name "test_*.py" \
    | sed 's|^.*/tests/tls/|tests.tls.|; s|/|.|g; s|\.py$||' \
    | sort
}

# The TLS tests connect with these two names; the second one must resolve to the
# same address as the first so the server receives the (rejected) connection.
tls_hostnames_resolve() {
  getent hosts thehost >/dev/null 2>&1 && getent hosts thehostbutwrong >/dev/null 2>&1
}

docker_available() { command -v docker >/dev/null 2>&1; }

# Parse options first (so --help/--list-suites work without the backend).
suites=()
force_backend=""
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
    --host)
      force_backend=host
      ;;
    --container)
      force_backend=container
      ;;
    -*) die "unknown option: $arg (try '$0 --help')" ;;
    *) suites+=("$arg") ;;
  esac
done

NEO4J_TESTKIT_DIR="${NEO4J_TESTKIT_DIR:?set NEO4J_TESTKIT_DIR to the testkit checkout}"
PY="${NEO4J_TESTKIT_DIR}/.venv/bin/python"
TESTKIT_BACKEND_PORT="${TESTKIT_BACKEND_PORT:-9876}"
TESTKIT_BACKEND_IMAGE="${TESTKIT_BACKEND_IMAGE:-ocaml-neo4j-testkit-backend}"
BACKEND_BINARY="${BACKEND_BINARY:-${REPO_ROOT}/_build/default/testkitbackend/testkitbackend.exe}"
TESTKIT_MODULE_TIMEOUT="${TESTKIT_MODULE_TIMEOUT:-600}"
TESTKIT_VERBOSITY="${TESTKIT_VERBOSITY:-1}"
TESTKIT_TLS_BACKEND="${TESTKIT_TLS_BACKEND:-auto}"

[ -x "$PY" ] || die "no venv python at $PY (install the testkit dependencies first)"
[ -d "$NEO4J_TESTKIT_DIR/nutkit" ] || die "NEO4J_TESTKIT_DIR does not look like a testkit checkout"

TLS_CERT="${NEO4J_TESTKIT_DIR}/tests/tls/certs/driver/trusted/trustedRoot.crt"
[ -r "$TLS_CERT" ] || die "testkit TLS root CA not found at $TLS_CERT"
# The [trusted_certificates] configs of the TLS tests name their files relative
# to this directory (e.g. "customRoot.crt"); the backend resolves them against
# TESTKIT_TLS_CERTS_DIR.
TLS_CERTS_DIR="${NEO4J_TESTKIT_DIR}/tests/tls/certs/driver/custom"
[ -d "$TLS_CERTS_DIR" ] || die "testkit custom TLS certs not found at $TLS_CERTS_DIR"
TLSSERVER_DIR="${NEO4J_TESTKIT_DIR}/tlsserver"
TLSSERVER_BIN="${TLSSERVER_DIR}/tlsserver"
[ -f "${TLSSERVER_DIR}/main.go" ] || die "testkit TLS server source not found in $TLSSERVER_DIR"

# The tests spawn the Go TLS server themselves; build it once (no network needed,
# the program only uses the standard library).
if [ ! -x "$TLSSERVER_BIN" ]; then
  command -v go >/dev/null 2>&1 \
    || die "go not found (needed to build ${TLSSERVER_DIR}/tlsserver)"
  echo "=== Building the testkit TLS server (go) ==="
  # The testkit checkout ships a bare main.go (no go.mod), so build the file
  # directly instead of the package.
  (cd "$TLSSERVER_DIR" && go build -o tlsserver main.go)
fi

# Pick the backend placement.
backend="${force_backend:-$TESTKIT_TLS_BACKEND}"
case "$backend" in
  auto)
    if tls_hostnames_resolve; then
      backend=host
    elif docker_available; then
      backend=container
    else
      die "thehost/thehostbutwrong do not resolve and docker is unavailable; add '127.0.0.1 thehost thehostbutwrong' to /etc/hosts or install docker"
    fi
    ;;
  host | container) ;;
  *) die "invalid TESTKIT_TLS_BACKEND '$backend' (host | container | auto)" ;;
esac

if [ "$backend" = host ] && ! tls_hostnames_resolve; then
  die "thehost/thehostbutwrong do not resolve; add '127.0.0.1 thehost thehostbutwrong' to /etc/hosts or use --container"
fi

backend_pid=""
backend_container="testkit-tls-backend"
cleanup() {
  if [ -n "${backend_pid}" ]; then
    kill "${backend_pid}" >/dev/null 2>&1 || true
    wait "${backend_pid}" >/dev/null 2>&1 || true
  fi
  docker rm -f "${backend_container}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [ "$backend" = host ]; then
  # shellcheck source=lib/testkit_backend.sh
  source "${REPO_ROOT}/scripts/lib/testkit_backend.sh"
  # Add the testkit root CA to the trust store (ca-certs) and let the backend
  # resolve the tests' relative certificate paths.
  export OCAML_EXTRA_CA_CERTS="$TLS_CERT"
  export TESTKIT_TLS_CERTS_DIR="$TLS_CERTS_DIR"
  testkit_backend_start
else
  docker_available || die "docker not found (required for the container backend)"
  echo "=== Building the testkit backend image ==="
  docker build -t "${TESTKIT_BACKEND_IMAGE}" "$REPO_ROOT"
  echo "=== Starting the testkit backend in a container (port ${TESTKIT_BACKEND_PORT}) ==="
  docker rm -f "${backend_container}" >/dev/null 2>&1 || true
  docker run -d --name "${backend_container}" \
    --add-host thehost:host-gateway \
    --add-host thehostbutwrong:host-gateway \
    -e OCAML_EXTRA_CA_CERTS=/certs/trustedRoot.crt \
    -e TESTKIT_TLS_CERTS_DIR=/certs/custom \
    -v "${TLS_CERT}:/certs/trustedRoot.crt:ro" \
    -v "${TLS_CERTS_DIR}:/certs/custom:ro" \
    -p "${TESTKIT_BACKEND_PORT}:9876" \
    "${TESTKIT_BACKEND_IMAGE}" >/dev/null
  ready=0
  for _ in $(seq 1 100); do
    if (exec 3<>"/dev/tcp/127.0.0.1/${TESTKIT_BACKEND_PORT}") 2>/dev/null; then
      exec 3>&- 3<&-
      ready=1
      break
    fi
    if [ "$(docker inspect -f '{{.State.Running}}' "${backend_container}" 2>/dev/null)" != "true" ]; then
      docker logs "${backend_container}" >&2 || true
      die "backend container exited before the suite ran"
    fi
    sleep 0.1
  done
  [ "${ready}" -eq 1 ] || die "backend did not start listening on port ${TESTKIT_BACKEND_PORT}"
fi

if [ "${#suites[@]}" -eq 0 ] && [ -n "${SUITE:-}" ]; then
  read -r -a suites <<< "${SUITE}"
fi

export PYTHONPATH="${NEO4J_TESTKIT_DIR}"
export TEST_DRIVER_NAME=ocaml
export TEST_BACKEND_HOST=127.0.0.1
export TEST_BACKEND_PORT="${TESTKIT_BACKEND_PORT}"

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
  echo "=== Running the TestKit TLS suite(s) per module ==="
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

echo "=== Running the TestKit TLS suite ==="
cd "${NEO4J_TESTKIT_DIR}"
"${PY}" -m tests.tls.suites
