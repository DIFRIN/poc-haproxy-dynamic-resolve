#!/bin/sh
# ============================================================================
# Gatling entrypoint: set up the client's DNS view, then run the simulation.
#
# THE DNS VIEW IS NOT OPTIONAL. See the Dockerfile: the POC's PowerDNS
# resolves device names to the IoT Mock, which is the backend address and the
# right answer for HAProxy but the wrong one for a client. Here dnsmasq maps
# the whole zone to the VIP so Gatling dials the proxy under test.
#
# Environment:
#   VIP         (required) floating VIP, e.g. 172.28.0.10
#   DNS_ZONE    zone the device namespace lives in    (default test.domain)
#   MODE        target | current                      (default target)
#   RPS         new virtual users per second          (default 1000)
#   DURATION    seconds                               (default 60)
#   DEVICES     size of the device namespace          (default 1000000)
#   PROXY_PORT  CURRENT's CONNECT port                (default 38888)
#   BODY_BYTES  PUT payload size                      (default 256)
#   LABEL       run label, used for the report folder (default target/current)
#   RESULTS_DIR where Gatling writes                 (default /results)
# ============================================================================
set -eu

: "${VIP:?VIP is required (the floating VIP address)}"
ZONE="${DNS_ZONE:-test.domain}"
MODE="${MODE:-target}"
RPS="${RPS:-1000}"
DURATION="${DURATION:-60}"
DEVICES="${DEVICES:-1000000}"
PROXY_PORT="${PROXY_PORT:-38888}"
BODY_BYTES="${BODY_BYTES:-256}"
LABEL="${LABEL:-$MODE}"
RESULTS_DIR="${RESULTS_DIR:-/results}"
PATH_OPT="${PATH_OPT:-/}"

mkdir -p "${RESULTS_DIR}"

# ---------------------------------------------------------------------------
# 1. Point every device name at the VIP.
# ---------------------------------------------------------------------------
mkdir -p /etc/dnsmasq.d
cat > /etc/dnsmasq.d/poc.conf <<EOF
# The client's view: every name in the zone resolves to the VIP. The proxy
# routes on the SNI; resolving to the IoT Mock would bypass it entirely.
address=/.${ZONE}/${VIP}
listen-address=127.0.0.1
bind-interfaces
no-resolv
server=1.1.1.1
EOF

dnsmasq --conf-dir=/etc/dnsmasq.d --keep-in-foreground &
DNSMASQ_PID=$!
sleep 1

if ! kill -0 "${DNSMASQ_PID}" 2>/dev/null; then
    echo "[gatling] FATAL: dnsmasq failed to start; device names would not resolve" >&2
    exit 1
fi

# /etc/resolv.conf is a Docker bind mount. Writing it is what the JVM actually
# reads, so try that first and fall back to a bind mount if it is read-only.
if ! printf 'nameserver 127.0.0.1\n' > /etc/resolv.conf 2>/dev/null; then
    printf 'nameserver 127.0.0.1\n' > /tmp/resolv.conf
    mount --bind /tmp/resolv.conf /etc/resolv.conf
fi

# ---------------------------------------------------------------------------
# 2. Prove the view before measuring. A run whose names resolve to the wrong
#    address would produce a full, plausible, meaningless report.
# ---------------------------------------------------------------------------
echo "[gatling] mode=${MODE} vip=${VIP} zone=${ZONE} rps=${RPS} duration=${DURATION}s"

RESOLVED="$(getent hosts "iot0000001.${ZONE}" 2>/dev/null | awk '{print $1}' | head -1 || true)"
if [ "${RESOLVED}" != "${VIP}" ]; then
    echo "[gatling] FATAL: iot0000001.${ZONE} resolved to '${RESOLVED}', expected ${VIP}" >&2
    echo "[gatling] the load generator would not be talking to the proxy under test" >&2
    exit 1
fi
echo "[gatling] DNS view OK: iot0000001.${ZONE} -> ${RESOLVED}"

# The proxy must actually be listening before we generate load against it.
if [ "${MODE}" = "current" ]; then
    if ! curl -s -o /dev/null -m 5 "http://${VIP}:${PROXY_PORT}" 2>/dev/null; then
        # A CONNECT proxy answers a plain GET with an error, which is still a
        # connection -- curl returning non-zero here means nothing is there.
        if ! curl -s -o /dev/null -m 5 -x "http://${VIP}:${PROXY_PORT}" "http://${VIP}:${PROXY_PORT}" 2>/dev/null; then
            echo "[gatling] FATAL: no CONNECT proxy answering on ${VIP}:${PROXY_PORT}" >&2
            exit 1
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 2b. Build the truststore, here, with keytool.
#
# NOT from the CA .p12 that gen-certs.sh writes: `openssl pkcs12 -export
# -nokeys` produces a store that Java reads as having ZERO entries, so the CA
# silently is not there. The run then fails every request with
#   ValidatorException: No trusted certificate found
# which reads like a server fault. `keytool -list` on it reports "contains 0
# entries" -- that is how the cause was found, and it is worth checking any
# time this error appears.
#
# Built at runtime into /tmp because pki/ is mounted read-only, and passed as
# a SYSTEM PROPERTY so it overrides gatling.conf. Typesafe Config merges
# system properties last, so this also means a rotated CA needs no image
# rebuild.
# ---------------------------------------------------------------------------
TRUSTSTORE=/tmp/poc-truststore.p12
rm -f "${TRUSTSTORE}"
if keytool -importcert -noprompt -alias poc-root-ca \
       -file /pki/ca/ca.crt \
       -keystore "${TRUSTSTORE}" -storetype PKCS12 -storepass changeit \
       >/dev/null 2>&1; then
    ENTRIES="$(keytool -list -keystore "${TRUSTSTORE}" -storetype PKCS12 \
                -storepass changeit 2>/dev/null | grep -c 'trustedCertEntry')"
    if [ "${ENTRIES}" -ge 1 ]; then
        echo "[gatling] truststore built: ${ENTRIES} CA entr(y|ies)"
    else
        echo "[gatling] FATAL: truststore has no entries; TLS would fail" >&2
        exit 1
    fi
else
    echo "[gatling] FATAL: could not build the truststore from /pki/ca/ca.crt" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 3. Run Gatling.
#    /opt/poc is on the classpath so gatling.conf is picked up from there.
# ---------------------------------------------------------------------------
CP="/opt/poc:/opt/poc/target/test-classes:$(cat /opt/poc/cp.txt)"

# Gatling reaches into java.base internals for session handling and its stats
# writer. The official gatling.sh launcher passes these --add-opens flags; we
# invoke the Gatling main class directly, so they have to be supplied here or
# the JVM refuses with
#   IllegalAccessException: module java.base does not open java.lang to
#   unnamed module
# (Gatling wraps many of its own exceptions, so the symptom is a bare stack
# trace rather than anything pointing at a missing JVM flag.)
JAVA_OPTS="--add-opens=java.base/java.lang=ALL-UNNAMED \
--add-opens=java.base/java.lang.invoke=ALL-UNNAMED \
--add-opens=java.base/java.lang.reflect=ALL-UNNAMED \
--add-opens=java.base/java.io=ALL-UNNAMED \
--add-opens=java.base/java.net=ALL-UNNAMED \
--add-opens=java.base/java.nio=ALL-UNNAMED \
--add-opens=java.base/java.util=ALL-UNNAMED \
--add-opens=java.base/java.util.concurrent=ALL-UNNAMED \
--add-opens=java.base/java.util.concurrent.atomic=ALL-UNNAMED \
--add-opens=java.base/sun.nio.ch=ALL-UNNAMED \
--add-opens=java.base/sun.nio.cs=ALL-UNNAMED \
--add-opens=java.base/sun.security.action=ALL-UNNAMED \
--add-opens=java.base/sun.util.calendar=ALL-UNNAMED"

echo "[gatling] starting simulation ${LABEL}"
set +e
# shellcheck disable=SC2086
java ${JAVA_OPTS} \
    -Dgatling.ssl.useOpenSsl=false \
    -Dgatling.ssl.trustStore.type=PKCS12 \
    -Dgatling.ssl.trustStore.file="${TRUSTSTORE}" \
    -Dgatling.ssl.trustStore.password=changeit \
    -Dpoc.mode="${MODE}" \
    -Dpoc.vip="${VIP}" \
    -Dpoc.zone="${ZONE}" \
    -Dpoc.devices="${DEVICES}" \
    -Dpoc.rps="${RPS}" \
    -Dpoc.duration="${DURATION}" \
    -Dpoc.proxyPort="${PROXY_PORT}" \
    -Dpoc.bodyBytes="${BODY_BYTES}" \
    -Dpoc.path="${PATH_OPT}" \
    -Dpoc.label="${LABEL}" \
    -cp "${CP}" \
    io.gatling.app.Gatling \
    -s poc.PocSimulation \
    -rf "${RESULTS_DIR}" \
    -rd "${LABEL}"
RC=$?
set -e

echo "[gatling] simulation exited rc=${RC}"
echo "[gatling] report -> ${RESULTS_DIR}/$(ls -1t "${RESULTS_DIR}" 2>/dev/null | head -1)/index.html"

kill "${DNSMASQ_PID}" 2>/dev/null || true
exit "${RC}"
