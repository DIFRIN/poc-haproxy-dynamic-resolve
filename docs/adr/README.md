# Architecture Decision Records

One entry per decision the POC had to make. Decisions that were contested, measured, or
that changed during implementation are written up in full as separate files — the rest are
recorded here with their context, decision and consequences.

| # | Decision | Status |
|---|---|---|
| 1 | [CURRENT vs TARGET](#1-current-vs-target) | Accepted |
| 2 | [One-datacenter POC boundary](#2-one-datacenter-poc-boundary) | Accepted |
| 3 | [Two HAProxy nodes](#3-two-haproxy-nodes) | Accepted |
| 4 | [Active/passive HAProxy](#4-activepassive-haproxy) | Accepted |
| 5 | [Keepalived / VRRP](#5-keepalived--vrrp) | Accepted |
| 6 | [Single VIP](#6-single-vip) | Accepted |
| 7 | [Only the VIP owner receives traffic](#7-only-the-vip-owner-receives-traffic) | Accepted |
| 8 | [Common downstream service model](#8-common-downstream-service-model) | Accepted |
| 9 | [CURRENT uses Squid](#9-current-uses-squid) | Accepted |
| 10 | [CURRENT Squid DNS behaviour](#10-current-squid-dns-behaviour) | Measured |
| 11 | **[TARGET dynamic CONNECT — rejected](0011-target-dynamic-connect.md)** | **Rejected** |
| 12 | [SNI passthrough replaces CONNECT](#12-sni-passthrough-replaces-connect) | Accepted |
| 13 | [HAProxy `do-resolve`](#13-haproxy-do-resolve) | Accepted |
| 14 | [HAProxy `set-dst` / `set-dst-port`](#14-haproxy-set-dst--set-dst-port) | Accepted |
| 15 | [dnsdist](#15-dnsdist) | Accepted |
| 16 | [Local dnsdist per HAProxy](#16-local-dnsdist-per-haproxy) | Accepted |
| 17 | [dnsdist round-robin](#17-dnsdist-round-robin) | Accepted |
| 18 | [PowerDNS](#18-powerdns) | Accepted |
| 19 | [PostgreSQL backend](#19-postgresql-backend) | Accepted |
| 20 | [1M DNS namespace](#20-1m-dns-namespace) | Accepted |
| 21 | [End-to-end mTLS](#21-end-to-end-mtls) | Accepted |
| 22 | [Destination security policy](#22-destination-security-policy) | Accepted |
| 23 | [DNS failure semantics](#23-dns-failure-semantics) | Accepted |
| 24 | [HAProxy / dnsdist failure semantics](#24-haproxy--dnsdist-failure-semantics) | Accepted |
| 25 | [Benchmark methodology](#25-benchmark-methodology) | Accepted |
| 26 | [Resource model](#26-resource-model) | Accepted |
| 27 | [Production migration](#27-production-migration) | Open |
| 28 | **[Production config fidelity](0028-production-config-fidelity.md)** | **Accepted** |
| 29 | **[TARGET narrows the DNS path](0029-target-dns-fallback-regression.md)** | **Accepted** |

---

## 1. CURRENT vs TARGET

**Context.** The brief asks whether a production proxy layer (2 HAProxy + 2 Squid per DC)
can be replaced by 2 HAProxy active/passive + Keepalived + 2 dnsdist + 2 PowerDNS on
PostgreSQL. The answer must rest on measurement.

**Decision.** Build both architectures from the same repository, on the same network, over
the same DNS namespace and the same IoT backend, and measure them under equivalent
workloads. Each has its own self-contained compose file — `compose.yaml` for the nominal
TARGET run, `compose.current.yaml` for the comparison — so
neither can drift into a subtly different environment than the other.

**Consequences.** The comparison is like-for-like at the application layer. The transport
differs by design (CONNECT in CURRENT, direct TLS in TARGET) — that difference *is* the
thing under test.

## 2. One-datacenter POC boundary

**Context.** Production has 2 datacenters; each is independently equipped.

**Decision.** Reproduce exactly one complete datacenter — 2 HAProxy, 2 Keepalived, 1 VIP,
plus 2 Squid (CURRENT) or 2 dnsdist (TARGET). Do not simulate the second datacenter and do
not simplify to one HAProxy.

**Consequences.** Cross-DC routing, failover, global load balancing and cross-DC DNS are
untested and unmeasured here. Simplifying to one HAProxy would have removed the entire
active/passive and VIP question, which is the point of the exercise.

## 3. Two HAProxy nodes

**Context.** A single HAProxy would be simpler to build.

**Decision.** Two nodes, always. The HA pair *is* the architecture under test; a
single-node POC would silently assume away the failover, VIP-ownership and
standby-receives-no-traffic questions.

## 4. Active/passive HAProxy

**Context.** Active/active would use both nodes' CPU.

**Decision.** Strict active/passive. At any instant exactly one node owns the VIP and
processes client traffic; the other processes none. No configuration in this repository
permits both to serve simultaneously.

**Consequences.** Half the proxy capacity is idle by design. That is the accepted cost of
deterministic failover, and it must be reflected in capacity planning: the target 6,000
rps must be achievable by **one** node, not by two sharing the load.

## 5. Keepalived / VRRP

**Context.** The VIP must move automatically on failure. Docker bridge networks cannot
carry multicast VRRP (224.0.0.18) between containers without host-level multicast routing.

**Decision.** Use real Keepalived with **unicast VRRP** (`unicast_src_ip` / `unicast_peer`).
The same VRRP advertisements (IP protocol 112) are sent directly to the peer, which the
bridge forwards normally. HAProxy and Keepalived share one container per node because a
VIP belongs to a network namespace.

**Consequences.** Election, priority, preemption, advert interval, health-check weighting
and failover timing are genuine and were measured (see the benchmark report). **Not**
reproduced: switch-level IGMP snooping, physical-link failure detection, and failure of the
shared host itself. Real-host validation steps are in `docs/final-validation.md`. This must
not be presented as identical to production VRRP.

## 6. Single VIP

**Decision.** Exactly one floating VIP per datacenter (172.28.0.10). Both architectures use
the same one. Two VIPs would let both nodes serve and would be active/active by the back
door.

## 7. Only the VIP owner receives traffic

**Decision.** HAProxy binds its listening port on the node address; it receives VIP traffic
only while it owns the VIP. The standby's port is open but unreachable via the VIP.

**Consequences.** Verified as a gate in `scripts/wait-ready.sh` and reported by
`scripts/status.sh`, which fails loudly on both "no owner" and "two owners".

## 8. Common downstream service model

**Context.** It is tempting to pair Squid 1 with HAProxy 1 and Squid 2 with HAProxy 2.

**Decision.** Do not. The downstream layer (Squid in CURRENT, dnsdist+PowerDNS in TARGET)
is **common** to whichever node is active. There is no HAProxy→Squid affinity.

**Consequences.** When the VIP moves, the new active node uses the same downstream
services. This also exposes CURRENT's structural weakness — the shared Squid layer is a
single point of failure that VIP movement cannot mitigate (see 9).

## 9. CURRENT uses Squid

**Context.** Squid is the component that terminates CONNECT. HAProxy cannot (ADR 11).

**Decision.** Keep Squid in CURRENT, behind a TCP-mode HAProxy that only load-balances.
Squid is modelled strictly as a **tunnel terminator** — its only role is to terminate
`CONNECT` and create the TCP tunnel. It is not a caching proxy, not a policy engine, and
not application-aware: the `PUT` the client sends to the IoT device is opaque bytes to it.
`cache deny all` is set because caching is not part of the role.

**Consequences.**

- CURRENT's health check deliberately checks only the local HAProxy process and **excludes
  Squid**. Including a shared component in a per-node health check would move the VIP
  between two nodes that are equally unable to serve, adding an outage window on top of an
  outage. The consequence is a shared fate domain below a highly-available frontend;
  TARGET removes it.
- **An open security question.** If Squid's only job is tunnelling, then nothing in CURRENT
  validates the `CONNECT` destination. This POC configures Squid's resolved-address ACL
  (ADR 0022) because that is the only place such a control *can* live in this architecture —
  but if the real production Squid carries no equivalent, CURRENT has **no SSRF protection
  at all**, while TARGET's HAProxy applies one structurally as part of resolving the
  destination. That would be an argument for TARGET on security grounds independent of
  performance. **Unconfirmed against the real Squid configuration; do not rely on it until
  it is.**

## 10. CURRENT Squid DNS behaviour

**Context.** The brief requires reversed DNS-server preference between the two Squid
instances, and asks for round-robin/least-used if the chosen version supports it.

**Decision.** Configure `dns_nameservers` in reverse order on the two instances
(squid-1: PDNS1, PDNS2; squid-2: PDNS2, PDNS1), with short retransmit/timeout so that the
"PowerDNS 1 down" scenario measures failover rather than a stall.

**Consequences — measured, not assumed.** What Squid *actually does* with the list
(whether it round-robins, whether it fails over, and on which errors) was measured against
this Squid version and is recorded in the benchmark report's DNS section. The distinction
that matters: a **timeout or unreachable** server falls through to the next, whereas
**NXDOMAIN is a valid answer** and does not.

> **CORRECTED — see [ADR 28](0028-production-config-fidelity.md).** The real production
> Squid configuration was subsequently supplied and it does **not** reverse the list.
> Production sets the *same* `dns_nameservers` on both instances, and its second entry is
> **the remote datacenter's nameservers**, not a second local server:
>
> ```
> dns_nameservers {{ role_squid_dns_current_site_joined }} {{ role_squid_dns_remote_site_joined }}
> ```
>
> So the reversal is a brief §8 POC experiment with **no production counterpart**, and the
> measured distribution is a property of a POC-only configuration. More importantly, the
> remote-site list is a genuine cross-datacenter DNS fallback — see
> **[ADR 29](0029-target-dns-fallback-regression.md)** for what TARGET loses by not having
> one.

## 11. TARGET dynamic CONNECT — REJECTED

See **[0011-target-dynamic-connect.md](0011-target-dynamic-connect.md)** for the full record
and the four measured configurations behind it. In short: HAProxy relays CONNECT to an
upstream and requires that upstream to answer 2xx; it never originates
`200 Connection established`. Pointed at a TLS origin it waits for an HTTP response that
never arrives and returns 502. TARGET-as-specified is not implementable.

## 12. SNI passthrough replaces CONNECT

**Context.** With CONNECT unavailable (11), the intent — *select a destination by name,
validate it, then get out of the way* — still needs a mechanism.

**Decision.** TARGET uses TLS passthrough with SNI-based dynamic routing. The client
connects TLS directly to the VIP with `SNI = iotNNNNNNN.test.domain`; HAProxy reads the SNI
from the ClientHello **without terminating TLS**, resolves it through its local dnsdist,
validates the resolved address, sets the destination and tunnels raw TLS. Squid is removed
entirely.

**Why this is a smaller change than it looks.** Squid's role is *solely* to terminate
CONNECT and create the TCP tunnel (ADR 9). TARGET does not remove that function — it
reassigns it to HAProxy via SNI passthrough. The request path keeps the same shape
(`client → proxy → IoT device`) with one fewer **process** in it. What changes is
*who* terminates the tunnel, and therefore how the destination name is carried: in a
`CONNECT` line, or in the TLS `ClientHello` as SNI. Both are plaintext metadata available
to the proxy without any decryption.

**Consequences.** Every non-negotiable constraint holds (end-to-end mTLS, no TLS
termination by the proxy, one VIP, active/passive, 1M namespace, resolved-address
validation). **The client contract changes**, and that is the single largest migration
cost — see 27. TARGET rejects by closing the TCP connection, since TCP mode has no HTTP
status to return; CURRENT can return an HTTP error status instead. Clients that
distinguish "refused" from "unreachable" will behave differently.

## 13. HAProxy `do-resolve`

**Decision.** Resolve the SNI with `tcp-request content do-resolve(txn.dstip,local_dns,ipv4)`.

**Consequences.** Resolution is asynchronous: HAProxy pauses the stream, resolves, then
re-evaluates the ruleset. Two operational details cost real debugging time — `do-resolve`
arguments must contain **no spaces** (`do-resolve(a,b,ipv4)`, not `do-resolve(a, b, ipv4)`;
HAProxy splits config tokens on whitespace), and resolution failure is indistinguishable
from "not yet resolved" on the first pass, so an explicit reject must be placed after it to
avoid a client-visible timeout. Also: the cached `hold valid` window is the main lever on
DNS query volume for a 1M-name namespace.

## 14. HAProxy `set-dst` / `set-dst-port`

**Decision.** Commit the validated address with `set-dst var(txn.dstip)` and
`set-dst-port int(<port>)`; the backend holds only the unroutable placeholder `0.0.0.0:0`.

**Consequences.** The placeholder is documented by HAProxy for use with
`do-resolve`/`set-dst`. Traffic that reaches the backend without a resolved destination
fails to connect — fail-closed by construction. `set-dst-port` requires an **expression**;
a bare literal is parsed as a fetch method and the config will not load.

## 15. dnsdist

**Decision.** Introduce dnsdist as the DNS abstraction between HAProxy and PowerDNS: it
load-balances, health-checks, removes failed backends and reintroduces recovered ones.

**Consequences.** A PowerDNS outage is absorbed here and never reaches HAProxy as an error,
which is what makes "PowerDNS failure must not move the VIP" achievable. It also gives the
DNS statistics the comparison needs.

## 16. Local dnsdist per HAProxy

**Decision.** Each HAProxy has exactly one configured nameserver: its own local dnsdist.
No PowerDNS fallback, and no cross-node dnsdist entry.

**Consequences.** Deliberately narrow. If the local dnsdist is unavailable, resolution
fails and the node's health check fails, which moves the VIP — the required behaviour. A
PowerDNS fallback would silently bypass the DNS abstraction layer.

## 17. dnsdist round-robin

**Decision.** `setServerPolicy(roundrobin)`, explicitly — not least-outstanding or
latency-based.

**Consequences.** The distribution across the PowerDNS pair is reproducible rather than
dependent on machine noise, which is what makes it measurable. Measured split is in the
benchmark report.

## 18. PowerDNS

**Decision.** Two authoritative servers, **identical configuration, same database**.

**Consequences.** Identical answers are true by construction rather than by a replication
process that could lag or diverge. DNSSEC is disabled: it has its own failure modes and
would add an unmeasured variable to the DNS comparison.

## 19. PostgreSQL backend

**Decision.** PowerDNS `gpgsql` backend on PostgreSQL 16.

**Consequences.** Standard, supports the `generate_series` bulk generation the 1M dataset
needs, and gives the query statistics the metrics section requires. Query cache and packet
cache are disabled so the measured path is the real database-backed one.

## 20. 1M DNS namespace

**Decision.** 1,000,000 A records (`iot0000001`–`iot1000000`) generated **in-database**
with `generate_series`, plus a corpus of names resolving into every forbidden address class.

**Consequences.** No ~100 MB file has to cross the 9p boundary from `/mnt/c` into the
container. Measured seed time: 27 s. The SSRF corpus makes the security policy testable
against real resolution rather than hypotheticals.

## 21. End-to-end mTLS

**Decision.** Application TLS is end-to-end in both architectures. No frontend or backend
in this repository carries `ssl`/`ssl_crt`/`ssl_key`; there is no decrypt, inspect, MITM or
re-encrypt step anywhere.

**Consequences.** Directly testable, and tested: with a client certificate missing, the
alert the client receives comes from the **IoT Mock's** TLS stack. A proxy that had
terminated TLS would have emitted that alert itself and opened a separate session to the
backend.

## 22. Destination security policy

**Decision.** Validate the **resolved IP**, never the hostname. Deny loopback, RFC1918
(all three blocks), link-local, CGNAT, unspecified, multicast, broadcast, reserved and
benchmarking ranges, plus IPv6 equivalents.

**Consequences.** TARGET enforces this with HAProxy `-m ip` ACLs on `txn.dstip`.
`ipmask()` takes a dotted-quad mask, not CIDR — use `-m ip`. **One documented deviation:**
the POC's IoT endpoint range is RFC1918 (as a real datacenter's would be), so each
private-range deny carries an explicit exception for it, standing in for production's
allow-list of IoT endpoint networks. In production those endpoints resolve to publicly
routable addresses and the exception would not exist.

> **CORRECTED — see [ADR 28](0028-production-config-fidelity.md).** This entry previously
> read *"Enforcement differs by mechanism but not by policy … CURRENT uses Squid `acl dst`
> on the resolved address."* **That is false.** The real production Squid has no `dst` ACL
> and no destination validation of any kind — it is an open forward proxy. Measured: from a
> source outside `env_network`, CONNECT to `127.0.0.1:443`, to `169.254.169.254:443` (cloud
> metadata) and to an RFC1918 address on `:443` are all **allowed**; the only denial is
> port-based (port 22 is absent from `Safe_ports`). The `acl dst` policy this entry
> described was **invented by the POC** and then benchmarked as if it were CURRENT's
> posture, which biased the security comparison against TARGET. That policy is now retained
> only as an explicitly-labelled counterfactual in `configs/squid/squid-*/squid.conf.hardened`.
>
> The corrected position: **TARGET's destination policy is net-new security capability, not
> a re-implementation.** In CURRENT there is no policy to migrate — there is a hole to
> close. It remains true that resolved-address validation is *implementable* in Squid (the
> counterfactual demonstrates it), so the claim that only TARGET can do it would also have
> been wrong; the point is that production does not do it.

## 23. DNS failure semantics

**Decision.** Distinguish an **infrastructure failure** (no response: timeout, refused,
unreachable) from a **DNS result** (`NXDOMAIN`, `SERVFAIL`, a valid answer). Only the
former may move the VIP.

**Consequences.** This is why the TARGET health check uses `dig`, which exits non-zero only
when it receives *no response* — any rcode counts as proof the resolver is alive and
serving. When every PowerDNS backend is down, dnsdist keeps answering with SERVFAIL, so the
node stays healthy and the VIP stays put. Making this distinction wrongly in either
direction would break a non-negotiable rule.

## 24. HAProxy / dnsdist failure semantics

**Decision.**
- Active HAProxy dead → node unhealthy → **VIP moves**.
- Local dnsdist unreachable → node unhealthy → **VIP moves**.
- PowerDNS dead → dnsdist absorbs it → **VIP stays**.
- `NXDOMAIN` / `SERVFAIL` → DNS results → **VIP stays**.

**Consequences.** Encoded in `configs/keepalived/checks/target.sh` and weighted so that a failing
check drops the node's effective priority (150 → 90) below its peer's (100), forcing a real
election rather than relying on preemption. `fall 2` prevents a single jittered probe under
benchmark load from moving the VIP and corrupting a measurement run.

## 25. Benchmark methodology

**Decision.** Run CURRENT and TARGET under equivalent workloads over the same namespace and
the same backend. Record raw output per run under `benchmark/results/`. Report only
measured numbers; state every unmeasured claim as unmeasured. Run the client **not** on the
same CPU budget as the stack under test — a benchmark competing with its own subject
produces numbers that mean nothing.

**Consequences.** See the benchmark report, which states the run parameters and machine
limits alongside every figure.

## 26. Resource model

**Decision.** Named Docker volumes for all database state, never bind mounts into `/mnt/c`,
which WSL2 exposes over 9p. Explicit capability grants (`NET_ADMIN`, `NET_RAW`,
`NET_BROADCAST`) rather than `privileged: true`. `ulimits.nofile` set above `2 × maxconn`,
because HAProxy refuses to start otherwise.

**Consequences.** Storage is not the bottleneck and the numbers are not an artefact of a
network filesystem. The FD limit is a hard startup requirement, not a tuning nicety:
`[ALERT] Cannot raise FD limit to 400048, limit is 200000` aborts startup.

## 27. Production migration — OPEN

**Context.** The corrected TARGET requires clients to connect TLS directly to the VIP with
SNI, instead of issuing `CONNECT`. That is a client-side change across the entire IoT fleet.

**Consequences.** The migration is a **fleet-wide client change**, and it is larger than
this entry originally recorded. It is not only CONNECT → direct TLS: the client-facing port
also moves, from **38888 to 443**. Both changes must be sequenced and rolled back together,
and the port change was not previously listed anywhere. See ADR 28.

## 28. Production config fidelity

The real production HAProxy and Squid configurations were supplied after the POC was built
from the brief. Three load-bearing assumptions did not survive, one open security question
was answered, and one mandatory requirement turned out to be unreachable in the
architecture the POC was comparing against.

Read **[0028-production-config-fidelity.md](0028-production-config-fidelity.md)**. In short:

- **CURRENT has two ports**, not one: client-facing `38888`, Squid `4443`. The POC modelled
  a single `PROXY_PORT=3128` for both hops, which is a structural defect, not a typo.
- **The real Squid has no destination validation — it is an open forward proxy.** Measured
  from its own access log: CONNECT to loopback, to the cloud-metadata address
  `169.254.169.254` and to RFC1918 are all **allowed**; `http_access deny to_localhost` is
  unreachable dead code. The destination policy the POC attributed to CURRENT was invented
  by the POC and biased the security comparison **against** TARGET. It is now kept only as
  a labelled counterfactual.
- **Production CURRENT cannot carry 10,000 tunnels.** `2 × server maxconn 3200` caps it at
  **6,400**, below brief §15's mandatory 10,000. The POC's CURRENT ran `maxconn 200000`, so
  its "10,000 tunnels, 34,241 rps" measured a proxy production does not run.
- **`option http-keep-alive` in a `mode tcp` frontend is inert** — verified by parse and by
  end-to-end behaviour.

## 29. TARGET narrows the DNS path — accepted regression

**Context.** Production Squid's real `dns_nameservers` is
`{{ ..._current_site_joined }} {{ ..._remote_site_joined }}` — this site **and the remote
datacenter**. That is a cross-datacenter DNS fallback. TARGET reaches one local dnsdist with
no fallback, so it removes one.

**Decision.** Accept and document. The brief is explicit and non-negotiable (rules 14, 15)
and the second site is outside the POC boundary (rule 10).

**Consequences.** TARGET is a **net availability regression** in one nameable dimension:
loss of all local DNS fails closed, where CURRENT degrades to cross-site resolution.

See **[0029-target-dns-fallback-regression.md](0029-target-dns-fallback-regression.md)**,
which also records a remedy that preserves rule 14 exactly — give **dnsdist** the remote
site's nameservers as backends, ordered after the local PowerDNS pair. HAProxy's path stays
as specified; the cross-site fallback returns. Recommended for production, not implemented
in the POC.
