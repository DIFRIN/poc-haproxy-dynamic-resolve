#!/usr/bin/env bash
# ============================================================================
# tests/lib.sh — shared helpers for the POC test suite.
#
# Source this; do not execute it.
#
# Every test prints PASS or FAIL with the evidence that produced the verdict,
# and every raw command output is kept under benchmark/results/ so a verdict can
# be re-checked without re-running the stack. Nothing here fabricates a result:
# a check that could not be run is reported as SKIP, never as PASS.
# ============================================================================

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO}"

RESULTS="${REPO}/benchmark/results"
RAW="${RESULTS}/raw"
RUNLOG="${RESULTS}/tests-run.log"
NET="poc-proxy_dc-lan"
PKI="${REPO}/pki"

mkdir -p "${RESULTS}" "${RAW}"

# --- .env ---------------------------------------------------------------------
envval() { grep -E "^$1=" "${REPO}/.env" 2>/dev/null | head -1 | cut -d= -f2-; }

VIP="$(envval VIP_ADDRESS)";        VIP="${VIP:-172.28.0.10}"
# CURRENT has TWO ports and production runs them on different numbers. The
# client-facing CONNECT listener is CLIENT_PORT (production: 38888); Squid
# listens on SQUID_PORT (production: 4443), which is also the port HAProxy's
# proxyhttp backend connects to. A single PROXY_PORT used for both was a
# fidelity defect -- see docs/adr/0028-production-config-fidelity.md.
CLIENT_PORT="$(envval CLIENT_PORT)"; CLIENT_PORT="${CLIENT_PORT:-38888}"
SQUID_PORT="$(envval SQUID_PORT)";   SQUID_PORT="${SQUID_PORT:-4443}"
# Which Squid access-control model the stack was started with: `squid.conf`
# (production-faithful, default) or `squid.conf.hardened` (counterfactual).
# Tests that assert anything about CURRENT's security posture MUST record this,
# because the two produce opposite results. b4 branches on it and says which
# model it ran against; any other group citing CURRENT security must do the
# same. See ADR 0028; tests/fidelity/run.sh measures both models side by side.
SQUID_CONF="$(envval SQUID_CONF)";   SQUID_CONF="${SQUID_CONF:-squid.conf}"
IOT_MOCK_PORT="$(envval IOT_MOCK_PORT)"; IOT_MOCK_PORT="${IOT_MOCK_PORT:-443}"
IOT_MOCK_IP="$(envval IOT_MOCK_IP)";   IOT_MOCK_IP="${IOT_MOCK_IP:-172.28.0.60}"
DNS_ZONE="$(envval DNS_ZONE)";         DNS_ZONE="${DNS_ZONE:-test.domain}"
ARCH="$(envval ARCH)";              ARCH="${ARCH:-target}"
CLIENT_IP="$(envval CLIENT_IP)";    CLIENT_IP="${CLIENT_IP:-172.28.0.100}"

# --- counters -----------------------------------------------------------------
PASS_N=0; FAIL_N=0; SKIP_N=0
GROUP=""; GROUP_LOG=""

# group <name> — start a new test group; opens its own raw directory and log.
group() {
    GROUP="$1"
    GROUP_LOG="${RESULTS}/${GROUP}.txt"
    mkdir -p "${RAW}/${GROUP}"
    : > "${GROUP_LOG}"
    log ""
    log "================================================================================"
    log "GROUP ${GROUP}   $(date -u +%Y-%m-%dT%H:%M:%SZ)   arch=${ARCH}"
    log "================================================================================"
}

# log <line...> — print to stdout AND to the group log AND to the run log.
log() {
    local line="$*"
    printf '%s\n' "${line}"
    [ -n "${GROUP_LOG}" ] && printf '%s\n' "${line}" >> "${GROUP_LOG}"
}

runlog() {
    printf '%s\n' "$*" >> "${RUNLOG}"
}

pass() {
    PASS_N=$((PASS_N+1))
    log "PASS  $1"
}
fail() {
    FAIL_N=$((FAIL_N+1))
    log "FAIL  $1"
}
skip() {
    SKIP_N=$((SKIP_N+1))
    log "SKIP  $1"
}

# expect <description> <condition-result> — condition is "0" for true.
expect() {
    local desc="$1" rc="$2"
    if [ "${rc}" -eq 0 ]; then pass "${desc}"; else fail "${desc}"; fi
}

summary() {
    log ""
    log "---- ${GROUP}: ${PASS_N} PASS, ${FAIL_N} FAIL, ${SKIP_N} SKIP ----"
    runlog "[${GROUP}] $(date -u +%Y-%m-%dT%H:%M:%SZ) pass=${PASS_N} fail=${FAIL_N} skip=${SKIP_N} arch=${ARCH}"
    if [ "${FAIL_N}" -gt 0 ]; then return 1; fi
    return 0
}

# --- JSON helpers -------------------------------------------------------------
# jget <jsonfile> <python-expression over `d`>
jget() {
    python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception as e:
    print("ERR:"+str(e)); sys.exit(0)
print(eval(sys.argv[2]))' "$1" "$2"
}

# --- client wrapper -----------------------------------------------------------
# client_json <outfile> <args...> — run the client on the DC LAN and tee the JSON.
# Returns the client's exit code. Stderr (progress) goes to the group log.
client_json() {
    local out="$1"; shift
    # Record the exact invocation: a verdict is only reproducible if the command
    # that produced it is written down next to it.
    log "  \$ docker run --rm --network ${NET} -v ${PKI}:/pki:ro -v ${RESULTS}:/results poc-client $*"
    runlog "  client: poc-client $*   -> $(basename "${out}")"
    docker run --rm --network "${NET}" \
        -v "${PKI}:/pki:ro" \
        -v "${RESULTS}:/results" \
        poc-client "$@" 2>>"${GROUP_LOG}" | tee "${out}"
    return "${PIPESTATUS[0]}"
}

# Convenience: credentials that the positive tests all use.
CERT_VALID="-client-cert=/pki/clients/client-valid.crt -client-key=/pki/clients/client-valid.key"
CA_POC="-ca=/pki/ca/ca.crt"

# --- VIP / VRRP helpers -------------------------------------------------------

# vip_owner — prints the container name that currently owns the VIP, or "none".
vip_owner() {
    local owner=""
    for n in 1 2; do
        if docker exec "poc-haproxy-${n}" ip -4 addr show eth0 2>/dev/null | grep -q "${VIP}/"; then
            owner="${owner} haproxy-${n}"
        fi
    done
    owner="${owner# }"
    [ -n "${owner}" ] && printf '%s\n' "${owner}" || printf 'none\n'
}

# ctr <node-name> -> the docker container name.
#
# vip_owner() reports the NODE identity ("haproxy-1"), because that is what the
# logs, the VRRP events and the report all speak in. The container is named
# "poc-haproxy-1". Every docker command must go through this mapping: passing
# the node name straight to `docker kill` fails with "No such container" and
# the fault is silently never applied.
ctr() { printf 'poc-%s\n' "$1"; }

# VRRP transition evidence.
#
# WHAT THE DESIGN INTENDED vs WHAT IS ACTUALLY AVAILABLE
#   configs/keepalived/haproxy-N/notify.sh is written to emit
#       [vrrp] <ms-UTC-timestamp> state=MASTER node=haproxy-N
#   and the keepalived.conf comment calls those lines "the primary evidence for
#   every failover-timing number". Measured, they are unusable — see
#   tests/failover/FAILOVER-NOTES.txt, generated by b5. Two independent reasons:
#     1. busybox `date` (this image is Alpine) does not implement %N. The
#        format string "%Y-%m-%dT%H:%M:%S.%3NZ" renders as
#        "2026-09-14T16:16:42." — no fractional seconds and no Z suffix.
#     2. keepalived does not forward notify-script stdout to the container log,
#        so even that truncated line never reaches `docker logs`.
#
#   The evidence that DOES exist is keepalived's own console log, which is in
#   `docker logs` because the entrypoint starts it with `-n -l`. `docker logs -t`
#   prefixes every line with Docker's own nanosecond UTC receipt timestamp.
#
# vrrp_events <node> — "<docker-rfc3339-ms> <STATE>" per state transition.
vrrp_events() {
    docker logs -t "poc-$1" 2>&1 \
        | grep -E '\(DC1\) Entering (MASTER|BACKUP|FAULT) STATE' \
        | sed -E 's/^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3})[0-9]*Z .*Entering ([A-Z]+) STATE/\1Z \2/' \
        || true
}

# vrrp_since <node> <ISO8601-ms-with-Z> — the first transition at or after the
# timestamp. Both sides are UTC and millisecond-width, so string ordering is
# chronological ordering.
vrrp_since() {
    local node="$1" since="$2"
    vrrp_events "${node}" | awk -v s="${since}" '{ if ($1 >= s) { print; exit } }'
}

# notify_hook_evidence — record, once, exactly what the notify hook produces
# versus what keepalived logs. This is raw evidence for the finding above.
notify_hook_evidence() {
    local out="$1"
    {
        echo "=== keepalived/notify.sh, run by hand inside poc-haproxy-1 ==="
        echo '$ /run/keepalived/notify.sh MASTER | cat -A'
        docker exec poc-haproxy-1 /run/keepalived/notify.sh MASTER 2>&1 | cat -A
        echo
        echo "=== busybox date format support ==="
        echo '$ date -u +%Y-%m-%dT%H:%M:%S.%3NZ'
        docker exec poc-haproxy-1 date -u +%Y-%m-%dT%H:%M:%S.%3NZ
        echo '$ date -u +%Y-%m-%dT%H:%M:%S.%NZ'
        docker exec poc-haproxy-1 date -u +%Y-%m-%dT%H:%M:%S.%NZ
        echo '$ date -u +%Y-%m-%dT%H:%M:%SZ'
        docker exec poc-haproxy-1 date -u +%Y-%m-%dT%H:%M:%SZ
        echo
        echo "=== [vrrp] lines present in docker logs (both nodes) ==="
        for n in 1 2; do
            printf 'poc-haproxy-%s: %s lines matching [vrrp]\n' "${n}" \
                "$(docker logs "poc-haproxy-${n}" 2>&1 | grep -c '^\[vrrp\]' || true)"
        done
        echo "(expected 0: keepalived does not forward notify-script stdout)"
        echo
        echo "=== what IS available: keepalived console transitions, docker timestamped ==="
        for n in 1 2; do
            echo "--- poc-haproxy-${n} ---"
            vrrp_events "haproxy-${n}"
        done
    } > "${out}" 2>&1
}

# now_iso — millisecond UTC timestamp in the same format the notify hook emits.
now_iso() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }

# wait_owner <expected-node-name> <timeout-seconds> — poll until the VIP is owned
# by exactly the named node. Prints the elapsed milliseconds on success.
wait_owner() {
    local want="$1" timeout="${2:-60}"
    local start_ms end_ms
    start_ms=$(date +%s%3N)
    local i=0
    while [ "${i}" -lt $((timeout*10)) ]; do
        if [ "$(vip_owner)" = "${want}" ]; then
            end_ms=$(date +%s%3N)
            printf '%s\n' "$((end_ms-start_ms))"
            return 0
        fi
        sleep 0.1
        i=$((i+1))
    done
    printf '%s\n' "-1"
    return 1
}

# --- dnsdist backend introspection -------------------------------------------
# dnsdist 1.9's REST API (/api/v1/...) is not routed in this build, but the
# Prometheus exporter is, and it labels every backend by name. That is the
# cleanest possible evidence for "did dnsdist mark pdns-1 down and keep
# answering from pdns-2": a per-backend up/down gauge plus a per-backend query
# counter, read from the dnsdist that actually made the decision.
DNSDIST_API_KEY="poc-dnsdist-api-key"

dnsdist_backends() { # dnsdist_backends <dnsdist-ip>
    prober_ensure
    docker exec "${PROBER}" curl -s -m 3 -H "X-API-Key: ${DNSDIST_API_KEY}" \
        "http://$1:8083/metrics" 2>/dev/null \
        | grep -E '^dnsdist_server_(status|queries|responses)\{' || echo "(metrics unavailable)"
}

# --- prober -------------------------------------------------------------------
# A long-lived curl container on the DC LAN, used to observe client-visible
# outage windows at ~100 ms resolution. It is deliberately NOT one of the POC's
# nodes: it must survive whatever we kill.
PROBER="poc-test-prober"

prober_start() {
    prober_stop
    docker run -d --name "${PROBER}" --network "${NET}" \
        -v "${PKI}:/pki:ro" \
        --entrypoint sh curlimages/curl:latest -c 'while true; do sleep 3600; done' >/dev/null
    # Wait only for the container to be running. Do NOT wait for the IoT name to
    # resolve: the probes use `curl --resolve`/`--proxy`, so they never consult
    # the prober's resolver, and test.domain is not in Docker's embedded DNS
    # anyway. Waiting on it just burns a minute of docker-exec round trips per
    # call and never succeeds.
    for _ in $(seq 1 40); do
        docker inspect -f '{{.State.Running}}' "${PROBER}" 2>/dev/null | grep -q true && return 0
        sleep 0.25
    done
    return 1
}

prober_stop() {
    docker rm -f "${PROBER}" >/dev/null 2>&1 || true
}

prober_ensure() {
    docker inspect -f '{{.State.Running}}' "${PROBER}" 2>/dev/null | grep -q true || prober_start
}

# probe_ok — one client-visible request through the VIP. Prints nothing; the
# exit status is 0 when the end-to-end mTLS request returned HTTP 200.
probe_ok() {
    docker exec "${PROBER}" curl -sS -o /dev/null -m 4 -w '%{http_code}' \
        --resolve "iot0000001.test.domain:${IOT_MOCK_PORT}:${VIP}" \
        --cert /pki/clients/client-valid.crt --key /pki/clients/client-valid.key \
        --cacert /pki/ca/ca.crt \
        "https://iot0000001.test.domain/health" 2>/dev/null | grep -qx '200'
}

# probe_ok_connect — the same, for the CURRENT architecture. CONNECT goes to the
# client-facing port (production: 38888), NOT to Squid's port.
probe_ok_connect() {
    docker exec "${PROBER}" curl -sS -o /dev/null -m 4 -w '%{http_code}' \
        --proxy "http://${VIP}:${CLIENT_PORT}" \
        --proxy-cert /pki/clients/client-valid.crt --proxy-key /pki/clients/client-valid.key \
        --cacert /pki/ca/ca.crt \
        "https://iot0000001.test.domain/health" 2>/dev/null | grep -qx '200'
}

# prober_loop <label> <duration-seconds> — writes a timestamped OK/FAIL sample
# every ~100 ms to $RAW/<group>/<label>.probe. Run it in the background.
prober_loop() {
    local label="$1" dur="$2"
    local out="${RAW}/${GROUP}/${label}.probe"
    : > "${out}"
    local end=$(( $(date +%s%3N) + dur*1000 ))
    while [ "$(date +%s%3N)" -lt "${end}" ]; do
        local t; t=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
        if [ "${ARCH}" = "target" ]; then
            if probe_ok; then printf '%s OK\n' "${t}" >> "${out}"
            else printf '%s FAIL\n' "${t}" >> "${out}"; fi
        else
            if probe_ok_connect; then printf '%s OK\n' "${t}" >> "${out}"
            else printf '%s FAIL\n' "${t}" >> "${out}"; fi
        fi
    done
}

# vip_watch <label> <duration-seconds> — sample VIP ownership every second into
# $RAW/<group>/<label>.vip. Sampling before and after a fault is not enough: a
# killed node that Docker restarts re-takes the VIP within seconds, so a
# before/after pair can read "never moved" while the VIP demonstrably moved in
# between. The series is the evidence; the before/after pair is not.
vip_watch() {
    local label="$1" dur="$2"
    local out="${RAW}/${GROUP}/${label}.vip"
    : > "${out}"
    local end=$(( $(date +%s%3N) + dur*1000 ))
    while [ "$(date +%s%3N)" -lt "${end}" ]; do
        printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$(vip_owner)" >> "${out}"
        sleep 1
    done
}

# vip_series <label> — summarise a .vip file: the sequence of owners, the count
# of changes, and the first change timestamp.
vip_series() {
    local f="${RAW}/${GROUP}/$1.vip"
    [ -f "${f}" ] || { echo "no_vip_file"; return; }
    python3 - "${f}" <<'PY'
import sys
rows=[l.split(None,1) for l in open(sys.argv[1]) if l.strip()]
rows=[(t,o.strip()) for t,o in rows]
owners=[]
for t,o in rows:
    if not owners or owners[-1][0]!=o: owners.append((o,t))
seq=" -> ".join(o for o,_ in owners)
changes=len(owners)-1
print(f"series={seq} changes={changes} first_change={owners[1][1] if changes else 'none'}")
PY
}

# probe_window <label> — from a finished probe file, print first/last failure
# and the outage millisecond span. Prints "no_failures" when there were none.
probe_window() {
    local out="${RAW}/${GROUP}/$1.probe"
    [ -f "${out}" ] || { echo "no_probe_file"; return; }
    python3 - "${out}" <<'PY'
import sys, datetime
rows=[l.split() for l in open(sys.argv[1]) if l.strip()]
def p(ts): return datetime.datetime.strptime(ts,"%Y-%m-%dT%H:%M:%S.%fZ")
fails=[r for r in rows if r[1]=="FAIL"]
oks=[r for r in rows if r[1]=="OK"]
if not fails:
    print(f"no_failures samples={len(rows)} ok={len(oks)}")
    sys.exit(0)
first,last=p(fails[0][0]),p(fails[-1][0])
print(f"failures={len(fails)} samples={len(rows)} first_fail={fails[0][0]} last_fail={fails[-1][0]} "
      f"span_ms={int((last-first).total_seconds()*1000)}")
PY
}

# --- container control --------------------------------------------------------

# stop_container <name> — stop and confirm it stayed down.
stop_container() {
    docker stop -t 1 "$1" >/dev/null 2>&1 || true
    local i=0
    while [ "${i}" -lt 40 ]; do
        local st; st=$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || echo false)
        [ "${st}" = "false" ] && return 0
        sleep 0.25; i=$((i+1))
    done
    return 1
}

# start_container <name> — start and wait for running.
start_container() {
    docker start "$1" >/dev/null 2>&1 || true
    local i=0
    while [ "${i}" -lt 80 ]; do
        local st; st=$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || echo false)
        [ "${st}" = "true" ] && return 0
        sleep 0.25; i=$((i+1))
    done
    return 1
}

restore_all() {
    for c in poc-pdns-1 poc-pdns-2 poc-dnsdist-1 poc-dnsdist-2 poc-haproxy-1 poc-haproxy-2; do
        if ! docker inspect -f '{{.State.Running}}' "${c}" >/dev/null 2>&1; then continue; fi
        if [ "$(docker inspect -f '{{.State.Running}}' "${c}" 2>/dev/null)" != "true" ]; then
            docker start "${c}" >/dev/null 2>&1 || true
        fi
    done
    prober_stop
}
