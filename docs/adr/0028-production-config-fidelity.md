# 28. Production config fidelity — what the real HAProxy and Squid configs changed

**Status.** Accepted. Supersedes the production assumptions in ADR 9 (CURRENT uses Squid),
ADR 10 (CURRENT Squid DNS behaviour) and ADR 22 (Destination security policy) wherever
those were derived from the brief rather than from the production configuration.

---

## Context

The POC was built from the brief alone. The brief describes the production *architecture*
correctly — two HAProxy, one VIP, a common Squid layer, two PowerDNS — but it does not
contain the production *configuration*. Where the POC needed a concrete value it inferred
one, and documented the inference as an open question:

> "if the real production Squid carries no equivalent configuration, then CURRENT has no
> SSRF protection whatsoever… **and it must be confirmed against the real Squid
> configuration before being relied on.**" — `docs/architecture.md` §4

The real production HAProxy and Squid configurations were then supplied. This ADR records
what they show. Three of the POC's load-bearing assumptions do not survive, one security
question is answered, and one mandatory requirement turns out to be unreachable in the
architecture the POC was comparing against.

Everything below was verified against the real configs, not inferred. The HAProxy findings
were produced with HAProxy 3.0.27 (the version this repository pins, `haproxy:3.0-alpine`),
and the Squid findings with Squid on Alpine 3.20 running the production ACL block verbatim.

---

## Finding 1 — CURRENT has TWO ports, and the POC modelled one

Production:

```
frontend frontend_proxyhttp
    bind :38888
    mode tcp
    use_backend backend_proxyhttp
    ...
backend backend_proxyhttp
    server backend_proxyhttp_1 iode-squid-1-svc.ic1-stg.noe.ddd.com:4443 maxconn 3200 check no-check-ssl
    server backend_proxyhttp_2 iode-squid-2-svc.ic1-stg.noe.ddd.com:4443 maxconn 3200 check no-check-ssl
```

Squid's own listener is templated — `http_port {{ role_squid_proxy_port }}` — and HAProxy
targets `:4443`, so that is its value.

The POC used a single variable, `PROXY_PORT=3128`, for **both** the client-facing CONNECT
listener and the HAProxy→Squid hop. Neither number matched production, and collapsing two
ports into one is a structural defect rather than a typo: it makes it impossible to express
the production topology at all.

**Corrected.** `CLIENT_PORT` (default 38888) is the client-facing CONNECT listener;
`SQUID_PORT` (default 4443) is Squid's listener and the proxyhttp backend target. Clients
never reach Squid directly, in production or in the POC.

---

## Finding 2 — The real Squid has no destination validation. It is an open forward proxy.

This is the most consequential finding, and it closes the open question quoted above.

Production's entire access-control policy, verbatim:

```
acl to_localhost dst 127.0.0.0/8 0.0.0.0/32 ::1 {{ ansible_default_ipv4.address }}
acl env_network   src 0.0.0.0/32

acl SSL_ports port 443 / 445 / 8443
acl Safe_ports port 80 21 443 445 8443 70 210 1025-65535 280 488 591 777
acl CONNECT method CONNECT

http_access allow env_network CONNECT
http_access allow SSL_ports
http_access allow Safe_ports
http_access deny to_localhost
```

Read it as Squid does:

- `env_network` is `src 0.0.0.0/32`, which matches **no packet that can exist**. The one
  rule that looks like a source restriction is therefore dead.
- `http_access allow SSL_ports` and `http_access allow Safe_ports` are **not**
  source-restricted and **not** method-restricted. They allow any client, using any method,
  to reach any of those ports. `Safe_ports` includes `1025-65535` — effectively every
  unprivileged port.
- `http_access deny to_localhost` sits **after** both allows. Every request it could have
  caught has already been allowed, so it never fires. It is unreachable code.

**Measured.** Squid's own access log, with the client on an address outside `env_network`:

```
172.31.0.99 TCP_TUNNEL/503        CONNECT 127.0.0.1:443        HIER_DIRECT/127.0.0.1
172.31.0.99 TCP_TUNNEL/503        CONNECT 172.31.0.10:443       HIER_DIRECT/172.31.0.10
172.31.0.99 TCP_TUNNEL/503        CONNECT 169.254.169.254:443   HIER_DIRECT/169.254.169.254
172.31.0.99 TCP_TUNNEL/200        CONNECT 192.168.1.1:443       HIER_DIRECT/192.168.1.1
172.31.0.99 TCP_TUNNEL/200        CONNECT example.com:80        HIER_DIRECT/104.20.23.154
172.31.0.99 TCP_DENIED_ABORTED/403 CONNECT 172.31.0.10:22      HIER_NONE/-
```

`TCP_TUNNEL` means **allowed** — Squid proceeded to open the tunnel. Reading the rows:

- **`127.0.0.1:443` and the Squid's own address: allowed.** Both are listed in
  `acl to_localhost`, and `deny to_localhost` still never fired. This is the direct proof
  that the rule is unreachable, and it is the classic SSRF-to-loopback case.
- **`169.254.169.254:443`: allowed.** This is the cloud instance-metadata endpoint — the
  single most valuable SSRF target in a cloud environment.
- **`192.168.1.1:443`: `TCP_TUNNEL/200`** — a tunnel was actually *established* to an
  RFC1918 address.
- **`example.com:80`: allowed** — it is a functioning open forward proxy to the internet.
- **`172.31.0.10:22`: the only denial**, and it is purely port-based. Port 22 is absent
  from `Safe_ports`, so Squid's implicit default-deny caught it.

The same behaviour was confirmed end-to-end through the real HAProxy config on `:38888`,
not merely by talking to Squid directly.

**So: CURRENT has zero destination validation.** The only thing refusing anything is
Squid's default port list, which is not a security control — it is a list of ports that a
default Squid installation considers safe to fetch from.

### What this does to the POC's security comparison

The POC had invented a resolved-address policy (`acl to_private dst …`,
`acl iot_endpoints dst …`, `acl localnet src …`) in `configs/squid/squid-*/squid.conf` and then
reported CURRENT as **26 PASS / 0 FAIL** on the SSRF corpus, refusing with `HTTP 403`, and
described that 403 as "a cleaner client-visible signal than TARGET's connection close, and a
genuine operational difference between the two."

**That policy does not exist in production.** The comparison was therefore measuring a
hardened CURRENT that is not deployed, and it was biased *against* TARGET: the POC gave
CURRENT a control it does not have, then compared it to TARGET's real one.

The corrected picture inverts the security argument:

| | Destination validation | Refuses loopback / metadata / RFC1918 |
|---|---|---|
| CURRENT (production) | none | nothing |
| CURRENT (counterfactual, hardened) | resolved-address `dst` ACL | yes, `403` |
| TARGET | resolved-address policy on `txn.dstip` | yes, connection closed |

TARGET's destination policy is **net-new security capability, not a re-implementation**. In
CURRENT there is no policy to migrate; there is a hole to close. That is a stronger argument
for TARGET than the POC previously made, and it rests on measurement rather than on the
brief's intent.

One honest qualification survives: the counterfactual file shows that resolved-address
validation **is** implementable in Squid, so it is not true that only TARGET can do it. If
the decision were taken to keep CURRENT and harden it, the control is available — but it
must then be hand-maintained as bespoke Squid configuration, whereas in TARGET the same
control falls out of the resolution the proxy already performs in order to route.

**Decision.** The production-faithful policy is now `configs/squid/squid-1|2/squid.conf` and is the
**default** (`SQUID_CONF=squid.conf`). The invented policy is retained verbatim as
`configs/squid/squid-1|2/squid.conf.hardened`, explicitly labelled a counterfactual, so the
"what if CURRENT were hardened?" comparison remains available without misrepresenting what
CURRENT does today. No result may be attributed to CURRENT without stating which of the two
produced it.

---

## Finding 3 — Production CURRENT cannot carry 10,000 tunnels

Production sizing:

```
global   maxconn  10000
frontend maxconn   6400
backend  fullconn  6400
server   maxconn   3200   (x2 Squid)
```

`maxconn` on a server is a hard cap on concurrent connections to that server, and a CONNECT
tunnel holds one connection for its lifetime. Two Squids at 3200 therefore cap the
datacenter at **6,400 concurrent tunnels**, and the frontend's own `maxconn 6400` caps it
independently at the same number.

**Measured** to confirm the semantics rather than assume them: offering 10 concurrent
connections against declared per-server `maxconn 2` yielded exactly 4 established
(s1=2, s2=2) — the declared value, no overshoot.

Brief §15 makes **10,000 simultaneous CONNECT tunnels mandatory** (restated as non-negotiable
rule 25). So:

> **The mandatory 10,000-tunnel requirement is unreachable in CURRENT as production is
> configured today.** Not "unmet under the POC's load generator" — unreachable, by
> configuration, at 6,400.

This matters because the POC had run its CURRENT arm with `maxconn 200000`, no `fullconn`
and no per-server cap — 31× the real frontend limit — and reported:

> "Tunnels established: **10,000** (exactly one per worker; 10,000 × HTTP 200 on CONNECT,
> 0 failures)" … "the 10,000-tunnel requirement is **demonstrated for CURRENT** and
> **undemonstrated for TARGET**."

Both halves of that sentence are wrong against the real config. "Demonstrated for CURRENT"
described a proxy that production does not run; against production's own numbers the
requirement is not merely undemonstrated for CURRENT — it is impossible. The accompanying
34,241 rps headline and the 5.7× headroom claim were taken at that same unreachable
concurrency and inherit the same invalidation.

The existing report already attributed the shortfall it *did* see to "a **generator** limit,
not a proxy limit — 10,000 real IoT devices each have their own address and never contend."
That reasoning is correct about source-port exhaustion and wrong about what the proxy would
do next: the 10,000 devices would contend, because only 6,400 of them can hold a tunnel.

**Decision.** The POC's CURRENT now reproduces production's exact ceilings by default
(`CURRENT_GLOBAL_MAXCONN`, `CURRENT_FRONTEND_MAXCONN`, `CURRENT_FULLCONN`,
`CURRENT_SERVER_MAXCONN`), so the measured architecture is the deployed one. A
**"CURRENT resized"** variant exists to answer the fair follow-up — *what would CURRENT need
in order to meet the requirement?* — which is a question about re-sizing an existing
platform, and is the honest form of the comparison the brief asks for.

The 10,000-tunnel figures in the benchmark report are marked as pre-fix measurements taken
against an over-provisioned CURRENT. They are not deleted — they are still the correct
answer to "can this mechanism carry 10,000 tunnels?", which is what TARGET needed to prove —
but they are no longer evidence about CURRENT as deployed.

---

## Finding 4 — `option http-keep-alive` in a TCP frontend is inert

Production sets, inside a `mode tcp` frontend *and* a `mode tcp` backend:

```
option  http-keep-alive
timeout http-keep-alive 2s
```

`http-keep-alive` is an HTTP-mode option. In TCP mode HAProxy does not parse HTTP at all.
Verified both ways:

- **Parse:** HAProxy 3.0.27 config-checks the real config with **zero warnings and zero
  errors** — the directive is accepted silently. (A deliberately broken config was checked
  alongside it to confirm error output does surface.)
- **Behaviour:** an end-to-end test with the real config in front of the real Squid ACLs
  shows HAProxy relaying the byte stream opaquely. Squid's own `403` and `503` responses
  reached the client unchanged, and HAProxy's log is in `tcplog` format
  (`frontend_proxyhttp backend_proxyhttp/backend_proxyhttp_1 …`). Had the proxy been in HTTP
  mode it would have interpreted the CONNECT itself and, per ADR 11, relayed it upstream
  awaiting a `2xx` — the failure mode this POC already measured and ruled out.

So these two directives do nothing. They are reproduced in the POC's CURRENT template so
that the config under test matches production byte-for-byte, and flagged so that no reader
mistakes them for a working keep-alive policy. Their presence suggests the config was
carried over from an HTTP-mode configuration, or that keep-alive was believed to be doing
something it cannot do in TCP mode. Either way it is worth raising with the team that owns
it: a directive that reads like a policy but has no effect is a maintenance hazard.

---

## Finding 5 — Production directives the POC never modelled

Recorded for completeness, since "full comprehension of the actual architecture" is the
point. None of these is a defect in the POC; each is a place where the POC simplified, and
the simplification is now explicit rather than silent.

| Production | POC | Effect of the difference |
|---|---|---|
| `timeout connect 1m` | `5s` | POC fails a slow Squid accept faster than production would |
| `log 127.0.0.1 local1` (syslog) | `log stdout` | POC deviation, deliberate: keeps evidence in `docker logs` |
| `stats` on `127.0.0.1:15080` | `NODE_IP:8404` + Prometheus | POC addition for scraping; production's loopback listener is now modelled alongside |
| `retries 3` + `option redispatch` | `retries 2`, no redispatch | redispatch is what retries a CONNECT on the surviving Squid — now modelled |
| `ulimit-n 65536` | container `nofile` ulimit | now modelled; must stay ≥ this or HAProxy refuses to start |
| `no-check-ssl` | absent | deprecated no-op on a plain TCP check; now reproduced |
| `stats auth : <password>` | named user | production's **empty username** is accepted by HAProxy but is a config smell; POC diverges deliberately |
| `option http-keep-alive` | absent | inert (Finding 4); now reproduced and documented |

---

## Consequences

1. **Prior CURRENT benchmark results are invalidated** wherever they depend on an
   over-provisioned `maxconn`, on a Squid destination policy that production lacks, or on
   the `3128` port model. Affected figures are annotated in `docs/benchmark-report.md` and
   `docs/final-validation.md` rather than silently rewritten.
2. **The security conclusion reverses direction and strengthens.** CURRENT has no
   destination validation; TARGET's is net-new. The POC's earlier framing — that CURRENT
   refuses CONNECT with a cleaner `403` — described a configuration nobody runs.
3. **The 10,000-tunnel requirement is reframed.** It is unreachable for CURRENT as
   deployed, which is a finding about production sizing, and the "resized" variant is the
   fair form of the comparison.
4. **One question is now closed.** `docs/architecture.md` §4 asked whether production Squid
   carries an equivalent control. It does not. That section is corrected.
5. **What this does not change.** The CONNECT finding (ADR 11), the SNI-passthrough
   correction, end-to-end mTLS, the 1M namespace, dnsdist/PowerDNS behaviour and the
   failover model are all unaffected — they were derived from measurement and from the
   brief, not from the production config's concrete values.

## What remains to be confirmed

- Whether the production Squid `http_access` block is genuinely as supplied at every site,
  or whether a site-local include adds restrictions. The block reproduces exactly what was
  provided.
- Whether the 6,400-tunnel ceiling is a deliberate sizing decision with a documented
  rationale, or drift. If production genuinely needs 10,000 concurrent tunnels today, this
  is a live capacity incident independent of this POC.
- The intent behind `option http-keep-alive`. Removing it changes nothing; leaving it
  invites the belief that it does something.
