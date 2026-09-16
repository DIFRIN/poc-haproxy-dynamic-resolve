# Work units

The implementation plan, with honest status. Status values: **DONE** (built *and*
verified by running it), **PARTIAL** (built, verified only in part), **BLOCKED** (could not
be completed — reason given), **OPEN** (not started).

This file is a record, not an aspiration. Anything marked DONE was executed; the evidence
is in `benchmark/results/` and the reports.

> **CORRECTED (prod-fidelity audit).** The **real production HAProxy and Squid
> configurations were supplied after this plan was written**, and units 12, 13, 26, 27, 28
> and the migration row below were affected: production runs **two ports (38888 client-facing,
> 4443 Squid-side)**, its Squid has **no destination validation at all**, and its HAProxy
> caps concurrent tunnels at **6,400**. Corrected rows carry an inline note. Canonical
> write-ups: [ADR 28](adr/0028-production-config-fidelity.md) and
> [ADR 29](adr/0029-target-dns-fallback-regression.md).

---

## P0 — foundation

| # | Work unit | Status | Notes |
|---|---|---|---|
| 1 | Repository / environment inspection | DONE | WSL2, 20 vCPU, 31 GB, Docker 28.0.2 + Compose v2.34. Host has no Go/Haproxy/Squid/dig — everything is containerised. |
| 2 | Docker foundation | DONE | One `dc-lan` bridge models the datacenter L2 segment. The architecture is selected by **compose file** (`compose.yaml` = TARGET, `compose.current.yaml` = CURRENT), each self-contained so a bare `docker compose up -d` starts the recommended stack. `ARCH` is hardcoded per file. **CORRECTED (restructure):** an earlier revision used one `docker-compose.yml` with `ARCH` + `COMPOSE_PROFILES`; that indirection was removed. |
| 3 | PostgreSQL | DONE | 16-alpine, named volume (never a 9p bind mount), tuned for bulk load then read-heavy serving. |
| 4 | PowerDNS 1 | DONE | 4.9.17, `gpgsql` backend. |
| 5 | PowerDNS 2 | DONE | Identical config, same database — identical data by construction. |
| 6 | 1M DNS dataset | DONE | Generated in-database with `generate_series`. Measured seed time **27 s**, count asserted at 1,000,000 by the seed script itself. |
| 7 | IoT Mock | DONE | Go, stdlib only. mTLS enforced; the only component in either architecture that terminates application TLS. |
| 8 | Test PKI | DONE | Root CA + a second **rogue** CA + valid/expired/untrusted client certs + server cert with `SAN *.test.domain`. Expiry is genuine (2020–2021 window via `openssl ca`), not simulated. |
| 9 | mTLS client | DONE | Go, stdlib only, hand-rolled DNS codec. Verified against real root DNS servers. |
| 10 | CURRENT HAProxy active/passive pair | DONE | TCP-mode load balancer in front of the Squid layer; performs no DNS of its own. **CORRECTED (prod-fidelity audit):** now models production's connection ceilings *by default* — `global maxconn 10000`, `frontend maxconn 6400`, `backend fullconn 6400`, `server maxconn 3200` ×2 — because the earlier POC ran `maxconn 200000` with no `fullconn` and no per-server cap, which is a config production does not run. |
| 11 | CURRENT Keepalived / VIP | DONE | Unicast VRRP. Verified: exactly one node owns the VIP; the standby serves nothing. |
| 12 | CURRENT Squid 1 / 2 | DONE | Squid terminates CONNECT and resolves. **CORRECTED (prod-fidelity audit):** the default config is now production's **verbatim** access-control block, which performs **no destination validation at all** — Squid is an open forward proxy (measured; ADR 28). The resolved-address policy the POC originally built is retained only as the labelled counterfactual `configs/squid/squid-*/squid.conf.hardened`, selected by `SQUID_CONF`. Squid listens on **4443** (production), behind HAProxy's client-facing **38888** — two ports, not one. |
| 13 | CURRENT Squid DNS configuration | DONE | Reversed server preference between the two instances. **Measured** behaviour in the benchmark report. **CORRECTED (prod-fidelity audit):** the reversal is a **brief §8 POC experiment with no production counterpart** — production configures the *same* list on both instances, and that list also contains the **remote datacenter's** nameservers (a cross-DC fallback the one-datacenter POC does not model and TARGET removes; accepted regression, ADR 29). The measured distribution is therefore a property of this POC-only configuration. |
| 14 | CURRENT nominal test | DONE | End-to-end CONNECT + mTLS through the VIP, over the production port pair (`VIP:38888` → Squid `:4443`). |
| 15 | TARGET HAProxy active/passive pair | DONE | Originally specified as dynamic CONNECT — **[not implementable, ADR 0011](adr/0011-target-dynamic-connect.md)**. Rebuilt as SNI passthrough. |
| 16 | TARGET Keepalived / VIP | DONE | Health check covers HAProxy **and** the local dnsdist, and deliberately excludes PowerDNS. |
| 17 | TARGET dynamic CONNECT | **BLOCKED** | HAProxy cannot originate the CONNECT `200`. Four configurations built and measured; evidence in ADR 0011. Replaced by SNI passthrough (work unit 17b). |
| 17b | TARGET SNI passthrough | DONE | SNI read from the ClientHello without terminating TLS, resolved via local dnsdist, validated, `set-dst`, raw tunnel. Verified end-to-end with mTLS. |
| 18 | TARGET dnsdist 1 / 2 | DONE | Identical configs, both know both PowerDNS servers, explicit round-robin, health checks with `rise`. |
| 19 | TARGET PowerDNS integration | DONE | dnsdist probes the zone apex SOA (its default probe name would be REFUSED and would mark every backend down). |
| 20 | TARGET nominal test | DONE | Direct TLS with SNI through the VIP, mTLS end-to-end, `200 ok`. |
| 21 | End-to-end mTLS | DONE | **Proven, not asserted**: with the client certificate missing, the alert the client receives is emitted by the IoT Mock's TLS stack. |
| 22 | PowerDNS failure | DONE | dnsdist removes the failed backend, survives on the other; **VIP does not move**. |
| 23 | DNS response-error semantics | DONE | `NXDOMAIN` and `SERVFAIL` are DNS *results*; neither moves the VIP. Health check uses `dig` exit status, which distinguishes "no response" from "an answer". **CORRECTED (prod-fidelity audit):** this is a **TARGET** semantic, observed through dnsdist. The "all PowerDNS down" scenario that exercises it is a **POC-only construction for CURRENT** — production Squid also queries the **remote datacenter's** nameservers, so killing this site's PowerDNS pair does not stop production Squid resolving (ADR 29). |
| 24 | dnsdist failure | DONE | Health check fails → VIP moves to the other node and its dnsdist. |
| 25 | HAProxy failure | DONE | VIP moves; traffic resumes. Measured outage window in the benchmark report. |
| 26 | SSRF / security | DONE | Corpus of names resolving into every forbidden class, tested against the **resolved address**. **CORRECTED (prod-fidelity audit):** resolved-address validation exists in **TARGET only**. Production CURRENT does not validate destinations at all — it is an open forward proxy, measured from Squid's own access log (private IPv4, loopback, link-local and the cloud-metadata endpoint all ALLOWED; the sole denial observed is **port-based**). The previously reported "CURRENT: 26 PASS / 0 FAIL" was measured against the counterfactual `squid.conf.hardened` and **does not describe CURRENT**; the ✅ is withdrawn for CURRENT and stands for TARGET. |
| 27 | 10,000 simultaneous tunnels | **PARTIAL** | Requires `ulimits.nofile` above `2 × maxconn`; HAProxy refuses to start otherwise. **CORRECTED (prod-fidelity audit): measured, but only against an over-provisioned CURRENT that production does not run** (`maxconn 200000`, no `fullconn`, no per-server cap). Production's ceilings (`frontend maxconn 6400`, `fullconn 6400`, `2 × server maxconn 3200`) cap concurrent tunnels at **6,400**, so brief §15's mandatory 10,000 is **UNREACHABLE for CURRENT as production is configured today**. The POC's CURRENT now models those ceilings by default and a "CURRENT resized" variant exists for the comparison, but **no resized run is retained**, so the requirement is met by neither architecture as measured (CURRENT structurally, TARGET unmeasured). ADR 28. |
| 28 | 6,000 rps | DONE | Headline comparison. **CORRECTED (prod-fidelity audit):** the 5.7× persistent-tunnel headroom (34,241 rps) holds only for the over-provisioned pre-fix CURRENT; at production sizing the tunnel population is capped at 6,400 and no such run exists. The short-lived-connection ceiling (both architectures) is unaffected — at 200 workers the ceiling cannot bind. |
| 29 | CURRENT vs TARGET benchmark | DONE | `docs/benchmark-report.md`. Read its `CORRECTED (prod-fidelity audit)` notes: the CURRENT column of §1 and the whole of §2 are **pre-fix** measurements. |

## P1

| Work unit | Status | Notes |
|---|---|---|
| Dashboard | OPEN | Metrics are collected and exposed (HAProxy Prometheus exporter, dnsdist/PowerDNS APIs, IoT Mock `/metrics`); no dashboard is built on top. Not required to answer the engineering question. |
| Detailed metrics | DONE | Per-component collectors; snapshots written alongside every benchmark run so a throughput figure can be read next to the cost that produced it. |
| DNS comparison | DONE | PowerDNS-direct control vs dnsdist path; Squid's DNS counters captured for CURRENT. **CORRECTED (prod-fidelity audit):** the comparison exercises the *local* PowerDNS pair only. Production Squid also holds the **remote datacenter's** nameservers (cross-DC fallback), which the one-datacenter boundary excludes and TARGET removes — accepted regression, ADR 29. |
| Prod-fidelity audit | DONE | The real production HAProxy and Squid configurations were supplied and diffed against the modelled ones. Corrected: **two ports** (38888/4443, was a single `PROXY_PORT=3128`), **Squid's ACLs** (production has no destination validation; the invented policy became a labelled counterfactual), **HAProxy connection ceilings** (6400, capping the mandatory 10,000 tunnels), the **DNS server list** (production is identical on both instances and includes the remote site), plus `timeout connect 1m`, `retries 3`/`option redispatch`, `ulimit-n 65536`, syslog, stats binding and `stats auth`. Findings in the benchmark report, final validation, ADR 28 and ADR 29. |
| DNS duplication analysis | DONE | Addressed by the HAProxy resolver hold window and by dnsdist's own behaviour; measured effect in the report. |
| TLS/mTLS performance | PARTIAL | Short-lived and persistent mTLS sessions measured. Full handshake-cost isolation (separating handshake from request) not done. |
| Connection burst | PARTIAL | Covered by the concurrency scenario; a dedicated burst-above-target test was not run. |
| Resource tuning | DONE | Per-service CPU/NBTHREAD/worker budgets set explicitly so the comparison is resource-fair; FD limits corrected after a hard startup failure. |
| Extended failures | PARTIAL | Single-failure scenarios covered. Combined and cascading failures not tested. |
| Improved benchmark reporting | DONE | Raw per-run JSON plus environment snapshots retained under `benchmark/results/`. |

## P2

| Work unit | Status | Notes |
|---|---|---|
| Soak tests | OPEN | No multi-hour run. Would be required before production, not before a POC verdict. |
| Network failures | OPEN | Packet loss, latency injection and MTU issues untested. |
| Certificate rotation | OPEN | Not tested; would exercise Squid/dnsdist reload paths that this POC does not touch. |
| DNS recovery | DONE | dnsdist reintroduces a recovered backend automatically and this was observed across the PowerDNS failure scenarios. |
| Production migration documentation | PARTIAL | The migration cost is identified but sequencing and rollback are not designed — [ADR 0027](adr/README.md#27-production-migration--open). **CORRECTED (prod-fidelity audit) — the cost is two changes, not one:** (a) the client protocol change from `CONNECT` to direct TLS with SNI, **and (b) the client-facing port change from 38888 (production CURRENT) to 443 (TARGET)**. The port change was missing from every earlier revision of this plan; it is not covered automatically by a protocol-level dual-stack period, because the two protocols do not share a port today. A third, smaller cost is the **loss of the cross-DC DNS fallback** (ADR 29), which is a resilience reduction on the server side, not a client change. |
| Capacity planning | PARTIAL | Single-host measurements only. Extrapolating from one WSL2 host to production hardware is not defensible and is not attempted. |

---

## What went wrong during implementation

Recorded because each cost real debugging time and each is a trap that will recur.

1. **TARGET could not be built as specified.** HAProxy relays CONNECT rather than
   terminating it. This is the POC's headline result, not a setback — see ADR 0011.
2. **`do-resolve` arguments must not contain spaces.** HAProxy splits config tokens on
   whitespace, so `do-resolve(a, b, ipv4)` parses as fragments. It must be
   `do-resolve(a,b,ipv4)`.
3. **`ipmask()` takes a dotted-quad mask, not CIDR.** `ipmask(10.0.0.0/8)` fails at parse
   time; `-m ip 10.0.0.0/8` is the correct construct.
4. **`set-dst-port` takes an expression.** `set-dst-port 443` is parsed as a fetch method
   and the config will not load; it must be `int(443)`.
5. **Keepalived silently disables health-check scripts.** Its default script user,
   `keepalived_script`, does not exist in the image, and it refuses scripts that are
   group- or other-writable — which every file under `/mnt/c` is, because WSL2 exposes 9p
   with fixed 777 permissions. The failure mode is a cluster where neither node ever takes
   the VIP while every test appears to run. Fixed by `script_user root`,
   `enable_script_security`, and staging the scripts root-owned 0700.
6. **HAProxy refuses to start if it cannot raise `RLIMIT_NOFILE` to ~`2 × maxconn`.** The
   default limits abort startup outright.
7. **A failing health check on *both* nodes means no VIP owner at all.** Because the check
   reflects each node's local stack, a fault common to both nodes takes the datacenter down
   — correct fail-closed behaviour, but only visible if you check for "no owner" and not
   merely "an owner exists".
8. **Rendered config must not be written back into read-only mounts.** Templates live in
   the repository (read-only); rendered output goes to `/run/`, and is printed to stdout so
   `docker logs` contains the exact bytes that ran.
9. **A modelled configuration is not the production configuration, and the difference was
   invisible until the real configs arrived.** Three defensible-looking modelling shortcuts
   each produced a published result that does not describe production: one `PROXY_PORT`
   standing in for **two** production ports (38888 client-facing, 4443 Squid-side), a
   Squid destination policy the POC **invented** and then reported as CURRENT's security
   posture, and `maxconn 200000` with no `fullconn` and no per-server cap, which produced a
   10,000-tunnel result that production's 6,400 ceiling makes impossible. None of the three
   was detectable from inside the POC — every run was green. The lesson is not "model more
   carefully"; it is that **any figure attributed to an architecture must cite the
   configuration it was measured against, and the production configuration must be obtained
   before the figure is published.** See ADR 28 and the benchmark report's correction
   notes.
