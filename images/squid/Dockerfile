# ============================================================================
# Squid image for the CURRENT architecture.
#
# Built from alpine rather than a third-party Squid image so the Squid version
# is pinned by the Alpine tag and the build is reproducible from this repo
# alone. The exact version under test is recorded at container start and quoted
# in the benchmark report -- Squid's DNS-server selection behaviour is
# version-dependent, and docs/adr/0010-current-squid-dns-behaviour.md documents
# what THIS version was measured doing.
# ============================================================================
FROM alpine:3.20

# squid       - the proxy itself
# bind-tools  - dig, for the DNS-behaviour probes in tests/dns/
# curl        - operational checks
RUN apk add --no-cache squid bind-tools curl && rm -rf /var/cache/apk/*

# Squid writes its cache log to /dev/stdout so `docker logs` captures startup
# errors. Access logging is disabled in squid.conf: at 6,000 rps it would
# dominate the run and distort every CPU measurement.
RUN mkdir -p /var/log/squid /var/cache/squid /run/squid \
    && chown -R squid:squid /var/log/squid /var/cache/squid /run/squid

# -N  run in the foreground (no daemonisation) so the container's lifetime is
#     the process's lifetime and SIGTERM reaches Squid directly.
# Squid's listener, and the port HAProxy's proxyhttp backend connects to.
# PRODUCTION VALUE: 4443 (role_squid_proxy_port; HAProxy targets
# iode-squid-N-svc...:4443). This is NOT the client-facing port -- clients never
# reach Squid directly. See docs/adr/0028-production-config-fidelity.md.
EXPOSE 4443
ENTRYPOINT ["/usr/sbin/squid", "-N", "-f", "/etc/squid/squid.conf"]
