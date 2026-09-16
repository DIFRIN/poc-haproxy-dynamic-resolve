#!/bin/sh
# ============================================================================
# HAProxy node entrypoint: render config, start Keepalived, start HAProxy.
#
# This container represents ONE PRODUCTION HAPROXY NODE: a proxying process and
# a Keepalived instance that owns (or waits to own) the datacenter's single
# floating VIP. See the Dockerfile for why they share a container.
#
# START ORDER MATTERS
#   Keepalived is started first, in the background, and HAProxy immediately
#   after. Keepalived must be running before the VIP can land on this node; but
#   HAProxy must NOT wait for VIP ownership, because on the standby node the VIP
#   never arrives until a failover happens. HAProxy therefore always binds
#   its client-facing port on the node address and simply sees no VIP traffic
#   until it wins the election -- which is exactly the production arrangement.
#
#   CURRENT binds CLIENT_PORT (production: 38888) and relays to Squid on
#   SQUID_PORT (production: 4443). Those are DIFFERENT ports in production, and
#   modelling them as one number was a fidelity defect; see
#   docs/adr/0028-production-config-fidelity.md.
#
# The fully rendered configs are printed to stdout at startup. `docker logs`
# therefore contains the exact bytes that were executed, which is what makes
# the benchmark results auditable after the fact.
# ============================================================================
set -eu

: "${NODE_NAME:?NODE_NAME is required (haproxy-1|haproxy-2)}"
: "${NODE_IP:?NODE_IP is required}"
: "${PEER_IP:?PEER_IP is required}"
: "${VIP_ADDRESS:?VIP_ADDRESS is required}"
: "${ARCH:?ARCH is required (current|target)}"
: "${CLIENT_PORT:?CLIENT_PORT is required (CURRENT client-facing CONNECT port)}"
: "${SQUID_PORT:?SQUID_PORT is required (Squid listener / HAProxy->Squid port)}"
: "${VRRP_ROUTER_ID:?VRRP_ROUTER_ID is required}"
: "${VRRP_PRIORITY:?VRRP_PRIORITY is required}"
: "${VRRP_STATE:?VRRP_STATE is required}"

CONF_TMPL="/etc/haproxy/${ARCH}/haproxy.cfg.tmpl"
KA_TMPL="/etc/keepalived/keepalived.conf.tmpl"

# Rendered output goes to /run, NOT next to the templates.
# /etc/haproxy and /etc/keepalived are bind-mounted READ-ONLY from the repo so
# that what runs is always traceable to a file under version control, and so a
# container can never mutate the repository's configs. The renderer therefore
# writes to a writable tmpfs. The templates remain the single source of truth;
# the rendered files are derived artifacts, printed to stdout at startup.
CONF_OUT="/run/haproxy/haproxy.cfg"
KA_OUT="/run/keepalived/keepalived.conf"
mkdir -p /run/haproxy /run/keepalived

# --- stage the executable VRRP scripts -------------------------------------
# Keepalived refuses to run scripts that are writable by group or other, and
# everything under the repository is mode 777 because WSL2 exposes /mnt/c over
# 9p with fixed permissions. Without this copy, Keepalived logs
# "SECURITY VIOLATION ... There are insecure scripts" and silently DISABLES the
# health check -- so the VIP would never move on a dnsdist failure, and every
# failover test would "pass" for the wrong reason. Staging them root-owned and
# 0700 satisfies Keepalived's check while keeping the real sources in git.
install -m 0700 -o root -g root "/opt/keepalived-checks/${ARCH}.sh" /run/keepalived/check.sh
install -m 0700 -o root -g root /etc/keepalived/notify.sh /run/keepalived/notify.sh

echo "[node] health check staged: /run/keepalived/check.sh (from keepalived/checks/${ARCH}.sh)"

# Substituted variables. An explicit list is used rather than a bare `envsubst`
# so that any `$` that legitimately belongs to HAProxy or Keepalived syntax is
# never eaten by the renderer.
# CURRENT sizing. Defaults are PRODUCTION's own values, so a container started
# without these set still measures the architecture that actually runs. The
# benchmark's "CURRENT resized" variant overrides them deliberately.
# See docs/adr/0028-production-config-fidelity.md.
: "${CURRENT_GLOBAL_MAXCONN:=10000}"
: "${CURRENT_FRONTEND_MAXCONN:=6400}"
: "${CURRENT_FULLCONN:=6400}"
: "${CURRENT_SERVER_MAXCONN:=3200}"

# Production's `stats auth` uses an EMPTY username. HAProxy accepts that, but
# an empty user is a config smell, so the POC uses a named one and documents
# the divergence rather than reproducing it. See ADR 28.
: "${STATS_USER:=admin}"
: "${STATS_PASSWORD:=poc-stats}"

SUBST_VARS='${NODE_NAME} ${NODE_IP} ${PEER_IP} ${VIP_ADDRESS} ${ARCH}
${CLIENT_PORT} ${SQUID_PORT} ${STATS_PORT} ${DNS_PORT} ${IOT_MOCK_IP} ${IOT_MOCK_PORT}
${SQUID_1_IP} ${SQUID_2_IP} ${LOCAL_DNSDIST_IP}
${CURRENT_GLOBAL_MAXCONN} ${CURRENT_FRONTEND_MAXCONN} ${CURRENT_FULLCONN} ${CURRENT_SERVER_MAXCONN}
${STATS_USER} ${STATS_PASSWORD}
${VRRP_ROUTER_ID} ${VRRP_PRIORITY} ${VRRP_STATE} ${VRRP_ADVERT_INT} ${VIP_PREFIX}'

render() {
    src="$1"; dst="$2"
    [ -f "$src" ] || { echo "[node] FATAL: template not found: $src" >&2; exit 1; }
    # shellcheck disable=SC2086
    envsubst "$SUBST_VARS" < "$src" > "$dst"
}

echo "=============================================================="
echo "[node] ${NODE_NAME}  arch=${ARCH}  ip=${NODE_IP}  vip=${VIP_ADDRESS}"
echo "[node] vrrp: state=${VRRP_STATE} priority=${VRRP_PRIORITY} router_id=${VRRP_ROUTER_ID}"
echo "=============================================================="

render "$KA_TMPL" "$KA_OUT"
render "$CONF_TMPL" "$CONF_OUT"

echo "[node] ---------- rendered keepalived.conf ----------"
cat "$KA_OUT"
echo "[node] ---------- rendered haproxy.cfg (${ARCH}) ----------"
cat "$CONF_OUT"
echo "[node] ---------- end rendered config ----------"

# ---------------------------------------------------------------------------
# Keepalived
#   -n  don't fork, so its lifetime is tied to this container and its logs go
#       to stdout where `docker logs` can see VRRP state transitions. VRRP
#       transition timestamps in those logs are the primary evidence for the
#       failover-timing measurements.
#   -l  log to console
#   -p  pidfile, used below for the shutdown trap
# ---------------------------------------------------------------------------
echo "[node] starting keepalived"
keepalived -n -l -f "$KA_OUT" -p /run/keepalived.pid &
KA_PID=$!

# Give Keepalived a moment to bind VRRP and settle its initial state before
# HAProxy starts. Without this, on a cold start the first VRRP advertisement
# can race the interface scan and Keepalived logs a spurious FAULT state.
sleep 2

if ! kill -0 "$KA_PID" 2>/dev/null; then
    echo "[node] FATAL: keepalived exited during startup" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Graceful shutdown: stop Keepalived first so the VIP is withdrawn deliberately
# (with a priority-0 advertisement) rather than by the interface disappearing.
# An abrupt exit makes the peer wait out the full master-down interval, which
# would make measured failover times pessimistic and unrepeatable.
# ---------------------------------------------------------------------------
shutdown() {
    echo "[node] SIGTERM received, stopping keepalived"
    kill -TERM "$KA_PID" 2>/dev/null || true
    wait "$KA_PID" 2>/dev/null || true
    echo "[node] shutdown complete"
}
trap shutdown TERM INT

echo "[node] starting haproxy (arch=${ARCH}, client_port=${CLIENT_PORT}, squid_port=${SQUID_PORT})"
# exec-free so the trap above still runs; HAProxy runs in the foreground and
# receives SIGTERM from tini, which is PID 1.
haproxy -W -db -f "$CONF_OUT" &
HAPROXY_PID=$!

# Exit when EITHER process dies -- a node with a dead HAProxy or a dead
# Keepalived is not a functioning node, and silently continuing would hide that
# from the test harness, which would then record a "successful" run against a
# half-dead node.
#
# A polling loop is used rather than `wait -n`: this is busybox ash, where
# `wait -n` is not reliably available, and the Dockerfile deliberately does not
# pull in bash just for one builtin.
while kill -0 "$KA_PID" 2>/dev/null && kill -0 "$HAPROXY_PID" 2>/dev/null; do
    sleep 1
done

if ! kill -0 "$HAPROXY_PID" 2>/dev/null; then
    echo "[node] haproxy exited; shutting down" >&2
else
    echo "[node] keepalived exited; shutting down" >&2
fi
shutdown
exit 1
