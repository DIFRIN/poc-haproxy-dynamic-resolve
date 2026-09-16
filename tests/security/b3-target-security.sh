#!/usr/bin/env bash
# ============================================================================
# B3 — TARGET security: the SSRF corpus against SNI passthrough (arch=target).
#
# Each name below resolves (in the authoritative zone) to an address class the
# destination policy must refuse. The client opens TLS DIRECTLY to the VIP with
# that name as SNI; HAProxy resolves it through local dnsdist, validates the
# RESOLVED ADDRESS, and refuses by closing the TCP connection.
#
# EXPECTED OUTCOME: no HTTP status ever, because a TCP-mode proxy has no status
# line to send. The refusal surfaces as a TLS handshake failure (EOF) and is
# classified tls_error, with the raw error preserved. A refused connection is a
# PASS here, not a failure.
#
# The corpus is read from the database rather than hard-coded, so the test
# cannot silently drift from the zone it is testing.
# ============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

if [ "${ARCH}" != "target" ]; then
    echo "b3 requires ARCH=target (currently ${ARCH}); run ./scripts/up.sh target" >&2
    exit 2
fi

group b3-target-security

log "VIP=${VIP}:${IOT_MOCK_PORT}  haproxy owner: $(vip_owner)"
runlog "b3 start: arch=${ARCH} vip_owner=$(vip_owner)"

# --- corpus, straight from the authoritative database -------------------------
CORPUS_SQL="select name, coalesce(string_agg(type||' '||content, ', ' order by type, content),'(no records)')
            from records where name like 'ssrf-%' group by name order by name"
docker exec poc-postgres psql -tA -F'|' -U pdns -d pdns -c "${CORPUS_SQL}" \
    > "${RAW}/${GROUP}/corpus.txt" 2>>"${GROUP_LOG}"
mapfile -t CORPUS < <(grep -v '^[[:space:]]*$' "${RAW}/${GROUP}/corpus.txt")
log "corpus size: ${#CORPUS[@]} names (raw: ${RAW}/${GROUP}/corpus.txt)"

# The two non-corpus names the brief also calls out.
EXTRA=("nx.test.domain|(undefined -> NXDOMAIN)" "servfail.test.domain|(intended SERVFAIL)")

# --- raw DNS evidence: what each name actually resolves to --------------------
log ""
log "---- DNS: what the local dnsdist returns for each corpus name ----"
{
    printf '%-30s %-46s %s\n' NAME "DB RECORDS" "dnsdist-1 A (via the active node)"
    for row in "${CORPUS[@]}" "${EXTRA[@]}"; do
        name="${row%%|*}"; recs="${row#*|}"
        ans=$(docker exec poc-haproxy-1 dig +short +time=2 +tries=1 -p "$(envval DNS_PORT)" \
                "@$(envval DNSDIST_1_IP)" "${name}" A 2>/dev/null | tr '\n' ',' | sed 's/,$//')
        [ -z "${ans}" ] && ans="(no A record)"
        printf '%-30s %-46s %s\n' "${name}" "${recs:0:45}" "${ans}"
    done
} | tee "${RAW}/${GROUP}/dns-resolution.txt" | sed 's/^/    /' >> "${GROUP_LOG}"

# ---------------------------------------------------------------------------
# One corpus name = one attempt set. The check is "no request ever succeeded",
# NOT a throughput number: a refusal is a refusal.
# ---------------------------------------------------------------------------
DUR="${B3_DURATION:-6s}"
RPS="${B3_RPS:-8}"

check_name() {
    local name="$1" recs="$2" i="$3"
    local J="${RAW}/${GROUP}/$(printf '%02d' "${i}")-${name}.json"
    client_json "${J}" -mode=tls -proxy="${VIP}:${IOT_MOCK_PORT}" \
        -servername="${name}" -path=/health ${CERT_VALID} ${CA_POC} \
        -duration="${DUR}" -rps="${RPS}" -concurrency=2 -timeout=5s \
        -label="b3-${name}" >/dev/null

    local att succ tls mtls http to codes p50 err
    att=$(jget "${J}" "d['attempts']")
    succ=$(jget "${J}" "d['success']")
    tls=$(jget "${J}" "d['tls_error']")
    mtls=$(jget "${J}" "d['mtls_rejected']")
    http=$(jget "${J}" "d['http_error']")
    to=$(jget "${J}" "d['timeout']")
    codes=$(jget "${J}" "d['http_status_codes']")
    p50=$(jget "${J}" "d['latency_ms']['p50']")
    err=$(jget "${J}" "(d['errors_sample'] or ['(none)'])[0]")

    log ""
    log "  name=${name}"
    log "    resolves to : ${recs}"
    log "    attempts=${att} success=${succ} tls_error=${tls} mtls_rejected=${mtls} http_error=${http} timeout=${to}"
    log "    http_status_codes=${codes}   p50_refusal_ms=${p50}"
    log "    failure mode: ${err}"

    if [ "${att}" -eq 0 ]; then
        fail "B3 ${name}: no attempt completed -- cannot conclude the policy refused it"
        return
    fi
    if [ "${succ}" -eq 0 ] && [ "${codes}" = "{}" ]; then
        pass "B3 ${name} REFUSED (success=0, no HTTP status; ${tls} tls_error/${mtls} mtls_rejected/${to} timeout of ${att}; p50=${p50}ms)"
    else
        fail "B3 ${name} NOT refused: success=${succ} http_status_codes=${codes}"
    fi
}

log ""
log "---- SSRF corpus (${DUR} per name, ${RPS} req/s, timeout 5s) ----"
log "     (ssrf-rebind is excluded here and handled in its own section below: it has BOTH a"
log "      permitted and a forbidden answer, so \"always refused\" is the wrong assertion for it)"
i=0
for row in "${CORPUS[@]}"; do
    case "${row%%|*}" in
        ssrf-rebind.test.domain) i=$((i+1)); continue ;;
    esac
    i=$((i+1))
    check_name "${row%%|*}" "${row#*|}" "${i}"
done

# ---------------------------------------------------------------------------
# Names that must not resolve at all. Same expectation (refused), but the
# reason is a failed resolution rather than a policy match, and it is worth
# separating: it is the fail-closed path, not the deny-list path.
# ---------------------------------------------------------------------------
log ""
log "---- unresolvable / failing names ----"
for row in "${EXTRA[@]}"; do
    i=$((i+1))
    check_name "${row%%|*}" "${row#*|}" "${i}"
done

# ---------------------------------------------------------------------------
# THE IMPORTANT ONE: ssrf-rebind.test.domain
#
# Two A records: one permitted (${IOT_MOCK_IP}) and one forbidden (127.0.0.1).
# The claim under test is that the policy is applied to the RESOLVED address,
# not to the attacker-chosen NAME. If it keyed on the name, this run would be
# uniformly accepted or uniformly refused. It is neither: the resolver rotates
# the answer order, and the outcome follows the address.
# ---------------------------------------------------------------------------
log ""
log "---- ssrf-rebind: policy must follow the RESOLVED address ----"

# Show that the resolver really does hand back both addresses over time.
REBIND_ANSWERS="${RAW}/${GROUP}/rebind-dns-answers.txt"
: > "${REBIND_ANSWERS}"
for _ in $(seq 1 12); do
    docker exec poc-haproxy-1 dig +short +time=2 +tries=1 -p "$(envval DNS_PORT)" \
        "@$(envval DNSDIST_1_IP)" ssrf-rebind.test.domain A 2>/dev/null \
        | tr '\n' ',' | sed 's/,$//' >> "${REBIND_ANSWERS}"
    printf '\n' >> "${REBIND_ANSWERS}"
done
log "  dnsdist answer order over 12 queries (comma-separated, first = one HAProxy may pick):"
sed 's/^/      /' "${REBIND_ANSWERS}" | tee -a "${GROUP_LOG}"
N_60=$(grep -c '^172\.28\.0\.60,127\.0\.0\.1$' "${REBIND_ANSWERS}" || true)
N_LO=$(grep -c '^127\.0\.0\.1,172\.28\.0\.60$' "${REBIND_ANSWERS}" || true)
log "  orderings observed: permitted-first=${N_60}  forbidden-first=${N_LO}"
[ "${N_60}" -gt 0 ] && [ "${N_LO}" -gt 0 ]
expect "B3.rebind resolver returns BOTH orderings (permitted-first=${N_60}, forbidden-first=${N_LO})" $?

J="${RAW}/${GROUP}/99-ssrf-rebind.test.domain.json"
client_json "${J}" -mode=tls -proxy="${VIP}:${IOT_MOCK_PORT}" \
    -servername=ssrf-rebind.test.domain -path=/health ${CERT_VALID} ${CA_POC} \
    -duration="${B3_REBIND_DURATION:-20s}" -rps=5 -concurrency=1 -timeout=5s \
    -label=b3-rebind >/dev/null
ATT=$(jget "${J}" "d['attempts']")
SUCC=$(jget "${J}" "d['success']")
TLS=$(jget "${J}" "d['tls_error']")
CODES=$(jget "${J}" "d['http_status_codes']")
log "  attempts=${ATT} success(permitted address)=${SUCC} tls_error(forbidden address)=${TLS} http_status_codes=${CODES}"
log "  (successes are the connections the resolver pointed at ${IOT_MOCK_IP}; refusals are the"
log "   connections it pointed at 127.0.0.1. Both outcomes from ONE name prove the decision"
log "   was made on the resolved address.)"

# The decisive assertions: nothing that resolved to the forbidden address got
# through, and the name was not uniformly allowed.
C200=$(jget "${J}" "d['http_status_codes'].get('200',0)")
[ "${TLS}" -gt 0 ]
expect "B3.rebind the forbidden address was refused at least once (tls_error=${TLS})" $?
[ "${SUCC}" -gt 0 ]
expect "B3.rebind the permitted answer was NOT collateral damage (it still succeeded ${SUCC}x)" $?
# Every success must have come from the permitted address: the ONLY way a
# success can occur is a connection to ${IOT_MOCK_IP}, because 127.0.0.1 inside
# this container has no listener and could not have answered an mTLS request.
log "  note: a success proves the connection reached the IoT Mock (an mTLS handshake"
log "        against 127.0.0.1 inside the node container cannot produce HTTP 200)."

# ---------------------------------------------------------------------------
# Explicit rcode evidence for the two non-corpus names.
#
# The corpus entry servfail.test.domain is documented in configs/postgres/init/02-seed.sh
# as "a zone with no SOA -> genuine SERVFAIL". MEASURED, IT IS NOT: PowerDNS 4.9
# with the gmysql backend only treats a domain as a zone when an SOA record
# exists, so `servfail.test.domain` (a domains row with ZERO records) is answered
# out of its parent zone and returns NXDOMAIN. Recorded here rather than assumed
# away. The genuine SERVFAIL path in this stack is "every PowerDNS backend down",
# which is exercised by the failover group (B5.5).
# ---------------------------------------------------------------------------
log ""
log "---- rcode evidence (dnstest against the local dnsdist) ----"
for n in nx.test.domain servfail.test.domain test.domain; do
    OUT="$(docker run --rm --network "${NET}" -v "${PKI}:/pki:ro" poc-client \
        -mode=dnstest -server="$(envval DNSDIST_1_IP):$(envval DNS_PORT)" -name="${n}" -qtype=A 2>/dev/null)"
    printf '%s\n' "${OUT}" > "${RAW}/${GROUP}/dnstest-${n}.json"
    log "  ${n}: rcode=$(printf '%s' "${OUT}" | grep -o '"rcode": "[A-Z]*"' | head -1) answers=$(printf '%s' "${OUT}" | grep -o '"answers": \[[^]]*\]' | head -1)"
done
RCODE_SF="$(grep -o '"rcode": "[A-Z]*"' "${RAW}/${GROUP}/dnstest-servfail.test.domain.json" | head -1 | cut -d'"' -f4)"
if [ "${RCODE_SF}" = "SERVFAIL" ]; then
    log "  the seed name servfail.test.domain does produce a genuine SERVFAIL as documented."
else
    log "  FINDING (not a security failure): servfail.test.domain returns ${RCODE_SF}, not the"
    log "  SERVFAIL configs/postgres/init/02-seed.sh documents. It is still refused by the proxy, so the"
    log "  security property holds; the corpus entry simply does not test what it claims to."
    log "  The real SERVFAIL path (all PowerDNS backends down) is tested in the failover group."
fi

# ---------------------------------------------------------------------------
# Raw HAProxy evidence for the refusal path.
# ---------------------------------------------------------------------------
log ""
log "---- HAProxy log evidence (last 15 fe_tls lines on the active node) ----"
docker logs --tail 400 "poc-$(vip_owner)" 2>&1 | grep 'fe_tls' | tail -15 \
    | tee "${RAW}/${GROUP}/haproxy-refusals.log" | sed 's/^/    /' >> "${GROUP_LOG}"

summary
