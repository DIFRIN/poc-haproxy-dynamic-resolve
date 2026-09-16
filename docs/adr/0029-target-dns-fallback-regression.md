# 29. TARGET narrows the DNS path — an accepted regression

**Status.** Accepted, with a recommended follow-up for production. Supersedes the DNS
assumptions in ADR 10 (CURRENT Squid DNS behaviour) that were derived from the brief.

---

## Context

The brief specifies TARGET's DNS path precisely, and it is deliberately narrow:

> "Each HAProxy must use **only its local dnsdist**. Do not configure HAProxy → PDNS 1 /
> HAProxy → PDNS 2 as a direct fallback." — brief §9, restated as non-negotiable rules 14
> and 15

The POC implemented that, and `docs/architecture.md` §5 defended it as a feature:

> "There is no second nameserver entry and **no fallback to PowerDNS**. If the local
> dnsdist is unavailable, resolution fails and the request fails. A PowerDNS fallback would
> silently bypass the DNS abstraction layer that TARGET exists to introduce."

That reasoning is sound *about the local PowerDNS pair*. What the POC did not know is what
the real production Squid queries, because it had never seen the real Squid configuration:

```
dns_nameservers {{ role_squid_dns_current_site_joined }} {{ role_squid_dns_remote_site_joined }}
```

Two variables. The first is this datacenter's nameservers — the POC's two PowerDNS. The
second is **the remote datacenter's**.

---

## What this means

Production Squid holds a **cross-datacenter DNS fallback**. If every nameserver in this
site is gone, Squid does not stop resolving: it falls through to the other site's
nameservers and keeps serving CONNECT requests.

TARGET, as specified and as built, does not have that. Each HAProxy reaches exactly one
resolver — its own local dnsdist — and that dnsdist knows exactly two backends, both
PowerDNS servers in this datacenter. If both die, dnsdist answers `SERVFAIL` and stays
healthy, the VIP correctly does not move (rule 16, rule 17), and **every request fails**
until PowerDNS returns. The datacenter's DNS is a single-site single-point-of-failure where
production today has a two-site one.

So TARGET does not merely re-implement CURRENT's DNS path with a better load balancer. It
**narrows** it, and the narrowing is a capability reduction that the POC's documents
previously presented as a pure improvement. `docs/benchmark-report.md` and
`docs/final-validation.md` described TARGET's DNS path as strictly better (lower latency,
fewer queries, round-robin distribution) without recording anywhere that a fallback had
been removed. That omission is corrected.

Note the asymmetry this creates. Rules 16–18 require that PowerDNS infrastructure failure be
*absorbed* — never allowed to move the VIP — which is exactly what dnsdist does and is the
right behaviour. But "absorbed" now means "absorbed into a total outage of the datacenter's
name resolution", because there is no longer anywhere for the failure to fall through to.

---

## The "all PowerDNS down" scenario is a POC-only construction

`tests/failover/b5-failover.sh` exercises "genuine SERVFAIL — all PowerDNS backends down,
VIP must not move", and the TARGET security test cites the same path. **Against production
CURRENT this scenario is not reproducible.** Stopping this site's PowerDNS pair does not
produce a `SERVFAIL` in production: Squid reaches the remote site's nameservers and resolves
normally.

The scenario exists only because the POC gave both Squids two local servers and no remote
list. It remains a valid test of TARGET's failure semantics — dnsdist *should* absorb a
PowerDNS loss without moving the VIP — but it must not be read as reproducing a CURRENT
failure mode, and the CURRENT arm of it proves nothing about production.

---

## Decision

**Accept the regression and record it.** The brief is explicit and non-negotiable on rules
14 and 15, the POC boundary excludes the second datacenter (rule 10), and the cross-site
behaviour cannot be reproduced faithfully inside a one-datacenter POC anyway — the second
site's DNS would have to be simulated, which would put a fabricated component inside the
path being measured.

This is a decision to be *transparent about the loss*, not a claim that the loss is
costless.

---

## Consequences

1. **TARGET is less resilient than CURRENT in one specific, nameable dimension:**
   loss of all local DNS. CURRENT degrades to cross-site resolution; TARGET fails closed.
2. **This is a migration risk that must be stated in the recommendation.** It is a real
   availability regression, weighing against TARGET on operational grounds, alongside
   TARGET's wins (one fewer process in the path, no open proxy, net-new destination
   validation).
3. **The `SERVFAIL` failover scenario is relabelled** as a TARGET-semantics test that does
   not model production CURRENT.
4. **Rule 16 is satisfied but means something narrower than it appears.** dnsdist does
   absorb PowerDNS failure — within the site. It has nothing to absorb *across* sites.

---

## Recommended follow-up — available without violating the brief

There is a fix that preserves rule 14 exactly. The brief constrains what **HAProxy** may
reach — its local dnsdist, and nothing else — and it separately enumerates what each
dnsdist must know:

> "Each dnsdist must: Know both PowerDNS servers. Use explicit round-robin. Perform health
> checks. Remove unhealthy PowerDNS backends. Reintroduce recovered backends. Expose DNS
> statistics." — brief §9

Nothing in that list forbids dnsdist from also being configured with the **remote site's
nameservers as additional backends**, ordered after the two local PowerDNS servers. That
would:

- leave HAProxy's DNS path exactly as specified — still one resolver, still no direct
  PowerDNS fallback, rules 14 and 15 untouched;
- keep dnsdist as the single DNS abstraction and policy layer, which is the point of
  introducing it;
- restore the cross-site fallback CURRENT has today, so TARGET is not a net availability
  regression;
- keep the failure ordering sensible: local PowerDNS first, remote site only when the local
  pair is entirely gone. Round-robin across a healthy local pair is unaffected.

This is **not implemented** in the POC, because the remote site is outside the POC boundary
(rule 10) and simulating it would introduce a fabricated component into the measured path.
It is recorded as the recommended production design, and it should be settled before the
migration is committed to, not after.

The alternative — accept the narrowing as a deliberate trade, on the grounds that a site
which has lost its entire DNS pair has larger problems — is defensible, but it should be a
decision someone makes explicitly, with the regression in front of them. It was previously
invisible.

---

## Related

- **ADR 10** — CURRENT Squid DNS behaviour. The "reversed preference" the brief mandates
  (squid-1 → PDNS1,PDNS2; squid-2 → PDNS2,PDNS1) has **no production counterpart**:
  production configures the *same* list on both instances, and the second entry in that list
  is the remote site, not a second local server. The reversal is a brief §8 POC experiment,
  and the measured DNS distribution is therefore a property of a POC-only configuration.
  Recorded here rather than left implied, because that measurement is cited in the
  comparison.
- **ADR 28** — production config fidelity, which is where the real `dns_nameservers` line
  was discovered and the rest of the production configuration is recorded.
- **ADR 16** — local dnsdist per HAProxy. Unchanged and still correct.
