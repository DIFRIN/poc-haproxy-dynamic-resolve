# ---------------------------------------------------------------------------
# Scenario B — DNS layer comparison (brief §14)
#
# The two architectures are compared on the DNS path each one actually uses:
#   CURRENT: the Squid instances resolve, and their DNS-server selection is
#            whatever the installed Squid version does with dns_nameservers.
#   TARGET:  HAProxy resolves through its local dnsdist, which round-robins
#            across both PowerDNS servers.
# Measured directly against PowerDNS as a control, so the cost of each
# intermediate layer is visible rather than inferred.
# Sourced by benchmark/run.sh, which defines everything this scenario closes
# over. Not executable on its own.
# ---------------------------------------------------------------------------
scenario_dns() {
    local qps="${DNS_QPS:-5000}"
    require_ready
    log "SCENARIO: DNS layer comparison, ${qps} qps target, ${DURATION}s"

    local label="${ARCH}${SIZING_SUFFIX}-dns-${qps}qps"

    echo "  -- control: PowerDNS 1 directly (no intermediate layer) --"
    run_client -mode=dns -server="${PDNS_1}:${DNS_PORT}" \
        -zone="${ZONE}" -host-count="${HOST_COUNT}" \
        -duration="${DURATION}s" -qps="${qps}" -concurrency="${CONCURRENCY}" \
        -out="/results/control-pdns1-dns.json" -label="control-pdns1"

    if [ "${ARCH}" = "target" ]; then
        local d
        for d in 1 2; do
            local ip; ip="$(envval DNSDIST_${d}_IP)"
            echo "  -- dnsdist-${d} (${ip}) --"
            run_client -mode=dns -server="${ip}:${DNS_PORT}" \
                -zone="${ZONE}" -host-count="${HOST_COUNT}" \
                -duration="${DURATION}s" -qps="${qps}" -concurrency="${CONCURRENCY}" \
                -out="/results/${ARCH}-dnsdist${d}-dns.json" -label="dnsdist-${d}"
        done
        echo "  per-backend distribution: read from the dnsdist API"
        curl -s "http://$(envval DNSDIST_1_IP):8083/api/v1/servers/localhost" \
            -H "X-API-Key: poc-dnsdist-api-key" 2>/dev/null | head -c 2000 \
            > "${RESULTS}/${label}-dnsdist-servers.json" || true
    else
        echo "  NOTE: the CURRENT DNS path runs inside Squid and is not directly"
        echo "  addressable as a DNS endpoint. Its DNS behaviour is measured by"
        echo "  the request-rate scenarios (each new CONNECT forces a Squid"
        echo "  resolution) and by Squid's own cache-manager DNS counters."
        for s in 1 2; do
            docker exec "poc-squid-${s}" sh -c \
              'squidclient mgr:dns 2>/dev/null || echo "squidclient unavailable"' \
              > "${RESULTS}/${label}-squid${s}-mgr-dns.txt" 2>&1 || true
            echo "  squid-${s} DNS counters -> benchmark/results/${label}-squid${s}-mgr-dns.txt"
        done
    fi
}
