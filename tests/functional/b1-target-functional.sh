#!/usr/bin/env bash
# ============================================================================
# B1 — TARGET functional tests (SNI passthrough, arch=target).
#
# A client opens TLS DIRECTLY to the VIP:443 with SNI = iotNNNNNNN.test.domain.
# There is no CONNECT in this architecture. Every check below is performed
# through the VIP, so it exercises the full path: VIP -> HAProxy -> SNI parse ->
# local dnsdist -> resolved-address policy -> IoT Mock mTLS.
# ============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

if [ "${ARCH}" != "target" ]; then
    echo "b1 requires ARCH=target (currently ${ARCH}); run ./scripts/up.sh target" >&2
    exit 2
fi

group b1-target-functional

log "VIP=${VIP}:${IOT_MOCK_PORT}  haproxy owner: $(vip_owner)"
runlog "b1 start: arch=${ARCH} vip_owner=$(vip_owner)"

# ---------------------------------------------------------------------------
# B1.1  valid SNI + valid client cert  ->  HTTP 200, body "ok"
#
# -method=GET is explicit and load-bearing. The measured workload is PUT, so
# PUT is the client default; /health with a body is not the health probe. This
# check is about the INFRASTRUCTURE probe, so it asks for the probe: GET with
# no body, answering "ok".
# ---------------------------------------------------------------------------
J="${RAW}/${GROUP}/b1.1-valid.json"
client_json "${J}" -mode=tls -proxy="${VIP}:${IOT_MOCK_PORT}" \
    -servername=iot0000001.test.domain -path=/health -method=GET -body-bytes=0 \
    ${CERT_VALID} ${CA_POC} -duration=2s -concurrency=2 -label=b1.1 >/dev/null

SUCC=$(jget "${J}" "d['success']")
ATT=$(jget "${J}" "d['attempts']")
C200=$(jget "${J}" "d['http_status_codes'].get('200',0)")
BODY=$(jget "${J}" "d['outcomes_sample'][0].get('body','')")
TLSERR=$(jget "${J}" "d['tls_error']")
MTLS=$(jget "${J}" "d['mtls_rejected']")
log "B1.1  attempts=${ATT} success=${SUCC} http_200=${C200} tls_error=${TLSERR} mtls_rejected=${MTLS} first_body=${BODY}"
[ "${C200}" -gt 0 ] && [ "${SUCC}" -gt 0 ]
expect "B1.1 valid SNI + valid client cert -> HTTP 200 (200s=${C200}, success=${SUCC})" $?
[ "${BODY}" = "ok" ]
expect "B1.1 response body is exactly \"ok\" (got \"${BODY}\")" $?

# ---------------------------------------------------------------------------
# B1.2  random identity from the 1M namespace -> 200, and the server-observed
#       SNI must equal the name requested.
#
#       This is also the PUT workload check: -method=PUT with a 256-byte body is
#       the request the real IoT devices accept, and the device's own byte count
#       in the response is what proves the body arrived intact.
# ---------------------------------------------------------------------------
J="${RAW}/${GROUP}/b1.2-random.json"
client_json "${J}" -mode=tls -proxy="${VIP}:${IOT_MOCK_PORT}" \
    -path=/ -method=PUT -body-bytes=256 \
    -random-host -host-count=1000000 ${CERT_VALID} ${CA_POC} \
    -duration=4s -concurrency=4 -label=b1.2 >/dev/null

CHECKED=$(jget "${J}" "d['identity_checked']")
MISMATCH=$(jget "${J}" "d['identity_mismatch']")
SUCC=$(jget "${J}" "d['success']")
C200=$(jget "${J}" "d['http_status_codes'].get('200',0)")
METHOD=$(jget "${J}" "d.get('method','')")
SAMPLE=$(jget "${J}" "d['outcomes_sample'][0].get('name','')+' -> sni='+d['outcomes_sample'][0].get('sni','')")
BODY=$(jget "${J}" "d['outcomes_sample'][0].get('body','')")
log "B1.2  attempts=$(jget "${J}" "d['attempts']") success=${SUCC} http_200=${C200} identity_checked=${CHECKED} identity_mismatch=${MISMATCH} method=${METHOD}"
log "B1.2  sample: ${SAMPLE}"
log "B1.2  device response to the PUT: ${BODY}"
[ "${METHOD}" = "PUT" ]
expect "B1.2 the measured workload request is PUT, not GET (method=${METHOD})" $?
printf '%s' "${BODY}" | grep -q '"bytes":256'
expect "B1.2 the device consumed the full 256-byte PUT body" $?
[ "${SUCC}" -gt 0 ] && [ "${C200}" -gt 0 ] && [ "${CHECKED}" -gt 0 ]
expect "B1.2 random identity answers 200 (200s=${C200} of ${SUCC} successes, ${CHECKED} identities checked)" $?
[ "${MISMATCH}" -eq 0 ]
expect "B1.2 server-observed SNI equals the name requested for every response (mismatches=${MISMATCH})" $?
[ "${CHECKED}" -ge "${SUCC}" ]
expect "B1.2 identity JSON present on every successful response (checked=${CHECKED} >= success=${SUCC})" $?

# ---------------------------------------------------------------------------
# B1.5  missing client certificate -- the one negative mTLS case that is left.
#
# [REMOVED] B1.3 (client-expired) and B1.4 (client-untrusted, signed by a rogue
# CA). The PKI was simplified to the nominal case only -- scripts/gen-certs.sh
# now generates ca/, server/ and client-valid.* and nothing else -- so neither
# certificate exists any more. Removed by decision, not by accident.
#
# THIS REMOVES REAL COVERAGE. Those two cases were what proved the IoT Mock
# *rejects* a client certificate that is present and invalid, i.e. that the mTLS
# alert the client sees is emitted by the Mock's own TLS stack and not by a
# proxy that had already terminated TLS. The missing-certificate case below
# still exercises the rejection path, but a certificate that is present and
# invalid no longer is.
# The loss is recorded in docs/final-validation.md (section "mTLS").
#
# The numbers 3 and 4 are deliberately left as a GAP rather than reused: old
# evidence under benchmark/results/raw/ names its files b1.3-*/b1.4-*, and
# renumbering would silently re-point those artifacts at different checks.
#
# Presented to the SAME valid SNI as B1.1, so the only variable left in the
# negative case is the absence of the client certificate: the rejection must
# come from the IoT Mock at the TLS layer, not from the destination policy.
# ---------------------------------------------------------------------------
sleep 3   # let the preceding closed-loop traffic drain before the negative test

# B1.5  missing certificate is a distinct case: no -client-cert at all.
J="${RAW}/${GROUP}/b1.5-nocert.json"
client_json "${J}" -mode=tls -proxy="${VIP}:${IOT_MOCK_PORT}" \
    -servername=iot0000001.test.domain -path=/health \
    ${CA_POC} -duration=2s -concurrency=1 -label=b1.5 >/dev/null
SUCC=$(jget "${J}" "d['success']")
MTLS=$(jget "${J}" "d['mtls_rejected']")
TLSERR=$(jget "${J}" "d['tls_error']")
ERRS=$(jget "${J}" "' | '.join(d['errors_sample'][:2])")
log "B1.5  no client cert: attempts=$(jget "${J}" "d['attempts']") success=${SUCC} mtls_rejected=${MTLS} tls_error=${TLSERR}"
log "B1.5  errors_sample: ${ERRS}"
[ "${SUCC}" -eq 0 ] && [ "${MTLS}" -gt 0 ]
expect "B1.5 missing client cert rejected at the TLS layer (mtls_rejected=${MTLS}, success=${SUCC})" $?
printf '%s' "${ERRS}" | grep -qi "certificate required"
expect "B1.5 raw TLS alert is \"certificate required\": ${ERRS%% | *}" $?

# ---------------------------------------------------------------------------
# B1.6  verbatim curl — reproduces the operator-facing smoke test literally.
# ---------------------------------------------------------------------------
curl_health() {
    docker run --rm --network "${NET}" -v "${PKI}:/pki:ro" curlimages/curl:latest \
        -sS -w '\nhttp=%{http_code}\n' \
        --resolve "iot0000001.test.domain:${IOT_MOCK_PORT}:${VIP}" \
        --cert /pki/clients/client-valid.crt \
        --key /pki/clients/client-valid.key \
        --cacert /pki/ca/ca.crt \
        "https://iot0000001.test.domain/health" 2>&1
}
CURL_OUT="${RAW}/${GROUP}/b1.6-curl.txt"
curl_health | tee "${CURL_OUT}" >> "${GROUP_LOG}"
CURL_RC=${PIPESTATUS[0]}
log "B1.6  curl exit=${CURL_RC}"
grep -q '^ok$' "${CURL_OUT}" && grep -q 'http=200' "${CURL_OUT}"
expect "B1.6 verbatim curl --resolve --cert --key --cacert -> body \"ok\", http=200" $?

summary
