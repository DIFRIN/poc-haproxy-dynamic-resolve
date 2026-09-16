#!/usr/bin/env bash
# ============================================================================
# F1 — production-config fidelity: Squid's real access-control behaviour.
#
# WHAT THIS PROVES
#   That the REAL production Squid access-control block is an OPEN FORWARD
#   PROXY with no destination validation: any client, from any source, can
#   CONNECT to any destination on a Safe_port — including loopback, the cloud
#   instance-metadata address, and RFC1918 addresses — and the one rule that
#   looks like it prevents that (`http_access deny to_localhost`) never fires.
#
# WHY IT IS A SEPARATE, STANDALONE GROUP
#   This test does NOT need the POC stack: no VIP, no Keepalived, no PowerDNS,
#   no PostgreSQL, no IoT Mock. It runs Squid directly, with this repository's
#   own squid configs mounted read-only, so it validates the artefacts in
#   configs/squid/squid-{1,2}/ and can run in seconds on a bare Docker host.
#
#   It is deliberately NOT part of run-all.sh's ordered stack suite, because
#   its verdict is independent of whether the POC is up.
#
# IT RUNS TWO SQUIDS, SIDE BY SIDE
#   fid-prod  configs/squid/squid-1/squid.conf           PRODUCTION's real ACLs
#   fid-hard  configs/squid/squid-1/squid.conf.hardened  the counterfactual policy
#
#   The comparison is the point. The hardened file is what earlier revisions of
#   this POC MISTAKENLY reported as CURRENT's security posture, and benchmarking
#   it as CURRENT biased the security comparison against TARGET. Running both
#   makes the difference impossible to misread.
#
# HOW THE VERDICT IS CLASSIFIED
#   Squid's response to a CONNECT tells us exactly what its ACLs decided:
#     403 Forbidden            -> DENIED by the ACLs
#     200 Connection established -> ALLOWED, tunnel actually established
#     503 Service Unavailable  -> ALLOWED, upstream refused/unreachable
#     no response              -> ALLOWED, Squid is still waiting on the upstream
#   Only the first is a refusal. Everything else means the ACLs let it through.
#
# EVIDENCE
#   Squid's own access log is captured for both instances under
#   benchmark/results/raw/F1/. The TAG in that log is Squid's own verdict --
#   TCP_TUNNEL means allowed, TCP_DENIED_ABORTED means refused -- so the
#   classification above can be re-checked against the proxy's own record
#   rather than taken from this script.
#
#   NOTE: the repository's squid configs set `access_log none` deliberately, so
#   that at 6,000 rps the log stream does not become the bottleneck and corrupt
#   the benchmark's CPU and latency measurements. This test therefore renders a
#   COPY of each config with logging re-enabled. The copy differs from the
#   committed file in that one line and nothing else, and that is asserted
#   below rather than asserted in prose.
#
# See docs/adr/0028-production-config-fidelity.md.
# ============================================================================

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

group "F1"

FID_NET="poc-fidelity-net"
FID_SUBNET="172.31.0.0/24"
PROD_IP="172.31.0.10"
HARD_IP="172.31.0.11"
CLIENT_IP_FID="172.31.0.99"
FID_PORT=4443
# Squid's own management address, substituted for {{ ansible_default_ipv4.address }}
# in production's `acl to_localhost dst` line.
PROD_OWN_ADDR="${PROD_IP}"

WORK="${RAW}/F1/proxy-configs"
mkdir -p "${WORK}"

cleanup() {
    docker rm -f fid-prod fid-hard fid-client >/dev/null 2>&1
    docker network rm "${FID_NET}" >/dev/null 2>&1
}
trap cleanup EXIT

log "F1 production-config fidelity — Squid access control"
log "  repo config under test : configs/squid/squid-1/squid.conf (production, verbatim)"
log "  counterfactual         : configs/squid/squid-1/squid.conf.hardened"
log ""

# ---------------------------------------------------------------------------
# Render logging-enabled copies. For the PRODUCTION config the ONLY change is
# the access_log line, and the diff is printed so that claim is verifiable from
# this script's own output.
# ---------------------------------------------------------------------------
render_logging_copy() {
    local src="$1" dst="$2"
    sed 's|^access_log none$|access_log stdio:/var/log/squid/access.log|' "${src}" > "${dst}"
}

render_logging_copy "${REPO}/configs/squid/squid-1/squid.conf" "${WORK}/prod.conf"

log "--- diff of the production config against the committed file ---"
if diff -u "${REPO}/configs/squid/squid-1/squid.conf" "${WORK}/prod.conf" > "${RAW}/F1/config-diff.txt" 2>&1; then
    fail "F1.prepares expected exactly one changed line (access_log); diff was empty"
else
    log "$(cat "${RAW}/F1/config-diff.txt")"
    changed="$(grep -cE '^[+-][^+-]' "${RAW}/F1/config-diff.txt" || true)"
    expect "F1.prepares the production logging copy changes exactly 2 lines (got ${changed})" \
        "$([ "${changed}" -eq 2 ] && echo 0 || echo 1)"
fi
log ""

# ---------------------------------------------------------------------------
# The COUNTERFACTUAL config needs TWO changes, and the second one matters.
#
# Its policy is source-restricted -- `acl localnet src 172.28.0.0/24` -- because
# the hardened design assumed a trusted client network. This test runs on its
# own 172.31.0.0/24 network, so without substituting that ACL, every CONNECT
# would be refused for being from the wrong SOURCE and the test would "prove"
# the destination policy works while actually measuring a source restriction.
# That conflation is exactly the kind of error this audit exists to remove.
#
# So `localnet` is rewritten to the test client's address, isolating the
# DESTINATION policy -- which is the control under comparison. The production
# config needs no such substitution because it has no source restriction at
# all, which is itself part of the finding.
# ---------------------------------------------------------------------------
sed -e 's|^access_log none$|access_log stdio:/var/log/squid/access.log|' \
    -e "s|^acl localnet      src 172\.28\.0\.0/24$|acl localnet      src ${CLIENT_IP_FID}/32|" \
    "${REPO}/configs/squid/squid-1/squid.conf.hardened" > "${WORK}/hard.conf"

log "--- diff of the counterfactual config: logging + source-ACL isolation ---"
diff -u "${REPO}/configs/squid/squid-1/squid.conf.hardened" "${WORK}/hard.conf" > "${RAW}/F1/hardened-diff.txt" 2>&1
log "$(cat "${RAW}/F1/hardened-diff.txt")"
expect "F1.prepares the counterfactual's source ACL was rewritten to the test client, isolating the DESTINATION policy" \
    "$(grep -q "^+acl localnet      src ${CLIENT_IP_FID}/32$" "${RAW}/F1/hardened-diff.txt" && echo 0 || echo 1)"
log ""

# ---------------------------------------------------------------------------
# Bring up the two Squids and one client on a dedicated network.
# ---------------------------------------------------------------------------
docker network rm "${FID_NET}" >/dev/null 2>&1
docker network create --subnet "${FID_SUBNET}" "${FID_NET}" >/dev/null 2>&1 || {
    fail "F1.setup could not create the fidelity network"
    summary; exit 1
}

start_squid() {
    local name="$1" ip="$2" conf="$3"
    docker run -d --name "${name}" --network "${FID_NET}" --ip "${ip}" \
        -v "${conf}:/etc/squid/squid.conf:ro" alpine:3.20 \
        sh -c 'apk add -q squid >/dev/null 2>&1
               mkdir -p /var/log/squid /run/squid /var/cache/squid
               chown -R squid:squid /var/log/squid /run/squid /var/cache/squid
               exec /usr/sbin/squid -N -f /etc/squid/squid.conf' >/dev/null 2>&1
}

log "starting fid-prod (production ACLs) and fid-hard (counterfactual)..."
start_squid fid-prod "${PROD_IP}" "${WORK}/prod.conf"
start_squid fid-hard "${HARD_IP}" "${WORK}/hard.conf"

docker run -d --name fid-client --network "${FID_NET}" --ip "${CLIENT_IP_FID}" \
    alpine:3.20 sleep 900 >/dev/null 2>&1

wait_listen() {
    local name="$1" i
    for i in $(seq 1 60); do
        if docker exec "${name}" sh -c "netstat -ltn 2>/dev/null | grep -q ':${FID_PORT}'" 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

if wait_listen fid-prod && wait_listen fid-hard; then
    pass "F1.setup both Squids are listening on :${FID_PORT}"
else
    fail "F1.setup a Squid failed to start; see benchmark/results/raw/F1/ for logs"
    docker logs fid-prod > "${RAW}/F1/fid-prod.log" 2>&1
    docker logs fid-hard > "${RAW}/F1/fid-hard.log" 2>&1
    summary; exit 1
fi

# The client's address must be OUTSIDE `acl env_network src 0.0.0.0/32`, or the
# whole test proves nothing. Assert it rather than assume it.
src_ip="$(docker exec fid-client sh -c "ip -4 addr show eth0 2>/dev/null | grep -o 'inet [0-9.]*' | cut -d' ' -f2" 2>/dev/null)"
expect "F1.setup client source ${src_ip} is outside env_network (0.0.0.0/32) — the ACLs are genuinely uncontrolled" \
    "$([ "${src_ip}" = "${CLIENT_IP_FID}" ] && echo 0 || echo 1)"
log ""

# ---------------------------------------------------------------------------
# The CONNECT matrix.
#
# Each destination is chosen to be a class the brief requires be refused
# (rule 22/23, brief §13) plus controls that isolate WHY it is refused.
# ---------------------------------------------------------------------------
# label|destination|expect_prod|expect_hard
#   expect: allow | deny
MATRIX="\
loopback:443|127.0.0.1:443|allow|deny
squid-own-address:443|${PROD_OWN_ADDR}:443|allow|deny
cloud-metadata:443|169.254.169.254:443|allow|deny
rfc1918:443|10.0.0.5:443|allow|deny
public:443|example.com:443|allow|allow
non-safe-port:22|${PROD_OWN_ADDR}:22|deny|deny"

connect_status() {
    local proxy_ip="$1" dest="$2"
    docker exec fid-client sh -c \
        "printf 'CONNECT ${dest} HTTP/1.1\r\nHost: ${dest}\r\n\r\n' | nc -w 6 ${proxy_ip} ${FID_PORT} 2>/dev/null | head -1" \
        2>/dev/null
}

# classify <status-line> -> deny | allow
classify() {
    case "$1" in
        *403*) echo "deny" ;;
        *200*|*503*|"") echo "allow" ;;   # "" = still awaiting upstream = allowed
        *) echo "allow" ;;
    esac
}

log "--- CONNECT matrix: production ACLs vs the counterfactual ---"
log ""
printf '%-26s %-22s %-26s %s\n' "CLASS" "DESTINATION" "PRODUCTION (real)" "HARDENED (counterfactual)"
printf '%-26s %-22s %-26s %s\n' "--------------------------" "----------------------" "--------------------------" "---------------------------"

while IFS='|' read -r label dest exp_prod exp_hard; do
    [ -n "${label}" ] || continue
    raw_prod="$(connect_status "${PROD_IP}" "${dest}")"
    raw_hard="$(connect_status "${HARD_IP}" "${dest}")"
    got_prod="$(classify "${raw_prod}")"
    got_hard="$(classify "${raw_hard}")"

    printf '%-26s %-22s %-26s %s\n' \
        "${label}" "${dest}" \
        "${got_prod}  ${raw_prod:-<no response>}" \
        "${got_hard}  ${raw_hard:-<no response>}"

    # Assert the production behaviour IS the insecure one.
    expect "F1.prod ${label}: production Squid ALLOWS this (real behaviour reproduced)" \
        "$([ "${got_prod}" = "${exp_prod}" ] && echo 0 || echo 1)"
    expect "F1.hard ${label}: counterfactual Squid behaves as its policy specifies" \
        "$([ "${got_hard}" = "${exp_hard}" ] && echo 0 || echo 1)"

    printf '%s|%s|prod_raw=%s|prod=%s|hard_raw=%s|hard=%s\n' \
        "${label}" "${dest}" "${raw_prod:-none}" "${got_prod}" "${raw_hard:-none}" "${got_hard}" \
        >> "${RAW}/F1/matrix.txt"
done <<< "${MATRIX}"

log ""

# ---------------------------------------------------------------------------
# Capture the proxies' own verdicts. This is the authoritative evidence: the
# TAG is Squid's decision, not this script's classification.
# ---------------------------------------------------------------------------
docker exec fid-prod sh -c 'cat /var/log/squid/access.log 2>/dev/null' > "${RAW}/F1/prod-access.log" 2>&1
docker exec fid-hard sh -c 'cat /var/log/squid/access.log 2>/dev/null' > "${RAW}/F1/hard-access.log" 2>&1

log "--- PRODUCTION Squid's own access log (its verdict, not ours) ---"
log "$(cat "${RAW}/F1/prod-access.log")"
log ""
log "--- COUNTERFACTUAL Squid's own access log ---"
log "$(cat "${RAW}/F1/hard-access.log")"
log ""

# The decisive assertions, from the proxy's own log rather than our
# classification.
#
# READING THE LOG: Squid writes an entry when the request RESOLVES, so a
# destination whose upstream connect neither succeeds nor fails — an
# unroutable or blackholed address — has no line yet when the matrix finishes.
# TCP_TUNNEL is therefore only asserted for destinations that complete. For the
# unroutable ones the correct claim is the ABSENCE of a denial, which together
# with the client-side observation (no 403) establishes they were allowed.
prod_log="$(cat "${RAW}/F1/prod-access.log")"

expect "F1.log production ALLOWED CONNECT to loopback and completed the attempt (TCP_TUNNEL on 127.0.0.1)" \
    "$(grep -q 'TCP_TUNNEL.*CONNECT 127\.0\.0\.1:' <<< "${prod_log}" && echo 0 || echo 1)"
expect "F1.log production ALLOWED CONNECT to its OWN address — proving 'deny to_localhost' is unreachable dead code" \
    "$(grep -q "TCP_TUNNEL.*CONNECT ${PROD_OWN_ADDR}:" <<< "${prod_log}" && echo 0 || echo 1)"
expect "F1.log production did NOT deny the cloud-metadata address 169.254.169.254 (absent from the log = pending, not refused)" \
    "$(grep -q 'TCP_DENIED.*CONNECT 169\.254\.169\.254:' <<< "${prod_log}" && echo 1 || echo 0)"
expect "F1.log production did NOT deny the RFC1918 address 10.0.0.5 (absent from the log = pending, not refused)" \
    "$(grep -q 'TCP_DENIED.*CONNECT 10\.0\.0\.5:' <<< "${prod_log}" && echo 1 || echo 0)"
expect "F1.log the ONLY production denial anywhere is port-based (no Safe_port entry for :22)" \
    "$(grep -q 'TCP_DENIED.*CONNECT .*:22' <<< "${prod_log}" && echo 0 || echo 1)"
expect "F1.log production denied NOTHING on port 443 (zero TCP_DENIED on :443)" \
    "$(grep -q 'TCP_DENIED.*CONNECT .*:443' <<< "${prod_log}" && echo 1 || echo 0)"

hard_log="$(cat "${RAW}/F1/hard-access.log")"
expect "F1.log the counterfactual Squid DID refuse the forbidden destinations (TCP_DENIED on :443)" \
    "$(grep -q 'TCP_DENIED.*CONNECT .*:443' <<< "${hard_log}" && echo 0 || echo 1)"
expect "F1.log the counterfactual refused loopback specifically (the control production lacks)" \
    "$(grep -q 'TCP_DENIED.*CONNECT 127\.0\.0\.1:443' <<< "${hard_log}" && echo 0 || echo 1)"
expect "F1.log the counterfactual refused the cloud-metadata address specifically" \
    "$(grep -q 'TCP_DENIED.*CONNECT 169\.254\.169\.254:443' <<< "${hard_log}" && echo 0 || echo 1)"

log ""
log "================================================================================"
log "FINDING — CURRENT ARCHITECTURE, CONFIRMED VULNERABILITY"
log ""
log "  Production Squid applies NO destination validation. Any client that can"
log "  reach it may CONNECT to loopback, to RFC1918, and to the cloud"
log "  instance-metadata address 169.254.169.254. 'http_access deny to_localhost'"
log "  is unreachable: both allows that precede it are unrestricted by source."
log ""
log "  This is the production configuration, not a POC artefact. It is why"
log "  TARGET's resolved-address policy is net-new security capability rather"
log "  than a re-implementation of something CURRENT already had."
log ""
log "  Full write-up: docs/adr/0028-production-config-fidelity.md"
log "================================================================================"

summary
