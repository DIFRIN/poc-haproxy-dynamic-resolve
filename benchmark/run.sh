#!/usr/bin/env bash
# ============================================================================
# run.sh — CURRENT vs TARGET benchmark harness.
#
#   ./benchmark/run.sh tls      # A/B: end-to-end mTLS request throughput
#   ./benchmark/run.sh dns      # DNS layer: QPS and latency, Squid path vs dnsdist path
#   ./benchmark/run.sh tunnels  # 10,000 simultaneous tunnels
#   ./benchmark/run.sh all
#
# DESIGN CONSTRAINTS THAT MATTER
#
#  1. The load generator does NOT run inside the stack under test. `docker
#     compose run client` would share the CPU budget with HAProxy, dnsdist and
#     the IoT Mock on a single host, so the client would be stealing cycles from
#     its own subject and the result would measure the scheduler, not the
#     architecture. The client runs as its own container with an explicit CPU
#     pinning, and the harness records the host's CPU budget alongside every
#     result so a saturated run is visible rather than silently published.
#
#  2. Every scenario is run against BOTH architectures with the same client
#     flags. The difference under test is the transport: CURRENT speaks CONNECT
#     to VIP:CLIENT_PORT (production: 38888) and is proxied by Squid, TARGET
#     speaks TLS to VIP:IOT_MOCK_PORT (443) with the name as SNI.
#
#     Note CURRENT involves TWO hops on two different ports -- the client-facing
#     CLIENT_PORT and Squid's SQUID_PORT (production: 4443). A single
#     PROXY_PORT variable used for both was a fidelity defect; see
#     docs/adr/0028-production-config-fidelity.md.
#
#     CURRENT's connection ceilings are production's own values, so the harness
#     measures the architecture that actually runs. At production sizing the
#     Squid pair caps concurrent tunnels at 6400, BELOW brief §15's mandatory
#     10,000 -- which is why a "CURRENT resized" variant exists. It is selected
#     by raising the CURRENT_* values in .env and recreating the stack; see the
#     SIZING label block below, which derives the label from the config so a
#     resized run can never be published as production behaviour.
#
#  3. Raw output is preserved. Each run writes its client JSON and a metrics
#     snapshot to benchmark/results/, and the report is written FROM those files.
#     Nothing is retyped and nothing is estimated.
#
#  4. A run is refused unless wait-ready.sh passes. Benchmarking a half-seeded
#     dataset or a stack with no VIP owner produces plausible-looking numbers
#     that are wrong, which is worse than no numbers.
# ============================================================================
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO="$PWD"
RESULTS="${REPO}/benchmark/results"
mkdir -p "${RESULTS}"

SCENARIO="${1:-all}"
DURATION="${DURATION:-60}"
CONCURRENCY="${CONCURRENCY:-50}"

# The measured workload request. The real IoT devices accept PUT, so PUT is
# what every scenario here measures; GET exists only as the /health
# infrastructure probe and is never the workload. -path=/ is the device path
# (PUT answers on any path), -body-bytes is the payload size carried by the
# request. METHOD is overridable only so a probe run can be labelled honestly.
METHOD="${METHOD:-PUT}"
PATH_OPT="${PATH_OPT:-/}"
BODY_BYTES="${BODY_BYTES:-256}"
# Lower-cased method for file/label names, so a PUT result can never be
# mistaken on disk for the GET numbers it replaces.
LABEL_METHOD="$(printf '%s' "${METHOD}" | tr '[:upper:]' '[:lower:]')"

# Read the addressing plan from .env rather than hardcoding.
envval() { grep -E "^$1=" .env | head -1 | cut -d= -f2; }
VIP="$(envval VIP_ADDRESS)"
CLIENT_PORT="$(envval CLIENT_PORT)"
SQUID_PORT="$(envval SQUID_PORT)"
IOT_MOCK_PORT="$(envval IOT_MOCK_PORT)"
DNS_PORT="$(envval DNS_PORT)"
DNSDIST_1="$(envval DNSDIST_1_IP)"
PDNS_1="$(envval PDNS_1_IP)"
ZONE="$(envval DNS_ZONE)"
HOST_COUNT="$(envval DNS_RECORD_COUNT)"
ARCH="$(envval ARCH)"

# ---------------------------------------------------------------------------
# CURRENT sizing label — the "CURRENT resized" variant.
#
# CURRENT's connection ceilings are production's own values by default, which
# caps concurrent tunnels at 6,400 — below brief §15's mandatory 10,000. The
# resized variant raises those ceilings so the fair question can be asked: what
# would CURRENT need in order to meet the requirement?
#
# The label is DERIVED FROM THE CONFIG THAT IS ACTUALLY IN .env, not from a
# command-line flag. That is deliberate: a flag can be forgotten or wrong, and a
# resized run mislabelled as production sizing would silently corrupt the
# comparison this whole harness exists to produce. If the numbers in .env say
# production, this says production; if they have been raised, it says resized
# and names the values.
#
# Switch it by editing the four CURRENT_* values in .env and RECREATING the
# CURRENT stack. The architecture is selected by COMPOSE FILE, not by profile:
# CURRENT is compose.current.yaml, TARGET is compose.yaml. Recreate with
#   ./scripts/up.sh current
# or equivalently
#   docker compose -f compose.current.yaml up -d --build --force-recreate \
#       haproxy-1 haproxy-2
# The ceilings are applied when the container renders its config, so a running
# stack keeps the sizing it started with.
# ---------------------------------------------------------------------------
CUR_SRV_MAXCONN="$(envval CURRENT_SERVER_MAXCONN)";   CUR_SRV_MAXCONN="${CUR_SRV_MAXCONN:-3200}"
CUR_FE_MAXCONN="$(envval CURRENT_FRONTEND_MAXCONN)";  CUR_FE_MAXCONN="${CUR_FE_MAXCONN:-6400}"
if [ "${ARCH}" = "current" ]; then
    if [ "${CUR_SRV_MAXCONN}" = "3200" ] && [ "${CUR_FE_MAXCONN}" = "6400" ]; then
        SIZING_SUFFIX=""
        SIZING_NOTE="PRODUCTION sizing — ceiling ${CUR_FE_MAXCONN} concurrent tunnels (2 x server maxconn ${CUR_SRV_MAXCONN})"
    else
        SIZING_SUFFIX="-resized"
        SIZING_NOTE="RESIZED — server maxconn=${CUR_SRV_MAXCONN}, frontend maxconn=${CUR_FE_MAXCONN}. NOT PRODUCTION SIZING; results are labelled '-resized' and must never be reported as CURRENT's production behaviour."
    fi
else
    SIZING_SUFFIX=""
    SIZING_NOTE="n/a (TARGET has no Squid pair and no per-server connection cap)"
fi

NET="$(docker network ls --format '{{.Name}}' | grep dc-lan | head -1)"
PKI_MOUNT="${REPO}/pki"

log() { printf '\n=== %s ===\n' "$*"; }

# ---------------------------------------------------------------------------
# Run the client in its own container on the DC LAN.
# ---------------------------------------------------------------------------
run_client() {
    # SOURCE-PORT EXHAUSTION IS THE DOMINANT LIMIT FOR SHORT-LIVED CONNECTIONS.
    #
    # A connection is identified by (srcIP, srcPort, dstIP, dstPort). With one
    # source address there are only ~28k ephemeral ports, and a closed
    # connection holds its port for the full TIME_WAIT (60 s). Sustained
    # short-lived load therefore caps out at roughly 28000/60 ~ 466 conn/s per
    # source IP, and past that the client fails with
    #   dial tcp ...: connect: cannot assign requested address
    #
    # That is a property of the LOAD GENERATOR, not of either architecture --
    # 10,000 real IoT devices each have their own address and never contend.
    # It is worked around here rather than hidden:
    #   tcp_tw_reuse=1        reuse TIME_WAIT sockets for outgoing connections
    #   ip_local_port_range   widen the pool beyond the default 32768-60999
    # Any result where connect_error is dominated by EADDRNOTAVAIL is the
    # harness running out of ports, and is labelled as such in the report.
    docker run --rm --network "${NET}" \
        --sysctl net.ipv4.tcp_tw_reuse=1 \
        --sysctl net.ipv4.ip_local_port_range="1024 65535" \
        -v "${PKI_MOUNT}:/pki:ro" \
        -v "${RESULTS}:/results" \
        poc-client "$@"
}

# ---------------------------------------------------------------------------
# Snapshot stack metrics so a throughput number can be read alongside the
# resource cost that produced it. A result without its cost is not a result.
# ---------------------------------------------------------------------------
snapshot_metrics() {
    local label="$1"
    local out="${RESULTS}/metrics-${label}.txt"
    {
        echo "# metrics snapshot: ${label}"
        echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo
        echo "## host"
        echo "vCPUs: $(nproc)"
        free -m | sed 's/^/  /'
        echo
        echo "## container resource usage (docker stats --no-stream)"
        docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}' 2>/dev/null \
            | grep -E "poc-|NAME" | sed 's/^/  /'
        echo
        echo "## VIP ownership"
        for n in 1 2; do
            if docker exec "poc-haproxy-${n}" ip -4 addr show eth0 2>/dev/null | grep -q "${VIP}/"; then
                echo "  haproxy-${n}: OWNS VIP (ACTIVE)"
            else
                echo "  haproxy-${n}: standby"
            fi
        done
        echo
        echo "## HAProxy stats (active node)"
        for n in 1 2; do
            if docker exec "poc-haproxy-${n}" ip -4 addr show eth0 2>/dev/null | grep -q "${VIP}/"; then
                docker exec "poc-haproxy-${n}" sh -c \
                  'echo "show stat" | socat stdio /var/run/haproxy/admin.sock 2>/dev/null' \
                  | head -4 | sed 's/^/  /'
            fi
        done
        echo
        echo "## dnsdist backends (TARGET)"
        for d in 1 2; do
            docker logs --tail 200 "poc-dnsdist-${d}" 2>/dev/null \
                | grep -iE "Marking downstream|is up|is down" | tail -4 | sed "s/^/  dnsdist-${d}: /"
        done
    } > "${out}" 2>&1
    echo "  metrics -> ${out#$REPO/}"
}

require_ready() {
    # Announce the sizing BEFORE any number is produced. Every result this run
    # writes carries the same suffix in its label, but a reader looking at a
    # terminal or a partial log needs to see which config produced the numbers
    # without having to infer it from a filename.
    log "architecture and sizing under test"
    echo "  arch   : ${ARCH}"
    echo "  sizing : ${SIZING_NOTE}"
    if [ -n "${SIZING_SUFFIX}" ]; then
        echo ""
        echo "  !! THIS RUN IS NOT PRODUCTION SIZING. Result labels carry '${SIZING_SUFFIX}'."
        echo "  !! Figures from it answer \"what would CURRENT need?\", not \"what does CURRENT do?\"."
    fi

    log "readiness gate"
    if ! ./scripts/wait-ready.sh; then
        echo "REFUSING TO BENCHMARK: stack is not ready." >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# The three scenarios live in benchmark/scenarios/, one file each. They are
# sourced HERE — after every variable and helper they close over is defined
# above — so their bodies resolve the harness context unchanged.
# ---------------------------------------------------------------------------
source "${REPO}/benchmark/scenarios/mtls.sh"
source "${REPO}/benchmark/scenarios/dns.sh"
source "${REPO}/benchmark/scenarios/tunnels.sh"

case "${SCENARIO}" in
    tls)     scenario_tls ;;
    dns)     scenario_dns ;;
    tunnels) scenario_tunnels ;;
    all)     scenario_tls; scenario_dns; scenario_tunnels ;;
    *) echo "usage: $0 {tls|dns|tunnels|all}" >&2; exit 2 ;;
esac

log "done"
