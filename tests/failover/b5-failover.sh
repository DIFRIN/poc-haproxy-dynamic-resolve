#!/usr/bin/env bash
# ============================================================================
# B5 — failover behaviour.
#
# Runs under BOTH architectures (the checks that only apply to one are skipped
# explicitly rather than silently). For every scenario this records:
#   * VIP owner before and after
#   * the wall-clock time to VIP movement, taken from the notify hook's own
#     millisecond timestamps in `docker logs poc-haproxy-N` ("[vrrp] ... state=")
#   * whether client traffic actually recovered, measured by a ~100 ms curl
#     prober through the VIP (not by inspecting the stack, which would be
#     circular: the question is what a CLIENT saw)
#
# The rules under test (brief §7):
#   HAProxy dead          -> VIP MOVES
#   local dnsdist dead    -> VIP MOVES     (TARGET only; CURRENT has no dnsdist)
#   PowerDNS dead         -> VIP STAYS     (dnsdist absorbs it — TARGET semantics)
#   NXDOMAIN / SERVFAIL   -> VIP STAYS     (a DNS result is not an infra failure)
#
# CAVEAT ON THE LAST TWO ROWS, and it applies to the CURRENT arm only: they are
# not reachable in production CURRENT, whose Squid holds a cross-datacenter DNS
# fallback, so killing this site's PowerDNS pair does not produce a SERVFAIL
# there at all. Each scenario below says so at the point it runs. See
# docs/adr/0029-target-dns-fallback-regression.md.
# ============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

group b5-failover

log "arch=${ARCH}  VIP=${VIP}  initial owner: $(vip_owner)"
runlog "b5 start: arch=${ARCH} vip_owner=$(vip_owner)"

# Capture, before anything is killed, exactly what the notify hook produces
# versus what keepalived actually logs -- the failover timings below are taken
# from the latter, so the substitution is recorded rather than assumed.
notify_hook_evidence "${RESULTS}/failover-notify-hook-evidence.txt"
log "notify-hook evidence written to ${RESULTS}/failover-notify-hook-evidence.txt"
log "  (the [vrrp] lines the design relies on are NOT in docker logs; see that file)"
{
    echo "FAILOVER TIMING EVIDENCE — what the notify hook emits vs what is available"
    echo "generated $(now_iso) by tests/failover/b5-failover.sh"
    echo "================================================================"
    cat "${RESULTS}/failover-notify-hook-evidence.txt"
} > "${RESULTS}/FAILOVER-NOTES.txt"

prober_start

# --- baseline ---------------------------------------------------------------
# A failover test can only claim "traffic recovered" if traffic worked to
# begin with. On an architecture that cannot serve a request at all, every
# recovery assertion below would fail for a reason that has nothing to do with
# failover -- so the baseline is measured and stated up front.
BASELINE_OK=no
if [ "${ARCH}" = "target" ]; then probe_ok && BASELINE_OK=yes
else probe_ok_connect && BASELINE_OK=yes; fi
log "baseline client traffic (before any fault): ${BASELINE_OK}"
if [ "${BASELINE_OK}" = "yes" ]; then
    log "  (failover recovery is therefore directly verifiable in this run)"
else
    log "  (WARNING: the architecture cannot serve a request even with the whole stack up,"
    log "   so the recovery assertions below will fail for that reason rather than for a"
    log "   failover reason. Recorded explicitly rather than silently.)"
fi
runlog "b5 baseline_traffic=${BASELINE_OK}"

# recovery_check — probe client traffic and state the baseline alongside the
# verdict, so a failure is never mis-attributed to failover.
recovery_check() {
    log "  (baseline traffic at the start of this run was: ${BASELINE_OK})"
    if [ "${ARCH}" = "target" ]; then probe_ok; else probe_ok_connect; fi
}

# Track which node the VIP started on, so each scenario can restore to it.
scenario_header() {
    log ""
    log "------------------------------------------------------------------------"
    log "SCENARIO: $1"
    log "------------------------------------------------------------------------"
    SC_BEFORE="$(vip_owner)"
    SC_T0="$(now_iso)"
    log "  VIP owner before      : ${SC_BEFORE}"
    log "  trigger recorded at   : ${SC_T0}"
}

# conclude_scenario <label> <expect_move yes|no>
conclude_scenario() {
    local label="$1" expect_move="$2"
    local after; after="$(vip_owner)"
    log "  VIP owner after       : ${after}"

    local series; series="$(vip_series "${label}")"
    log "  VIP ownership series  : ${series}"
    local moved=no
    case "${series}" in *"changes=0"*) moved=no ;; no_vip_file) [ "${after}" != "${SC_BEFORE}" ] && moved=yes ;; *) moved=yes ;; esac
    log "  VIP moved             : ${moved} (expected: ${expect_move}; before=${SC_BEFORE} after=${after})"
    log "  probe window          : $(probe_window "${label}")"

    if [ "${expect_move}" = "yes" ]; then
        [ "${moved}" = "yes" ]
        expect "B5 ${label}: VIP MOVED (${SC_BEFORE} -> ${after})" $?
        local ms; ms="$(wait_owner "${after}" 5)"
        log "  VIP settled on ${after} after ${ms} ms of polling"
        # The movement timestamp: the first keepalived state transition that
        # Docker logged at or after the trigger. See vrrp_events in tests/lib.sh
        # for why the notify hook's own lines cannot be used.
        local ev; ev="$(vrrp_since "${after}" "${SC_T0}")"
        local other; other="$(vrrp_since "$([ "${after}" = "haproxy-1" ] && echo haproxy-2 || echo haproxy-1)" "${SC_T0}")"
        if [ -n "${ev}" ]; then
            log "  keepalived transition on ${after}: ${ev}"
            [ -n "${other}" ] && log "  keepalived transition on the old owner: ${other}"
            python3 - "$SC_T0" "${ev%% *}" <<'PY' | while read -r line; do log "  $line"; done
import sys, datetime
t0 = datetime.datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%S.%fZ")
t1 = datetime.datetime.strptime(sys.argv[2], "%Y-%m-%dT%H:%M:%S.%fZ")
print(f"VIP movement (trigger -> new owner MASTER, docker receipt clock): "
      f"{int((t1-t0).total_seconds()*1000)} ms  [{sys.argv[1]} -> {sys.argv[2]}]")
PY
        else
            log "  keepalived transition on ${after}: (none after ${SC_T0})"
            fail "B5 ${label}: expected a MASTER transition on ${after} after the trigger, found none"
        fi
    else
        [ "${moved}" = "no" ]
        expect "B5 ${label}: VIP DID NOT MOVE (still ${after})" $?
    fi
}

# ===========================================================================
# B5.1  PowerDNS 1 failure -> VIP must NOT move, dnsdist absorbs it.
# ===========================================================================
scenario_header "PowerDNS 1 (poc-pdns-1) stopped — VIP must NOT move"
log "  dnsdist-1 backends before:"; dnsdist_backends "$(envval DNSDIST_1_IP)" | sed 's/^/      /' | tee -a "${GROUP_LOG}"
Q1_BEFORE=$(dnsdist_backends "$(envval DNSDIST_1_IP)" | grep 'server="pdns-2"' | grep queries)

prober_loop b5.1 "$(( ${B5_OBSERVE:-25} ))" &
PROBE_PID=$!
vip_watch b5.1 "$(( ${B5_OBSERVE:-25} + 5 ))" &
VIP_PID=$!
stop_container poc-pdns-1
log "  poc-pdns-1 stopped at $(now_iso)"
sleep 8
log "  dnsdist-1 backends during the outage:"
dnsdist_backends "$(envval DNSDIST_1_IP)" | sed 's/^/      /' | tee -a "${GROUP_LOG}"
Q1_DURING=$(dnsdist_backends "$(envval DNSDIST_1_IP)" | grep 'server="pdns-2"' | grep queries)

# dnsdist must still be answering: a correct answer with pdns-1 down can only
# have come from pdns-2.
# The dnsdist-specific evidence below is TARGET-only: CURRENT has no dnsdist
# layer at all (Squid is the resolver there). The VIP assertion still applies to
# both architectures and runs either way.
if [ "${ARCH}" = "target" ]; then
    ANS="$(docker exec poc-haproxy-1 dig +short +time=2 +tries=1 -p "$(envval DNS_PORT)" "@$(envval DNSDIST_1_IP)" iot0000001.test.domain A 2>/dev/null | tr '\n' ' ' | tr -d ' ')"
    log "  dnsdist-1 answer while pdns-1 is down: '${ANS}' (expected: $(envval IOT_MOCK_IP))"
    [ "${ANS}" = "$(envval IOT_MOCK_IP)" ]
    expect "B5.1 dnsdist still ANSWERS CORRECTLY with pdns-1 down (answer='${ANS}', which can only have come from pdns-2)" $?
    P1ST="$(dnsdist_backends "$(envval DNSDIST_1_IP)" | grep 'server="pdns-1"' | grep status)"
    log "  ${P1ST}"
    printf '%s' "${P1ST}" | grep -q 'dnsdist_server_status{server="pdns-1".*} 0$'
    expect "B5.1 dnsdist marked pdns-1 DOWN (${P1ST})" $?
    [ "${Q1_BEFORE##* }" -lt "${Q1_DURING##* }" ]
    expect "B5.1 pdns-2 kept serving queries (${Q1_BEFORE##* } -> ${Q1_DURING##* })" $?
else
    log "  no dnsdist in CURRENT; the PowerDNS-failover evidence is TARGET-only."
    skip "B5.1 dnsdist backend-state evidence (TARGET-only; arch=${ARCH})"
    skip "B5.1 pdns-2 query-count evidence (TARGET-only; arch=${ARCH})"
fi

wait "${PROBE_PID}" 2>/dev/null || true
wait "${VIP_PID}" 2>/dev/null || true
conclude_scenario b5.1 no
start_container poc-pdns-1
sleep 6
log "  restored; dnsdist-1 backends:"; dnsdist_backends "$(envval DNSDIST_1_IP)" | sed 's/^/      /' | tee -a "${GROUP_LOG}"
if [ "${ARCH}" = "target" ]; then
    P1ST=$(dnsdist_backends "$(envval DNSDIST_1_IP)" | grep 'server="pdns-1"' | grep status)
    printf '%s' "${P1ST}" | grep -q '} 1$'
    expect "B5.1 pdns-1 marked UP again after restore (${P1ST})" $?
fi

# ===========================================================================
# B5.2  PowerDNS 2 failure -> mirrored.
# ===========================================================================
scenario_header "PowerDNS 2 (poc-pdns-2) stopped — VIP must NOT move"
Q2_BEFORE=$(dnsdist_backends "$(envval DNSDIST_1_IP)" | grep 'server="pdns-1"' | grep queries)
prober_loop b5.2 "$(( ${B5_OBSERVE:-25} ))" &
PROBE_PID=$!
vip_watch b5.2 "$(( ${B5_OBSERVE:-25} + 5 ))" &
VIP_PID=$!
stop_container poc-pdns-2
log "  poc-pdns-2 stopped at $(now_iso)"
sleep 8
log "  dnsdist-1 backends during the outage:"
dnsdist_backends "$(envval DNSDIST_1_IP)" | sed 's/^/      /' | tee -a "${GROUP_LOG}"
Q2_DURING=$(dnsdist_backends "$(envval DNSDIST_1_IP)" | grep 'server="pdns-1"' | grep queries)
if [ "${ARCH}" = "target" ]; then
    ANS="$(docker exec poc-haproxy-1 dig +short +time=2 +tries=1 -p "$(envval DNS_PORT)" "@$(envval DNSDIST_1_IP)" iot0000002.test.domain A 2>/dev/null | tr '\n' ' ' | tr -d ' ')"
    log "  dnsdist-1 answer while pdns-2 is down: '${ANS}' (expected: $(envval IOT_MOCK_IP))"
    [ "${ANS}" = "$(envval IOT_MOCK_IP)" ]
    expect "B5.2 dnsdist still ANSWERS CORRECTLY with pdns-2 down (answer='${ANS}', via pdns-1)" $?
    P2ST="$(dnsdist_backends "$(envval DNSDIST_1_IP)" | grep 'server="pdns-2"' | grep status)"
    log "  ${P2ST}"
    printf '%s' "${P2ST}" | grep -q 'dnsdist_server_status{server="pdns-2".*} 0$'
    expect "B5.2 dnsdist marked pdns-2 DOWN (${P2ST})" $?
    [ "${Q2_BEFORE##* }" -lt "${Q2_DURING##* }" ]
    expect "B5.2 pdns-1 kept serving queries (${Q2_BEFORE##* } -> ${Q2_DURING##* })" $?
else
    log "  no dnsdist in CURRENT; the PowerDNS-failover evidence is TARGET-only."
    skip "B5.2 dnsdist backend-state evidence (TARGET-only; arch=${ARCH})"
    skip "B5.2 pdns-1 query-count evidence (TARGET-only; arch=${ARCH})"
fi
wait "${PROBE_PID}" 2>/dev/null || true
wait "${VIP_PID}" 2>/dev/null || true
conclude_scenario b5.2 no
start_container poc-pdns-2
sleep 6
log "  restored; dnsdist-1 backends:"; dnsdist_backends "$(envval DNSDIST_1_IP)" | sed 's/^/      /' | tee -a "${GROUP_LOG}"

# ===========================================================================
# B5.3  local dnsdist failure (TARGET only) -> VIP MUST move.
#       The dnsdist local to the ACTIVE node is stopped, which is the one the
#       node's health check probes. The health check must fail, the node must
#       drop the VIP, and the peer must take it over -- serving through ITS OWN
#       dnsdist, which is still up.
# ===========================================================================
if [ "${ARCH}" != "target" ]; then
    log ""
    log "SCENARIO: local dnsdist failure — SKIPPED (CURRENT has no dnsdist layer)"
    skip "B5.3 local dnsdist failure is TARGET-only (arch=${ARCH})"
else
    ACTIVE="$(vip_owner)"
    N="${ACTIVE##*-}"
    LOCAL_DNS="poc-dnsdist-${N}"
    LOCAL_DNS_IP="$(envval DNSDIST_${N}_IP)"
    scenario_header "local dnsdist (${LOCAL_DNS}, ${LOCAL_DNS_IP}) of the ACTIVE node ${ACTIVE} stopped — VIP MUST move"
    log "  active node's health check now: $(docker exec "$(ctr "${ACTIVE}")" /opt/keepalived-checks/target.sh 2>&1; echo "exit=$?")"

    prober_loop b5.3 "$(( ${B5_OBSERVE:-40} ))" &
    PROBE_PID=$!
    vip_watch b5.3 "$(( ${B5_OBSERVE:-40} + 5 ))" &
    VIP_PID=$!
    stop_container "${LOCAL_DNS}"
    log "  ${LOCAL_DNS} stopped at $(now_iso)"

    # Health check must now fail on the active node (the check probes this
    # dnsdist by name).
    sleep 3
    HC="$(docker exec "$(ctr "${ACTIVE}")" /opt/keepalived-checks/target.sh 2>&1; echo "exit=$?")"
    log "  active node health check with its dnsdist down: ${HC}"
    printf '%s' "${HC}" | grep -q 'exit=1'
    expect "B5.3 active node's health check FAILED (${HC})" $?

    wait "${PROBE_PID}" 2>/dev/null || true
wait "${VIP_PID}" 2>/dev/null || true
    conclude_scenario b5.3 yes
    log "  probe window detail: $(probe_window b5.3)"

    # Traffic must now be served by the peer's dnsdist.
    sleep 5
    NEW="$(vip_owner)"
    log "  probing through the new owner ${NEW} ..."
    if [ "${NEW}" != "none" ]; then
        recovery_check
        expect "B5.3 client traffic recovered through ${NEW} (end-to-end mTLS 200; baseline=${BASELINE_OK})" $?
    else
        fail "B5.3 no node owns the VIP -- no ingress"
    fi

    start_container "${LOCAL_DNS}"
    sleep 8
    log "  restored; owner now: $(vip_owner)"
fi

# ===========================================================================
# B5.4  active HAProxy failure -> VIP MUST move, traffic must resume.
#       `docker kill` (not `docker stop`): a crash, not a graceful shutdown.
#       Both nodes have restart:unless-stopped, so the killed node comes back
#       on its own -- which is realistic, and is recorded rather than hidden.
# ===========================================================================
ACTIVE="$(vip_owner)"
scenario_header "active HAProxy (${ACTIVE}) killed with SIGKILL — VIP MUST move"
prober_loop b5.4 "$(( ${B5_OBSERVE:-45} ))" &
PROBE_PID=$!
vip_watch b5.4 "$(( ${B5_OBSERVE:-45} + 5 ))" &
VIP_PID=$!
KILLED_AT="$(now_iso)"
docker kill "$(ctr "${ACTIVE}")" >/dev/null 2>&1
log "  docker kill $(ctr "${ACTIVE}") issued at ${KILLED_AT}"

wait "${PROBE_PID}" 2>/dev/null || true
wait "${VIP_PID}" 2>/dev/null || true
conclude_scenario b5.4 yes
log "  probe window detail: $(probe_window b5.4)"

NEW="$(vip_owner)"
if [ "${NEW}" != "none" ]; then
    recovery_check
    expect "B5.4 client traffic recovered through ${NEW} (end-to-end mTLS 200; baseline=${BASELINE_OK})" $?
else
    fail "B5.4 no node owns the VIP -- no ingress"
fi

log "  killed node's restart policy state: $(docker inspect -f '{{.State.Status}} restarts={{.RestartCount}}' "$(ctr "${ACTIVE}")" 2>/dev/null)"
start_container "$(ctr "${ACTIVE}")"
sleep 12
log "  after restore, VIP owner: $(vip_owner)"
log "  (both nodes advertise the same virtual_router_id; the node with priority 150 preempts"
log "   once its own health check passes again -- observed owner above reflects that)"
# Whichever node holds the VIP, traffic must work.
recovery_check
expect "B5.4 traffic works after restore (owner=$(vip_owner); baseline=${BASELINE_OK})" $?

# ===========================================================================
# B5.5  NXDOMAIN and (genuine) SERVFAIL must NOT move the VIP.
#
# 5a: a storm of NXDOMAIN lookups through the proxy.
# 5b: the SERVFAIL path that actually exists in this stack -- ALL PowerDNS
#     backends down, so dnsdist answers SERVFAIL. The health check treats "any
#     response at all" as healthy precisely so this does not move the VIP.
#
# NOTE: the corpus name servfail.test.domain does NOT produce SERVFAIL in this
# stack (it returns NXDOMAIN -- reported as a finding, see the group log). The
# infrastructure SERVFAIL path below is the faithful test of the same rule.
# ===========================================================================
scenario_header "NXDOMAIN lookup storm — VIP must NOT move"
if [ "${ARCH}" = "target" ]; then
    prober_loop b5.5-nx "$(( ${B5_OBSERVE:-25} ))" &
    PROBE_PID=$!
    vip_watch b5.5-nx "$(( ${B5_OBSERVE:-25} + 5 ))" &
    VIP_PID=$!
    client_json "${RAW}/${GROUP}/b5.5-nx.json" -mode=tls -proxy="${VIP}:${IOT_MOCK_PORT}" \
        -servername=nx.test.domain -path=/health ${CERT_VALID} ${CA_POC} \
        -duration=15s -rps=4 -concurrency=1 -timeout=5s -label=b5.5-nx >/dev/null
    log "  NXDOMAIN attempts: $(jget "${RAW}/${GROUP}/b5.5-nx.json" "d['attempts']") (all refused: success=$(jget "${RAW}/${GROUP}/b5.5-nx.json" "d['success']"))"
    wait "${PROBE_PID}" 2>/dev/null || true
wait "${VIP_PID}" 2>/dev/null || true
else
    prober_loop b5.5-nx "$(( ${B5_OBSERVE:-25} ))" &
    PROBE_PID=$!
    vip_watch b5.5-nx "$(( ${B5_OBSERVE:-25} + 5 ))" &
    VIP_PID=$!
    client_json "${RAW}/${GROUP}/b5.5-nx.json" -mode=connect -proxy="${VIP}:${CLIENT_PORT}" \
        -target-host=nx.test.domain -target-port=443 ${CERT_VALID} ${CA_POC} \
        -duration=15s -rps=4 -concurrency=1 -timeout=6s -label=b5.5-nx >/dev/null
    log "  NXDOMAIN attempts: $(jget "${RAW}/${GROUP}/b5.5-nx.json" "d['attempts']") (all refused: success=$(jget "${RAW}/${GROUP}/b5.5-nx.json" "d['success']"))"
    wait "${PROBE_PID}" 2>/dev/null || true
wait "${VIP_PID}" 2>/dev/null || true
fi
conclude_scenario b5.5-nx no
log "  probe window detail: $(probe_window b5.5-nx)"

# ---------------------------------------------------------------------------
# THIS SCENARIO IS POC-ONLY AND DOES NOT MODEL PRODUCTION CURRENT.
#
# Stopping both of this site's PowerDNS servers is NOT a way to produce a
# SERVFAIL against production CURRENT. Production Squid is configured with
#
#     dns_nameservers <this site's nameservers> <the REMOTE site's nameservers>
#
# — the SAME list on both instances — so killing the local pair does not stop it
# resolving: Squid falls through to the other datacenter and keeps serving
# CONNECT requests. There is no SERVFAIL to observe. See
# docs/adr/0029-target-dns-fallback-regression.md.
#
# The scenario reproduces HERE only because the POC's two Squid instances were
# given two LOCAL servers and no remote list — the one-datacenter boundary
# (brief §4, rule 10) excludes the second site. That makes this failure domain a
# property of the POC's own configuration, not of CURRENT.
#
# Read it, therefore, as a TARGET-semantics test: it asserts that dnsdist
# absorbs a total local-PowerDNS loss without moving the VIP (rules 16-17). The
# CURRENT arm below — and its dig probe — proves nothing about production, and
# no result from it may be reported as a CURRENT failure mode. It is kept rather
# than deleted because the TARGET half is still the faithful test of the rule.
# ---------------------------------------------------------------------------
scenario_header "genuine SERVFAIL (all PowerDNS down) — VIP must NOT move"
if [ "${ARCH}" = "target" ]; then
    DNS_IP="$(envval DNSDIST_1_IP)"
else
    DNS_IP="$(envval PDNS_1_IP)"
fi
prober_loop b5.5-servfail "$(( ${B5_OBSERVE:-30} ))" &
PROBE_PID=$!
vip_watch b5.5-servfail "$(( ${B5_OBSERVE:-30} + 5 ))" &
VIP_PID=$!
stop_container poc-pdns-1
stop_container poc-pdns-2
log "  both PowerDNS stopped at $(now_iso)"
sleep 8

if [ "${ARCH}" = "target" ]; then
    # WHAT THE DESIGN SAYS vs WHAT HAPPENS.
    # configs/keepalived/checks/target.sh asserts that dnsdist "returns SERVFAIL when
    # every PowerDNS backend is down" and that the check therefore stays
    # HEALTHY, which is why the VIP must not move. Measured, dnsdist does NOT
    # answer at all when no backend is available -- it drops the query -- so
    # `dig` receives nothing and the health check FAILS. Both facts are
    # recorded, because the required OUTCOME still holds (see below) but the
    # documented MECHANISM does not.
    DIGOUT="$(docker exec poc-haproxy-1 dig +time=2 +tries=1 +noall +comments -p "$(envval DNS_PORT)" "@${DNS_IP}" test.domain SOA 2>&1)"
    RC="$(printf '%s' "${DIGOUT}" | grep -o 'status: [A-Z]*' | head -1)"
    log "  dnsdist rcode with every backend down: '${RC:-<no response at all>}'"
    log "  dig output: $(printf '%s' "${DIGOUT}" | tr '\n' ' ' | cut -c1-160)"
    if [ -z "${RC}" ]; then
        log "  FINDING: dnsdist DROPS the query when no backend is up. It does not return"
        log "  SERVFAIL as configs/keepalived/checks/target.sh documents, so the health check does"
        log "  NOT stay healthy -- it fails on BOTH nodes (verified in the logs below)."
    fi
    HC="$(docker exec "$(ctr "$(vip_owner)")" /opt/keepalived-checks/target.sh 2>&1; echo "exit=$?")"
    log "  active node health check with every backend down: ${HC}"
    log "  keepalived priority, active node:"
    docker logs "$(ctr "$(vip_owner)")" 2>&1 | grep -E 'Changing effective priority|VRRP_Script\(chk_node\) (failed|succeeded)' | tail -4 | sed 's/^/      /' | tee -a "${GROUP_LOG}"
    log "  keepalived priority, peer node:"
    docker logs "$(ctr "$([ "$(vip_owner)" = "haproxy-1" ] && echo haproxy-2 || echo haproxy-1)")" 2>&1 | grep -E 'Changing effective priority' | tail -2 | sed 's/^/      /' | tee -a "${GROUP_LOG}"
    log "  NOTE: both nodes degrade (150->90 and 100->40), so the incumbent master keeps"
    log "  the higher effective priority and the VIP stays put by priority arithmetic."
    log "  The required outcome holds; it is the documented reason that does not."
else
    # DIAGNOSTIC ARTEFACT — POC-ONLY, AND IT PROVES NOTHING ABOUT CURRENT.
    # This dig targets Squid's own address, and Squid is a CONNECT proxy, not a
    # nameserver: it cannot answer an SOA query at all, so the rcode captured
    # here describes neither Squid nor CURRENT's DNS path (RC is not consumed by
    # any assertion below — it is recorded as-is). What CURRENT actually does is
    # resolve through the PowerDNS pair named in its dns_nameservers line, which
    # is what the probe below shows.
    RC="$(docker exec poc-haproxy-1 dig +time=2 +tries=1 +noall +comments -p "$(envval DNS_PORT)" "@$(envval SQUID_1_IP)" test.domain SOA 2>&1 | grep -o 'status: [A-Z]*' || true)"
    RC_PDNS="$(docker exec poc-haproxy-1 dig +time=2 +tries=1 +noall +comments -p 53 "@$(envval PDNS_1_IP)" test.domain SOA 2>&1 | grep -o 'status: [A-Z]*' || true)"
    log "  (CURRENT has no dnsdist; Squid resolves directly against the PowerDNS pair)"
    log "  dig @SQUID_1_IP  (Squid is a proxy, not a resolver): ${RC:-<no response>}  <- POC diagnostic artefact, not evidence"
    log "  dig @PDNS_1 ($(envval PDNS_1_IP)) with both PowerDNS down                  : ${RC_PDNS:-<no response>}"
    log "  NOTE: in production this site's DNS loss does not surface as a SERVFAIL at all —"
    log "  Squid falls through to the remote datacenter's nameservers (ADR 0029). The DNS"
    log "  failure induced here is reachable only in a one-datacenter POC."
fi

wait "${PROBE_PID}" 2>/dev/null || true
wait "${VIP_PID}" 2>/dev/null || true
conclude_scenario b5.5-servfail no
log "  probe window detail: $(probe_window b5.5-servfail)"

start_container poc-pdns-1
start_container poc-pdns-2
sleep 10
log "  restored; VIP owner: $(vip_owner)"

# ---------------------------------------------------------------------------
log ""
log "---- final state ----"
log "  VIP owner            : $(vip_owner)"
log "  probe recovery       : $(probe_window b5.1) / $(probe_window b5.5-servfail)"
for pp in b5.1 b5.2 b5.3 b5.4 b5.5-nx b5.5-servfail; do
    [ -f "${RAW}/${GROUP}/${pp}.probe" ] && log "  ${pp} probe: $(probe_window "${pp}")"
done

prober_stop
summary
