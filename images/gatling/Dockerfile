# ============================================================================
# Gatling load generator for the POC.
#
# WHY IT EXISTS
#   The Go client is bespoke: it speaks CONNECT, holds tunnels open, and does
#   DNS queries, but it is a purpose-built binary that nobody outside this POC
#   can read or extend. Gatling is a standard, widely understood load tool, and
#   its HTML report is a familiar artefact. This image drives the same TARGET
#   and CURRENT HTTP workloads so the numbers can be reproduced with tooling a
#   reviewer already trusts.
#
# WHAT IT CANNOT DO (the Go client is still needed for these)
#   * hold N tunnels OPEN simultaneously -- Gatling is request-oriented, so the
#     10,000-tunnel requirement is measured by benchmark/hold-tunnels.py
#   * issue raw DNS queries -- the DNS comparison is driven by the Go client
#
# DNS: THE CONTAINER RESOLVES DEVICE NAMES TO THE VIP
#   In TARGET the client connects to the VIP and HAProxy routes on the SNI.
#   The POC's PowerDNS resolves iotNNNNNNN.test.domain to the IoT Mock, which
#   is the BACKEND address -- correct for HAProxy, wrong for a client. So this
#   image runs dnsmasq mapping the whole zone to the VIP, giving the load
#   generator the client's view. Without it Gatling would dial the Mock
#   directly and bypass the proxy under test entirely.
#
# Built on Maven so Gatling comes from Maven Central at a pinned version
# rather than from a prebuilt image of uncertain vintage.
# ============================================================================
FROM maven:3.9-eclipse-temurin-17

# dnsmasq  - the client-side DNS view described above
# curl     - the entrypoint's readiness probe
RUN apt-get update \
    && apt-get install -y --no-install-recommends dnsmasq curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/poc

# Dependencies first, so a simulation edit does not re-download Gatling.
COPY pom.xml .
RUN mvn -B -q dependency:go-offline || true

COPY src ./src
# test-compile also builds the simulation; build-classpath pins the full
# runtime classpath into a file so the entrypoint can invoke Gatling without
# starting Maven again.
RUN mvn -B -q test-compile dependency:build-classpath -Dmdep.outputFile=/opt/poc/cp.txt

# gatling.conf MUST sit on the classpath: Gatling loads it through the
# classloader (Typesafe Config), not from a path. Putting it only in /opt/poc
# looked correct and silently did nothing -- the symptom was a run that
# completed with "No trusted certificate found" on every request, because the
# truststore setting was never read. target/test-classes is unambiguously on
# the classpath, and /opt/poc is kept as well.
COPY gatling.conf /opt/poc/gatling.conf
RUN cp /opt/poc/gatling.conf /opt/poc/target/test-classes/gatling.conf

COPY entrypoint.sh /usr/local/bin/gatling-run
RUN chmod +x /usr/local/bin/gatling-run

# Results are written here; the harness bind-mounts benchmark/results over it.
VOLUME ["/results"]

ENTRYPOINT ["/usr/local/bin/gatling-run"]
