#!/usr/bin/env bash
# ============================================================================
# gen-certs.sh — generate the POC's PKI for end-to-end mTLS.
#
# Produces exactly three things:
#
#   pki/ca/ca.crt                  the root CA the IoT Mock trusts
#   pki/server/server.{crt,key}    the IoT Mock's certificate
#   pki/clients/client-valid.{crt,key}   a client certificate
#
# Generated into pki/, which is GITIGNORED: it contains private keys and is
# reproducible from this script. Do not commit a private key.
#
# SCOPE — NOMINAL ONLY.
#   An earlier revision also generated certs designed to FAIL: an expired
#   client cert, and one signed by a second "rogue" CA. Those existed to prove
#   the negative mTLS paths (that the IoT Mock rejects a bad client cert, and
#   that the alert therefore comes from the Mock's TLS stack rather than from a
#   proxy that had terminated TLS). They were deliberately dropped to keep this
#   script simple, which REMOVES that negative coverage -- the mTLS rejection
#   path is no longer tested. Recorded in docs/final-validation.md.
#
# Uses a container rather than the host's openssl so the result does not depend
# on whatever version the developer happens to have installed.
# ============================================================================
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_ROOT="$PWD"
PKI_DIR="${REPO_ROOT}/pki"

# The IoT Mock's identity. The wildcard covers iotNNNNNNN.test.domain, which is
# what every device name in the 1M namespace looks like.
DNS_ZONE="${DNS_ZONE:-$(grep -E '^DNS_ZONE=' .env 2>/dev/null | cut -d= -f2)}"
DNS_ZONE="${DNS_ZONE:-test.domain}"
IOT_MOCK_IP="${IOT_MOCK_IP:-$(grep -E '^IOT_MOCK_IP=' .env 2>/dev/null | cut -d= -f2)}"
IOT_MOCK_IP="${IOT_MOCK_IP:-172.28.0.60}"

echo "[certs] writing to ${PKI_DIR}"
echo "[certs] zone=${DNS_ZONE}  iot_mock=${IOT_MOCK_IP}"

rm -rf "${PKI_DIR}"
mkdir -p "${PKI_DIR}/ca" "${PKI_DIR}/server" "${PKI_DIR}/clients"

docker run --rm -v "${PKI_DIR}:/work" -e ZONE="${DNS_ZONE}" -e IOTIP="${IOT_MOCK_IP}" \
    alpine:3.20 sh -eu -c '
    apk add --no-cache openssl >/dev/null 2>&1
    cd /work

    # --- root CA -----------------------------------------------------------
    openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
        -keyout ca/ca.key -out ca/ca.crt \
        -subj "/C=FR/O=POC/CN=POC Test Root CA" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1

    # --- server (the IoT Mock) --------------------------------------------
    # SANs cover the wildcard device namespace, the zone apex, and the Mock
    # address itself so the client can verify whichever name it dials.
    openssl req -newkey rsa:2048 -sha256 -nodes \
        -keyout server/server.key -out server/server.csr \
        -subj "/C=FR/O=POC/CN=iot-mock.${ZONE}" >/dev/null 2>&1

    printf "subjectAltName=DNS:*.%s,DNS:%s,DNS:iot-mock.%s,IP:%s\n" \
        "${ZONE}" "${ZONE}" "${ZONE}" "${IOTIP}" > server/san.cnf

    openssl x509 -req -in server/server.csr -CA ca/ca.crt -CAkey ca/ca.key \
        -CAcreateserial -out server/server.crt -days 825 -sha256 \
        -extfile server/san.cnf \
        -extfile <(printf "subjectAltName=DNS:*.%s,DNS:%s,DNS:iot-mock.%s,IP:%s\nbasicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n" \
            "${ZONE}" "${ZONE}" "${ZONE}" "${IOTIP}") >/dev/null 2>&1

    # --- client ------------------------------------------------------------
    openssl req -newkey rsa:2048 -sha256 -nodes \
        -keyout clients/client-valid.key -out clients/client-valid.csr \
        -subj "/C=FR/O=POC/CN=poc-client" >/dev/null 2>&1

    openssl x509 -req -in clients/client-valid.csr -CA ca/ca.crt -CAkey ca/ca.key \
        -CAcreateserial -out clients/client-valid.crt -days 825 -sha256 \
        -extfile <(printf "basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=clientAuth\n") >/dev/null 2>&1

    # --- PKCS#12 for the JVM (Gatling) -------------------------------------
    # Java cannot read PEM. Gatling takes its client certificate from a
    # keystore, so the same client identity is exported in PKCS#12 alongside
    # the PEM files. Both describe the SAME certificate; the PEM pair is used
    # by curl and the Go client, the .p12 by Gatling.
    #
    # The password is a POC constant, not a secret: the keystore holds a test
    # client certificate generated moments ago, and it is gitignored with the
    # rest of pki/.
    openssl pkcs12 -export -name poc-client \
        -inkey clients/client-valid.key -in clients/client-valid.crt \
        -out clients/client-valid.p12 -passout pass:changeit >/dev/null 2>&1

    # Truststore: the CA, so the JVM trusts the server certificate.
    openssl pkcs12 -export -name poc-ca \
        -in ca/ca.crt -nokeys \
        -out ca/ca.p12 -passout pass:changeit >/dev/null 2>&1

    rm -f server/server.csr clients/client-valid.csr server/san.cnf
'

# --- verify what was produced ----------------------------------------------
fail=0
for f in ca/ca.crt ca/ca.p12 server/server.crt server/server.key \
         clients/client-valid.crt clients/client-valid.key clients/client-valid.p12; do
    if [ -s "${PKI_DIR}/${f}" ]; then
        printf '  OK   %-34s %s bytes\n' "${f}" "$(wc -c < "${PKI_DIR}/${f}")"
    else
        printf '  MISSING %s\n' "${f}"; fail=1
    fi
done
[ "${fail}" -eq 0 ] || { echo "[certs] FAILED: a certificate was not produced" >&2; exit 1; }

# The server cert must actually be valid for a device name, or every mTLS
# handshake in the POC fails with a confusing verification error.
if openssl x509 -in "${PKI_DIR}/server/server.crt" -noout -text 2>/dev/null \
     | grep -q "DNS:\*.${DNS_ZONE}"; then
    echo "  OK   server cert SAN covers *.${DNS_ZONE}"
else
    # openssl may be unavailable on the host; re-check inside a container.
    if docker run --rm -v "${PKI_DIR}:/work:ro" alpine:3.20 sh -c \
        'apk add --no-cache openssl >/dev/null 2>&1; openssl x509 -in /work/server/server.crt -noout -text' \
        2>/dev/null | grep -q "DNS:\*.${DNS_ZONE}"; then
        echo "  OK   server cert SAN covers *.${DNS_ZONE}"
    else
        echo "  FAIL server cert SAN does not cover *.${DNS_ZONE}" >&2; exit 1
    fi
fi

# ---------------------------------------------------------------------------
# If the stack is running, its containers are still holding the certificates
# they loaded at startup. Regenerating underneath them leaves a client that
# trusts the NEW CA talking to a server presenting the OLD certificate, which
# fails as `SignatureException: Signature does not match` -- an error that
# points at the server rather than at the stale state. Warn rather than
# restart anything unasked: recreating containers is the operator's call.
# ---------------------------------------------------------------------------
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^poc-iot-mock$'; then
    echo
    echo "[certs] NOTE: poc-iot-mock is RUNNING and is still serving the PREVIOUS"
    echo "[certs]       certificate. TLS will fail with 'Signature does not match'"
    echo "[certs]       until it is recreated:"
    echo "[certs]         docker compose -f compose.yaml up -d --force-recreate iot-mock"
    echo "[certs]       or simply re-run ./scripts/up.sh <arch>"
fi

echo "[certs] done"
