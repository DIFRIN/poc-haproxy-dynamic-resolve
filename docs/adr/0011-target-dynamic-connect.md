# ADR 0011 — TARGET dynamic CONNECT: REJECTED AS SPECIFIED, REPLACED BY SNI PASSTHROUGH

- **Status:** Accepted (supersedes the "dynamic CONNECT" proposal in the POC brief)
- **Date:** 2026-09-14
- **Deciders:** POC engineering
- **Evidence:** measured on HAProxy 3.0.27-a2b09cd; see "Evidence" below

## Context

The brief proposed TARGET as: remove Squid, and let HAProxy forward client `CONNECT`
requests to dynamically resolved IoT endpoints using `http-request do-resolve()`,
`set-dst`, and `set-dst-port`. HAProxy would resolve `iotNNNNNNN.test.domain` through a
local dnsdist, set the destination, establish TCP to the IoT Mock, and tunnel the
encrypted stream end-to-end.

The architectural intent is sound and worth stating plainly, because it survives:

> The proxy must choose a destination by DNS name, validate it, and then get out of the
> way — carrying mTLS end-to-end without ever decrypting it.

The question this ADR settles is narrower: **can HAProxy be the component that terminates
the CONNECT method?** It cannot, and therefore this specific design is not implementable.

## Decision

**HAProxy cannot terminate `CONNECT`.** It has no facility to originate the
`200 Connection established` response. TARGET-as-specified is therefore rejected, and
TARGET is redefined as **SNI-based TLS passthrough** (ADR 0012).

## Evidence

Four configurations were built and run against a real PowerDNS-equivalent resolver, a
real TLS backend, and the POC's own IoT Mock. All four are reproducible from this repo.

### 1. HTTP mode relays CONNECT and requires the upstream to answer 2xx

The decisive measurement. `http-request do-resolve()` + `set-dst` + `set-dst-port`,
pointed at the real IoT Mock (a TLS listener with mTLS):

```
host=iot0000001.test.domain ip=172.30.0.40 realdst=172.30.0.40:443 status=502 term=SH--
```

Read carefully — every part of the proposed mechanism *worked*:

- `ip=172.30.0.40` — `do-resolve()` resolved the hostname through the resolver.
- `realdst=172.30.0.40:443` — `set-dst`/`set-dst-port` set the destination correctly.
- The TCP connection to the IoT Mock was established.

And it still failed: `status=502`, `term=SH` (server-side abort). HAProxy had forwarded
the `CONNECT` request line to the IoT Mock and was waiting for an HTTP response. A TLS
server waits for a ClientHello and never sends one. Deadlock, then 502.

The failure is not in resolution or routing. It is that HAProxy **proxies** the CONNECT
rather than **answering** it.

### 2. A non-HTTP backend reply is rejected as a malformed response

With a backend that sends a non-HTTP banner, `show errors` on the admin socket reports:

```
backend be_tunnel (#3): invalid response
  H1 msg state MSG_RPVER(10), H1 msg flags 0x00003404
  00000  HELLO-FROM-BACKEND\r\n
```

HAProxy is parsing the server's bytes as an HTTP response. Confirms direction of travel.

### 3. A silent backend causes a hang, not a tunnel

Backend accepts and sends nothing (exactly how a TLS server behaves). HAProxy never
responds to the client — no `200`, no error, until timeout. Rules out the possibility
that HAProxy emits the `200` itself and merely waits for the tunnel to become writable.

### 4. TCP mode does not help — it cannot parse, and it does not answer

HAProxy forbids mixing modes, which rules out "HTTP frontend for parsing + TCP backend
for tunnelling":

```
config : http frontend 'fe_tunnel' tries to use incompatible tcp backend 'be_tunnel'
         as its default backend (see 'mode').
```

`do-resolve`, `set-dst` and `set-dst-port` *are* accepted under `tcp-request content`,
so dynamic resolution in TCP mode is possible. But a TCP-mode HAProxy does not speak
HTTP at all: it forwards the client's `CONNECT ...` bytes verbatim to the resolved
destination, and the TLS server rejects them. Observed client-side:

```
curl: (56) Proxy CONNECT aborted
```

### Corroboration: upstream HAProxy semantics

HAProxy's own source defines tunnel establishment on the **response** path, reading the
status from the server's reply:

```c
(h1s->meth == HTTP_METH_CONNECT && h1s->status >= 200 && h1s->status < 300)
    || h1s->status == 101
```

"a successful reply to a CONNECT or a protocol switching is sent to the client. Switch
the response to tunnel mode." The status is the *upstream's*. HAProxy forwards that
response and tunnels after it. It is a CONNECT **chain** proxy, not a CONNECT
**terminator**. Legacy `option http-tunnel` does not change this and is ignored under
HTX, which is mandatory in HAProxy 3.x.

### Why the CURRENT architecture corroborates this

CURRENT places Squid behind HAProxy. That is not an accident of history — Squid is the
component that terminates CONNECT. HAProxy is in front of it because HAProxy cannot do
the job alone. The proposed TARGET removed the one component doing the work the frontend
cannot do, which is why it does not compile into a working system.

## Consequences

- **TARGET-as-specified: not implementable.** No amount of HAProxy tuning recovers it.
  Any proposal of the form "drop Squid, let HAProxy do dynamic CONNECT" is dead on
  arrival, and this POC exists partly to make that unarguable.
- **The intent is preserved.** TARGET is redefined as SNI-based TLS passthrough
  (ADR 0012): the client connects TLS to the VIP, HAProxy reads the SNI from the
  ClientHello without terminating TLS, resolves it through local dnsdist, validates the
  resolved address, sets the destination, and tunnels raw TLS to the IoT Mock. Squid is
  genuinely removed, and end-to-end mTLS is untouched by the proxy.
- **The client contract changes.** IoT clients under TARGET connect directly to
  `VIP:443` with `SNI = iotNNNNNNN.test.domain` instead of issuing `CONNECT` to
  `VIP:3128`. This is a client-side firmware/protocol change and the single largest
  migration cost of the corrected TARGET. It is called out in the migration ADR.
- **Security testing moves, it does not disappear.** The CONNECT destination policy
  (ADR 0021) becomes an SNI/resolved-address policy with the same rules and the same
  adversarial corpus. CURRENT continues to be tested through CONNECT, since CURRENT
  still terminates it.
- **The comparison stays fair.** Both architectures are measured on the same
  user-visible operation — an IoT identity establishes an end-to-end mTLS session and
  issues a request — over the same 1M namespace. The removed CONNECT hop is precisely
  the difference under test.

## Alternatives considered

1. **Keep CONNECT; retain a thin CONNECT terminator behind HAProxy.** Viable, and it
   does shrink Squid's role (HAProxy takes over DNS, policy, load balancing). But it
   does not remove the second proxy component, so it answers "can Squid be demoted?"
   rather than the brief's question, "can Squid be removed?". Rejected as the primary
   target; retained as a documented fallback for clients that cannot drop CONNECT.
2. **Lua in HTTP mode to synthesise the 200.** HAProxy's Lua API can send a response on
   the response channel, but the connection then remains an HTTP transaction awaiting a
   server response; there is no supported way to force the session into tunnel mode from
   Lua. Rejected.
3. **Do nothing; report the blocker.** Insufficient — it leaves the migration question
   with no tested alternative.
