# Benchmark report — CURRENT vs TARGET

Every figure below was produced by a command in this repository and the raw output is
retained under `benchmark/results/`. Where a number is absent, it is because it was **not
measured** — not because it was estimated.

Read the caveats section before quoting anything. One comparison in this report is
explicitly **not valid** (§2.4), a second is a **single-host POC result with a stated
caveat** (§2.2), and saying so is part of the result.

---

> ## CORRECTED (prod-fidelity audit) — and RE-RUN against the corrected configs
>
> The **real production HAProxy and Squid configurations were supplied after this report was
> first written**, and they contradict what the POC modelled in three places. The stack was
> then rebuilt at production-faithful sizing and **the benchmark re-run in full** against it.
> Every figure below is now a measurement of the corrected stack: passages that previously
> said "no run is retained yet" or "pre-fix, must be re-run" carry their measured replacement,
> and figures taken against the old over-provisioned CURRENT are retained only where they are
> labelled **Superseded**. Nothing has been silently rewritten. The canonical write-ups are
> [ADR 28](adr/0028-production-config-fidelity.md) (config fidelity) and
> [ADR 29](adr/0029-target-dns-fallback-regression.md) (DNS fallback regression).
>
> 1. **CURRENT has two ports on two different numbers.** `client --CONNECT--> HAProxy :38888
>    --tcp relay--> Squid :4443`. The POC modelled a single `PROXY_PORT=3128` for both hops,
>    and **neither number matched production**. Any earlier statement that CURRENT speaks
>    CONNECT to `VIP:3128`, or that the client-facing port and the Squid port are the same,
>    is wrong.
> 2. **Production Squid performs no destination validation at all.** It is an **open forward
>    proxy**, measured from Squid's own access log (evidence in §4). The POC invented a
>    resolved-address policy (`acl to_private dst` / `acl iot_endpoints dst` / `acl localnet
>    src`) and reported CURRENT as blocking the SSRF corpus with HTTP 403. **That policy does
>    not exist in production.** It survives only as an explicitly-labelled counterfactual in
>    `configs/squid/squid-1/squid.conf.hardened` (selected with `SQUID_CONF`; the default is the
>    production-faithful `squid.conf`), and it may never be presented as CURRENT's behaviour.
> 3. **Production CURRENT cannot reach 10,000 concurrent tunnels — now measured, not read.**
>    Production sizes HAProxy at `global maxconn 10000`, `frontend maxconn 6400`, `backend
>    fullconn 6400` and `2 × server maxconn 3200`, a hard ceiling of **6,400** concurrent
>    tunnels, against a mandatory requirement of 10,000 (brief §15). Offered 10,000 tunnels,
>    the production-sized CURRENT established **exactly 6,400** — each Squid pinned at
>    precisely its configured `smax=3200` and the frontend at its own `smax=6400` (§2.1). The
>    shortfall is therefore **observed**, not inferred from a configuration. The earlier POC
>    CURRENT ran `maxconn 200000` with no `fullconn` and no per-server cap; its 10,000-tunnel
>    and 34,241 rps figures are retained below **marked Superseded** and describe a
>    configuration production does not run. The POC's CURRENT now models production's exact
>    ceilings by default (`CURRENT_GLOBAL_MAXCONN` / `CURRENT_FRONTEND_MAXCONN` /
>    `CURRENT_FULLCONN` / `CURRENT_SERVER_MAXCONN`), with a "CURRENT resized" variant to show
>    what CURRENT would need in order to meet the requirement. **That resized run has now been
>    taken**, and raising HAProxy's ceilings **degraded** CURRENT on this host — 3,596 tunnels,
>    29,529 rps and 216,597 timeouts against the production-sized 6,400 / 35,900 rps / 79,601
>    (§2.2, which carries its own single-host caveat).
>
> Two further production facts the POC did not model, both recorded inline: production
> Squid's `dns_nameservers` carries this site's *and the remote datacenter's* nameservers,
> identically on both instances (§3, ADR 29), and production HAProxy carries a set of
> directives the POC did not reproduce (`timeout connect 1m`, `retries 3` + `option
> redispatch`, `ulimit-n 65536`, syslog `127.0.0.1 local1`, stats on `127.0.0.1:15080`,
> `stats auth` with an empty username, and `option http-keep-alive` inside a `mode tcp`
> frontend — the last two verified **inert** against HAProxy 3.0.27, see ADR 28).

---

## Test environment

| | |
|---|---|
| Host | WSL2, Linux 6.18.33.2-microsoft-standard-WSL2 |
| CPU | 12th Gen Intel i9-12900HK, **20 vCPU** |
| RAM | 31 GiB |
| Storage | ext4 named volumes (never 9p bind mounts — see ADR 0026) |
| Docker | 28.0.2, Compose v2.34.0 |
| HAProxy | 3.0.27 (USE_LUA, USE_PROMEX, PCRE2) |
| Squid | Alpine 3.20 package |
| dnsdist | 1.9.16 |
| PowerDNS Auth | 4.9.17 |
| PostgreSQL | 16-alpine |

**All components — including both "HAProxy nodes", both Squid/dnsdist, both PowerDNS, the
client and the backend — run on this one host.** CPU, memory and network bandwidth are
therefore shared between the system under test and its load generator. This is the single
most important limitation of every number in this report.

**Dataset:** 1,000,000 A records (`iot0000001`–`iot1000000`) plus the SSRF corpus, seeded
in **27 s**.

---

## 1. End-to-end mTLS request throughput

The headline comparison. Same client, same backend, same namespace, same host. The only
difference is the transport: CURRENT speaks `CONNECT` to `VIP:CLIENT_PORT`
(production **38888**); HAProxy TCP-relays that byte stream to Squid on `SQUID_PORT`
(production **4443**), which terminates the CONNECT and establishes the tunnel. TARGET
speaks TLS to `VIP:443` with the name as SNI and is tunnelled directly.

> **RE-MEASURED (prod-fidelity audit).** Earlier revisions of this report said CURRENT speaks
> `CONNECT` to `VIP:3128`. Production has **two ports, on two different numbers** (38888
> client-facing, 4443 Squid-side), and the POC's single `PROXY_PORT=3128` matched neither.
> The CURRENT column below was also measured against the *counterfactual* Squid ACLs
> documented in §4 — not production's verbatim ACLs (which are a smaller, cheaper rule set).
> **Both columns have now been re-measured against the production-faithful stack** — CURRENT
> on `VIP:38888` relaying to Squid on 4443 with production's own (unrestricted) ACLs — and
> those measurements are the table below. The old CURRENT column, taken at
> `PROXY_PORT=3128` against counterfactual ACLs, is superseded and retained only in the
> comment under the table. The §1 workload opens at most 50 concurrent tunnels, an order of
> magnitude below production's 6,400 concurrent-tunnel ceiling, so the ceilings in §2 cannot
> bind here and the short-lived-connection conclusion is unaffected.

**Parameters:** 60 s measured, 10 s warmup dropped, 50 workers, target 6,000 rps,
`PUT` with a 256-byte body to `/`, random identity per request from the 1M namespace
(forces a DNS cache miss every request).

> An earlier revision of this report measured `GET /health`. That is an infrastructure
> probe, not the workload — the IoT devices accept `PUT`. The `GET` figures (1,255.8 /
> 1,518.9 rps) are superseded and retained only under
> `benchmark/results/*-mtls-6000rps.json` for comparison. They were taken at **200 workers
> over 45 s** against the pre-fix CURRENT, so they are **not** comparable with the table
> below, which is a 50-worker run on the production-faithful stack. The published workload is
> the `PUT` one.

| | **CURRENT** (HAProxy→Squid) | **TARGET** (HAProxy→SNI tunnel) |
|---|---|---|
| Attempts | 64,640 | 77,327 |
| Successful `PUT`s | 64,589 | 77,277 |
| **Achieved throughput** | **1,077 rps** | **1,289 rps** |
| HTTP 200 | 64,589 (100 %) | 77,277 (100 %) |
| CONNECT rejected / errored | 0 / 0 (64,636 × 200) | n/a — no CONNECT |
| Tunnels opened | 64,608 | n/a — no CONNECT tunnel |
| Connection errors | 0 | 0 |
| TLS errors / mTLS rejections | 0 / 0 | 0 / 0 |
| HTTP errors | 0 | 0 |
| Timeouts | 51 | 50 |
| **p50** | **41.6 ms** | **34.6 ms** |
| p90 | 72.9 ms | 64.6 ms |
| p95 | 84.1 ms | 75.5 ms |
| p99 | 108.1 ms | 99.3 ms |
| max | 192.4 ms | 210.8 ms |
| mean | 45.0 ms | 38.2 ms |

> **Superseded.** The previous version of this table (CURRENT **1,272.2 rps** / p50 135.3 ms;
> TARGET **1,571.4 rps** / p50 108.1 ms) was taken at **200 workers over 45 s** against the
> **pre-fix** CURRENT — `PROXY_PORT=3128`, and the counterfactual Squid ACLs that production
> does not run. It is a different parameter set against a different CURRENT and **must not be
> set beside the table above**. The paths `benchmark/results/current-mtls-put-6000rps.json`
> and `benchmark/results/target-mtls-put-6000rps.json` now hold the re-run. The superseded
> CURRENT arm survives in `benchmark/results/put-workload-run.log` (proxy
> `172.28.0.10:3128`, 200 workers, 45 s, success 57,058, timeout 196); its TARGET arm has no
> retained file of its own — the nearest survivor is
> `benchmark/results/target-mtls-put-6000rps-firstrun.json`, which is a **different** run
> (1,595.3 rps / 71,797 attempts) and is not the source of the TARGET column above.

**Server-side cross-check.** The re-run's device-side counter snapshot is **not** among the
retained files — the `metrics-*-mtls-put-*` snapshots carry host, container, VIP and HAProxy
counters, not the IoT Mock's — so **no counter cross-check figure is published for the
re-run**; by this report's own rule, absent means not measured, not estimated. What the
re-run does retain is the client-side profile in the table: **0 connection errors, 0 TLS
errors, 0 mTLS rejections and 0 HTTP errors on both arms**, so every request counted as
successful was served successfully. No run in this scenario logged
`connect: cannot assign requested address`, so none is port-exhaustion contaminated.

> **Superseded.** The previous version of this paragraph cited the IoT Mock's
> `http_requests_total` 90,034 with `http_errors_total` 0 for the TARGET run and a CURRENT
> delta of +72,852 requests with 0 errors. Those were the pre-fix runs.

**Reading this.** TARGET carries **~20 % more requests** (77,277 successful `PUT`s against
64,589) and is **lower latency at every percentile** — p50 34.6 ms against 41.6 ms, p90 64.6
against 72.9, p95 75.5 against 84.1, p99 99.3 against 108.1 — with an identical zero-error
profile. TARGET's single worst request is slower (max 210.8 ms against 192.4 ms); the
percentiles are what the workload lives in. That gain is the cost of the CONNECT hop plus the
Squid layer, removed.

### The 6,000 rps target was not reached — and the reason is the connection model, not the architecture

Both architectures measured 1,077 rps (CURRENT) and 1,289 rps (TARGET) against a 6,000 rps
target. **The 6,000 rps target is not met by either architecture in this short-lived
(connection-per-request) mode.** This is a property of the connection model, and it was
verified rather than assumed:

- The load generator runs a closed loop: `throughput ≈ concurrency ÷ latency`. At 50 workers
  and the measured mean latency (45.0 ms CURRENT, 38.2 ms TARGET), the loop — not the proxy —
  is the limit, and the measured figures are what that concurrency and latency produce.
- Each "short-lived" request costs a full TCP handshake, a CONNECT exchange (CURRENT), a
  **TLS handshake with client-certificate verification**, one HTTP request, and a close.
  The TLS/mTLS handshake dominates.
- **With persistent tunnels the same stack measured 35,900 rps** — far above the 6,000 rps
  target — and that is now a measurement of the **production-sized** CURRENT (§2.1), not of
  an over-provisioned one. The target is met in persistent mode; it is not met in this one.

> **Superseded.** An earlier revision of this subsection argued from a 40→200-worker
> concurrency sweep (1,126 → 1,256 rps for CURRENT, p50 27.6 → 138.3 ms) and claimed 5.7×
> headroom with persistent tunnels. Both were taken at **200 workers against the pre-fix,
> over-provisioned CURRENT** (`maxconn 200000`, `PROXY_PORT=3128`, counterfactual Squid
> ACLs). Those figures are superseded by the measurements above and must not be quoted as
> CURRENT's behaviour.

Also relevant, and measured: at high short-lived rates a single load-generator IP exhausts
its ~28k ephemeral ports before TIME_WAIT recycles them, failing with
`connect: cannot assign requested address`. This is a **generator** limit, not a proxy
limit — 10,000 real IoT devices each have their own address and never contend. The harness
mitigates it (`tcp_tw_reuse=1`, widened `ip_local_port_range`) and any run where
`connect_error` is dominated by `EADDRNOTAVAIL` is labelled as a harness failure, not a
result. An earlier run of this report's scenario failed exactly that way and was discarded.

> **CORRECTED (prod-fidelity audit).** This argument covers ephemeral-port exhaustion under
> **short-lived** load only. It does **not** explain, and must not be used to explain, the
> tunnel shortfall in §2: there the binding limit is production's 6,400 concurrent-tunnel
> ceiling, which is a property of the proxy, not of the generator — and §2.1 now measures the
> shortfall directly (3,600 tunnels never established). Where generator-side connect failures
> do contribute to a run, they are counted separately in `connect_error`; the resized run in
> §2.2 recorded 189,273 of them, and this report does **not** attribute those between the
> generator and the proxy.

---

## 2. 10,000 simultaneous tunnels

**Parameters:** 10,000 workers (one tunnel per worker), 60 s, persistent tunnels
(`-requests-per-tunnel=1000000`), random identity per request from the 1M namespace,
`PUT` with a 256-byte body.

> ### MEASURED — the mandatory 10,000-tunnel requirement, arm by arm
>
> Brief §15 makes 10,000 simultaneous CONNECT tunnels mandatory. After the re-run the state of
> that requirement is:
>
> - **CURRENT at production sizing: MEASURED AND UNMET — 6,400 of 10,000 established.** The
>   ceiling is no longer a reading of the configuration; it is observed, and it is exactly the
>   configured number (§2.1).
> - **CURRENT "resized": MEASURED AND WORSE.** Raising HAProxy's ceilings produced *fewer*
>   tunnels and *lower* throughput, not more. The bind on this host is the Squid layer, not
>   HAProxy's `maxconn` (§2.2 — single-host caveat stated there).
> - **TARGET: NOT MEASURED, AND NOT COMPARABLE.** The client's `-mode=tls` has no persistent
>   tunnel implementation, so it cannot open and hold tunnels the way `-mode=connect` does.
>   That is now proven, not inferred (§2.4), and **no TARGET tunnels figure may be set beside
>   CURRENT's.**
>
> [ADR 28](adr/0028-production-config-fidelity.md) Finding 3 is the canonical write-up of the
> ceiling; this section is its measurement.

### 2.1 CURRENT — production sizing (measured)

Production sizes HAProxy as `global maxconn 10000`, `frontend maxconn 6400`, `backend
fullconn 6400` and `server maxconn 3200` on each of two Squids — `2 × 3200 = 6,400`
concurrent tunnels, and no more. Offered 10,000, this is what happened:

| | |
|---|---|
| Tunnels established | **6,400 of the 10,000 requested** |
| CONNECT status codes | `{"200": 6400}` — every CONNECT that received a status received `200` |
| Attempts / successful `PUT`s | 2,155,444 / 2,075,843 |
| Throughput | **35,900 rps** |
| Timeouts | 79,601 |
| Connection / TLS / HTTP errors | 0 / 0 / 0 |
| mTLS rejections | 0 |
| p50 / p99 | 179.4 ms / 214.3 ms |

**HAProxy's own counters during the run** (active node):

```
fe_connect        smax=6400  slim=6400
be_squid/squid-1  smax=3200  slim=3200
be_squid/squid-2  smax=3200  slim=3200
```

**Reading this.** 10,000 tunnels were requested and 6,400 were established: each Squid is
pinned at **precisely** its configured `maxconn`, and the frontend at its own. **3,600 tunnels
could not be established at all.** The mandatory §15 requirement is therefore **unmet by
CURRENT as production is configured**, by 3,600 tunnels, and the cause is the configured
ceiling rather than the load generator. This is the direct measurement of
[ADR 28](adr/0028-production-config-fidelity.md) Finding 3 — previously a configuration
reading, now observed.

**The 6,000 rps *throughput* requirement, by contrast, is met once tunnels are persistent:**
this same production-sized run measured **35,900 rps**, well above the target. It is the
tunnel *count* requirement that this run misses — 6,400 rather than 10,000.

### 2.2 CURRENT — the "resized" variant (measured): raising the ceilings made it worse

The resized variant raises every HAProxy ceiling — `global 40000`, `frontend maxconn 20000`,
`backend fullconn 20000`, `server maxconn 10000` (2 × 10000 = 20,000 tunnel slots) — and asks
the fair follow-up question: what would CURRENT need in order to meet the requirement?

| | **CURRENT, production sizing** | **CURRENT, resized** |
|---|---|---|
| Tunnels established | **6,400** | **3,596** |
| CONNECT status codes | `{"200": 6400}` | `{"200": 3645, "503": 1761}` |
| Successful `PUT`s | 2,075,843 | 1,371,908 |
| Throughput | **35,900 rps** | **29,529 rps** |
| Timeouts | 79,601 | **216,597** |
| Connection errors | 0 | 189,273 |
| p50 / p99 | 179.4 ms / 214.3 ms | 115.5 ms / 299.2 ms |

Both Squids failed their own L4 health checks repeatedly during the resized run:
`squid-1 chkdown=8 downtime=41 s`, `squid-2 chkdown=7 downtime=13 s`. Squid peak RSS reached
**~1.36 GB**, and Squid consumed **117 s of CPU time within a 60 s window**. Kernel socket
state after the run: `TCP alloc 30,579, orphan 7,645` — against `alloc 92, orphan 46` after the
production-sizing run.

**Reading this.** Raising HAProxy's ceilings made CURRENT **worse, not better**: fewer tunnels
(3,596 against 6,400), lower throughput (29,529 against 35,900 rps), and timeouts up from
79,601 to 216,597, with **1,761 CONNECTs answered `503`**. The binding limit is the **Squid
layer**, not HAProxy's `maxconn`: the production figure of 6,400 is (approximately) matched to
what this Squid pair can actually serve. **Raising HAProxy's `maxconn` alone is not a fix.**

> **Caveat — this is a single-host POC result, and it proves less than it looks like it does.**
> Both Squids contend for CPU with every other component on the same 20-vCPU host (§Test
> environment). Production Squids have their own hardware. This is therefore a statement about
> **POC-host Squid capacity**, not a proven production Squid limit, and it is **not** proof
> that production's 6,400 is correctly sized. What it does prove is narrow and still useful:
> raising HAProxy's `maxconn` alone does not help.
>
> **On the 189,273 connection errors.** The retained error sample is unambiguous about what
> they are *not*. Every sampled entry is
> `timeout: read tcp <client>->172.28.0.10:38888: i/o timeout` — the client's TCP connection
> was established, but no `200 Connection established` came back before the timeout. None is
> an `EADDRNOTAVAIL` / "cannot assign requested address", so this is **not** source-port
> exhaustion in the load generator, and the sample points at the proxy side stalling
> CONNECTs. That is consistent with the Squid health-check flapping recorded above, but no
> run isolating the cause was taken, so the mechanism is inferred rather than proven. What
> the sample *does* establish is that the degradation is not an artefact of the generator
> running out of ports. For contrast, the production-sizing run recorded **0** connection
> errors under the same client and the same flags.

### 2.3 Superseded — the pre-fix, over-provisioned CURRENT run

Retained for context only. This run was taken against a CURRENT that production does not run
(`maxconn 200000`, no `fullconn`, no per-server cap, and the POC's single `PROXY_PORT=3128`
instead of production's two ports). **Every figure in this block is superseded by §2.1** and
must not be quoted as CURRENT's behaviour.

| | |
|---|---|
| Tunnels established | 10,000 (exactly one per worker; 10,000 × HTTP 200 on CONNECT, 0 failures) — ⚠️ only possible because this run had no per-server `maxconn`; production's ceiling is 6,400 |
| Attempts / successful `PUT`s | 1,555,176 / 1,497,550 |
| Throughput | 34,241 rps — ⚠️ superseded |
| Timeouts | 57,626 |
| Connection / TLS / HTTP errors | 0 / 0 / 0 |
| p50 / p90 / p95 / p99 | 270.5 / 324.3 / 333.6 / 359.7 ms |
| max / mean | 4,123.8 / 280.5 ms |

**Resource cost of holding 10,000 tunnels in that run, sampled *during* it — also superseded:**
active HAProxy 20,033 FDs; each Squid 10,011 FDs; kernel `TCP alloc` 60,046; conntrack
62,036 / 262,144 (24 %). For comparison, the production-sized run in §2.1 holds 6,400 tunnels
and left `TCP alloc 92, orphan 46` behind it. Production's `ulimit-n 65536` is not the binding
constraint (the Squid-pair `maxconn` ceiling binds first).

**Server-side cross-check (that run).** The IoT Mock's delta over it was +10,000 connections,
+10,000 TLS handshakes, +0 handshake failures, +1,506,858 requests, 0 HTTP errors.

> **CORRECTED (prod-fidelity audit).** This report previously concluded from that
> cross-check that the attempts which never reached a device were "**client-side timeouts**,
> a load-generator artefact rather than a proxy or backend result". **That attribution is
> withdrawn**, and §2.1 now settles the question by measurement rather than inference: offered
> 10,000 tunnels, the production-sized CURRENT establishes exactly 6,400 and 3,600 tunnels are
> never established at all. The production-sized run's 79,601 timeouts are **not** decomposed
> between generator-side and proxy-side causes here, and no split is offered.

### 2.4 TARGET — NOT COMPARABLE to §2.1, and no TARGET tunnels figure may be quoted beside it

The TARGET arm of this scenario **did not execute the same workload**, and that is now proven
directly rather than inferred:

- The client's `-mode=tls` has **no persistent-tunnel implementation**. The harness passes
  `-persistent -requests-per-tunnel=1000000` to both branches, but the `tls` path ignores it:
  the TARGET result file for this run contains **no `persistent`, `requests_per_tunnel` or
  `tunnels_opened` key at all**, while CURRENT's contains all three.
- Measured with a standalone persistent TLS probe: `handshakes_completed` **7,710** against
  `success` **7,709** — i.e. **one TLS handshake per request**, not one per tunnel.

So TARGET cannot open and hold tunnels in this harness. What the TARGET arm of this scenario
produced — **rps 2,685, success 41,586, timeouts 118,459, tls_error 1,549**, and no
`tunnels_opened` figure — is a *connection-per-request* run at 10,000-way concurrency, with a
latency distribution dominated by the client timeout (p50 5,000.1 ms in the retained result
file). **It is not a 10,000-tunnel measurement and it must not be read against §2.1's.**

The earlier attempt at this scenario already showed the same limitation from the server side —
the IoT Mock served **128,409 requests** with `http_errors_total` 0, and HAProxy's active node
recorded **`MaxConnRate` 16,499/s** — enough to rule the stack out as the cause, but not enough
to say what the cause was. The probe above says it.

**Status of the requirement, as measured:**

- **CURRENT: measured and unmet — 6,400 of 10,000, structurally, by configuration (§2.1).**
  The earlier statement that the requirement is "**demonstrated for CURRENT** and
  **undemonstrated for TARGET**" is withdrawn on both halves: what was demonstrated, 10,000
  tunnels at 34,241 rps, was demonstrated against **a configuration production does not run**.
- **TARGET: still unmeasured.** Its HAProxy config does not carry the `3200`-per-server cap
  that binds CURRENT, so it is not subject to the same ceiling — but that is a reading of its
  configuration, not a measurement, and it is not offered as one. The blocker is the client
  harness, not the stack.

---

## 3. DNS layer comparison (brief §14)

**Parameters:** 60 s, 5,000 qps target, 50 workers, UDP, random names from the 1M namespace.
All three arms were re-measured against the corrected stack.

| Path | Queries | Achieved QPS | NOERROR | Timeout | p50 | p95 | p99 |
|---|---|---|---|---|---|---|---|
| **PowerDNS 1 direct** (control — no intermediate layer) | 160,453 | **2,674.2** | 160,452 | 1 | **0.438 ms** | 0.559 ms | 0.621 ms |
| **via dnsdist-1** (TARGET path) | 139,528 | **2,325.4** | 139,527 | 1 | **0.555 ms** | 0.683 ms | 0.830 ms |
| **via dnsdist-2** (TARGET path) | 141,781 | **2,363.0** | 141,781 | 0 | **0.549 ms** | 0.660 ms | 0.736 ms |

**dnsdist overhead:** **+0.117 ms p50** through dnsdist-1 and **+0.111 ms** through
dnsdist-2 — **~0.11 ms at p50** over PowerDNS-direct. This reproduces the **~0.097 ms**
figure previously published from the earlier run: a tenth of a millisecond, not a
millisecond, and it is the cost of the hop, not of any policy.

**Note the ceiling of this measurement.** The client's DNS generator caps out near **2.7k
qps** at concurrency 50 — below the 5,000 qps target — on **all three** arms, including
PowerDNS-direct with no proxy in the path. This measures **per-query overhead**, not maximum
DNS throughput, and no DNS capacity figure should be read from it.

**This is a small price for what it buys**: backend health checking, automatic removal of a
failed PowerDNS, automatic reintroduction on recovery, and a single stable resolver address
per node. §5 shows that this is exactly what keeps a PowerDNS outage from moving the VIP.

### Round-robin distribution — verified, not assumed

dnsdist per-backend counters after the earlier DNS run:

```
pdns-1  172.28.0.41:53   queries=23262   drops=0
pdns-2  172.28.0.42:53   queries=23261   drops=0
```

**23,262 vs 23,261 — a 50.00 / 50.00 split.** Explicit round-robin is confirmed by
measurement. Drops: zero. *(The re-run's own counter dump is retained at
`benchmark/results/target-dns-5000qps-dnsdist-servers.json`, but it is truncated at 2,000
bytes — before the per-backend list — so the re-run's split cannot be quoted from it; the
file does record the re-run's UDP frontend at 139,669 queries, consistent with the 139,528
queries the client sent through dnsdist-1 above.)*

### CURRENT's DNS path

CURRENT resolves inside Squid via `dns_nameservers`.

> **CORRECTED (prod-fidelity audit).** Two claims previously made here were wrong about
> production, and both matter:
>
> 1. **The reversed preference is a POC experiment, not production behaviour.** Production
>    configures the **same** nameserver list on both instances. The reversal
>    (squid-1: PDNS1,PDNS2; squid-2: PDNS2,PDNS1) exists only because brief §8 mandates it as
>    an experiment; no production counterpart exists, and the distribution it produces is a
>    property of this POC-only configuration.
> 2. **Production Squid also queries the REMOTE datacenter's nameservers.** Its directive is
>    `dns_nameservers <current-site list> <remote-site list>`, identically on both instances.
>    That second list is a genuine **cross-datacenter DNS fallback**: killing this site's
>    PowerDNS pair does **not** stop production Squid resolving. The POC's one-datacenter
>    boundary (ADR 0002) models only the local pair, and TARGET replaces the whole list with
>    a single local dnsdist and **no fallback at all** — so TARGET does not merely
>    re-implement CURRENT's DNS path, it **narrows** it. That loss is recorded as an
>    **accepted regression** in [ADR 29](adr/0029-target-dns-fallback-regression.md), and it
>    is the reason the "all PowerDNS down → SERVFAIL" scenarios in §4 and §5 are POC-only
>    constructions that have **no production counterpart and are not reproducible against
>    production**.
>
> The measured DNS duplication result below is unaffected by either point: it compares
> per-tunnel against per-request resolution, which the fallback list does not change.

**Not directly addressable as a DNS endpoint**, so it is not in the table above. Its cost is
visible instead in §1: at equal offered load, on the production-faithful stack, CURRENT's
end-to-end p50 is **41.6 ms against TARGET's 34.6 ms** on the same short-lived workload — the
short-lived random-name workload forces a fresh resolution per request on Squid's own resolver,
with no equivalent of HAProxy's resolver `hold valid` cache.

**Measured DNS duplication:** with a random name per request, TARGET issues **one** DNS query
per tunnel rather than per request, because HAProxy's resolver holds positive answers for
`hold valid` (30 s). The production-sized CURRENT run in §2.1 served **2,075,843 `PUT`s over
6,400 tunnels**; the equivalent TARGET topology would issue DNS queries per *tunnel*, not per
*request*. This is the "reduces unnecessary DNS queries" effect the brief asked about, and it
is a direct consequence of resolution living at the proxy rather than at the request handler.

---

## 4. Security policy — measured

Full sweep, all results in `benchmark/results/`.

**TARGET: 26 PASS / 0 FAIL.** All 22 SSRF corpus names plus `nx.test.domain` and
`servfail.test.domain` were refused. Rejections surface as a closed connection (TCP mode has
no HTTP status to return), classified as `tls_error: EOF`, at **p50 1.6–3.9 ms** — the policy
is evaluated before any connection to the destination is attempted.

**DNS rebinding — the decisive test.** `ssrf-rebind.test.domain` carries **two** A records:
one permitted (`172.28.0.60`) and one forbidden (`127.0.0.1`). Over 99 attempts: **50
succeeded, 49 were refused** — and dnsdist was observed returning both orderings, 6 of each.
The decision tracked the **resolved address**, not the name. A hostname-based check would
have passed all 99.

### CURRENT — production Squid performs NO destination validation

> **CORRECTED (prod-fidelity audit).** This report previously published
> "**CURRENT: 26 PASS / 0 FAIL**", described Squid as enforcing "the equivalent policy with
> `acl to_private dst ...` against the resolved address", and called the resulting HTTP 403
> "a cleaner client-visible signal than TARGET's connection close". **All three statements
> are withdrawn: they describe a policy that does not exist in production.**
>
> The 26/26 result was measured against a Squid access-control configuration this POC
> invented. That configuration survives only in `configs/squid/squid-1/squid.conf.hardened` (and
> `squid-2`'s), selected by `SQUID_CONF=squid.conf.hardened`; the **default is now the
> production-faithful `squid.conf`**. Any figure taken from the hardened file may be quoted
> **only** as an explicitly-labelled counterfactual — "what if CURRENT were hardened?" —
> and never as CURRENT's behaviour.

Production Squid's entire access-control policy is:

```
http_access allow env_network CONNECT   # acl env_network src 0.0.0.0/32 -- matches NOTHING. Dead.
http_access allow SSL_ports             # ANY source, ANY method, to 443/445/8443
http_access allow Safe_ports            # ANY source, ANY method, to 80,21,443,445,8443,70,210,
                                        #   1025-65535,280,488,591,777
http_access deny to_localhost           # UNREACHABLE: both allows precede it, neither is
                                        #   source-restricted
```

**Squid is an open forward proxy.** Measured from Squid's own access log, from a source
outside `env_network`:

| CONNECT destination | Squid's verdict | What it means |
|---|---|---|
| `127.0.0.1:443` | `TCP_TUNNEL/503` | **ALLOWED** — `deny to_localhost` is dead; the 503 is the upstream being unreachable, not a refusal |
| `169.254.169.254:443` | `TCP_TUNNEL/503` | **ALLOWED** — the cloud metadata endpoint |
| `192.168.0.1:443` | `TCP_TUNNEL/200` | **ALLOWED** — an RFC1918 tunnel, established |
| `example.com:80` | `TCP_TUNNEL/200` | **ALLOWED** — an arbitrary internet destination, on a plain-HTTP port |
| `<ip>:22` | `TCP_DENIED_ABORTED/403` | the **only** denial observed, and it is purely **port-based** (Squid's default port list) |

Every "CURRENT blocks X" row in `docs/final-validation.md` §4 — loopback, private IPv4,
link-local, the 26/26 SSRF corpus, the resolved-address rebinding decision — is therefore
**wrong for production**: those destinations are permitted. The only control production
CURRENT has is a port allow-list. The old "cleaner client-visible signal" comparison is
moot: production CURRENT never refuses a *destination*, so there is no CURRENT refusal
signal to compare with TARGET's connection close. See
[ADR 28](adr/0028-production-config-fidelity.md).

### Test suites, re-run against the production-faithful CURRENT

Run at production sizing with `SQUID_CONF=squid.conf` (the production-faithful default). The
summaries below are the harness's own; raw output is under `benchmark/results/`.

| Suite | Result | What it establishes |
|---|---|---|
| `b2` CURRENT functional | **13 PASS, 0 FAIL, 0 SKIP** | the CONNECT path, per-request random identity and the in-tunnel mTLS rejections all work end to end against production's config |
| `b4` CURRENT security | **28 PASS, 0 FAIL, 0 SKIP** | the suite **CONFIRMED the open-proxy behaviour** — CURRENT ALLOWS the SSRF corpus. PASS here means "the measurement agreed with the model under test", and the model is production-faithful |
| `F1` fidelity (`tests/fidelity/run.sh`) | **25 PASS, 0 FAIL** | production ACLs against the counterfactual, both Squid models measured side by side |
| `b5` failover | **6 PASS, 1 FAIL, 5 SKIP** | see the open harness defect below — **pre-existing, and not a finding about either architecture** |

Read the `b4` and `F1` numbers carefully: **PASS is a statement about the model, not a
security pass.** Both suites print the model they measured and then confirm it:

```
SQUID_CONF=squid.conf
MODEL UNDER TEST: production-faithful -- OPEN PROXY, no destination validation   [verdict below is valid ONLY for this model]
...
PASS  B4.verdict production-faithful Squid refused NOTHING in the SSRF corpus (open proxy confirmed; 17 allowed, 0 refused, 8 silent)
```

and both the `b4` group log and `tests/fidelity/run.sh` close with a
`FINDING — CURRENT ARCHITECTURE, CONFIRMED VULNERABILITY` banner. So "28 PASS" means *the open
proxy was confirmed on 28 checks*, not that CURRENT passed a security policy.

#### Open harness defect — the failover prober (PRE-EXISTING)

`b5`'s single FAIL is `B5.4 client traffic recovered through haproxy-2`. **This is not caused
by the config corrections**: the identical `6 PASS / 1 FAIL / 5 SKIP` and the identical FAIL
line were recorded in the pre-change run retained at
`benchmark/results/b5-failover-current.stdout`, at the same position in both logs.

Root signature: the background prober records **100 % failure in every scenario** —
`b5.1` 132 failures in 132 samples, `b5.2` 119 in 119, `b5.4` 213 in 213 — so the harness's
baseline check is **always** "no" (`b5 baseline_traffic=no`), while the one-shot probe used
elsewhere in the same run succeeds. The prober instrumentation is not measuring what it claims
to measure.

**This is an open defect in the harness.** It is pre-existing, it is labelled as such, and it
is **not** a finding about CURRENT or about TARGET.

### Defects found by this testing

1. **Squid could not resolve anything.** `dns_nameservers` accepts no port suffix and always
   queries 53, while PowerDNS was listening on 5300. Every CONNECT returned
   `503 ERR_DNS_FAIL`. **CURRENT was entirely non-functional** and the functional suite caught
   it. Fixed by moving the DNS layer to port 53 (safe: each container has its own network
   namespace and nothing is published to the host). This is a real POC defect and is
   unaffected by the fidelity audit — it was found against the then-current Squid
   configuration, and the same defect would have existed against production's ACLs.
2. **`servfail.test.domain` returns NXDOMAIN, not SERVFAIL.** A NATIVE PowerDNS domain with no
   SOA yields NXDOMAIN, not SERVFAIL as the seed comment claimed. The security requirement
   still holds — both are DNS *results* and neither moves the VIP — but the corpus does not
   contain a genuine SERVFAIL and the code comment was corrected. **Note (prod-fidelity
   audit):** this is a property of the POC's DNS corpus. It says nothing about production,
   and no production Squid behaviour can be inferred from it.
3. **The health check could have moved the VIP during a total PowerDNS outage.** The check
   probed a name requiring PowerDNS. With both PowerDNS servers down, dnsdist **drops** the
   query (measured — it does not answer SERVFAIL), so the check failed on *both* nodes; with
   weighted priorities that is 150→90 and 100→40, and whether the VIP moved then depended
   only on which node happened to be active. Fixed by having dnsdist answer the probe
   **locally**, so the check measures dnsdist liveness and nothing else. **Note (prod-fidelity
   audit):** this defect is in TARGET, and it is genuinely TARGET's — TARGET replaces
   production's DNS path with a single local dnsdist and no fallback, so "every PowerDNS
   down" is a real TARGET scenario *and is made sharper by the accepted regression in
   [ADR 29](adr/0029-target-dns-fallback-regression.md)*. For **CURRENT it is a POC-only
   construction**: production Squid's `dns_nameservers` also lists the remote datacenter's
   nameservers, so killing this site's PowerDNS pair does not stop production Squid
   resolving, and this scenario is **not reproducible against production**.
4. **`scripts/up.sh` forwarded its own argument** to `docker compose`, failing with
   `no such service: current`.
5. **`-mode=connect -random-host` emitted unqualified names** (`iotNNNNNNN`, no zone), so the
   DNS-cardinality test queried names that do not exist and Squid correctly answered 503.
   This briefly looked like a Squid DNS limitation. It was a harness bug, and the corrected
   re-run (fixed name 1,126 rps / 28,125 OK vs random name 1,030 rps / 25,708 OK at equal
   offered load) showed no such limitation.

---

## 5. Failover — measured

Timings from Keepalived's own console state transitions. The notify hook's `[vrrp]` lines
proved unusable (busybox `date` has no `%N`, and Keepalived does not forward notify stdout
to the container log) — recorded so the next person does not rebuild that dead end.

> **Suite status (re-run).** The `b5` failover suite returned **6 PASS, 1 FAIL, 5 SKIP**
> against the production-faithful CURRENT. The single FAIL is a **pre-existing harness
> defect, not a failover result** — the background prober records 100 % failure in every
> scenario — and it is written up in §4. The state-transition timings below are the
> measurements this section rests on, and they are unaffected by it.

> **CORRECTED (prod-fidelity audit) — scope of this section.** Every DNS-failure scenario
> below is a **TARGET** scenario, driven by and observed through dnsdist. There is no
> equivalent measurement for CURRENT, and there cannot be one against production: production
> Squid carries this site's *and the remote site's* nameservers, so a local PowerDNS outage
> does not stop it resolving (§3, [ADR 29](adr/0029-target-dns-fallback-regression.md)).
> "PowerDNS failure absorbed without moving the VIP" is therefore a **TARGET property that
> CURRENT already had by a different mechanism in production**, and it should not be read as
> a TARGET improvement unique to this design. TARGET's own path is narrower: one local
> dnsdist, no fallback.

### PowerDNS failure — the VIP must NOT move

| Scenario | dnsdist backend status | Service | VIP owner |
|---|---|---|---|
| `pdns-1` stopped | up → down | still resolving via pdns-2; pdns-2 queries 105 → 109 | **unchanged** |
| `pdns-2` stopped | up → down | 123/123 probes OK | **unchanged** |

120/120 client probes succeeded during the `pdns-1` outage. **Requirement met.** The outage
is absorbed by dnsdist and never reaches HAProxy.

### DNS response errors — the VIP must NOT move

An `NXDOMAIN` storm: **124/124 probes OK, VIP unchanged.** Requirement met.

### Active node's local dnsdist failure — the VIP MUST move

| | |
|---|---|
| Health check | failed on the active node |
| **VIP moved after** | **7,439 ms** |
| Client-observed outage | **6,453 ms** |
| Recovery | traffic resumed through the other node's local dnsdist |

7.4 s is slower than the HAProxy case because it is a *health-check* failure, not an advert
timeout: `interval 2 × fall 2` = ~4 s to detect, plus `3 × advert_int + skew` ≈ 3.6 s to
elect — consistent with the configuration, and tunable.

### Active HAProxy failure (SIGKILL, no graceful VRRP withdraw)

| Architecture | VIP movement |
|---|---|
| TARGET | **2,829 ms** |
| CURRENT | **3,171 ms** |

Both consistent with the VRRP master-down interval (`3 × advert_int + skew` ≈ 3.6 s at
`advert_int 1`) measured directly in this environment.

---

## 6. What this report does not establish

- **The 6,000 rps target is not met for short-lived connections** by either architecture —
  measured at **1,077 rps (CURRENT)** and **1,289 rps (TARGET)** — because of the connection
  model and the single-host generator. It **is** met for persistent tunnels: the
  production-sized CURRENT in §2.1 measured **35,900 rps**.
- **The 10,000-tunnel requirement is unmet where it can be measured, and unmeasurable where it
  might have been met.** CURRENT is capped at **6,400** by production sizing — observed, not
  inferred (§2.1). TARGET's 10,000-tunnel behaviour is **not measured**, because the client's
  `-mode=tls` cannot hold tunnels (§2.4); that scenario's TARGET-arm figures are not comparable
  with CURRENT's and are not offered as a measurement of the requirement.
- **Raising CURRENT's HAProxy ceilings does not fix the shortfall.** The resized variant
  measured *fewer* tunnels and *lower* throughput than production sizing (§2.2). That result
  carries a single-host caveat and is a statement about **POC-host Squid capacity**, not a
  proven production Squid limit.
- **CURRENT's real security posture is measured, and it is an open forward proxy.** Re-run
  against production's verbatim ACLs, the security suite returned 28 PASS / 0 FAIL
  **confirming** that CURRENT allows the SSRF corpus (§4) — the pass count confirms the
  finding, it does not clear it.
- **One harness defect is unresolved.** The failover prober records 100 % failure in every
  scenario, producing `b5`'s single FAIL (§4). It is pre-existing and says nothing about
  either architecture.
- **No soak testing.** Nothing ran longer than 60 s.
- **No network faults** — no packet loss, latency injection or partitioning.
- **Both nodes share one host.** CPU and bandwidth contention between "nodes" is an artefact
  of the POC, and a host failure is not survivable here.
- **Single-host capacity numbers are not production capacity numbers.** Extrapolating from
  one 20-vCPU WSL2 host to production hardware is not defensible and is not attempted.
- **CURRENT's Squid DNS behaviour is characterised indirectly**, through end-to-end latency
  (§1), not as a standalone DNS benchmark. The re-run's attempt to read Squid's own
  cache-manager counters returned `squidclient unavailable`
  (`benchmark/results/current-dns-5000qps-squid1-mgr-dns.txt`, and the same for squid-2), so
  **no cache-manager figure is published** for it.
