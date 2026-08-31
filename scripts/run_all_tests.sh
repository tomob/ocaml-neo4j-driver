#!/usr/bin/env bash
#
# Run every test in the project:
#   1. unit            dune runtest + backend smoke
#   2. testkit stub    every tests.stub.* module, one process per module
#   3. testkit neo4j   every tests.neo4j.* module, one process per module
#                      (local Neo4j container up once for the whole phase)
#   4. integration     scripts/integration.sh run-integration (plain + TLS)
#   5. check           dune build @fmt + @doc (not part of --all)
#
# Per-module runs are isolated and time-bounded (TESTKIT_MODULE_TIMEOUT), so a
# single hanging test cannot block the whole script. A final report lists the
# PASS/SKIP/FAIL/ERROR/TIMEOUT breakdown per module and per phase.
#
# Usage:
#   scripts/run_all_tests.sh [OPTION...]
#     --unit --stub --neo4j --integration --check   run only the given phases
#     --all            every test phase: unit, stub, neo4j, integration (default)
#     --no-docker      unit + stub only
#     --stop-on-error  stop after the first failing phase
#     -h, --help
#
# Environment (passed through to the phase scripts):
#   NEO4J_TESTKIT_DIR       required for the stub/neo4j phases
#   NEO4J_EDITION           community (default) | aura | enterprise
#   NEO4J_URI, NEO4J_USER, NEO4J_PASS, TESTKIT_VERSION, TESTKIT_BACKEND_PORT,
#   TESTKIT_NETWORK         passed through unchanged
#   TESTKIT_MODULE_TIMEOUT=600   per-module timeout in seconds (0 = no limit)
#   TESTKIT_PHASE_TIMEOUT=3600   safety net for a whole testkit phase (0 = off)
#   LOG_DIR=...              where phase logs go (default: _build/logs/run-all)
set -uo pipefail

# Locate the project root. The script is usually run from the source tree, but
# dune's @test-all alias invokes a copy placed under _build/default/scripts,
# so fall back to the git top-level (which is the same directory).
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ ! -f "${REPO_ROOT}/dune-project" ]; then
  REPO_ROOT="$(git -C "$REPO_ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
fi
if [ -z "${REPO_ROOT}" ] || [ ! -f "${REPO_ROOT}/dune-project" ]; then
  echo "error: cannot locate the project root (no dune-project nearby)" >&2
  exit 1
fi
cd "$REPO_ROOT"

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: run_all_tests.sh [OPTION...]

Run every test in the project: unit tests, the TestKit stub and neo4j suites
(one process per module, each under a timeout) and the integration tests, then
print a PASS/SKIP/FAIL/ERROR report.

Options:
  -h, --help          show this help and exit
  --unit              run the unit tests (dune runtest + backend smoke)
  --stub              run every TestKit stub suite module
  --neo4j             run every TestKit neo4j suite module (needs docker)
  --integration       run the integration tests (needs docker)
  --check             run dune build @fmt and @doc
  --all               every test phase above except --check (default)
  --no-docker         --unit --stub
  --stop-on-error     stop after the first failing phase

Environment:
  NEO4J_TESTKIT_DIR        required for --stub/--neo4j
  TESTKIT_MODULE_TIMEOUT=600   per-module timeout in seconds (0 = no limit)
  TESTKIT_PHASE_TIMEOUT=3600   safety net for a whole testkit phase (0 = off)
  NEO4J_EDITION, NEO4J_URI, NEO4J_USER, NEO4J_PASS, TESTKIT_VERSION,
  TESTKIT_BACKEND_PORT, TESTKIT_NETWORK  are passed through to the scripts.
EOF
}

# --- phase selection -------------------------------------------------------
run_unit=0
run_stub=0
run_neo4j=0
run_integration=0
run_check=0
stop_on_error=0
specified=0
for arg in "$@"; do
  case "$arg" in
    -h | --help)
      usage
      exit 0
      ;;
    --unit)
      run_unit=1
      specified=1
      ;;
    --stub)
      run_stub=1
      specified=1
      ;;
    --neo4j)
      run_neo4j=1
      specified=1
      ;;
    --integration)
      run_integration=1
      specified=1
      ;;
    --check)
      run_check=1
      specified=1
      ;;
    --all)
      run_unit=1
      run_stub=1
      run_neo4j=1
      run_integration=1
      specified=1
      ;;
    --no-docker)
      run_unit=1
      run_stub=1
      specified=1
      ;;
    --stop-on-error)
      stop_on_error=1
      ;;
    -*) die "unknown option: $arg (try '--help')" ;;
    *) die "unexpected argument: $arg (try '--help')" ;;
  esac
done
if [ "${specified}" -eq 0 ]; then
  run_unit=1
  run_stub=1
  run_neo4j=1
  run_integration=1
fi

# --- shared state ----------------------------------------------------------
log_dir="${LOG_DIR:-${REPO_ROOT}/_build/logs/run-all}"
mkdir -p "${log_dir}" || die "cannot create log directory ${log_dir}"

overall_failed=0
stopped=0
results=()
failed_modules=()
declare -A mod_status

ph_status=""
ph_detail=""

require_docker() {
  command -v docker >/dev/null 2>&1
}

require_testkit() {
  [ -n "${NEO4J_TESTKIT_DIR:-}" ] || return 1
  [ -x "${NEO4J_TESTKIT_DIR}/.venv/bin/python" ] || return 1
  [ -d "${NEO4J_TESTKIT_DIR}/nutkit" ] || return 1
}

# --- phases ----------------------------------------------------------------
phase_unit() {
  local log="${log_dir}/unit.log"
  ph_detail=""
  echo "=== Unit tests (dune runtest) ==="
  if ! dune runtest 2>&1 | tee "${log}"; then
    ph_status=FAIL
    ph_detail="dune runtest failed (see ${log})"
    return 1
  fi
  echo "=== Backend smoke ==="
  if ! "${REPO_ROOT}/scripts/backend_smoke.sh" 2>&1 | tee -a "${log}"; then
    ph_status=FAIL
    ph_detail="backend smoke failed (see ${log})"
    return 1
  fi
  ph_status=PASS
  return 0
}

# Aggregate the RESULT lines of a per-module testkit run into globals.
aggregate_testkit_log() {
  local log="$1"
  local line re m run passed skipped failures errors
  agg_run=0
  agg_passed=0
  agg_skipped=0
  agg_failures=0
  agg_errors=0
  agg_nmodules=0
  agg_nfailed=0
  agg_timeouts=0
  re='^RESULT module=([^ ]+) run=([0-9]+) passed=([0-9]+) skipped=([0-9]+) failures=([0-9]+) errors=([0-9]+)( import_error=.*)?$'
  while IFS= read -r line; do
    if [[ "${line}" =~ ${re} ]]; then
      m="${BASH_REMATCH[1]}"
      run="${BASH_REMATCH[2]}"
      passed="${BASH_REMATCH[3]}"
      skipped="${BASH_REMATCH[4]}"
      failures="${BASH_REMATCH[5]}"
      errors="${BASH_REMATCH[6]}"
      agg_nmodules=$((agg_nmodules + 1))
      agg_run=$((agg_run + run))
      agg_passed=$((agg_passed + passed))
      agg_skipped=$((agg_skipped + skipped))
      agg_failures=$((agg_failures + failures))
      agg_errors=$((agg_errors + errors))
      if [ "${failures}" -ne 0 ] || [ "${errors}" -ne 0 ]; then
        agg_nfailed=$((agg_nfailed + 1))
        mod_status["${m}"]="FAIL (passed=${passed}, skipped=${skipped}, failures=${failures}, errors=${errors})"
        failed_modules+=("${m}")
      elif [ "${run}" -eq 0 ] && [ "${skipped}" -gt 0 ]; then
        mod_status["${m}"]="SKIP (skipped=${skipped})"
      elif [ "${run}" -eq 0 ]; then
        mod_status["${m}"]="ERROR (no tests ran)"
      else
        mod_status["${m}"]="PASS (passed=${passed}, skipped=${skipped})"
      fi
    fi
  done < <(grep -E '^RESULT ' "${log}" 2>/dev/null || true)

  local to
  while IFS= read -r to; do
    [ -n "${to}" ] || continue
    agg_timeouts=$((agg_timeouts + 1))
    agg_nfailed=$((agg_nfailed + 1))
    agg_errors=$((agg_errors + 1))
    failed_modules+=("${to}")
    mod_status["${to}"]="TIMEOUT"
  done < <(grep '^!!! module timed out' "${log}" 2>/dev/null | sed 's/^!!! module timed out after [0-9]*s: //' || true)
}

phase_testkit() {
  local name="$1" script="$2"
  local log="${log_dir}/${name}.log"
  local modules rc tnote
  modules="$("${script}" -l 2>/dev/null)" || {
    ph_status=ERROR
    ph_detail="cannot list ${name} modules (is NEO4J_TESTKIT_DIR set?)"
    return 1
  }
  mapfile -t modarr <<< "${modules}"
  echo "=== TestKit ${name} suites (${#modarr[@]} modules, one process each) ==="
  if [ "${TESTKIT_PHASE_TIMEOUT:-3600}" != "0" ]; then
    timeout -k 60 "${TESTKIT_PHASE_TIMEOUT:-3600}" "${script}" "${modarr[@]}" 2>&1 | tee "${log}"
  else
    "${script}" "${modarr[@]}" 2>&1 | tee "${log}"
  fi
  rc=$?
  aggregate_testkit_log "${log}"
  tnote=""
  [ "${agg_timeouts}" -gt 0 ] && tnote=", ${agg_timeouts} timed out"
  ph_detail="${agg_nmodules}/${#modarr[@]} modules | ${agg_passed} passed, ${agg_skipped} skipped, ${agg_failures} failures, ${agg_errors} errors${tnote}"
  if [ "${rc}" -ne 0 ]; then
    ph_status=FAIL
    return 1
  fi
  ph_status=PASS
  return 0
}

phase_stub() {
  if ! require_testkit; then
    ph_status=ERROR
    ph_detail="NEO4J_TESTKIT_DIR with a testkit venv is required (see scripts/README.md)"
    return 1
  fi
  phase_testkit stub "${REPO_ROOT}/scripts/testkit_stub.sh"
}

phase_neo4j() {
  if ! require_testkit; then
    ph_status=ERROR
    ph_detail="NEO4J_TESTKIT_DIR with a testkit venv is required (see scripts/README.md)"
    return 1
  fi
  if ! require_docker; then
    ph_status=ERROR
    ph_detail="docker is required for the neo4j phase"
    return 1
  fi
  phase_testkit neo4j "${REPO_ROOT}/scripts/testkit_run_locally.sh"
}

phase_integration() {
  local log="${log_dir}/integration.log"
  if ! require_docker; then
    ph_status=ERROR
    ph_detail="docker is required for the integration phase"
    return 1
  fi
  ph_detail=""
  echo "=== Integration tests (plain + TLS) ==="
  if ! "${REPO_ROOT}/scripts/integration.sh" run-integration 2>&1 | tee "${log}"; then
    ph_status=FAIL
    ph_detail="see ${log}"
    return 1
  fi
  ph_status=PASS
  return 0
}

phase_check() {
  local log="${log_dir}/check.log"
  ph_detail=""
  echo "=== Format check (dune build @fmt) ==="
  if ! dune build @fmt 2>&1 | tee "${log}"; then
    ph_status=FAIL
    ph_detail="ocamlformat check failed (see ${log})"
    return 1
  fi
  echo "=== Docs build (dune build @doc) ==="
  if ! dune build @doc 2>&1 | tee -a "${log}"; then
    ph_status=FAIL
    ph_detail="docs build failed (see ${log})"
    return 1
  fi
  ph_status=PASS
  return 0
}

# --- runner ----------------------------------------------------------------
run_phase() {
  local name="$1" func="$2"
  if [ "${stopped}" -eq 1 ]; then
    results+=("${name}|SKIP|stopped after an earlier failure (--stop-on-error)")
    return 0
  fi
  ph_status=""
  ph_detail=""
  "${func}"
  local rc=$?
  results+=("${name}|${ph_status:-ERROR}|${ph_detail:-}")
  if [ "${rc}" -ne 0 ]; then
    overall_failed=1
    if [ "${stop_on_error}" -eq 1 ]; then
      stopped=1
    fi
  fi
}

report() {
  echo
  echo "=== Report ==="
  local r name status detail
  for r in "${results[@]}"; do
    IFS='|' read -r name status detail <<< "${r}"
    printf '  [%-12s] %-6s %s\n' "${name}" "${status}" "${detail}"
  done
  if [[ ${mod_status[@]+set} = set ]]; then
    echo
    echo "Modules:"
    local m
    for m in $(printf '%s\n' "${!mod_status[@]}" | sort); do
      printf '  %-58s %s\n' "${m}" "${mod_status[$m]}"
    done
  fi
  if [ "${#failed_modules[@]}" -gt 0 ]; then
    echo
    echo "Failed/errored modules:"
    printf '  %s\n' "${failed_modules[@]}" | sort -u
  fi
  echo
  echo "Logs: ${log_dir}"
  if [ "${overall_failed}" -eq 1 ]; then
    echo "Result: FAIL (some tests did not pass)"
    return 1
  fi
  echo "Result: PASS (all phases green)"
  return 0
}

# --- main ------------------------------------------------------------------
if [ "${run_unit}" -eq 1 ]; then
  run_phase unit phase_unit
fi
if [ "${run_stub}" -eq 1 ]; then
  run_phase stub phase_stub
fi
if [ "${run_neo4j}" -eq 1 ]; then
  run_phase neo4j phase_neo4j
fi
if [ "${run_integration}" -eq 1 ]; then
  run_phase integration phase_integration
fi
if [ "${run_check}" -eq 1 ]; then
  run_phase check phase_check
fi

report
