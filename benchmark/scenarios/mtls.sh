# ---------------------------------------------------------------------------
# Scenario A — end-to-end mTLS request throughput (the headline comparison)
# Sourced by benchmark/run.sh, which defines everything this scenario closes
# over. Not executable on its own.
# ---------------------------------------------------------------------------
scenario_tls() {
    local rps="${RPS:-6000}"
    require_ready
    log "SCENARIO: end-to-end mTLS, ${rps} rps target, ${CONCURRENCY} workers, ${DURATION}s, arch=${ARCH}, workload=${METHOD} ${PATH_OPT} body=${BODY_BYTES}B"

    local label="${ARCH}${SIZING_SUFFIX}-mtls-${LABEL_METHOD}-${rps}rps"
    snapshot_metrics "${label}-before"

    if [ "${ARCH}" = "current" ]; then
        # CURRENT: client issues CONNECT to the VIP; Squid resolves and tunnels.
        run_client -mode=connect \
            -proxy="${VIP}:${CLIENT_PORT}" \
            -target-host="iot0000001.${ZONE}" -target-port="${IOT_MOCK_PORT}" \
            -random-host -host-count="${HOST_COUNT}" \
            -client-cert=/pki/clients/client-valid.crt \
            -client-key=/pki/clients/client-valid.key \
            -ca=/pki/ca/ca.crt \
            -method="${METHOD}" -path="${PATH_OPT}" -body-bytes="${BODY_BYTES}" \
            -duration="${DURATION}s" -rps="${rps}" -concurrency="${CONCURRENCY}" \
            -warmup=10s -label="${label}" -out="/results/${label}.json"
    else
        # TARGET: client speaks TLS directly to the VIP with the name as SNI.
        run_client -mode=tls \
            -proxy="${VIP}:${IOT_MOCK_PORT}" \
            -servername="iot0000001.${ZONE}" \
            -random-host -host-count="${HOST_COUNT}" \
            -client-cert=/pki/clients/client-valid.crt \
            -client-key=/pki/clients/client-valid.key \
            -ca=/pki/ca/ca.crt \
            -method="${METHOD}" -path="${PATH_OPT}" -body-bytes="${BODY_BYTES}" \
            -duration="${DURATION}s" -rps="${rps}" -concurrency="${CONCURRENCY}" \
            -warmup=10s -label="${label}" -out="/results/${label}.json"
    fi

    snapshot_metrics "${label}-after"
    echo "  result -> benchmark/results/${label}.json"
}
