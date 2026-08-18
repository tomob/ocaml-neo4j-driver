# Shared helpers for the TestKit harness scripts that run the backend on the
# host (testkit_run_locally.sh, testkit_stub.sh). Sourced, not executed:
# the sourcing script must define die() first and set TESTKIT_BACKEND_PORT,
# BACKEND_BINARY and backend_pid.

# Fail when something already listens on $1: a leftover backend from an
# interrupted run would otherwise satisfy the readiness probe below and the
# suite would silently run against the stale (old-build) backend.
testkit_backend_assert_free_port() {
  local port="$1"
  if (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
    exec 3>&- 3<&-
    echo "error: port ${port} is already in use (a stale testkit backend or another harness run?)" >&2
    echo "error: kill the stale process or set TESTKIT_BACKEND_PORT to a free port" >&2
    exit 1
  fi
}

# Wait until the backend accepts connections on $1, failing early when the
# backend process (backend_pid) exits first. Times out after 10 seconds.
testkit_backend_wait_ready() {
  local port="$1"
  for _ in $(seq 1 100); do
    if (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
      exec 3>&- 3<&-
      return 0
    fi
    if [ -n "${backend_pid}" ]; then
      kill -0 "${backend_pid}" 2>/dev/null || die "backend exited before the suite ran"
    fi
    sleep 0.1
  done
  die "backend did not start listening on port ${port}"
}

# Build, start and probe the locally built backend. Registers no trap: the
# sourcing script's cleanup() kills backend_pid on exit.
testkit_backend_start() {
  echo "=== Building the testkit backend (dune) ==="
  dune build testkitbackend/testkitbackend.exe
  [ -x "$BACKEND_BINARY" ] || die "backend executable not found at $BACKEND_BINARY"

  testkit_backend_assert_free_port "${TESTKIT_BACKEND_PORT}"

  echo "=== Starting the testkit backend locally (port ${TESTKIT_BACKEND_PORT}) ==="
  TESTKIT_BACKEND_PORT="${TESTKIT_BACKEND_PORT}" "${BACKEND_BINARY}" &
  backend_pid=$!

  testkit_backend_wait_ready "${TESTKIT_BACKEND_PORT}"
}
