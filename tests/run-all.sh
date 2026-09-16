#!/usr/bin/env bash
# ============================================================================
# tests/run-all.sh — run every test group that applies to the CURRENT
# architecture, in order, writing raw output to benchmark/results/.
#
#   ./tests/run-all.sh              # groups for whatever .env says
#   ./tests/run-all.sh b1 b3        # only the named groups
#
# Group -> architecture:
#   b1  TARGET functional      (arch=target)
#   b2  CURRENT functional     (arch=current)
#   b3  TARGET security        (arch=target)
#   b4  CURRENT security       (arch=current)
#   b5  failover               (both)
#
# WHAT b4's VERDICT MEANS DEPENDS ON .env's SQUID_CONF, and the two models are
# opposites. b4 branches on it and records which one it tested, so its group log
# is self-describing, but a reader must still know which to expect:
#
#   SQUID_CONF=squid.conf  (DEFAULT, production-faithful)
#       b4 PASSES by confirming CURRENT ALLOWS the SSRF corpus — production has
#       no destination policy and is an open forward proxy. The run ends with a
#       CONFIRMED VULNERABILITY banner. It is not a clean security result.
#
#   SQUID_CONF=squid.conf.hardened  (COUNTERFACTUAL, not deployed)
#       b4 PASSES by confirming 403 refusals from the invented resolved-address
#       policy. That is a result about a configuration nobody runs, and it must
#       never be reported as CURRENT's production behaviour.
#
# run-all does not choose between them: the model is decided when the stack is
# started (./scripts/up.sh + .env), so this suite only reports which one it ran
# against. See docs/adr/0028-production-config-fidelity.md.
#
# The architecture is NOT switched automatically: switching tears down and
# recreates containers, and doing that silently in the middle of a suite would
# destroy the stack a previous group just measured. Run ./scripts/up.sh first.
# ============================================================================
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO}"

ARCH="$(grep -E '^ARCH=' .env | cut -d= -f2)"
# Recorded for every run because it decides what a b4 PASS means: the two Squid
# access-control models produce opposite results for the same corpus. See the
# header note above.
SQUID_CONF="$(grep -E '^SQUID_CONF=' .env | cut -d= -f2)"; SQUID_CONF="${SQUID_CONF:-squid.conf}"
RESULTS="${REPO}/benchmark/results"
mkdir -p "${RESULTS}"

want() { [ "$#" -eq 0 ] && return 0; for a in "$@"; do [ "$a" = "$1" ] && return 0; done; return 1; }
WANT=("$@")

rc=0
run_group() { # run_group <id> <script> <required-arch|any>
    local id="$1" script="$2" need="$3"
    want "${id}" || { echo "[run-all] skipping ${id} (not requested)"; return 0; }
    if [ "${need}" != "any" ] && [ "${ARCH}" != "${need}" ]; then
        echo "[run-all] skipping ${id}: requires arch=${need}, current arch=${ARCH}"
        return 0
    fi
    echo
    echo "[run-all] ===== ${id} (${script}) arch=${ARCH} ====="
    "${REPO}/${script}" | tee "${RESULTS}/${id}.stdout"
    local r=${PIPESTATUS[0]}
    [ "${r}" -ne 0 ] && rc=1
    return 0
}

echo "[run-all] arch=${ARCH}  started $(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "${RESULTS}/tests-run.log"
# The b4 line matters more than it looks: an ALLOW-based PASS and a 403-based
# PASS are both "PASS", and only this line says which one this run produced.
echo "[run-all] SQUID_CONF=${SQUID_CONF}  (decides what a b4 PASS means: squid.conf = open proxy ALLOWS; squid.conf.hardened = counterfactual 403s)" | tee -a "${RESULTS}/tests-run.log"

run_group b1 tests/functional/b1-target-functional.sh  target
run_group b2 tests/functional/b2-current-functional.sh current
run_group b3 tests/security/b3-target-security.sh      target
run_group b4 tests/security/b4-current-security.sh     current
run_group b5 tests/failover/b5-failover.sh             any

echo
echo "[run-all] finished $(date -u +%Y-%m-%dT%H:%M:%SZ) rc=${rc}"
exit "${rc}"
