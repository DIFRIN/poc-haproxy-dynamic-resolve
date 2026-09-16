# Architecture

Component-by-component design of the POC, and the reasoning behind the parts that are not
obvious. Read alongside the ADRs, which record the decisions and their evidence.

---

## 1. The POC boundary

Production has **2 datacenters**. Each contains 2 HAProxy, 2 Keepalived, 1 floating VIP,
2 Squid, and its own DNS infrastructure — so production totals 4 HAProxy, 4 Keepalived,
2 VIPs and 4 Squid.

The POC reproduces **exactly one complete datacenter**, and does not simulate the second.
Cross-datacenter routing, failover, global load balancing and cross-DC DNS are out of
scope. The second datacenter's DNS servers are deliberately absent.

```
Production                          POC (DC1 only)
----------                          ---------------
DC1                DC2              2 HAProxy   (active/passive)
 2 HAProxy          2 HAProxy       2 Keepalived
 2 Keepalived       2 Keepalived    1 VIP
 1 VIP              1 VIP           2 Squid      (CURRENT)
 2 Squid            2 Squid         2 dnsdist    (TARGET)
 DNS infra          DNS infra       2 PowerDNS
                                    1 PostgreSQL
                                    1 IoT Mock
```

---

## 2. HA model — active/passive, one VIP

This applies identically to CURRENT and TARGET.

```
        Floating VIP 172.28.0.10
                 |
        +--------+--------+
        |                 |
   haproxy-1         haproxy-2
    ACTIVE            STANDBY
   (owns VIP)      (no VIP, no client traffic)
```

- Exactly **one** VIP per datacenter, owned by Keepalived/VRRP.
- **Only the VIP owner receives client traffic.** The standby has the proxy port open on
  its own address but sees nothing, because it does not own the VIP.
- The nodes are **never** active/active. There is no configuration in this repository
  under which both process production traffic simultaneously.

HAProxy and Keepalived run **in the same container**. This is not a simplification: a
floating VIP belongs to a network namespace, and Keepalived in a separate container would
add the VIP to its own namespace where the proxy could not see it. On a real node both
processes share one kernel networking stack; one container per node reproduces that
relationship exactly.

The entrypoint prints the fully rendered `haproxy.cfg` and `keepalived.conf` to stdout at
startup, so `docker logs` contains the exact bytes that ran. Rendered files go to `/run/`,
never back into the read-only repository mounts.

---

## 3. The workload

The IoT devices accept **`PUT` only**. The path is:

```
CURRENT:  client -> HAProxy -> Squid -> IoT device
TARGET:   client -> HAProxy -> IoT device
```

`GET /health` exists solely as an infrastructure probe and is never the measured workload.

---

## 4. CURRENT — HAProxy + common Squid layer

```
IoT Client  --CONNECT iotNNNNNNN.test.domain:443-->  VIP:38888
                                                        |
                                              HAProxy (mode tcp)
                                              balance roundrobin
                                                   /        \
                                            squid-1:4443    squid-2:4443
                                                   \        /
                                            resolve + tunnel
                                                        |
                                              IoT Mock :443 (mTLS)
                                              PUT from the client
```

**Two ports, and they are different numbers.** The client CONNECTs to the VIP on **38888**;
HAProxy relays to Squid on **4443**. Clients never reach Squid directly. This matters
because an earlier revision of the POC used one `PROXY_PORT=3128` for *both* hops — matching
neither production value, and making the production topology inexpressible. See
[ADR 28](adr/0028-production-config-fidelity.md).

**Squid's role is solely to terminate `CONNECT` and create the TCP tunnel.** It is not a
caching proxy, not a policy engine, and not application-aware — the `PUT` that follows is
opaque bytes to it. This is why the SQUID layer can be modelled as a dumb tunnel
terminator, and it is why `cache deny all` is set: caching is not part of the role.

**The consequence that matters for the TARGET decision.** Because Squid's only job is
tunnelling, the corrected TARGET does not remove a *capability* from the request path — it
reassigns tunnel termination to HAProxy (via SNI passthrough) and removes an entire
**process**. The architecture keeps the same function with one fewer component in the path.

It also raised a question this POC could not answer from its own configuration: **if Squid
only tunnels, nothing in CURRENT validates the `CONNECT` destination.** That question has
now been answered against the real production Squid configuration, and the answer is worse
than the POC assumed.

**Production Squid performs no destination validation at all.** Its access-control block is
two source- and method-unrestricted port allows followed by a `deny` that can never be
reached:

```
acl env_network  src 0.0.0.0/32        # matches nothing that can exist
http_access allow env_network CONNECT  # therefore dead
http_access allow SSL_ports            # any source, any method -> 443/445/8443
http_access allow Safe_ports           # any source, any method -> incl. 1025-65535
http_access deny to_localhost          # unreachable: both allows precede it
```

Measured from Squid's own access log, with the client outside `env_network`: CONNECT to
`127.0.0.1:443`, to Squid's own address, to `169.254.169.254:443` (cloud instance metadata)
and to RFC1918 addresses are **all allowed** (`TCP_TUNNEL`); the only denial anywhere is
port-based (port 22 is absent from `Safe_ports`). CURRENT is an **open forward proxy**.

An earlier revision of this POC gave Squid a resolved-address policy of its own invention
(see the former ADR 22), benchmarked it, and reported CURRENT as refusing 26/26 SSRF
attempts with `HTTP 403`. **That policy is not in production.** It gave CURRENT a control it
does not have and then compared that against TARGET's real one — biasing the comparison
*against* TARGET. It is now retained only as an explicitly-labelled counterfactual
(`configs/squid/squid-*/squid.conf.hardened`), and `tests/fidelity/run.sh` measures both models side
by side.

The corrected conclusion is stronger than the original speculation: **TARGET's destination
policy is net-new security capability, not a re-implementation.** In CURRENT there is no
policy to migrate — there is a hole to close. See
[ADR 28](adr/0028-production-config-fidelity.md).

**HAProxy is a TCP load balancer here.** It parses nothing — it does not read the CONNECT
line and performs no DNS resolution. All destination DNS is Squid's job, which is exactly
what the DNS comparison measures.

**The Squid layer is common, not paired.** There is no HAProxy-1 → Squid-1 affinity. When
the VIP moves, the new active HAProxy uses the same two Squids.

**DNS preference is deliberately reversed** between the two instances to spread load:

| Instance | Order |
|---|---|
| squid-1 | PDNS 1, then PDNS 2 |
| squid-2 | PDNS 2, then PDNS 1 |

What Squid *actually does* with that list is a measured result, not an assumption — see
ADR 0010 and the DNS section of the benchmark report.

**But the reversal has no production counterpart**, and the real list is longer than the
POC's. Production configures the *same* `dns_nameservers` on both instances, and its second
entry is **the remote datacenter's nameservers**, not a second local server:

```
dns_nameservers {{ role_squid_dns_current_site_joined }} {{ role_squid_dns_remote_site_joined }}
```

So production Squid holds a **cross-datacenter DNS fallback**: if this site's DNS is
entirely gone, it keeps resolving via the other site. The reversal above is a brief §8 POC
experiment, and the measured distribution is a property of a POC-only configuration. The
fallback's absence from TARGET is an accepted regression —
[ADR 29](adr/0029-target-dns-fallback-regression.md).

**The structural weakness.** Squid sits below a highly-available frontend but is itself a
shared fate domain. Losing both Squids takes the datacenter down no matter what Keepalived
does, and moving the VIP cannot help. The CURRENT health check therefore checks **only the
local HAProxy process** and deliberately excludes Squid: making a shared component part of
a per-node health check would bounce the VIP between two nodes that are equally unable to
serve, adding an outage window on top of an outage. TARGET removes this layer entirely.

**And it has a hard concurrency ceiling, below the stated requirement.** Production sizes
each Squid at `maxconn 3200` and the frontend at `maxconn 6400`, so the architecture caps
the datacenter at **6,400 concurrent tunnels** — the two limits coincide exactly. Brief §15
makes **10,000 simultaneous CONNECT tunnels mandatory**, so that requirement is
**unreachable in CURRENT as production is configured today**; it is not a load-generator
artefact, it is configuration. The POC previously ran its CURRENT arm at `maxconn 200000`
with no per-server cap, which is why its "10,000 tunnels established" result appeared to
satisfy the requirement. CURRENT now models production's real ceilings by default, with a
separate "CURRENT resized" variant for the like-for-like comparison. See
[ADR 28](adr/0028-production-config-fidelity.md).

---

## 5. TARGET — SNI passthrough, Squid removed

```
IoT Client  --TLS, SNI=iotNNNNNNN.test.domain-->  VIP:443
                                                     |
                                           HAProxy (mode tcp)
                                    tcp-request inspect-delay 5s
                                    req.ssl_sni  -> txn.sni
                                    do-resolve(txn.dstip, local_dns, ipv4)
                                    <destination policy on txn.dstip>
                                    set-dst / set-dst-port
                                                     |
                                           raw TLS tunnel (never decrypted)
                                                     |
                                           IoT Mock :443 (mTLS end-to-end)
                                                     ^
                                    dnsdist-1 / dnsdist-2
                                                     |
                                            PDNS 1 / PDNS 2
                                                     |
                                              PostgreSQL
```

HAProxy reads the **SNI from the ClientHello without terminating TLS**, resolves it,
validates the resolved address, sets the destination, and tunnels. It never holds a key
and never sees plaintext. mTLS is end-to-end between the client and the IoT Mock.

### The narrow DNS path

Each HAProxy node has exactly **one** nameserver configured: its own local dnsdist. There
is no second entry and **no fallback to PowerDNS**. If the local dnsdist is unavailable,
resolution fails and the request fails. A PowerDNS fallback would silently bypass the DNS
abstraction layer that TARGET exists to introduce. That reasoning is correct as far as it
goes, and it is required by the brief (§9, rules 14–15).

**What it costs, stated plainly.** This path is *narrower* than production CURRENT's, not
merely a re-implementation of it. Production Squid also carries the remote datacenter's
nameservers, so a total loss of this site's DNS degrades CURRENT rather than stopping it.
TARGET has nowhere to fall through to: dnsdist absorbs a PowerDNS failure exactly as
required (the VIP correctly does not move), but with both PowerDNS servers down the
datacenter's name resolution is simply gone. That is a real availability regression, and it
is recorded as an accepted one in [ADR 29](adr/0029-target-dns-fallback-regression.md),
which also documents a remedy that preserves rule 14 exactly — giving **dnsdist** the
remote site's nameservers as backends, ordered after the local PowerDNS pair, leaving
HAProxy's single-resolver path untouched.

It also means the POC's "all PowerDNS down → `SERVFAIL`" failover scenario is a **POC-only
construction** and does not reproduce a production CURRENT failure mode: killing this site's
DNS pair would not stop production Squid resolving.

### Destination policy

Validating the name would be worthless — the name is attacker-chosen and the address is
what the packet reaches. Every rule in the policy therefore operates on `txn.dstip`, the
**resolved** address.

Two implementation notes that cost real debugging time and are recorded so they are not
rediscovered:

- HAProxy's `ipmask()` converter takes a **dotted-quad mask** (`ipmask(255.0.0.0)`), not a
  CIDR network. Passing `10.0.0.0/8` fails at config-parse time. The `-m ip` ACL matcher
  is the correct construct and accepts CIDR directly.
- `set-dst-port` takes an **expression**, not a literal — `set-dst-port 443` is parsed as
  a fetch method and fails. It must be `set-dst-port int(443)`.

### Fail-closed by construction

Resolution failure does not fall through to a permissive path. An explicit reject fires as
soon as the resolver has definitively returned nothing, and the backend's only server is
the unroutable placeholder `0.0.0.0:0`. A name that does not resolve is refused, promptly.
(Measured before the explicit reject was added: an NXDOMAIN cost the client's full 15 s
timeout. After: 2 s, and a policy rejection returns in 0 s.)

---

## 6. DNS layer (TARGET)

Both dnsdist instances are configured **identically**. That is correct rather than lazy:
dnsdist is not a paired active/standby application. Each HAProxy uses its own local
dnsdist, and both dnsdist instances know both PowerDNS servers. There is no
dnsdist-to-dnsdist relationship, so there is nothing to differentiate.

- **Explicit round-robin** (`setServerPolicy(roundrobin)`) — required, and deliberately
  not latency-based, so the distribution is reproducible rather than machine-noise
  dependent.
- **Health checks probe `test.domain SOA`.** dnsdist's default probe asks for
  `a.root-servers.net.`, which our authoritative servers would answer with `REFUSED` —
  scoring every backend as failed. Probing our own apex asks the question that matters:
  can this PowerDNS answer for *our* zone?
- **Failed backends are removed and reintroduced** automatically (2 consecutive failures
  to eject, 2 successes to restore, 1 s probe interval).
- Statistics are exposed on the dnsdist web API and are the source for DNS QPS,
  per-backend QPS, distribution, health and latency.

---

## 7. PowerDNS and PostgreSQL

Two authoritative servers, **identical configuration, one shared database**. Identical
answers are therefore true by construction — there is no replication step that could lag
or diverge, which is what makes "confirm both PowerDNS return identical data" a meaningful
check rather than a race.

PostgreSQL holds **1,000,000 A records** (`iot0000001` … `iot1000000`), all resolving to
the IoT Mock, plus the SSRF corpus. The dataset is generated **in-database** with
`generate_series` rather than loaded from a file: at 1M rows the file would be ~100 MB and
would have to cross the 9p boundary from `/mnt/c` into the container. Measured seed time:
**27 s**.

**Storage is a named volume, never a bind mount.** The repository lives on `/mnt/c`, which
WSL2 exposes over 9p — a filesystem with very different latency and locking semantics from
a local disk. A PostgreSQL data directory behind 9p would make storage the bottleneck and
every benchmark number meaningless.

Query cache and packet cache are both **disabled** (`query-cache-ttl=0`, `cache-ttl=0`) so
the POC measures the real PostgreSQL-backed path, not a warm in-process cache.

---

## 8. End-to-end mTLS

```
IoT Client
    |
    |  TLS, client certificate presented
    |
HAProxy  --- tunnel only --->  IoT Mock
    |
    +--- TLS/mTLS is between client and server; the proxy is not a party to it
```

Neither architecture terminates application TLS. There is **no** `ssl`/`ssl_crt`/`ssl_key`
directive on any frontend or backend in this repository, no `termination` in dnsdist, and
no MITM, decrypt, inspect or re-encrypt step anywhere.

This is directly testable and is tested: with a client certificate missing, the alert
reported to the client is `tlsv13 alert certificate required` **from the IoT Mock's TLS
stack**. A proxy that had terminated TLS would have produced that alert itself, and the
connection to the backend would have been a *new*, separate TLS session.

The PKI (`scripts/gen-certs.sh`) provides a root CA, a second **rogue** CA for forged
certificates, a server certificate with `SAN *.test.domain`, and client certificates that
are valid, genuinely **expired** (a real 2020–2021 validity window, issued through an
`openssl ca` database so the dates are truthful rather than simulated), and signed by the
rogue CA.

---

## 9. Metrics

| Component | Source |
|---|---|
| HAProxy | admin socket + built-in Prometheus exporter on `NODE_IP:8404` (`/metrics`, `/stats`) |
| dnsdist | web API on `:8083` (QPS, per-backend QPS, distribution, health, latency) |
| PowerDNS | web API on `:8081` (QPS, latency, failures) |
| Squid | cache manager (DNS counters via `mgr:dns`) |
| IoT Mock | `:9090/stats` (JSON) and `:9090/metrics` (Prometheus) — connections, TLS handshakes, handshake failures, mTLS rejections, HTTP errors, bytes |
| PostgreSQL | catalog + `pg_stat_activity` |
| System | cgroup CPU/memory, `ss`, `/proc/net/sockstat`, conntrack, ephemeral ports |

The admin/metrics listeners bind the **node address**, never the VIP, so backend topology
is never exposed on a client-facing address.

---

## 10. What is deliberately not modelled

- The second datacenter, cross-DC routing, global load balancing, cross-DC DNS. **The last
  of these is not free.** Production Squid's `dns_nameservers` includes the remote site, so
  excluding it removes a fallback CURRENT has today; see
  [ADR 29](adr/0029-target-dns-fallback-regression.md). It is excluded because simulating
  the second site would put a fabricated component inside the measured DNS path.
- **Production's `option http-keep-alive` + `timeout http-keep-alive 2s`.** They are
  reproduced in the CURRENT template so the config under test matches production, but they
  are inert: both the frontend and backend are `mode tcp`, where HAProxy does not parse
  HTTP. Verified by parse (HAProxy 3.0.27 accepts them with no warning) and by behaviour (an
  end-to-end CONNECT is relayed opaquely). See
  [ADR 28](adr/0028-production-config-fidelity.md).
- DNSSEC (its own failure modes would add an unmeasured variable to the DNS comparison).
- Squid caching (a cache would make DNS query counts depend on hit rate and hide the DNS
  behaviour under measurement; the CURRENT layer exists to proxy, not to cache).
- Access logging on Squid and PowerDNS query logging — at 6,000 rps the log stream would
  dominate the run and corrupt every CPU and latency measurement.
- Production HAProxy reloads. `hard-stop-after` is set so that if a reload is ever
  introduced, old processes cannot linger holding connections and distort failover timing.
