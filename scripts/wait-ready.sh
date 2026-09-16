#!/usr/bin/env bash
# ============================================================================
# wait-ready.sh — block until the stack can actually serve, or fail loudly.
#
# This matters more than it looks. The 1M-row seed runs on the first
# `docker compose up`, and a benchmark started against a half-loaded dataset
# produces numbers that look plausible and are wrong. Every gate below checks a
# property the benchmark depends on, not merely that a container is running.
#
# Exits non-zero on timeout so CI / the harness can fail rather than silently
# measuring a broken stack.
# ============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

EXPECTED_RECORDS="$(grep '^DNS_RECORD_COUNT=' .env | cut -d= -f2)"
ZONE="$(grep '^DNS_ZONE=' .env | cut -d= -f2)"
PDNS_1="$(grep '^PDNS_1_IP=' .env | cut -d= -f2)"
PDNS_2="$(grep '^PDNS_2_IP=' .env | cut -d= -f2)"
DNSDIST_1="$(grep '^DNSDIST_1_IP=' .env | cut -d= -f2)"
DNS_PORT="$(grep '^DNS_PORT=' .env | cut -d= -f2)"
ARCH="$(grep '^ARCH=' .env | cut -d= -f2)"
VIP="$(grep '^VIP_ADDRESS=' .env | cut -d= -f2)"

# dig runs out of the HAProxy node image (bind-tools), which is on dc-lan and
# always present. This avoids depending on the `client` service being up: it is
# an on-demand overlay, added by compose.bench.yaml with an extra -f, and is
# never started by `docker compose up -d`.
dig_at() { docker exec poc-haproxy-1 dig +time=2 +tries=1 +short -p "${DNS_PORT}" "@$1" "$2" "$3" 2>/dev/null; }

wait_for() {
    local desc="$1" timeout="$2"; shift 2
    local i=0
    printf '  %-58s' "${desc}"
    while [ "${i}" -lt "${timeout}" ]; do
        if "$@" >/dev/null 2>&1; then echo "OK"; return 0; fi
        sleep 1; i=$((i+1))
    done
    echo "TIMEOUT (${timeout}s)"; return 1
}

rc=0

echo "[ready] gating on stack readiness (arch=${ARCH})"

# --- 1. PostgreSQL and the full 1M-row dataset -----------------------------
n_records() {
    docker exec poc-postgres psql -tA -U pdns -d pdns \
        -c "SELECT count(*) FROM records WHERE type='A' AND name LIKE 'iot%.${ZONE}'" 2>/dev/null \
        | grep -qx "${EXPECTED_RECORDS}"
}
wait_for "PostgreSQL seeded with ${EXPECTED_RECORDS} IoT records" 300 n_records || rc=1

# --- 2. both PowerDNS answer authoritatively -------------------------------
wait_for "PowerDNS 1 (${PDNS_1}) answers for ${ZONE}" 120 dig_at "${PDNS_1}" "${ZONE}" SOA || rc=1
wait_for "PowerDNS 2 (${PDNS_2}) answers for ${ZONE}" 120 dig_at "${PDNS_2}" "${ZONE}" SOA || rc=1

# --- 3. architecture-specific DNS path -------------------------------------
if [ "${ARCH}" = "target" ]; then
    wait_for "local dnsdist (${DNSDIST_1}) answers" 120 dig_at "${DNSDIST_1}" "${ZONE}" SOA || rc=1
fi

# --- 4. the VIP is owned by exactly one node -------------------------------
vip_owned() {
    local c=0
    for n in 1 2; do
        docker exec "poc-haproxy-${n}" ip -4 addr show eth0 2>/dev/null \
            | grep -q "${VIP}/" && c=$((c+1))
    done
    [ "${c}" -eq 1 ]
}
wait_for "exactly one HAProxy node owns the VIP ${VIP}" 60 vip_owned || rc=1

# --- 5. the IoT Mock is serving mTLS ---------------------------------------
wait_for "IoT Mock healthy" 60 \
    docker inspect -f '{{.State.Health.Status}}' poc-iot-mock 2>/dev/null >/dev/null || true
mock_healthy() {
    [ "$(docker inspect -f '{{.State.Health.Status}}' poc-iot-mock 2>/dev/null)" = "healthy" ]
}
wait_for "IoT Mock healthy" 60 mock_healthy || rc=1

echo
if [ "${rc}" -eq 0 ]; then
    echo "[ready] stack is ready"
else
    echo "[ready] STACK NOT READY -- do not run benchmarks against it" >&2
fi
exit "${rc}"
