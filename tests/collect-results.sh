#!/usr/bin/env bash
# ============================================================================
# tests/collect-results.sh — assemble benchmark/results/tests-run.log.
#
# The requirement is a log that captures the exact commands and their raw
# output. The group scripts already write their full stdout to
# benchmark/results/<group>.txt and every raw artifact to
# benchmark/results/raw/<group>/, so this script does not invent anything: it
# concatenates what was recorded, in order, under a header naming the exact
# commands that produced it.
# ============================================================================
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO}"
R="${REPO}/benchmark/results"
OUT="${R}/tests-run.log"

{
    echo "================================================================================"
    echo "POC test run — exact commands and raw output"
    echo "assembled $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "architecture at assembly time: $(grep -E '^ARCH=' .env | cut -d= -f2)"
    echo "================================================================================"
    echo
    echo "HOW THIS RUN WAS PRODUCED"
    echo "-------------------------"
    echo "  ./tests/functional/b1-target-functional.sh   # arch=target"
    echo "  ./tests/functional/b2-current-functional.sh  # arch=current"
    echo "  ./tests/security/b3-target-security.sh       # arch=target"
    echo "  ./tests/security/b4-current-security.sh      # arch=current"
    echo "  ./tests/failover/b5-failover.sh              # arch=target AND arch=current"
    echo
    echo "  # architecture switching (see the up.sh note below)"
    echo "  ./scripts/up.sh current|target"
    echo "  ./scripts/wait-ready.sh"
    echo
    echo "  # every client invocation is logged verbatim inside its group section,"
    echo "  # in the form: \$ docker run ... poc-client <args>"
    echo
    echo "  NOTE ON ./scripts/up.sh: the architecture is selected by COMPOSE FILE,"
    echo "  not by a profile -- compose.yaml is TARGET (a bare 'docker compose up -d'"
    echo "  brings TARGET up) and compose.current.yaml is CURRENT. up.sh picks the"
    echo "  file, writes ARCH into .env, and runs the compose build itself, so no"
    echo "  separate 'docker compose up -d --build' is needed (and a bare one after"
    echo "  './scripts/up.sh current' would start the TARGET services on top)."
    echo "  There is no docker-compose.yml and no COMPOSE_PROFILES any more."
    echo "  The run recorded below predates this: an earlier up.sh forwarded \"\$@\""
    echo "  without shifting the architecture argument off first, so compose failed"
    echo "  with 'no such service: current' and the run proceeded with a plain"
    echo "  'docker compose up -d --build'. That defect is fixed."
    echo
    echo "  RESULTS LAYOUT"
    echo "  --------------"
    echo "    tests-run.log            this file"
    echo "    <group>.txt              full stdout+stderr of one group, PASS/FAIL inline"
    echo "    <group>-<arch>.stdout    verbatim stdout for runs repeated per architecture"
    echo "    raw/<group>/*            every raw artifact: client JSON, probe series,"
    echo "                             VIP ownership series, DNS answers, dig output"
    echo
    echo "    FAILOVER-NOTES.txt       why failover timings come from keepalived's"
    echo "                             console log and not from the notify hook"
    echo "================================================================================"
    echo
    # b5-failover.txt is the group log of the LAST b5 run, which was on TARGET
    # (it is run last so the stack is left on the target architecture). The
    # CURRENT b5 run is preserved verbatim as b5-failover-current.stdout.
    for f in "${R}"/b1-target-functional.txt \
             "${R}"/b3-target-security.txt \
             "${R}"/b2-current-functional.txt \
             "${R}"/b4-current-security.txt \
             "${R}"/b5-failover-current.stdout \
             "${R}"/b5-failover.txt; do
        [ -f "${f}" ] || continue
        echo
        echo "################################################################################"
        echo "# $(basename "${f}")"
        echo "################################################################################"
        cat "${f}"
    done
    echo
    echo "================================================================================"
    echo "RAW ARTIFACT INVENTORY"
    echo "================================================================================"
    find "${R}/raw" -type f | sort | sed "s|${R}/raw/|  raw/|"
} > "${OUT}" 2>&1

echo "wrote ${OUT} ($(wc -l < "${OUT}") lines)"
