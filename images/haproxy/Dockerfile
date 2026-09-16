# ============================================================================
# The HAProxy node image: HAProxy + Keepalived in ONE container.
#
# WHY THEY SHARE A CONTAINER
#   Keepalived owns the floating VIP by adding it to a network interface. That
#   interface lives in a network namespace. If Keepalived ran in its own
#   container it would add the VIP to *its own* netns, and the HAProxy next to
#   it would never see the traffic, because nothing would route the VIP into
#   HAProxy's netns.
#
#   On a real host this is a non-issue: both processes run on the same node and
#   the same kernel networking stack, so "keepalived adds the VIP" and "haproxy
#   receives traffic on the VIP" are the same namespace by definition. Running
#   them in one container reproduces that relationship exactly. It is not a
#   simplification -- it is the faithful mapping of "one HAProxy node" onto
#   containerised infrastructure.
#
#   Consequently this container IS the production "HAProxy node": 2 per
#   datacenter, 2 Keepalived instances per datacenter. See
#   docs/adr/0003-two-haproxy-nodes.md and docs/adr/0005-keepalived-vrrp.md.
#
# BASE IMAGE
#   The official haproxy image is used rather than `apk add haproxy` so the
#   HAProxy version is pinned by the image tag instead of by whatever the Alpine
#   repository happens to carry. The image is Alpine-based, so apk still works
#   for the extra packages.
# ============================================================================
FROM haproxy:3.0-alpine

# The official image sets `USER haproxy` (uid 99). Build steps and Keepalived
# both need root, so switch back explicitly and stay there -- see "PRIVILEGES"
# below for why running this node as root is correct rather than sloppy.
USER root

# keepalived        - VRRP / floating VIP ownership
# iproute2          - `ip addr` for VIP inspection and the health-check scripts
# bind-tools        - `dig`, used by the TARGET health check to probe the LOCAL
#                     dnsdist. See haproxy/entrypoint.sh for why a real DNS query
#                     is the right health signal rather than a TCP connect.
# curl              - used by operational scripts and the health checks
# gettext           - `envsubst`, used to render the per-node config template
# tini              - correct PID 1 signal handling; without it SIGTERM is not
#                     reliably forwarded and container stop times are wrong,
#                     which would corrupt failover timing measurements.
RUN apk add --no-cache \
        keepalived \
        iproute2 \
        bind-tools \
        curl \
        gettext \
        tini \
    && rm -rf /var/cache/apk/*

# ---------------------------------------------------------------------------
# PRIVILEGES
#
# This container runs as root, and that is deliberate rather than incidental:
#
#   * Keepalived must add and remove the floating VIP on a real interface and
#     send/receive VRRP advertisements. On a production node that is done by a
#     root daemon, and there is no meaningful way to reproduce VIP ownership
#     without the same authority. It also needs to write /run/keepalived.pid
#     and execute the vrrp_script health checks.
#
#   * HAProxy itself does NOT run privileged. The `global` section of both
#     haproxy configs sets `user haproxy` / `group haproxy`, so HAProxy binds
#     its sockets as root and then drops to uid 99. That is the same
#     privilege-drop a production HAProxy performs.
#
# So the effective privilege split mirrors production: a privileged VRRP daemon
# and an unprivileged proxy. docker-compose additionally narrows this with an
# explicit capability list (NET_ADMIN, NET_RAW, NET_BROADCAST) instead of
# `privileged: true`, so the container cannot do anything VRRP does not need.
# See docs/adr/0005-keepalived-vrrp.md.
# ---------------------------------------------------------------------------

# Directories that must exist before the entrypoint renders configs into them.
# /var/run/haproxy is the admin-socket directory; /run is for the keepalived pid.
RUN mkdir -p /etc/haproxy/current /etc/haproxy/target /etc/keepalived \
             /var/run/haproxy /run

COPY entrypoint.sh /usr/local/bin/node-entrypoint.sh
RUN chmod +x /usr/local/bin/node-entrypoint.sh

# 38888 client-facing HTTP CONNECT in CURRENT (production's frontend_proxyhttp
#       port; see docs/adr/0028-production-config-fidelity.md)
# 443   client-facing TLS in TARGET, and the IoT Mock's mTLS port
# 15080 PRODUCTION's admin stats listener (loopback-bound, modelled for fidelity)
# 8404  POC admin: stats + Prometheus metrics (bound to the NODE address, never
#       the VIP). Not a production port -- see the metrics note in
#       haproxy/current/haproxy.cfg.tmpl.
# 9000  HAProxy admin socket (unix socket in /var/run/haproxy, not TCP)
EXPOSE 38888 443 15080 8404

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/node-entrypoint.sh"]
