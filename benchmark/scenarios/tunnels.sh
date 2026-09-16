# ---------------------------------------------------------------------------
# Scenario C — 10,000 simultaneous tunnels
#
# Concurrency, not throughput: the client opens and HOLDS the target number of
# tunnels, and the harness records the resource cost of holding them (FDs,
# sockets, memory) rather than only the request rate.
# Sourced by benchmark/run.sh, which defines everything this scenario closes
# over. Not executable on its own.
# ---------------------------------------------------------------------------
scenario_tunnels() {
    local conns="${TUNNELS:-10000}"
    require_ready
    log "SCENARIO: ${conns} simultaneous tunnels, arch=${ARCH}, workload=${METHOD} ${PATH_OPT} body=${BODY_BYTES}B"

    local label="${ARCH}${SIZING_SUFFIX}-tunnels-${conns}-${LABEL_METHOD}"
    snapshot_metrics "${label}-before"

    if [ "${ARCH}" = "current" ]; then
        run_client -mode=connect -proxy="${VIP}:${CLIENT_PORT}" \
            -target-host="iot0000001.${ZONE}" -target-port="${IOT_MOCK_PORT}" \
            -random-host -host-count="${HOST_COUNT}" \
            -client-cert=/pki/clients/client-valid.crt \
            -client-key=/pki/clients/client-valid.key -ca=/pki/ca/ca.crt \
            -method="${METHOD}" -path="${PATH_OPT}" -body-bytes="${BODY_BYTES}" \
            -persistent -requests-per-tunnel=1000000 \
            -duration="${DURATION}s" -concurrency="${conns}" \
            -out="/results/${label}.json" -label="${label}"
    else
        # NOTE: -mode=tls has no persistent-tunnel implementation, so this is
        # NOT the same workload as the CURRENT branch above and the two are not
        # comparable. It is kept so the scenario runs under either arch without
        # a silent no-op; the report must not quote it against CURRENT's.
        run_client -mode=tls -proxy="${VIP}:${IOT_MOCK_PORT}" \
            -servername="iot0000001.${ZONE}" \
            -random-host -host-count="${HOST_COUNT}" \
            -client-cert=/pki/clients/client-valid.crt \
            -client-key=/pki/clients/client-valid.key -ca=/pki/ca/ca.crt \
            -method="${METHOD}" -path="${PATH_OPT}" -body-bytes="${BODY_BYTES}" \
            -persistent -requests-per-tunnel=1000000 \
            -duration="${DURATION}s" -concurrency="${conns}" \
            -out="/results/${label}.json" -label="${label}"
    fi

    snapshot_metrics "${label}-after"

    # Resource cost of holding the tunnels, captured while they are up.
    local out="${RESULTS}/${label}-resources.txt"
    {
        echo "# tunnel resource snapshot: ${label}"
        echo "## active node HAProxy FDs"
        for n in 1 2; do
            docker exec "poc-haproxy-${n}" sh -c \
              'printf "  haproxy-%s open FDs: %s\n" "$(hostname)" "$(ls /proc/$(pidof haproxy | cut -d" " -f1)/fd 2>/dev/null | wc -l)"' 2>/dev/null
        done
        echo "## kernel socket state"
        cat /proc/net/sockstat | sed 's/^/  /'
        echo "## conntrack"
        cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null | sed 's/^/  count: /'
        cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null | sed 's/^/  max:   /'
    } > "${out}" 2>&1
    echo "  resources -> ${out#$REPO/}"
}
