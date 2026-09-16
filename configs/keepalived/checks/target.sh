#!/bin/sh
# ============================================================================
# TARGET node health check — decides whether THIS node keeps the VIP.
#
# Probes the LOCAL dnsdist for the zone apex SOA. A real DNS query is the right
# health signal here rather than a TCP connect: dnsdist's listener can accept a
# connection while every backend behind it is dead and it is answering SERVFAIL.
#
# WHY THE APEX, NOT dnsdist's DEFAULT PROBE
#   dnsdist's own health-check default asks for a.root-servers.net. Our
#   authoritative servers would answer that with REFUSED, scoring every backend
#   as failed. Asking for our own apex asks the question that actually matters:
#   can this node's DNS path answer for OUR zone?
#
# FAILURE SEMANTICS (brief §7)
#   no response at all      -> infrastructure failure -> the VIP MAY move
#   NXDOMAIN / SERVFAIL     -> a DNS RESULT, not an infrastructure failure
#                              -> the VIP must NOT move
#   any response at all     -> healthy, keep the VIP
#
# The second rule is why this script requires only that *an answer came back*
# rather than that the answer was NOERROR. A misconfigured zone or a missing
# name is not a reason to move a VIP.
#
# Exit 0 = healthy (keep the VIP). Non-zero = this node's local stack is broken.
# ============================================================================
set -u

: "${LOCAL_DNSDIST_IP:?LOCAL_DNSDIST_IP is required}"
: "${DNS_PORT:?DNS_PORT is required}"
: "${DNS_ZONE:?DNS_ZONE is required}"

OUT="$(dig +time=2 +tries=1 +noall +comments \
        -p "${DNS_PORT}" "@${LOCAL_DNSDIST_IP}" "${DNS_ZONE}" SOA 2>&1)" || exit 1

# `status:` appears in both successful and DNS-error responses. Only its total
# absence means nothing came back, which is the infrastructure failure above.
printf '%s\n' "${OUT}" | grep -q 'status:' || exit 1

exit 0
