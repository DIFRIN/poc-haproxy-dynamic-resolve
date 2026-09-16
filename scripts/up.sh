#!/usr/bin/env bash
# ============================================================================
# up.sh {current|target} [extra docker compose args]
#
# Brings up ONE architecture. The two are selected by COMPOSE FILE, not by
# profile:
#
#   target   compose.yaml          HAProxy + dnsdist  (the recommended stack)
#   current  compose.current.yaml  HAProxy + Squid    (the comparison)
#
# Only one runs at a time: they share the VIP and the HAProxy node addresses,
# so running both would put two nodes in a fight over one VIP and produce a
# meaningless benchmark.
#
# Because the architecture is chosen by which file you pass, `docker compose
# up -d` with no arguments always brings up TARGET -- see compose.yaml. This
# script exists to add the readiness gate and the status report on top.
# ============================================================================
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

ARCH_TARGET="${1:-}"
case "${ARCH_TARGET}" in
    current|target) ;;
    *) echo "usage: $0 {current|target}" >&2; exit 2 ;;
esac
shift

[ -f .env ] || { echo "[up] .env not found; copying from .env.example"; cp .env.example .env; }

COMPOSE_FILE="compose.yaml"
[ "${ARCH_TARGET}" = "current" ] && COMPOSE_FILE="compose.current.yaml"

# The compose files hardcode ARCH, so they are the source of truth for what
# gets rendered. This records the same value in .env so scripts/status.sh and
# scripts/wait-ready.sh agree with the stack that is actually running.
if grep -q '^ARCH=' .env; then
    sed -i "s|^ARCH=.*|ARCH=${ARCH_TARGET}|" .env
else
    printf '\n# --- architecture selector (managed by scripts/up.sh) ---\nARCH=%s\n' "${ARCH_TARGET}" >> .env
fi

# The stack cannot start without a PKI: the IoT Mock needs a server cert and
# every client needs a cert and the CA. Generate it on first use rather than
# failing with a confusing TLS error later.
if [ ! -f pki/ca/ca.crt ]; then
    echo "[up] no PKI found; generating with scripts/gen-certs.sh"
    ./scripts/gen-certs.sh
fi

echo "[up] architecture : ${ARCH_TARGET}"
echo "[up] compose file : ${COMPOSE_FILE}"
echo "[up] haproxy conf : configs/haproxy/${ARCH_TARGET}/haproxy.cfg.tmpl"
echo "[up] health check : configs/keepalived/checks/${ARCH_TARGET}.sh"
echo

# Tear down the OTHER architecture's services so a switch does not leave the
# previous stack holding its static addresses.
docker compose -f compose.yaml -f compose.current.yaml -f compose.bench.yaml \
    down --remove-orphans >/dev/null 2>&1 || true

docker compose -f "${COMPOSE_FILE}" up -d --build "$@"

echo
echo "[up] waiting for the stack to become healthy..."
"$(dirname "${BASH_SOURCE[0]}")/wait-ready.sh" || true
echo
"$(dirname "${BASH_SOURCE[0]}")/status.sh"
