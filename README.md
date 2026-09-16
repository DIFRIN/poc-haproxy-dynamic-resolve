# POC — replacing the Squid proxy layer with HAProxy + dnsdist + PowerDNS

A one-datacenter proof of concept answering one question:

> Can the production proxy layer — **2 HAProxy nodes + 2 Squid instances per datacenter** —
> be replaced by **2 HAProxy nodes in active/passive + Keepalived + 2 local dnsdist + 2
> PowerDNS authoritative servers backed by PostgreSQL**, while preserving end-to-end mTLS,
> a 1-million-device DNS namespace, 10,000 simultaneous tunnels, and 6,000 requests/sec?

Everything here is built to be run and measured, not asserted. Where a number appears in this
repository it was produced by a command in this repository. Where something was not measured,
it says so.

**Headline result: TARGET is recommended with conditions.** It holds 10,000 simultaneous
tunnels with zero errors, where production-sized CURRENT is measured at a hard 6,400 ceiling.
It is ~20% faster on short-lived requests. But it drops a cross-datacenter DNS fallback that
production has today, and the client fleet must change both protocol and port. The full
reasoning, with the numbers, is in **[docs/benchmark-report.md](docs/benchmark-report.md)** and
**[docs/final-validation.md](docs/final-validation.md)**.

---

## The two architectures

Both run **exactly one datacenter**: 2 HAProxy nodes, 2 Keepalived, 1 floating VIP. In both,
only the node owning the VIP receives client traffic.

### CURRENT — HAProxy in front of the shared Squid layer

```
client ──CONNECT──▶ VIP:38888 ──▶ haproxy-1 (ACTIVE) ──tcp relay──▶ squid-1:4443
                                  haproxy-2 (STANDBY)               squid-2:4443
                                                                        │
                                              resolve + CONNECT tunnel   │
                                                                        ▼
                                                          IoT Mock :443 (mTLS)
```

Clients CONNECT to **38888**; HAProxy relays to Squid on **4443**. Clients never reach Squid
directly. Squid terminates the CONNECT, resolves the destination name, and tunnels — it is a
tunnel terminator, not a cache and not a policy engine (`cache deny all`).

Two things about CURRENT matter and are measured, not assumed:

- **It is an open forward proxy with no destination validation.** Production's Squid has no
  `dst` ACL; its `deny to_localhost` sits after two source- and method-unrestricted allows and
  is unreachable. CONNECT to loopback, to `169.254.169.254` and to RFC1918 all succeed. See
  [ADR 28](docs/adr/0028-production-config-fidelity.md).
- **It caps at 6,400 concurrent tunnels.** Production sizes each Squid at `maxconn 3200`, so
  the pair cannot hold the 10,000 that brief §15 makes mandatory. Offering 10,000 establishes
  exactly 6,400.

### TARGET — SNI passthrough, Squid removed

```
client ──TLS, SNI=iotNNNNNNN.test.domain──▶ VIP:443 ──▶ haproxy-1 (ACTIVE)
                                                        haproxy-2 (STANDBY)
                                                              │
                                          do-resolve + validate + set-dst
                                                              ▼
                                                   IoT Mock :443 (mTLS)
```

HAProxy reads the SNI from the ClientHello **without terminating TLS**, resolves it through its
local dnsdist, validates the **resolved address** against the destination policy, sets the
destination, and tunnels raw TLS. mTLS is end-to-end between client and IoT Mock; no component
in the path holds a key or sees plaintext.

> The original TARGET — dynamic `CONNECT` in HAProxy — **is not implementable.** HAProxy relays
> CONNECT to an upstream and requires that upstream to answer `2xx`; it never originates
> `200 Connection established`. Full evidence in
> [docs/adr/0011-target-dynamic-connect.md](docs/adr/0011-target-dynamic-connect.md). SNI
> passthrough delivers the same intent and removes Squid entirely.

---

## Requirements

- Docker Engine 24+ with Compose v2, on Linux (developed on WSL2, kernel 6.18, 20 vCPU / 31 GB)
- `NET_ADMIN`, `NET_RAW`, `NET_BROADCAST` for the HAProxy nodes (granted explicitly in the
  compose files; `privileged: true` is **not** used)
- ~4 GB RAM free, ~3 GB disk for images and the PostgreSQL volume
- `python3` on the host, for `scripts/report.py`

---

## How to run

### 1. Configure

```bash
cp .env.example .env
```

`.env` holds the whole address plan and every tunable. The only values most people touch are
the ports and `SQUID_CONF`. Sensible defaults are already in place; nothing needs editing to
run TARGET.

### 2. Generate the certificates

```bash
./scripts/gen-certs.sh
```

Creates `pki/` — a root CA, the IoT Mock's server certificate (SAN `*.test.domain`), and one
valid client certificate. **`pki/` is gitignored** and holds private keys; regenerate it rather
than committing it. `./scripts/up.sh` runs this for you if `pki/` is missing.

> The generator produces the **nominal case only**. Earlier revisions also produced an expired
> client cert and a rogue-CA-signed cert, used to prove the IoT Mock *rejects* bad certificates
> — which is how the POC demonstrated that the TLS alert comes from the Mock's stack and not
> from a proxy that had terminated TLS. Those were deliberately dropped to keep the PKI simple.
> **That negative coverage is gone**; it is recorded in
> [docs/final-validation.md](docs/final-validation.md).

### 3. Bring up TARGET (the nominal run)

```bash
docker compose up -d
```

That is the whole thing — `compose.yaml` is TARGET, it is self-contained, and it takes no
profiles. Or use the wrapper, which adds a readiness gate and a status report:

```bash
./scripts/up.sh target
```

`up.sh` waits until the stack is genuinely ready — the full 1M-record seed finished, both
PowerDNS servers answering for the zone, **exactly one** node owning the VIP, and the IoT Mock
healthy. First boot seeds 1,000,000 DNS records (measured: **~27 s**); the data lives in a named
volume, so later runs skip it.

### 4. Bring up CURRENT (the comparison)

```bash
./scripts/up.sh current
```

Equivalent to `docker compose -f compose.current.yaml up -d`. Only one architecture runs at a
time — they share the VIP and the node addresses, so both at once would be two nodes fighting
over one VIP. `up.sh` tears down the other stack automatically when you switch.

### 5. Check status and tear down

```bash
./scripts/status.sh      # containers, and WHO OWNS THE VIP
./scripts/down.sh        # stop everything, keep the database volume
```

To wipe the dataset and force a fresh seed:

```bash
docker compose -f compose.yaml down -v
```

---

## Simple usage — one request, by hand

Everything runs in Docker, brought up by the nominal compose file. **The IoT Mock is a normal
service in that stack** — it starts with everything else and is not something you run
separately:

```bash
docker compose up -d          # nominal TARGET stack, IoT Mock included
./scripts/status.sh           # containers, and who owns the VIP
```

The examples below assume that stack is up. They are what a real IoT device does, and they are
the fastest way to confirm a change has not broken anything.

### One request with `curl`, from inside a container

The stack lives on its own Docker network, so the simplest approach is a throwaway container
attached to it — which also gives you a shell to poke around in:

```bash
NET=$(docker network ls --format '{{.Name}}' | grep dc-lan | head -1)
docker run --rm -it --network "$NET" -v "$PWD/pki:/pki:ro" alpine:3.20 sh
```

Then, inside it:

```sh
apk add -q curl

# TARGET — TLS straight to the VIP, the device name as SNI
curl -sS -o /dev/null -w "%{http_code}\n" \
  --resolve iot0000001.test.domain:443:172.28.0.10 \
  --cert /pki/clients/client-valid.crt --key /pki/clients/client-valid.key \
  --cacert /pki/ca/ca.crt \
  -X PUT --data-binary "telemetry" https://iot0000001.test.domain/
# -> 200

# CURRENT — the same request through the CONNECT proxy on 38888
curl -sS -o /dev/null -w "%{http_code}\n" \
  --proxy http://172.28.0.10:38888 \
  --cert /pki/clients/client-valid.crt --key /pki/clients/client-valid.key \
  --cacert /pki/ca/ca.crt \
  -X PUT --data-binary "telemetry" https://iot0000001.test.domain/
# -> 200
```

For TARGET, `--resolve` is the part that matters: it makes curl connect to the **VIP** while
still sending `iot0000001.test.domain` as the SNI and `Host` — which is exactly what HAProxy
routes on. The device name is never resolved by the client; that is HAProxy's job.

For CURRENT, curl issues `CONNECT iot0000001.test.domain:443`; Squid resolves the name and opens
the tunnel, and the TLS handshake happens **inside** it, end to end to the IoT Mock. Nothing
terminates TLS but the Mock itself.

Note the client certificate is passed with `--cert`/`--key`, **not** `--proxy-cert`/`--proxy-key`.
The `--proxy-*` pair authenticates curl *to the proxy*, on the hop to Squid; it says nothing
about the origin, so the Mock — which requires a client certificate — rejects the handshake with

```
tlsv13 alert certificate required
```

That error is worth recognising: it means the tunnel was established correctly and the failure
is the origin's mTLS, not a proxy fault. Squid here is an open forward proxy and asks for no
client certificate of its own.

Add `-v` and drop `-o /dev/null` to watch the CONNECT exchange rather than just its result. This
is the visible proof that TLS is tunnelled rather than terminated — note that the handshake, and
the certificate the Mock presents, come *after* the tunnel is established:

```
> CONNECT iot0000001.test.domain:443 HTTP/1.1
< HTTP/1.1 200 Connection established
* CONNECT tunnel established, response 200
* SSL connection using TLSv1.3 / TLS_AES_128_GCM_SHA256
*  subject: C=FR; O=POC; CN=iot-mock.test.domain
*  subjectAltName: host "iot0000001.test.domain" matched cert's "*.test.domain"
*  issuer: C=FR; O=POC; CN=POC Test Root CA
> PUT / HTTP/1.1
< HTTP/1.1 200 OK
```

Nothing in that exchange is Squid's certificate: the subject is the IoT Mock's.

### The same requests directly from the host

The host routes to the stack's network, so you do not need a container at all — just the
certificates and the same `--resolve`:

```bash
cd <repo>

# TARGET
curl -sS -o /dev/null -w "%{http_code}\n" \
  --resolve iot0000001.test.domain:443:172.28.0.10 \
  --cert pki/clients/client-valid.crt --key pki/clients/client-valid.key \
  --cacert pki/ca/ca.crt \
  -X PUT --data-binary "telemetry" https://iot0000001.test.domain/
# -> 200

# CURRENT
curl -sS -o /dev/null -w "%{http_code}\n" \
  --proxy http://172.28.0.10:38888 \
  --cert pki/clients/client-valid.crt --key pki/clients/client-valid.key \
  --cacert pki/ca/ca.crt \
  -X PUT --data-binary "telemetry" https://iot0000001.test.domain/
# -> 200
```

The IoT Mock also exposes a plain-HTTP health probe, which separates "the backend is up" from
"the proxy path is broken":

```bash
curl -sS http://172.28.0.60:9090/health && echo
```

`GET /health` works through both proxy paths too, but it is an infrastructure probe — the
measured workload is `PUT`.

### Populate the database

The 1M-record seed runs **automatically on first boot** of an empty volume, so normally there is
nothing to do. To force a fresh one:

```bash
# Use the compose file matching the stack you have up. Wiping the volume
# discards the database; the init scripts then re-run on the next start
# (schema, then the 1M-record seed -- measured at ~25 s).
docker compose -f compose.yaml down -v
docker compose -f compose.yaml up -d postgres
docker logs -f poc-postgres        # watch it seed

# This leaves ONLY Postgres running. Bring the rest of the stack back with:
./scripts/up.sh target             # or: current
```

If you run `down -v` with `compose.yaml` while CURRENT is up, the Squid containers survive
(they belong to `compose.current.yaml`) and the network cannot be removed — you will see
`Network poc-proxy_dc-lan  Resource is still in use`. Tear both down explicitly instead:

```bash
docker compose -f compose.yaml -f compose.current.yaml -f compose.bench.yaml \
  down -v --remove-orphans
```

To re-seed **without** dropping the volume — the init scripts are bind-mounted, so they are
already inside the container. This replaces the two zones rather than colliding with them, so it
is safe to run repeatedly:

```bash
docker exec \
  -e IOT_MOCK_IP=172.28.0.60 \
  -e DNS_RECORD_COUNT=1000000 \
  -e DNS_ZONE=test.domain \
  poc-postgres bash /docker-entrypoint-initdb.d/02-seed.sh
```

Check what landed:

```bash
docker exec poc-postgres psql -U pdns -d pdns -tAc \
  "select type, count(*) from records group by type order by 2 desc"
# A 1000016   (1,000,000 devices + the 16-name SSRF corpus)
# AAAA 8, NS 1, SOA 1
```

And ask the running DNS layer to resolve one of them — the lookup a TARGET request actually
causes, through this node's local dnsdist:

```bash
docker exec poc-haproxy-1 dig +short @172.28.0.31 iot0000001.test.domain
# -> 172.28.0.60      the IoT Mock, which is what HAProxy tunnels to
```

**TARGET only.** `172.28.0.31` is this node's dnsdist; under CURRENT there is no dnsdist and the
same command answers `communications error ... host unreachable`. That is the point of the
comparison rather than a fault — under CURRENT the name is resolved by Squid, and you can watch
that instead with the `curl -v` above, whose `CONNECT iot0000001.test.domain:443` line is Squid
being handed the name.

### If something goes wrong

| Symptom | Cause |
|---|---|
| HAProxy exits with `Cannot raise FD limit` | `ulimits.nofile` is below `2 × maxconn`. Lower `CURRENT_GLOBAL_MAXCONN` in `.env` or raise the ulimit in the compose file. |
| `no such service` | You used `-f` with the wrong file, or an old `docker-compose.yml` reference. There are only `compose.yaml`, `compose.current.yaml`, `compose.bench.yaml`. |
| Both nodes claim the VIP, or neither does | VRRP is **unicast** here (`unicast_peer`), because Docker bridges do not carry multicast VRRP. Check `docker logs poc-haproxy-1 \| grep -i vrrp`. |
| TLS handshake failures against the IoT Mock | `pki/` is stale or was generated before `.env` changed. Re-run `./scripts/gen-certs.sh` **and then recreate the affected containers** — see the row below. |
| **TLS works with curl but fails with `Signature does not match` after regenerating certs** | **`gen-certs.sh` rewrites `pki/` but running containers keep the certificate they loaded at startup.** The IoT Mock goes on serving the *old* server certificate while your client trusts the *new* CA, so chain verification fails with a signature error that looks like a server fault. Fix: `docker compose -f compose.yaml up -d --force-recreate iot-mock` (or just re-run `./scripts/up.sh`). Diagnose by comparing `openssl s_client … \| openssl x509 -fingerprint` against `openssl x509 -in pki/server/server.crt -fingerprint`. |
| Everything is slow on first run | The 1M-record seed is still running. `./scripts/wait-ready.sh` blocks until it is done. |

---

## How to test

The suite is grouped by what it proves. Every test prints `PASS` / `FAIL` / `SKIP` with the
evidence that produced the verdict, and writes raw command output under
`benchmark/results/raw/` so a verdict can be re-checked without re-running the stack.

| Group | File | Proves | Needs |
|---|---|---|---|
| `b1` | `tests/functional/b1-target-functional.sh` | TARGET serves `PUT` over end-to-end mTLS across the 1M namespace | arch=target |
| `b2` | `tests/functional/b2-current-functional.sh` | The same workload through the CONNECT path | arch=current |
| `b3` | `tests/security/b3-target-security.sh` | TARGET refuses the SSRF corpus on the **resolved address** | arch=target |
| `b4` | `tests/security/b4-current-security.sh` | CURRENT's real posture — see the caveat below | arch=current |
| `b5` | `tests/failover/b5-failover.sh` | VIP moves on the right faults and **does not move** on the wrong ones | either |
| `F1` | `tests/fidelity/run.sh` | Production's Squid ACLs vs the hardened counterfactual, side by side | Docker only |

### Run them

```bash
./tests/run-all.sh              # every group that applies to the current arch
./tests/run-all.sh b2 b4        # only the named groups
bash tests/fidelity/run.sh      # standalone: needs no stack
```

`run-all.sh` skips groups whose architecture does not match what is running, so `b1`/`b3` are
skipped when CURRENT is up. Bring up the other architecture to run those.

`tests/fidelity/run.sh` is deliberately **not** part of `run-all.sh`: it spins up its own two
Squid containers and needs no VIP, no PowerDNS and no database, so it runs in seconds on a bare
Docker host.

### Reading `b4` — the one that means two opposite things

`b4` asserts CURRENT's security posture, and **what a PASS means depends on `SQUID_CONF`**:

- `SQUID_CONF=squid.conf` (**the default**, production-faithful) — `b4` **PASSES by confirming
  that CURRENT ALLOWS the SSRF corpus**. That is the finding, not a bug in the test: production
  Squid has no destination validation.
- `SQUID_CONF=squid.conf.hardened` (the counterfactual) — `b4` PASSES by confirming `403`
  refusals from the resolved-address policy that production does *not* have.

`run-all.sh` echoes the selected model at startup, and `b4` prints a
`MODEL UNDER TEST:` banner. An ALLOW-based PASS and a 403-based PASS are both PASS — only that
line says which one you got. **Never quote a `b4` result without saying which model produced it.**

### Test groups that are not there

`tests/dns/`, `tests/tls/` and `tests/performance/` are referenced by some older prose but were
never populated; the DNS behaviour is covered by `benchmark/run.sh dns` and the failover group,
and TLS by `b1`. They have been removed rather than left as empty directories that imply
coverage.

---

## How to benchmark

```bash
./benchmark/run.sh tls       # end-to-end mTLS throughput (the headline)
./benchmark/run.sh dns       # DNS layer: PowerDNS-direct vs the proxy's DNS path
./benchmark/run.sh tunnels   # simultaneous tunnels
./benchmark/run.sh all
```

Overridable: `DURATION`, `CONCURRENCY`, `RPS`, `TUNNELS`, `METHOD`, `BODY_BYTES`. Raw JSON
lands in `benchmark/results/`, alongside metrics and resource snapshots for the same run.

A run is **refused** unless `scripts/wait-ready.sh` passes: benchmarking a half-seeded dataset
produces plausible-looking numbers that are wrong, which is worse than no numbers.

### The "CURRENT resized" variant

CURRENT's ceilings are production's own values by default, which caps it at 6,400 tunnels.
To ask the fair follow-up — *what would CURRENT need in order to meet 10,000?* — raise them in
`.env` and recreate the nodes:

```bash
# in .env
CURRENT_FRONTEND_MAXCONN=20000
CURRENT_SERVER_MAXCONN=10000

docker compose -f compose.current.yaml up -d --force-recreate haproxy-1 haproxy-2
```

`run.sh` derives its result labels **from the config**, so a resized run is written as
`current-resized-…` and cannot be mistaken for production sizing. Restore the values afterwards.

> Measured result: raising HAProxy's ceilings **degraded** CURRENT on this host — 3,596 tunnels
> and 29,529 rps against 6,400 and 35,900 at production sizing, with both Squids failing their
> own health checks. The binding constraint is the Squid layer, not HAProxy's `maxconn`. That is
> a single-host result and is caveated as such in the report.

### Driving the same workload with Gatling

`benchmark/run.sh` uses the Go client. If you would rather reproduce the numbers with standard
tooling, `images/gatling/` builds a Gatling runner for the same HTTP workload and emits a
familiar Gatling HTML report:

```bash
# TARGET: direct TLS, the device name as SNI
GATLING_MODE=target GATLING_RPS=1000 GATLING_DURATION=60 \
  docker compose -f compose.yaml -f compose.bench.yaml up --build gatling

# CURRENT: TLS THROUGH the CONNECT proxy on 38888
GATLING_MODE=current GATLING_RPS=1000 GATLING_DURATION=60 \
  docker compose -f compose.yaml -f compose.bench.yaml run --rm gatling
```

The report lands in `benchmark/results/gatling/<run>/index.html`.

Two things about it are worth knowing, because both would otherwise silently produce a
plausible but meaningless run:

- **The request URL carries the device name**, `https://iotNNNNNNN.test.domain/`, never the VIP
  address. Gatling derives both `Host` and the TLS **SNI** from the URL, and TARGET routes on
  the SNI — a request addressed to the IP would carry no SNI and measure nothing.
- **The container runs its own DNS.** The POC's PowerDNS resolves device names to the IoT Mock,
  which is the *backend* address — right for HAProxy, wrong for a client. `dnsmasq` inside the
  Gatling container maps the whole zone to the VIP so the load generator dials the proxy under
  test. The entrypoint **fails loudly** if the name does not resolve to the VIP rather than
  generating load against the wrong address.

**What Gatling cannot do, and why the Go client is still here.** Gatling is request-oriented: it
cannot hold N tunnels *open* simultaneously, so the 10,000-tunnel requirement is measured by
`hold-tunnels.py`; and it cannot issue raw DNS queries, so the DNS comparison uses the Go
client's `dns` mode.

### Holding tunnels open

`benchmark/hold-tunnels.py` measures the concurrency requirement directly — open N tunnels,
keep them open, report how many survive:

```bash
NET=$(docker network ls --format '{{.Name}}' | grep dc-lan | head -1)
docker run --rm --network "$NET" --ulimit nofile=200000:200000 \
  -v "$PWD/pki:/pki:ro" -v "$PWD/benchmark:/bench:ro" python:3.12-alpine \
  python3 /bench/hold-tunnels.py --vip 172.28.0.10 --port 443 --mode tls \
    --count 10000 --hold 55 \
    --cert /pki/clients/client-valid.crt --key /pki/clients/client-valid.key \
    --ca /pki/ca/ca.crt --label target-hold-10000
```

Use `--mode connect --port 38888` for CURRENT. Note the tunnels must carry **one request each**
to become holdable: the IoT Mock closes a connection that has sent no headers within 10 s.

### Reports

```bash
python3 scripts/report.py benchmark/results/current-mtls-put-6000rps.json
python3 scripts/report.py --all
```

Writes one **standalone HTML page per execution** to `reports/` — inline CSS, no JavaScript, no
network requests, opens straight from the filesystem. There is no index page by design; the
directory listing is the index. Deliberately not Grafana/Prometheus: a metrics stack would run
on the same host as the load generator and compete for the CPU it is meant to be measuring.

---

## Repository layout

```
compose.yaml            NOMINAL TARGET run — bare `docker compose up -d` starts this
compose.current.yaml    CURRENT stack (Squid), the comparison
compose.bench.yaml      overlay: the client, for `docker compose run`

images/                 Docker build contexts — build inputs only
  haproxy/  squid/  dnsdist/  client/  iot-mock/

configs/                everything bind-mounted at runtime — no build inputs
  haproxy/{current,target}/   HAProxy templates, selected by ARCH
  keepalived/{haproxy-1,haproxy-2,checks}/
  squid/{squid-1,squid-2}/    squid.conf + squid.conf.hardened
  dnsdist/  powerdns/  postgres/init/

benchmark/              harness, scenarios/, hold-tunnels.py, results/
reports/                generated per-execution HTML (gitignored)
scripts/                gen-certs, up, down, status, wait-ready, report.py
tests/                  functional, security, failover, fidelity
docs/                   architecture, ADRs, benchmark report, final validation
pki/                    generated certificates (gitignored — private keys)
```

The split between `images/` and `configs/` is deliberate: a directory either holds build inputs
or holds runtime configuration, never both.

---

## Security model

| | Destination validation | Refuses loopback / cloud-metadata / RFC1918 |
|---|---|---|
| **CURRENT — production** | **none** | **nothing** |
| CURRENT — counterfactual | resolved-address `dst` ACL | yes, `HTTP 403` |
| TARGET | resolved-address policy on `txn.dstip` | yes, connection closed |

CURRENT's Squid is an **open forward proxy**; this was measured from its own access log and
`tests/fidelity/run.sh` reproduces it. TARGET's policy is therefore **net-new capability, not a
re-implementation**. Where a policy is enforced it validates the **resolved IP**, never the
attacker-supplied name — a name is a request, the address is what the packet actually reaches.

A corpus of names resolving into every forbidden address class is seeded into the zone, so the
policy is tested against real resolution. `ssrf-rebind.test.domain` deliberately carries two A
records — one permitted, one forbidden — so a name-based check would pass while an address-based
check catches it.

**One documented deviation.** The POC's IoT endpoint range is RFC1918 (as a real datacenter's
would be), so each private-range deny carries an explicit exception for it, standing in for
production's allow-list of IoT endpoint networks. In production those endpoints resolve to
publicly routable addresses and the exception would not exist. See
[docs/adr/README.md](docs/adr/README.md) §22.

---

## Known limitations

Real, and not hidden anywhere else in this repository:

1. **Single host.** Every component — both "nodes", both Squid/dnsdist, the client and the
   backend — shares one 20-vCPU machine. CPU and bandwidth are contended, so absolute numbers
   are not production capacity. The A/B comparison remains valid.
2. **10,000 tunnels is measured for TARGET, and unreachable for production-sized CURRENT**
   (6,400, measured). The client's `-mode=tls` has no persistent-tunnel implementation, so the
   client-driven benchmark cannot run that scenario for TARGET; `hold-tunnels.py` is used
   instead, and it measures concurrency, not throughput on those tunnels.
3. **VRRP is unicast, not multicast.** Docker bridges cannot carry multicast VRRP. Election,
   priority, preemption and failover timing are real; switch-level IGMP snooping and
   physical-link failure detection are not reproduced.
4. **TARGET loses the cross-datacenter DNS fallback** that production Squid has today — an
   accepted regression. See [ADR 29](docs/adr/0029-target-dns-fallback-regression.md).
5. **TARGET rejects a connection by closing it**, because TCP mode has no HTTP status to return.
   CURRENT can return an HTTP error. Any client that distinguishes "refused" from "unreachable"
   behaves differently.
6. **IPv6 destinations are unsupported by TARGET.** The resolver is pinned to `ipv4` because the
   IoT namespace is A-record only. AAAA-only names fail closed, which is the correct direction,
   but it is a capability difference rather than a policy decision.
7. **The POC proves nothing about production readiness.** It measures behaviour under controlled
   synthetic load on one machine. See [docs/final-validation.md](docs/final-validation.md) for
   the production validation still required.

---

## Documentation

- [docs/architecture.md](docs/architecture.md) — component-by-component design and data flows
- [docs/adr/](docs/adr/README.md) — architecture decision records, including the CONNECT finding
  and the production-config-fidelity audit (ADR 28, ADR 29)
- [docs/benchmark-report.md](docs/benchmark-report.md) — measured CURRENT vs TARGET comparison
- [docs/final-validation.md](docs/final-validation.md) — what was validated, and what remains
- [docs/work-units.md](docs/work-units.md) — the implementation plan and its status
- [docs/scenarios/failure-injection.md](docs/scenarios/failure-injection.md) — fault scenarios
