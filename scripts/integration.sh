#!/usr/bin/env bash
#
# Convenience wrapper for running the integration tests against a Neo4j
# instance in Docker.
#
# Usage:
#   scripts/integration.sh run      # full cycle: up -> test -> down
#   scripts/integration.sh up       # start the container (no-op if running)
#   scripts/integration.sh test     # run the integration tests (container must be up)
#   scripts/integration.sh status   # report whether the container is running
#   scripts/integration.sh down     # stop and remove the container
#
# Configuration is via environment variables (defaults shown):
#   NEO4J_IMAGE=neo4j:latest
#   NEO4J_CONTAINER=neo4j-test
#   NEO4J_HOST_PORT=7687
#   NEO4J_BOLT_PORT=7687
#   NEO4J_USER=neo4j
#   NEO4J_PASS=testpassword
#   NEO4J_SCHEME=bolt
#   NEO4J_LOG=/var/lib/neo4j/logs/neo4j.log
set -euo pipefail

NEO4J_IMAGE="${NEO4J_IMAGE:-neo4j:latest}"
NEO4J_CONTAINER="${NEO4J_CONTAINER:-neo4j-test}"
NEO4J_HOST_PORT="${NEO4J_HOST_PORT:-7687}"
NEO4J_BOLT_PORT="${NEO4J_BOLT_PORT:-7687}"
NEO4J_USER="${NEO4J_USER:-neo4j}"
NEO4J_PASS="${NEO4J_PASS:-testpassword}"
NEO4J_SCHEME="${NEO4J_SCHEME:-bolt}"
NEO4J_LOG="${NEO4J_LOG:-/var/lib/neo4j/logs/neo4j.log}"

die() {
  echo "error: $*" >&2
  exit 1
}

docker_available() {
  command -v docker >/dev/null 2>&1
}

is_running() {
  docker ps --filter "name=${NEO4J_CONTAINER}" --format '{{.Names}}' 2>/dev/null | grep -q .
}

# Probe the Bolt port with a real handshake; succeeds only when the server
# actually responds (a bare TCP connect can succeed before the server is
# ready to serve Bolt and gets reset).
bolt_handshake_ok() {
  local n
  n=$(timeout 10 bash -c "exec 3<>/dev/tcp/127.0.0.1/${NEO4J_HOST_PORT}"'
      printf "\x60\x60\xb0\x17\x00\x00\x01\xff\x00\x08\x08\x05\x00\x02\x04\x04\x00\x00\x00\x03" >&3
      dd bs=4 count=1 <&3 2>/dev/null | wc -c' 2>/dev/null) || return 1
  [ "${n:-0}" -ge 4 ]
}

# Wait for the server to be ready: check the Neo4j log for "Started." and fall
# back to a real Bolt handshake probe for images that log elsewhere.
wait_ready() {
  echo "Waiting for Neo4j to start..."
  for _ in $(seq 1 90); do
    if docker exec "${NEO4J_CONTAINER}" sh -c "grep -q 'Started.' ${NEO4J_LOG} 2>/dev/null" 2>/dev/null; then
      echo "Neo4j is ready."
      return 0
    fi
    if bolt_handshake_ok; then
      echo "Neo4j is ready (Bolt handshake ok)."
      return 0
    fi
    sleep 2
  done
  echo "Neo4j did not become ready in time." >&2
  return 1
}

up() {
  docker_available || die "docker not found"
  if is_running; then
    echo "Container '${NEO4J_CONTAINER}' is already running."
    return 0
  fi
  docker run -d --name "${NEO4J_CONTAINER}" \
    -p "${NEO4J_HOST_PORT}:${NEO4J_BOLT_PORT}" \
    -e "NEO4J_AUTH=${NEO4J_USER}/${NEO4J_PASS}" \
    "${NEO4J_IMAGE}" >/dev/null
  wait_ready
}

down() {
  docker_available || return 0
  if is_running; then
    docker rm -f "${NEO4J_CONTAINER}" >/dev/null
    echo "Container '${NEO4J_CONTAINER}' removed."
  fi
}

run_tests() {
  local filter="${1:-}"
  docker_available || die "docker not found"
  is_running || die "container '${NEO4J_CONTAINER}' is not running; run 'scripts/integration.sh up' first"
  export TEST_NEO4J_HOST="127.0.0.1" \
    TEST_NEO4J_PORT="${NEO4J_HOST_PORT}" \
    TEST_NEO4J_SCHEME="${NEO4J_SCHEME}" \
    TEST_NEO4J_USER="${NEO4J_USER}" \
    TEST_NEO4J_PASS="${NEO4J_PASS}"
  if [ -n "${filter}" ]; then
    # Run only the tests whose suite name contains the filter.
    dune exec -- test/test_main.exe test "${filter}"
  else
    dune runtest --force
  fi
}

test_() {
  run_tests
}

test_integration() {
  run_tests Integration
}

run() {
  local mode="${1:-all}"
  # Ensure the container is removed even if the tests or startup fail.
  trap down EXIT
  up
  case "${mode}" in
    all) test_ ;;
    integration) test_integration ;;
    *) die "unknown run mode: ${mode}" ;;
  esac
}

usage() {
  cat <<EOF
Usage: $0 {run|run-integration|up|test|integration|status|down}

  run              start the container, run all tests, then stop it
  run-integration  start the container, run only the integration tests, then stop it
  up               start the Neo4j container (no-op if already running)
  test             run all tests (container must be running)
  integration      run only the integration tests (container must be running)
  status           report whether the container is running
  down             stop and remove the Neo4j container

Configuration is via environment variables: NEO4J_IMAGE, NEO4J_CONTAINER,
NEO4J_HOST_PORT, NEO4J_BOLT_PORT, NEO4J_USER, NEO4J_PASS, NEO4J_SCHEME, NEO4J_LOG.
EOF
}

case "${1:-run}" in
  up)
    up
    ;;
  down)
    down
    ;;
  test)
    test_
    ;;
  integration)
    test_integration
    ;;
  status)
    if is_running; then echo "running"; else echo "stopped"; fi
    ;;
  run)
    run all
    ;;
  run-integration)
    run integration
    ;;
  *)
    usage
    exit 1
    ;;
esac
