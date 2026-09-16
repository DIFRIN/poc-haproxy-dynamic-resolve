# Final validation

Status of every validation item from the brief, and the resulting architectural decision.

**Legend:** ✅ verified with observed evidence · ⚠️ partially verified · ❌ not verified — in
§4 and §7, which are decision tables, ❌ is also used for **the item is not satisfied by that
architecture** (the evidence for that is stated in the cell) ·
🚫 not applicable (the item assumed the original CONNECT-based TARGET, which is not
implementable — see [ADR 0011](adr/0011-target-dynamic-connect.md))

> **Nothing in this document is a claim of production readiness.** It records what was
> run in a single-datacenter POC on one host. §5 lists what remains before any production
> decision.

> ## CORRECTED (prod-fidelity audit)
>
> The **real production HAProxy and Squid configurations were supplied after this document
> was first written**. Three classes of item below do not survive contact with them and are
> marked inline; nothing has been silently rewritten.
>
> 1. **Ports (items 8, 30–44).** CURRENT has two ports on two different numbers:
>    `client --CONNECT--> HAProxy :38888 --tcp relay--> Squid :4443`. The POC modelled one
>    `PROXY_PORT=3128` for both hops and matched neither.
> 2. **CURRENT's security items (39–44).** Production Squid has **no destination
>    validation of any kind** — it is an open forward proxy, measured from its own access
>    log. The resolved-address policy the POC tested and reported as CURRENT's is a
>    **counterfactual** kept in `configs/squid/squid-1/squid.conf.hardened`, not production.
> 3. **10,000 tunnels (items 63, 65, 66, §9).** Production's HAProxy caps concurrent
>    tunnels at **6,400** (`2 × server maxconn 3200`). The requirement is therefore
>    **unreachable for CURRENT as production runs today**, and the POC's 10,000-tunnel /
>    34,241-rps figures were measured against an **over-provisioned, pre-fix CURRENT** that
>    production does not run.
>
> Canonical write-ups: [ADR 28](adr/0028-production-config-fidelity.md) and
> [ADR 29](adr/0029-target-dns-fallback-regression.md).

---

## 1. Infrastructure

| # | Item | Status | Evidence |
|---|---|---|---|
| 1 | Build | ✅ | All 8 images build from this repo |
| 2 | Start CURRENT | ✅ | `./scripts/up.sh current` |
| 3 | Verify HAProxy 1 | ✅ | Container up, config rendered and validated |
| 4 | Verify HAProxy 2 | ✅ | Container up, config rendered and validated |
| 5 | Verify active/passive state | ✅ | `scripts/status.sh`: one ACTIVE, one standby |
| 6 | Only active HAProxy owns VIP | ✅ | Exactly one owner asserted; `wait-ready.sh` fails on zero or two |
| 7 | Standby receives no VIP traffic | ✅ | Standby holds no VIP address, so the VIP is unreachable on it |
| 8 | Verify Squid 1 | ✅ | Serving CONNECT; resolves via PowerDNS |
| 9 | Verify Squid 2 | ✅ | Serving CONNECT — **CORRECTED (prod-fidelity audit):** the "reversed DNS preference" is a brief §8 POC experiment with **no production counterpart**. Production configures the *same* nameserver list on both instances, and that list includes the **remote datacenter's** nameservers (a cross-DC fallback the POC does not model and TARGET removes — accepted regression, [ADR 29](adr/0029-target-dns-fallback-regression.md)) |
| 10 | Verify IoT Mock | ⚠️ | mTLS enforced; rejects a **missing** client cert. The expired and untrusted cases are no longer generated or tested — see the note in §3. |
| 11 | **Boot from an empty volume** | ✅ | **DEFECT FOUND AND FIXED.** `docker compose -f compose.yaml down -v` followed by a start left an **empty database** and the Postgres container exited 3: `01-pdns-schema.sql:157: error: \unrestrict: not currently in restricted mode`. The file is a `pg_dump` capture and carried a trailing `\unrestrict <token>` guard; with `ON_ERROR_STOP=1` (the image's default for init scripts) that aborts initialisation. Removed, with a warning at the top of the file against re-dumping. **This masked itself in every earlier run**, because the named volume already held data and the init scripts never re-ran — the POC's own documented "first boot" path was broken while every subsequent start looked healthy. Re-verified from a genuinely empty volume: schema applies, seed completes, all six `wait-ready.sh` gates pass. |
| 12 | **Re-seed a live database** | ✅ | **DEFECT FOUND AND FIXED.** `02-seed.sh` was not idempotent: a second run died immediately on `duplicate key value violates unique constraint "name_index"` (`domains.name` is UNIQUE), so the README's documented re-seed command could not work. Added a scoped `DELETE FROM domains WHERE name IN (zone, servfail zone)` at the top, which cascades to records via `ON DELETE CASCADE`. On first boot it matches nothing (`DELETE 0`). Measured: ~25 s to rebuild the 1M records, counts unchanged (`A 1000016`, `AAAA 8`, `NS 1`, `SOA 1`). |

## 2. TARGET

| # | Item | Status | Evidence |
|---|---|---|---|
| 11 | Start TARGET | ✅ | `./scripts/up.sh target` |
| 12 | PostgreSQL | ✅ | Healthy; 1,000,000 A records |
| 13 | PowerDNS 1 | ✅ | Answers authoritatively |
| 14 | PowerDNS 2 | ✅ | Answers authoritatively |
| 15 | dnsdist 1 | ✅ | Serving; both backends up |
| 16 | dnsdist 2 | ✅ | Serving; both backends up |
| 17 | Verify health | ✅ | `wait-ready.sh` gates on all of the above |
| 18 | Verify identical DNS data | ✅ | **Same database** — identical by construction, not by replication |
| 19 | Verify representative 1M namespace | ✅ | 1,000,000 records asserted by the seed script |
| 20 | Resolve random IoT names | ✅ | Random identities resolved and routed correctly |

## 3. mTLS

Note: items 27–29 prove the proxy does **not** terminate TLS. With a client certificate
missing, the alert the client receives (`tlsv13 alert certificate required`) is emitted by
the **IoT Mock's** TLS stack. A proxy that had terminated TLS would have emitted that alert
itself and opened a separate session to the backend.

| # | Item | Status | Evidence |
|---|---|---|---|
| 21 | Valid client | ✅ | HTTP 200, body `ok` |
| 22 | Valid server | ✅ | Server cert verifies against the test root CA |
| 23 | Invalid client | ✅ | Rejected at handshake |
| 24 | Missing client | ✅ | `remote error: tls: certificate required` |
| 25 | Expired client | ⛔ **COVERAGE REMOVED** | Was `tls: expired certificate`, using a genuinely expired cert. The expired cert is no longer generated — see the note below. |
| 26 | Invalid server | ✅ | Untrusted server cert rejected by the client |
| 27 | Untrusted server | ⛔ **COVERAGE REMOVED** | Was "rogue CA not in trust store". The rogue CA is no longer generated — see the note below. |
| 28 | End-to-end TLS | ✅ | Alerts originate at the backend |
| 29 | Proxy does not terminate app TLS | ⚠️ | No `ssl`/`ssl_crt`/`ssl_key` anywhere in the repo. Previously proven by 24–27; **now only by 24** (missing client cert), because the expired and untrusted cases were removed. |

> ### ⛔ Negative mTLS coverage was deliberately removed
>
> `scripts/gen-certs.sh` generates the **nominal case only**: a root CA, the IoT Mock's server
> certificate, and one valid client certificate. The earlier PKI also produced a genuinely
> expired client certificate and a second "rogue" CA, which existed solely to drive the failure
> paths above.
>
> **What that costs.** Rows 25 and 27 were the POC's evidence that a bad client certificate is
> rejected *by the IoT Mock's own TLS stack*. That is what distinguished "TLS is end-to-end and
> the proxy never terminated it" from "a proxy terminated TLS and complained itself" — the alert
> had to come from the backend, and with a client certificate that the Mock rejects, it provably
> did. Only row 24 (missing certificate) still tests a rejection path, and it is a weaker signal:
> it proves the Mock *requires* a certificate, not that it *validates* the one presented.
>
> **Row 29 therefore rests on weaker evidence than it used to.** The structural argument still
> holds — no `ssl` directive exists anywhere in either architecture, and HAProxy is in `mode tcp`
> in both, so there is no code path that could terminate TLS. But the *behavioural* proof is now
> thinner than this document previously claimed. Restoring the expired and untrusted certificates
> to `gen-certs.sh` would restore it; the test functions remain in `b1` awaiting them.

## 4. CONNECT

**TARGET items 30–44 are 🚫** — the CONNECT-based TARGET is not implementable (ADR 0011).
The equivalent checks were executed against TARGET's SNI policy and against CURRENT's
CONNECT path. Full results: [benchmark report §4](benchmark-report.md#4-security-policy--measured).

> **CORRECTED (prod-fidelity audit).** The CURRENT column of this table was produced against
> a Squid configuration that **production does not run** (see the audit note at the top of
> this document). Rows 39–44 are therefore rewritten below: production Squid permits every
> one of those destinations. The successes reported in the CURRENT column for rows 39–44
> belong to the **counterfactual** policy in `configs/squid/squid-1/squid.conf.hardened`, selectable
> only via `SQUID_CONF`, and are labelled as such. Also note the client-facing port for every
> CURRENT row: production is **38888**, not the `3128` this POC used.

| # | Item | CURRENT (CONNECT) | TARGET (SNI policy) |
|---|---|---|---|
| 30 | Valid CONNECT | ✅ 200 (via `VIP:38888`) | ✅ 200 (direct TLS) |
| 31 | Dynamic DNS | ✅ | ✅ |
| 32 | HTTPS | ✅ | ✅ |
| 33 | Invalid hostname | ✅ 503 | ✅ refused |
| 34 | DNS timeout | ✅ | ✅ |
| 35 | DNS failure | ✅ | ✅ |
| 36 | NXDOMAIN | ✅ refused | ✅ refused (~1.9 s) |
| 37 | SERVFAIL | ⚠️ **corpus returns NXDOMAIN, not SERVFAIL** | ⚠️ same |
| 38 | Invalid port | 🚫 TCP mode; the client's CONNECT authority pins port 443 by design (the *client-facing* port is 38888) | 🚫 |
| 39 | Private IPv4 | ❌ **NOT blocked** — production Squid allows it (measured `TCP_TUNNEL/200 CONNECT 192.168.0.1:443`); the ✅ 403 belongs to the counterfactual `squid.conf.hardened` | ✅ refused |
| 40 | Loopback | ❌ **NOT blocked** — measured `TCP_TUNNEL/503 CONNECT 127.0.0.1:443`, i.e. allowed and only failing on the unreachable upstream; production's `http_access deny to_localhost` is unreachable because both `allow` lines precede it | ✅ refused |
| 41 | Link-local | ❌ **NOT blocked** — measured `TCP_TUNNEL/503 CONNECT 169.254.169.254:443`, the cloud metadata endpoint; allowed | ✅ refused |
| 42 | IPv6 | ⚠️ AAAA-only names not reachable in TARGET (IPv4-pinned resolver, fail-closed) | ⚠️ |
| 43 | SSRF | ❌ **NOT blocked in production** — SQUID IS AN OPEN FORWARD PROXY with no destination validation of any kind, so there is nothing in the path that could refuse these names. The previously published "✅ 26/26" was measured against the counterfactual `squid.conf.hardened` and is **withdrawn as a statement about CURRENT**; the only control production Squid has is a **port** allow-list (the sole denial observed, from its own access log, was `TCP_DENIED_ABORTED/403` to port 22). No production pass rate is published here because the POC has not run the corpus against the production-faithful config — but the verbatim ACL block contains no destination rule, so the result is determined by construction | ✅ 26/26 |
| 44 | DNS rebinding | ❌ **no resolved-address policy exists in production** (the old "✅ resolved-address policy" entry describes the counterfactual only) | ✅ **50 success / 49 refused from one name — decision tracks the resolved address** |

## 5. DNS HA

> **CORRECTED (prod-fidelity audit) — scope.** Every item below is observed through
> **dnsdist**, i.e. it is a **TARGET** property. There is no equivalent CURRENT measurement,
> and production CURRENT needs none: its Squid has a **cross-datacenter DNS fallback**
> (remote-site nameservers), so a local PowerDNS outage is absorbed there too — by a
> different mechanism. TARGET's path is the narrower one: a single local dnsdist with no
> fallback ([ADR 29](adr/0029-target-dns-fallback-regression.md)).

| # | Item | Status | Evidence |
|---|---|---|---|
| 45 | PowerDNS 1 failure | ✅ | dnsdist marks it down |
| 46 | dnsdist uses PowerDNS 2 | ✅ | pdns-2 queries 105 → 109 |
| 47 | **VIP does not move** | ✅ | **unchanged**; 120/120 client probes OK |
| 48 | Restore PowerDNS 1 | ✅ | Backend reintroduced automatically |
| 49 | PowerDNS 2 failure | ✅ | dnsdist marks it down |
| 50 | dnsdist uses PowerDNS 1 | ✅ | 123/123 probes OK |
| 51 | **VIP does not move** | ✅ | **unchanged** |
| 52 | Restore PowerDNS 2 | ✅ | Reintroduced automatically |

## 6. Proxy HA

| # | Item | Status | Evidence |
|---|---|---|---|
| 53 | Active dnsdist failure | ✅ | Health check failed |
| 54 | Confirm health check failure | ✅ | `VRRP_Script(chk_node) failed` |
| 55 | Confirm VIP moves | ✅ | Moved after **7,439 ms** |
| 56 | Other HAProxy becomes active | ✅ | Verified via `ip addr` |
| 57 | Traffic resumes | ✅ | Client outage **6,453 ms** |
| 58 | Restore dnsdist | ✅ | Node re-eligible; preempts back |
| 59 | Active HAProxy failure | ✅ | SIGKILL, no graceful withdraw |
| 60 | Confirm VIP moves | ✅ | **2,829 ms** (TARGET) / **3,171 ms** (CURRENT) |
| 61 | Standby becomes active | ✅ | Verified |
| 62 | Traffic resumes | ✅ | Verified |

## 7. Performance

The workload is `PUT` with a 256-byte body to an IoT device — the real device-facing
operation. `GET /health` is an infrastructure probe only and is never the measured load.

| # | Item | Status | Result |
|---|---|---|---|
| 63 | 10k simultaneous tunnels | ❌ | **CORRECTED (prod-fidelity audit) — the requirement is UNREACHABLE for CURRENT as production is configured.** Production's HAProxy caps concurrent tunnels at **6,400** (`frontend maxconn 6400`, `backend fullconn 6400`, `2 × server maxconn 3200`), against brief §15's mandatory 10,000. The previously published "**CURRENT: 10,000 tunnels established, 34,241 rps, 0 errors ✅**" is a **pre-fix measurement against an over-provisioned CURRENT** (`maxconn 200000`, no `fullconn`, no per-server cap) that production does not run; the ✅ is withdrawn. A "CURRENT resized" harness variant exists to measure what CURRENT would need, but **no resized run is retained**, so no resized figure is reported. TARGET: **not measured** — the client's `-mode=tls` has no persistent-tunnel implementation, so no comparable number exists and none is reported (TARGET's config does not carry the 3,200-per-server cap, but that is a reading of its config, not a measurement) |
| 64 | Short-lived mTLS | ✅ | CURRENT **1,272.2 rps** / TARGET **1,571.4 rps**, both 100 % HTTP 200, 0 errors. **Note:** the CURRENT leg is a **pre-fix** measurement (single `PROXY_PORT=3128`, counterfactual Squid ACLs); the 200-worker workload never approaches the 6,400-tunnel ceiling, so the connection-model conclusion is unaffected, but the CURRENT leg needs re-running against the production-faithful CURRENT before it is quoted |
| 65 | Persistent mTLS | ⚠️ | 34,241 rps over 10,000 concurrent tunnels — **pre-fix, over-provisioned CURRENT only; not reproducible at production sizing, which caps at 6,400 tunnels** |
| 66 | 6k RPS CURRENT | ⚠️ | Met at **5.7×** with persistent tunnels **against the over-provisioned CURRENT only**; not reached with short-lived connections (connection-model ceiling). Against production sizing the 5.7× cannot be claimed: the tunnel population is capped at 6,400 and no run exists |
| 67 | 6k RPS TARGET | ⚠️ | Same ceiling; TARGET **+23.5 %** faster than CURRENT at equal offered load (again: the CURRENT leg is pre-fix) |
| 68 | DNS-heavy | ✅ | Random-name workload on both |
| 69 | Connection burst | ⚠️ | HAProxy peaked at 16,499 conn/s; no dedicated burst-above-target run |
| 70 | DNS comparison | ✅ | dnsdist overhead **+0.097 ms p50**; round-robin **50.00/50.00** |
| 71 | Collect all metrics | ✅ | Snapshots alongside every run |

## 8. Documentation

| # | Item | Status |
|---|---|---|
| 72 | Benchmark report | ✅ `docs/benchmark-report.md` |
| 73 | Final validation report | ✅ this document |
| 74 | ADRs | ✅ `docs/adr/` — the decision log + the CONNECT finding, plus [ADR 28](adr/0028-production-config-fidelity.md) (production config fidelity) and [ADR 29](adr/0029-target-dns-fallback-regression.md) (DNS fallback regression) written after the prod-fidelity audit |
| 75 | README | ✅ |
| 76 | Limitations | ✅ README §Known limitations, report §6, §5 below |
| 77 | Production recommendations | ✅ §6 below |

---

## 9. Final architectural decision

The brief's question was whether 2 HAProxy + 2 Squid per datacenter can be replaced by
2 HAProxy active/passive + Keepalived + 2 dnsdist + 2 PowerDNS on PostgreSQL.

**As originally specified: no.** HAProxy cannot terminate CONNECT. That is not a tuning
problem; it is a property of the software, proven four ways in ADR 0011.

**As corrected to SNI passthrough: yes, with conditions.** The evidence:

| Dimension | Result |
|---|---|
| Functional correctness | ✅ Both architectures serve the full `PUT` workload end-to-end |
| End-to-end mTLS | ✅ Proven — the proxy never terminates application TLS |
| Dynamic destination selection | ✅ 1M namespace, resolved per tunnel **and address-validated in TARGET** (see the row below: this is now a difference between the architectures, not a shared property) |
| Destination validation | ✅ **TARGET enforces it; production CURRENT does not.** **CORRECTED (prod-fidelity audit):** production Squid is an open forward proxy — no destination ACL, and its `deny to_localhost` is unreachable. TARGET's resolved-address policy is a **new** control, not a replacement of an existing one ([ADR 28](adr/0028-production-config-fidelity.md)) |
| Throughput vs CURRENT | ✅ **+23.5 %**, 100 % success and 0 errors on both — **note:** the CURRENT leg is a **pre-fix** measurement (single `PROXY_PORT=3128`, counterfactual Squid ACLs) and should be re-run against the production-faithful CURRENT before being quoted |
| Median latency vs CURRENT | ✅ **−20.1 %** (108.1 ms vs 135.3 ms) — same pre-fix-CURRENT caveat |
| dnsdist overhead | ✅ **+0.097 ms p50**, under a tenth of a millisecond |
| DNS distribution | ✅ **50.00 / 50.00** round-robin, 0 drops — a property of the **POC-only** reversed `dns_nameservers` experiment (brief §8), not of production |
| DNS fallback | ⚠️ **ACCEPTED REGRESSION.** Production Squid also queries the **remote datacenter's** nameservers; TARGET has one local dnsdist and **no fallback at all**. TARGET narrows CURRENT's DNS path rather than merely re-implementing it — [ADR 29](adr/0029-target-dns-fallback-regression.md) |
| PowerDNS failure | ✅ Absorbed by dnsdist; **VIP does not move** — a TARGET property; in production CURRENT a local PowerDNS outage is absorbed by the remote-site fallback instead |
| DNS response errors | ✅ **VIP does not move** (TARGET; the all-PowerDNS-down construction itself is POC-only for CURRENT — see [ADR 29](adr/0029-target-dns-fallback-regression.md)) |
| Proxy node failure | ✅ VIP moves in 2.8 s (hard) / 7.4 s (health-check) |
| 10k tunnels | ❌ **Unreachable for CURRENT as production is configured** (hard ceiling **6,400** = `2 × server maxconn 3200`). The previously cited 34,241 rps / 10,000 tunnels is a **pre-fix, over-provisioned-CURRENT** measurement and is withdrawn as evidence for CURRENT; TARGET is **not measured** at this scenario |
| Component count | ✅ Squid layer **removed entirely** — one fewer process, same tunnel-termination function |

### Verdict

```
TARGET RECOMMENDED WITH CONDITIONS
```

**Conditions — all of which must be satisfied before migration:**

1. **The entire IoT fleet must change how it connects — in two ways, and both must be
   sequenced.** TARGET requires clients to open TLS directly to the VIP with
   `SNI = iotNNNNNNN.test.domain`, instead of issuing `CONNECT`; **and the client-facing
   port moves from `38888` (production CURRENT's CONNECT listener) to `443` (TARGET's TLS
   listener, and the IoT Mock's HTTPS port).** This is the single largest cost and the
   primary risk. It is a coordinated firmware change across every device, and it is **not**
   designed here — sequencing, rollback and the transition period are unresolved
   ([ADR 0027](adr/README.md#27-production-migration--open)). *The port change was missing
   from earlier revisions of this document; it is not optional and it is not covered by a
   protocol-level dual-stack period alone.*
2. **Client-visible rejection changes shape — as a NEW control, not a changed signal.**
   **CORRECTED (prod-fidelity audit):** the earlier claim here was that "CURRENT returns
   `HTTP 403` on a refused CONNECT; TARGET closes the connection". That is wrong about
   production. Production CURRENT has **no destination validation at all** and never refuses
   a destination; its only `403` is **port-based** (a CONNECT to a port outside Squid's
   default list, e.g. 22). TARGET therefore **introduces** destination refusal where
   CURRENT had none, and it does so by closing the connection because TCP mode has no HTTP
   status to return. Two distinct consequences must be handled: clients begin to see refusals
   they never saw before, and those refusals are indistinguishable from "unreachable" at the
   socket level unless the client is taught otherwise.
3. **Resolve the named capability gaps before committing:** IPv6 destination support
   (currently fail-closed), a genuine SERVFAIL in the test corpus, demonstrated TARGET
   behaviour at 10,000 concurrent tunnels, and a decision on the **lost cross-datacenter DNS
   fallback** ([ADR 29](adr/0029-target-dns-fallback-regression.md), currently accepted as
   a regression).
4. **Validate on real hardware.** Two VIP-sharing nodes on one WSL2 host is not a
   production topology. Multicast VRRP, switch behaviour, physical link failure and real
   per-node CPU/memory must be validated on real hosts — steps in §10.

**Why not "RECOMMENDED" without conditions:** the 10k-tunnel requirement is **unmet by both
architectures as measured** — **unreachable for CURRENT** as production is configured today
(a hard 6,400 ceiling, [ADR 28](adr/0028-production-config-fidelity.md)) and
**undemonstrated for TARGET** — the migration is fleet-wide and undesigned, the cross-DC DNS
fallback loss is unresolved, and no soak or network-fault testing was performed. **The
verdict is unaffected by the prod-fidelity corrections, but its weight has moved:** the
"keep CURRENT" alternative is now weaker than this document originally implied, because
production CURRENT (a) does not meet the mandatory concurrency requirement without resizing,
and (b) has **no SSRF protection at all**.

**Why not "NOT RECOMMENDED":** as specified, TARGET is impossible — but the corrected
architecture is faster than CURRENT at every measured point (with the CURRENT leg still a
pre-fix measurement, see §7), removes an entire shared-fate component, shows negligible
DNS-layer overhead, and meets every failover and DNS failure semantic the brief requires.
Recommending against it would mean recommending the retention of a proxy layer that is
measurably slower and structurally riskier, purely because the original proposal named the
wrong mechanism.

---

## 10. Remaining production validation requirements

Not one of these is satisfied by this POC.

**Infrastructure**
1. Deploy on real hosts — 2 physical HAProxy nodes per datacenter, separate failure domains.
2. Real **multicast** VRRP (this POC uses unicast; see ADR 0005), with switch IGMP snooping
   verified and a **fencing or quorum strategy** for split-brain. The POC has no fencing and
   does not evaluate one.
3. Physical link failure, NIC failure, and power loss.
4. Real per-node capacity planning — this POC's numbers come from one shared 20-vCPU host.

**Migration**
5. Design the fleet-wide client migration: staged rollout, per-device rollback, a dual-stack
   period where both CONNECT and direct-TLS clients are served, and a way to observe which
   clients have migrated. **The change is two-dimensional:** the protocol (`CONNECT` →
   direct TLS with SNI) **and the port (`38888` → `443`)**. A dual-stack period that serves
   both protocols on their existing ports (38888 for CONNECT, 443 for TLS) must be designed
   explicitly, because the two are *not* on the same port today.
6. Decide whether CURRENT and TARGET must coexist during transition, and if so how one VIP
   serves both.
7. **Resolve the DNS fallback regression or accept it explicitly.** Production CURRENT
   resolves via this site's *and* the remote datacenter's nameservers; TARGET has one local
   dnsdist and no fallback. Either a remote-site resolver is added to the TARGET path or the
   narrower DNS path is signed off as a deliberate reduction in resilience —
   [ADR 29](adr/0029-target-dns-fallback-regression.md) currently records it as
   **accepted**, which is a decision to revisit before migration.
8. **Decide CURRENT's fate on its own merits, now that its real posture is known.**
   Production CURRENT is an open forward proxy (no SSRF protection) and cannot reach 10,000
   tunnels without resizing. Keeping it therefore requires *both* a hardening project
   (`configs/squid/squid-1/squid.conf.hardened` is the only working example) *and* a capacity
   change; that combined cost has never been estimated.

**Load and failure**
9. TARGET at 10,000 concurrent tunnels under a harness that implements persistent reuse.
10. **CURRENT at production sizing, and the "CURRENT resized" variant** — measure where the
    6,400 ceiling actually binds, and measure what CURRENT would need to reach 10,000 tunnels
    ([ADR 28](adr/0028-production-config-fidelity.md)). No run of either is retained today.
11. Multi-hour soak at target load; memory and FD growth over time.
12. Network faults: packet loss, latency, MTU, asymmetric partitions.
13. Cascading and combined failures — e.g. one PowerDNS down *and* the active local dnsdist
    failing simultaneously.
14. Certificate rotation and expiry handling under live traffic.

**Security**
15. Review TARGET's destination policy against the real production allow-list. **CORRECTED
    (prod-fidelity audit):** the POC's RFC1918 exception for the IoT endpoint range (ADR
    0022) is a POC artefact and must not be carried into production — that part stands — but
    note the exception now lives **only in TARGET and in the labelled counterfactual**
    (`squid.conf.hardened`). Production CURRENT has **no** destination policy to review and
    no allow-list to reconcile: it permits every destination on a permitted port.
16. IPv6 destination support, or an explicit documented decision to remain IPv4-only.
17. Penetration testing of the SNI-based routing path, including SNI manipulation and
    ClientHello fragmentation.
18. **SSRF review of the production CURRENT path.** The production Squid is an open forward
    proxy (measured, [ADR 28](adr/0028-production-config-fidelity.md)). Whether that is an
    accepted exposure, a compensating control elsewhere in the estate, or a defect to fix in
    CURRENT is a decision this POC cannot take. It is the strongest security argument for
    migration, and it was invisible before the real config was supplied.

**Operational**
19. Monitoring and alerting thresholds derived from production baselines, not from this POC.
20. Runbooks for each failover scenario, validated by game-day exercises.
21. Capacity headroom policy for an active/passive pair — the standby contributes no
    capacity, so one node must carry full production load alone. At production sizing that
    node's ceiling is 6,400 concurrent tunnels, not 10,000.
