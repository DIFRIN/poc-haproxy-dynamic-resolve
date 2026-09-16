#!/usr/bin/env bash
# ============================================================================
# status.sh — one-screen view of the stack, including VIP ownership.
#
# VIP ownership is printed explicitly because it is the single most important
# piece of state in this POC: exactly one node must own it, and "which node"
# determines which HAProxy is receiving client traffic.
# ============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

VIP="$(grep '^VIP_ADDRESS=' .env 2>/dev/null | cut -d= -f2 || echo 172.28.0.10)"
VIP="${VIP:-172.28.0.10}"

echo "=== containers ==="
docker compose ps --format 'table {{.Name}}\t{{.Service}}\t{{.Status}}' 2>/dev/null

echo
echo "=== VIP ownership (must be exactly ONE node) ==="
owner=""
for n in 1 2; do
    if docker exec "poc-haproxy-${n}" ip -4 addr show eth0 2>/dev/null | grep -q "${VIP}/"; then
        echo "  haproxy-${n}: OWNS ${VIP}   <-- ACTIVE"
        owner="haproxy-${n}"
    else
        echo "  haproxy-${n}: no VIP        (standby)"
    fi
done
[ -z "${owner}" ] && echo "  !! NO NODE OWNS THE VIP -- the datacenter has no ingress"
[ "$(echo "${owner}" | wc -w)" -gt 1 ] && echo "  !! BOTH NODES CLAIM THE VIP -- split brain"

echo
echo "=== active node's proxy stack ==="
for n in 1 2; do
    if docker exec "poc-haproxy-${n}" ip -4 addr show eth0 2>/dev/null | grep -q "${VIP}/"; then
        echo "  node haproxy-${n} health check:"
        docker exec \
            -e "DNS_PORT=$(grep '^DNS_PORT=' .env | cut -d= -f2)" \
            -e "DNS_ZONE=$(grep '^DNS_ZONE=' .env | cut -d= -f2)" \
            -e "LOCAL_DNSDIST_IP=$( [ "${n}" = "1" ] && grep '^DNSDIST_1_IP=' .env | cut -d= -f2 || grep '^DNSDIST_2_IP=' .env | cut -d= -f2 )" \
            "poc-haproxy-${n}" /opt/keepalived-checks/"$(grep '^ARCH=' .env | cut -d= -f2)".sh 2>&1 | sed 's/^/    /' \
            && echo "    OK (exit 0)" || echo "    UNHEALTHY (exit non-zero)"
    fi
done
