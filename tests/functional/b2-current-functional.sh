#!/usr/bin/env bash
# ============================================================================
# B2 — CURRENT functional tests (HAProxy + Squid, arch=current).
#
# The client issues CONNECT to the VIP on CLIENT_PORT (production: 38888).
# HAProxy TCP-load-balances that byte stream across both Squid instances, which
# listen on SQUID_PORT (production: 4443) — a DIFFERENT port, and the one the
# production `backend backend_proxyhttp` targets. Squid terminates CONNECT,
# resolves the destination name, and tunnels. mTLS is end-to-end inside the
# tunnel, so Squid never sees application plaintext.
#
# HOW SQUID DECIDES. Squid's access control here is production's real one, and
# it has NO destination validation of any kind: a CONNECT is accepted if its
# PORT is in Squid's Safe_ports list and refused with 403 if it is not. Neither
# the client's identity nor the destination (or its resolved address) enters the
# decision. See docs/adr/0028-production-config-fidelity.md; the ACLs themselves
# are measured directly, without needing this stack, by tests/fidelity/run.sh.
#
# Note the structural difference from TARGET that these tests make visible:
# a client-certificate problem is reported by the IoT Mock *inside* an
# already-established tunnel. The tunnel setup itself (CONNECT) succeeds.
# ============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

if [ "${ARCH}" != "current" ]; then
    echo "b2 requires ARCH=current (currently ${ARCH}); run ./scripts/up.sh current" >&2
    exit 2
fi

group b2-current-functional

log "VIP=${VIP}:${CLIENT_PORT} (CONNECT)  haproxy owner: $(vip_owner)"
runlog "b2 start: arch=${ARCH} vip_owner=$(vip_owner)"

# ---------------------------------------------------------------------------
# B2.1  CONNECT with a valid client cert -> working end-to-end mTLS request
# ---------------------------------------------------------------------------
J="${RAW}/${GROUP}/b2.1-valid.json"
client_json "${J}" -mode=connect -proxy="${VIP}:${CLIENT_PORT}" \
    -target-host=iot0000001.test.domain -target-port=443 \
    ${CERT_VALID} ${CA_POC} -duration=3s -concurrency=2 -label=b2.1 >/dev/null

ATT=$(jget "${J}" "d['attempts']")
SUCC=$(jget "${J}" "d['success']")
C200=$(jget "${J}" "d['http_status_codes'].get('200',0)")
CREJ=$(jget "${J}" "d['connect_rejected']")
CERR=$(jget "${J}" "d['connect_error']")
TLS=$(jget "${J}" "d['tls_error']")
log "B2.1  attempts=${ATT} success=${SUCC} http_200=${C200} connect_rejected=${CREJ} connect_error=${CERR} tls_error=${TLS}"
log "B2.1  connect_status_codes=$(jget "${J}" "d['connect_status_codes']")"
[ "${SUCC}" -gt 0 ] && [ "${C200}" -gt 0 ]
expect "B2.1 CONNECT iot0000001.test.domain:443 with a valid cert -> end-to-end mTLS request succeeds (200s=${C200})" $?

# ---------------------------------------------------------------------------
# ROOT CAUSE PROBE for a CONNECT that does not come back 200.
#
# A non-2xx on CONNECT could come from HAProxy (no server available) or from
# Squid. This connects DIRECTLY to squid-1 on SQUID_PORT (production: 4443) —
# Squid's own listener, which clients never reach in production — bypassing
# HAProxy entirely, and prints the raw response, which carries Squid's own error
# code if Squid produced one. Any X-Squid-Error in it is Squid's verdict, not
# HAProxy's.
# ---------------------------------------------------------------------------
log ""
log "B2.diag  direct CONNECT to squid-1 on SQUID_PORT=${SQUID_PORT} (bypassing HAProxy entirely)"
SQUID_1_IP="$(envval SQUID_1_IP)"
RAWCONN="${RAW}/${GROUP}/squid-raw-connect.txt"
docker exec poc-haproxy-1 sh -c "printf 'CONNECT iot0000001.test.domain:443 HTTP/1.1\r\nHost: iot0000001.test.domain:443\r\n\r\n' | nc -w 5 ${SQUID_1_IP} ${SQUID_PORT}" \
    > "${RAWCONN}" 2>&1
head -8 "${RAWCONN}" | sed 's/^/      /' | tee -a "${GROUP_LOG}"
STATUS_LINE="$(head -1 "${RAWCONN}")"
XSQUID="$(grep -i '^X-Squid-Error' "${RAWCONN}" | head -1)"
log "      status line : ${STATUS_LINE:-<no response>}"
log "      ${XSQUID:-<no X-Squid-Error header>}"
# Three possible readings, and the test states which one it got rather than
# assuming the failure it was originally written to explain:
#   2xx          -> Squid itself accepted the CONNECT: the tunnel path works and
#                   the answer came from Squid, not from HAProxy.
#   error page   -> Squid's OWN error code is in the response; report which one.
#   nothing      -> neither, so the probe proved nothing and says so.
case "${STATUS_LINE}" in
    *" 2"*)
        pass "B2.diag Squid itself answered 200 Connection established — the CONNECT path through Squid works (${STATUS_LINE})" ;;
    *)
        if [ -n "${XSQUID}" ]; then
            printf '%s' "${XSQUID}" | grep -qi 'ERR_DNS_FAIL'
            expect "B2.diag the error page is Squid's OWN, and it is a DNS failure to resolve the destination (${XSQUID})" $?
        else
            fail "B2.diag Squid returned neither an accepted tunnel nor an error page of its own (status line: ${STATUS_LINE:-<none>}); this probe cannot attribute the failure"
        fi ;;
esac

# ---------------------------------------------------------------------------
# POC PORT-PLAN CHECK — NOT a property of production CURRENT.
#
# Squid's `dns_nameservers` directive accepts NO port suffix: it always queries
# port 53. Whether CURRENT-in-the-POC can resolve at all is therefore decided by
# the POC's own port plan, and by nothing about production.
#
# An earlier revision of this suite ran the DNS layer on a high port (5300) and
# recorded the resulting "Squid answers 503 ERR_DNS_FAIL because nothing answers
# on 53" as though it were a property of CURRENT. It was an artefact of the
# POC's port plan: in production the DNS is on 53, and Squid additionally holds
# a cross-datacenter fallback list (see ADR 0029). The POC now places its DNS
# layer on 53 for exactly this reason, so this checks the port plan that makes
# the rest of the group meaningful — if it fails, every 503 below is a POC
# configuration defect, not a finding about CURRENT.
# ---------------------------------------------------------------------------
PORT_EVIDENCE="${RAW}/${GROUP}/squid-dns-port-evidence.txt"
{
    echo "SQUID DNS PORT CHECK — can Squid resolve at all in this POC?"
    echo "generated $(now_iso) by tests/functional/b2-current-functional.sh"
    echo "================================================================================"
    echo
    echo "Squid's dns_nameservers directive takes NO port suffix, so Squid always"
    echo "queries port 53. Its configured nameservers are the two PowerDNS hosts:"
    echo "  configs/squid/squid-1/squid.conf: dns_nameservers $(envval PDNS_1_IP) $(envval PDNS_2_IP)"
    echo "  POC DNS_PORT (from .env): $(envval DNS_PORT)"
    echo
} > "${PORT_EVIDENCE}"
# The probe is Squid's own query — the destination name on port 53 — issued
# from poc-haproxy-1, which is known to carry dig. (An `nc -z` reachability test
# was the earlier form; it cannot distinguish "port closed" from "nc not
# installed", so it is not used as the assertion's evidence.)
P53_OK=0
for ip in "$(envval PDNS_1_IP)" "$(envval PDNS_2_IP)"; do
    # stderr is discarded deliberately: dig writes "connection refused" there,
    # and folding it into the answer would make a closed port read as a reply.
    A="$(docker exec poc-haproxy-1 dig +short +time=2 +tries=1 -p 53 "@${ip}" iot0000001.test.domain A 2>/dev/null | tr '\n' ' ')"
    printf '  %-14s :53  %s\n' "${ip}" "${A:-<no answer>}" >> "${PORT_EVIDENCE}"
    log "B2.diag  squid-1's nameserver ${ip}:53 answered the destination lookup: '${A:-<no answer>}'"
    [ -n "${A}" ] && P53_OK=$((P53_OK+1))
done
log "B2.diag  Squid's configured nameservers answering on port 53: ${P53_OK}/2"
[ "${P53_OK}" -eq 2 ]
expect "B2.diag Squid's nameservers answer the destination lookup on port 53, the only port Squid can query (POC port plan; NOT a CURRENT property)" $?
log "      raw evidence: ${PORT_EVIDENCE}"

# ---------------------------------------------------------------------------
# B2.2  the same through several random identities from the 1M namespace.
#       -random-host is NOT used here: connect mode's random helper produces a
#       bare iotNNNNNNN (no zone), which is not a resolvable CONNECT authority.
#       Iterating explicit random identities tests the same property without
#       depending on that helper.
# ---------------------------------------------------------------------------
log ""
log "B2.2  random identities from the 1M namespace"
RND_PASS=0
RND_FAIL=0
: > "${RAW}/${GROUP}/b2.2-random.txt"
for i in $(seq 1 6); do
    name="iot$(printf '%07d' $(( (RANDOM * 32768 + RANDOM) % 1000000 + 1 ))).test.domain"
    J="${RAW}/${GROUP}/b2.2-${name}.json"
    client_json "${J}" -mode=connect -proxy="${VIP}:${CLIENT_PORT}" \
        -target-host="${name}" -target-port=443 \
        ${CERT_VALID} ${CA_POC} -duration=2s -concurrency=1 -label="b2.2-${name}" >/dev/null
    s=$(jget "${J}" "d['success']")
    c=$(jget "${J}" "d['http_status_codes'].get('200',0)")
    printf '%s success=%s http_200=%s\n' "${name}" "${s}" "${c}" | tee -a "${RAW}/${GROUP}/b2.2-random.txt"
    if [ "${s}" -gt 0 ] && [ "${c}" -gt 0 ]; then RND_PASS=$((RND_PASS+1)); else RND_FAIL=$((RND_FAIL+1)); fi
done
log "B2.2  ${RND_PASS}/$((RND_PASS+RND_FAIL)) random identities served 200 (details: ${RAW}/${GROUP}/b2.2-random.txt)"
[ "${RND_FAIL}" -eq 0 ] && [ "${RND_PASS}" -gt 0 ]
expect "B2.2 every random identity reached the IoT Mock (${RND_PASS} ok, ${RND_FAIL} failed)" $?

# ---------------------------------------------------------------------------
# B2.5  missing client certificate -- the one negative mTLS case that is left.
#
# [REMOVED] B2.3 (client-expired) and B2.4 (client-untrusted, signed by a rogue
# CA): the PKI was simplified to the nominal case only (scripts/gen-certs.sh),
# so neither certificate exists any more. Removed by decision, not by accident.
# THIS REMOVES REAL COVERAGE -- the full note is in the matching block of
# tests/functional/b1-target-functional.sh, and the loss is recorded in
# docs/final-validation.md (section "mTLS"). The numbers 3 and 4 are left as a
# GAP rather than reused, so old evidence keeps its meaning.
#
# EXPECTED SHAPE IS DIFFERENT FROM TARGET: the CONNECT is accepted, the tunnel
# is established, and the IoT Mock then rejects the TLS handshake inside it. So
# connect_rejected must be 0 and mtls_rejected must be the dominant outcome.
#
# Why the CONNECT is accepted is not a subtlety about a destination policy:
# production Squid HAS no destination policy. Its whole decision is port-based
# ("is :443 in Safe_ports?"), and the client's certificate never reaches Squid
# at all -- it is presented INSIDE the tunnel, to the IoT Mock, during the TLS
# handshake Squid is merely relaying. A missing certificate therefore cannot
# affect the CONNECT in either direction. See ADR 0028.
# ---------------------------------------------------------------------------
sleep 2

# B2.5  missing certificate: no -client-cert at all.
J="${RAW}/${GROUP}/b2.5-nocert.json"
client_json "${J}" -mode=connect -proxy="${VIP}:${CLIENT_PORT}" \
    -target-host=iot0000001.test.domain -target-port=443 \
    ${CA_POC} -duration=2s -concurrency=1 -label=b2.5 >/dev/null
SUCC=$(jget "${J}" "d['success']")
MTLS=$(jget "${J}" "d['mtls_rejected']")
CODES=$(jget "${J}" "d['connect_status_codes']")
ERRS=$(jget "${J}" "' | '.join(d['errors_sample'][:2])")
log "B2.5  no client cert: attempts=$(jget "${J}" "d['attempts']") success=${SUCC} mtls_rejected=${MTLS} connect_status_codes=${CODES}"
log "B2.5  errors_sample: ${ERRS}"
[ "${SUCC}" -eq 0 ] && [ "${MTLS}" -gt 0 ]
expect "B2.5 missing client cert: rejected by the IoT Mock inside the tunnel (mtls_rejected=${MTLS}, success=${SUCC})" $?
printf '%s' "${CODES}" | grep -q '200'
expect "B2.5 tunnel WAS established (CONNECT answered 200)" $?
printf '%s' "${ERRS}" | grep -qi "certificate required"
expect "B2.5 raw TLS alert is \"certificate required\": ${ERRS%% | *}" $?

summary
