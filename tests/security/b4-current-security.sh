#!/usr/bin/env bash
# ============================================================================
# B4 — CURRENT security: the SSRF corpus through CONNECT (arch=current).
#
# WHAT CURRENT ACTUALLY IS. The real production Squid access-control block —
# reproduced verbatim in configs/squid/squid-1|2/squid.conf — is:
#
#     acl env_network src 0.0.0.0/32       <- matches NOTHING: the rule is dead
#     http_access allow env_network CONNECT
#     http_access allow SSL_ports          <- ANY source -> 443, 445, 8443
#     http_access allow Safe_ports         <- ANY source -> 80, 21, 443, 445,
#                                             8443, 70, 210, 1025-65535, 280,
#                                             488, 591, 777
#     http_access deny to_localhost        <- UNREACHABLE: both allows precede
#                                             it and neither is source-restricted
#
# There is NO destination validation of any kind — no `acl to_private dst`, no
# `acl iot_endpoints dst`, no source restriction. CURRENT is an OPEN FORWARD
# PROXY. Measured from a source outside env_network, Squid's own log shows
# CONNECT to 127.0.0.1:443, to Squid's own address, to 169.254.169.254 (cloud
# instance metadata) and to 192.168.0.1:443 all ALLOWED (TCP_TUNNEL), with a
# tunnel actually established to the RFC1918 address; the ONLY denial was
# port-based (CONNECT :22, absent from Safe_ports).
# See docs/adr/0028-production-config-fidelity.md.
#
# THEREFORE THIS FILE'S MEANING DEPENDS ON WHICH SQUID MODEL IS MOUNTED, and it
# branches on SQUID_CONF (tests/lib.sh) to say which one it ran against:
#
#   SQUID_CONF=squid.conf — DEFAULT, production-faithful
#       The corpus is ALLOWED and the test PASSES by confirming that. A 403
#       anywhere is a FAIL: production does not refuse these destinations. The
#       run ends with an unmissable CONFIRMED VULNERABILITY banner, because a
#       suite that reported this as a clean security result would be asserting
#       the opposite of what production does.
#
#   SQUID_CONF=squid.conf.hardened — COUNTERFACTUAL, NOT production
#       The corpus is refused with HTTP 403 by the invented resolved-address
#       policy. A PASS here means "the counterfactual policy works as written".
#       It is NOT a statement about CURRENT as deployed, and no result from this
#       branch may be presented as CURRENT's production behaviour.
#
# FIDELITY NOTE. An earlier revision of this file asserted only the hardened
# behaviour and so reported CURRENT as refusing 26/26 SSRF attempts with 403.
# That policy does not exist in production, and the comparison it produced was
# biased in CURRENT's favour. See ADR 0028.
#
# THE FAILURE MODE IS DIFFERENT FROM TARGET, AND THAT IS THE POINT.
# Squid terminates CONNECT, so it CAN answer with an HTTP status: when it does
# refuse, the client sees a non-2xx CONNECT response (403) rather than the
# closed socket TARGET produces. Capturing that status is required evidence, so
# it is printed for every name. Every verdict below is made on the STATUS CODE,
# never on the connect_rejected counter: the client classifies a 403 and a 503
# identically (both are "connect_rejected"), and only the status distinguishes
# "the ACLs refused this" from "the ACLs allowed it and the upstream did not
# answer".
# ============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

if [ "${ARCH}" != "current" ]; then
    echo "b4 requires ARCH=current (currently ${ARCH}); run ./scripts/up.sh current" >&2
    exit 2
fi

group b4-current-security

# --- which Squid model is under test -----------------------------------------
# Resolved ONCE, printed loudly, and written to the run log next to the verdict:
# the same corpus produces opposite results under the two models, so a verdict
# without this line is meaningless.
case "${SQUID_CONF}" in
    squid.conf.hardened)
        B4_MODEL="hardened"
        B4_MODEL_DESC="COUNTERFACTUAL resolved-address policy -- NOT production" ;;
    squid.conf|"")
        B4_MODEL="faithful"
        B4_MODEL_DESC="production-faithful -- OPEN PROXY, no destination validation" ;;
    *)
        B4_MODEL="faithful"
        B4_MODEL_DESC="UNRECOGNISED SQUID_CONF value; assuming the default production-faithful model" ;;
esac

log "VIP=${VIP}:${CLIENT_PORT} (CONNECT)  haproxy owner: $(vip_owner)"
log "SQUID_CONF=${SQUID_CONF}"
log "MODEL UNDER TEST: ${B4_MODEL_DESC}   [verdict below is valid ONLY for this model]"
runlog "b4 start: arch=${ARCH} squid_conf=${SQUID_CONF} model=${B4_MODEL} vip_owner=$(vip_owner)"

# --- corpus, straight from the authoritative database -------------------------
CORPUS_SQL="select name, coalesce(string_agg(type||' '||content, ', ' order by type, content),'(no records)')
            from records where name like 'ssrf-%' group by name order by name"
docker exec poc-postgres psql -tA -F'|' -U pdns -d pdns -c "${CORPUS_SQL}" \
    > "${RAW}/${GROUP}/corpus.txt" 2>>"${GROUP_LOG}"
mapfile -t CORPUS < <(grep -v '^[[:space:]]*$' "${RAW}/${GROUP}/corpus.txt")
EXTRA=("nx.test.domain|(undefined -> NXDOMAIN)" "servfail.test.domain|(intended SERVFAIL)")
log "corpus size: ${#CORPUS[@]} names (raw: ${RAW}/${GROUP}/corpus.txt)"

DUR="${B4_DURATION:-5s}"

# --- run-level tallies, used by the closing banner ---------------------------
# In the faithful model each name is asserted to be ALLOWED, so the count of
# outright refusals has to be zero. Kept separately from PASS/FAIL because the
# banner needs to state what happened, not just that the assertions held.
N_ALLOWED=0     # names with no 403 that Squid answered for
N_REFUSED=0     # names refused with 403
N_SILENT=0      # names where no HTTP status was ever seen (timeouts only)

# check_name <name> <records> <index> [dns-refusal-ok]
# The optional 4th argument marks a name that does not resolve at all (the two
# in EXTRA). Such a name cannot be evaluated by a `dst` ACL in any model, so in
# the hardened branch its refusal arrives as a 503 (ERR_DNS_FAIL) rather than a
# 403, and counting that as a failure would be scoring Squid for failing closed.
check_name() {
    local name="$1" recs="$2" i="$3" dns_refusal="${4:-no}"
    local J="${RAW}/${GROUP}/$(printf '%02d' "${i}")-${name}.json"
    client_json "${J}" -mode=connect -proxy="${VIP}:${CLIENT_PORT}" \
        -target-host="${name}" -target-port=443 ${CERT_VALID} ${CA_POC} \
        -duration="${DUR}" -rps=6 -concurrency=2 -timeout=6s \
        -label="b4-${name}" >/dev/null

    local att succ crej cerr codes tls http to p50 err
    att=$(jget "${J}" "d['attempts']")
    succ=$(jget "${J}" "d['success']")
    crej=$(jget "${J}" "d['connect_rejected']")
    cerr=$(jget "${J}" "d['connect_error']")
    codes=$(jget "${J}" "d['connect_status_codes']")
    tls=$(jget "${J}" "d['tls_error']")
    http=$(jget "${J}" "d['http_error']")
    to=$(jget "${J}" "d['timeout']")
    p50=$(jget "${J}" "d['latency_ms']['p50']")
    err=$(jget "${J}" "(d['errors_sample'] or ['(none)'])[0]")

    log ""
    log "  name=${name}"
    log "    resolves to   : ${recs}"
    log "    attempts=${att} success=${succ} connect_rejected=${crej} connect_error=${cerr} tls_error=${tls} http_error=${http} timeout=${to}"
    log "    CONNECT STATUS CODES : ${codes}"
    log "    p50_ms=${p50}   failure mode: ${err}"

    if [ "${att}" -eq 0 ]; then
        fail "B4 ${name}: no attempt completed -- cannot conclude anything about Squid's ACLs"
        return
    fi

    # A CONNECT status code is Squid's own verdict, so its presence is the
    # difference between "the ACLs were evaluated and allowed it" and "nothing
    # ever came back". Empty {} means every attempt timed out.
    if [ "${codes}" = "{}" ]; then
        N_SILENT=$((N_SILENT+1))
    fi

    if [ "${B4_MODEL}" = "hardened" ]; then
        # ---- COUNTERFACTUAL branch: the policy must refuse, and refuse with 403.
        # "No success" is NOT by itself proof that the POLICY refused this name.
        # It has to be the policy's own status code: Squid answers a denied
        # CONNECT with 403. A 503 means Squid never got as far as evaluating the
        # destination -- it failed to resolve it -- and crediting that as a
        # policy block would be a false pass. (the codes string is a Python dict
        # repr, hence the single quotes)
        if [ "${succ}" -ne 0 ] || [ "$(jget "${J}" "d['http_status_codes'].get('200',0)")" != "0" ]; then
            fail "B4 ${name} NOT refused by the counterfactual policy: success=${succ} connect_status_codes=${codes}"
            return
        fi
        case "${codes}" in
            *"'403'"*)
                N_REFUSED=$((N_REFUSED+1))
                pass "B4 ${name} REFUSED BY THE COUNTERFACTUAL POLICY (Squid 403; ${crej} of ${att} attempts; codes ${codes}) -- this is squid.conf.hardened, NOT production CURRENT" ;;
            *"'503'"*)
                if [ "${dns_refusal}" = "yes" ]; then
                    # The name has no A record, so `acl to_private dst` cannot be
                    # evaluated at all: the refusal is the fail-closed DNS path,
                    # not a deny-list match. Still a refusal; recorded as such
                    # rather than credited to the policy.
                    N_REFUSED=$((N_REFUSED+1))
                    pass "B4 ${name} REFUSED, but by DNS failure rather than by the policy (503 ERR_DNS_FAIL: the name does not resolve, so no 'dst' ACL can be evaluated; codes=${codes})"
                else
                    fail "B4 ${name} NOT evaluated by the policy: Squid answered 503 (ERR_DNS_FAIL), so the request never reached 'acl to_private dst'. codes=${codes}"
                fi ;;
            *)
                fail "B4 ${name} neither blocked with 403 nor refused cleanly: codes=${codes} success=${succ}" ;;
        esac
        return
    fi

    # ---- PRODUCTION-FAITHFUL branch: the open proxy must ALLOW, and a 403 is
    # the failure. This is the inverted assertion, and it is the honest one: the
    # destinations in this corpus are exactly the ones production refuses none
    # of, so "the corpus was refused" would mean the stack under test is not
    # running production's configuration.
    case "${codes}" in
        *"'403'"*)
            N_REFUSED=$((N_REFUSED+1))
            fail "B4 ${name} REFUSED WITH 403 -- production Squid has no destination policy and does not refuse this. Either the stack is running a hardened/counterfactual config, or SQUID_CONF does not describe the running stack. codes=${codes}" ;;
        "{}")
            # No HTTP status came back at all: every attempt hit the client's 6 s
            # deadline. Squid waiting on an upstream connect is consistent with
            # the CONNECT having been allowed, but it is not a refusal EITHER
            # way, so it is counted as silent rather than passed off as a
            # confirmed allowance. The refusal test (no 403) still holds.
            pass "B4 ${name} NOT REFUSED (no 403) -- but Squid returned no status within the client timeout, so this is recorded as SILENT, not as a confirmed allowance (${att} attempts)" ;;
        *)
            N_ALLOWED=$((N_ALLOWED+1))
            pass "B4 ${name} ALLOWED BY THE OPEN PROXY -- not refused (no 403; codes=${codes}; ${crej} of ${att} attempts answered by Squid, ${succ} succeeded end-to-end)" ;;
    esac
}

# ---------------------------------------------------------------------------
# Baseline first. Without it, a stack that answers nothing at all would show an
# "every name allowed" corpus in which every attempt simply timed out, and the
# allowance conclusion would be worthless. So the legitimate endpoint is
# exercised through the same VIP and the same CONNECT port before any claim is
# made about what the ACLs let through.
# ---------------------------------------------------------------------------
log ""
log "---- baseline: the legitimate destination must work through the same path ----"
J="${RAW}/${GROUP}/00-baseline-iot0000001.json"
client_json "${J}" -mode=connect -proxy="${VIP}:${CLIENT_PORT}" \
    -target-host=iot0000001.test.domain -target-port=443 \
    ${CERT_VALID} ${CA_POC} -duration=3s -concurrency=2 -label=b4-baseline >/dev/null
B_ATT=$(jget "${J}" "d['attempts']")
B_SUCC=$(jget "${J}" "d['success']")
B_CODES=$(jget "${J}" "d['connect_status_codes']")
log "  attempts=${B_ATT} success=${B_SUCC} connect_status_codes=${B_CODES}"
if [ "${B_SUCC}" -gt 0 ]; then
    pass "B4.baseline the CONNECT path works end-to-end (iot0000001.test.domain:443 -> HTTP 200, ${B_SUCC} successes), so a corpus of allowances below is meaningful"
else
    fail "B4.baseline the stack cannot serve even the legitimate destination (attempts=${B_ATT} success=0 codes=${B_CODES}). The corpus result below cannot be interpreted as an ACL decision -- record it as an environment failure, not as a security finding."
fi

log ""
log "---- SSRF corpus through CONNECT (${DUR} per name) ----"
i=0
for row in "${CORPUS[@]}"; do
    i=$((i+1))
    check_name "${row%%|*}" "${row#*|}" "${i}"
done

# ---------------------------------------------------------------------------
# Names that do not resolve. They stay in the corpus because the brief calls
# them out, but they are NOT a destination-policy question in either model: a
# name with no A record cannot be evaluated by a `dst` ACL at all, so Squid
# answers 503 (ERR_DNS_FAIL) rather than 403. That is a resolution failure, not
# a policy refusal, and in production-faithful mode it is the same answer any
# unresolvable name gets from an open proxy. What must NOT happen either way is
# a success or an HTTP 200.
# ---------------------------------------------------------------------------
log ""
log "---- unresolvable / failing names (refusal reason is DNS, not a policy) ----"
for row in "${EXTRA[@]}"; do
    i=$((i+1))
    check_name "${row%%|*}" "${row#*|}" "${i}" yes
done

# ---------------------------------------------------------------------------
# Control: the ONLY refusal production makes is port-based.
#
# A CONNECT to a port absent from Safe_ports (:22) is denied -- by Squid's
# default port list, not by any destination rule. The name chosen resolves to a
# NON-loopback address (172.16.5.5, from configs/postgres/init/02-seed.sh) so the 403
# cannot be `deny to_localhost` firing, and the answer is printed so that this
# is checkable rather than asserted. This control is model-independent: port 22
# is absent from Safe_ports in both configs.
# ---------------------------------------------------------------------------
log ""
log "---- control: the one port-based refusal production does make (:22) ----"
PORT_CTL="ssrf-private172.test.domain"
PORT_CTL_A="$(docker exec poc-haproxy-1 dig +short +time=2 +tries=1 -p "$(envval DNS_PORT)" \
    "@$(envval PDNS_1_IP)" "${PORT_CTL}" A 2>/dev/null | tr '\n' ' ')"
log "  ${PORT_CTL} resolves to: '${PORT_CTL_A:-<no A record>}'"
if [ -z "${PORT_CTL_A}" ]; then
    fail "B4.port the control name ${PORT_CTL} does not resolve, so a CONNECT to :22 could fail with 503 instead of 403 and the control cannot distinguish the two. Check the seeded zone."
else
    J="${RAW}/${GROUP}/98-port-control-${PORT_CTL}-22.json"
    client_json "${J}" -mode=connect -proxy="${VIP}:${CLIENT_PORT}" \
        -target-host="${PORT_CTL}" -target-port=22 ${CERT_VALID} ${CA_POC} \
        -duration=2s -rps=4 -concurrency=1 -timeout=5s -label=b4-port-control >/dev/null
    P_CODES=$(jget "${J}" "d['connect_status_codes']")
    P_SUCC=$(jget "${J}" "d['success']")
    log "  attempts=$(jget "${J}" "d['attempts']") success=${P_SUCC} connect_status_codes=${P_CODES}"
    case "${P_CODES}" in
        *"'403'"*)
            pass "B4.port CONNECT :22 denied with 403 (${P_CODES}) -- CURRENT's only refusal is the port, and it is Squid's default port list, not a destination policy" ;;
        *)
            fail "B4.port CONNECT :22 was not denied with 403 (codes=${P_CODES}); port 22 is absent from Safe_ports in both configs, so either the stack is running neither model or the request never reached the ACLs" ;;
    esac
fi

# ---------------------------------------------------------------------------
# ssrf-rebind: one name, two A records, one permitted and one forbidden.
#
# In the COUNTERFACTUAL model this is the decisive evidence that the policy is
# applied to the RESOLVED address rather than to the attacker-chosen name: the
# resolver rotates the answer order, and the outcome follows the address.
#
# In the PRODUCTION-FAITHFUL model there is nothing for the outcome to follow:
# the name is allowed whichever address it resolves to. That is asserted
# directly (no 403 on either ordering), because a name with one loopback answer
# is the canonical SSRF shape and production accepts it.
# ---------------------------------------------------------------------------
log ""
log "---- ssrf-rebind: there is no policy, so nothing follows the RESOLVED address ----"
REBIND_ANSWERS="${RAW}/${GROUP}/rebind-dns-answers.txt"
: > "${REBIND_ANSWERS}"
for _ in $(seq 1 12); do
    docker exec poc-haproxy-1 dig +short +time=2 +tries=1 -p "$(envval DNS_PORT)" \
        "@$(envval PDNS_1_IP)" ssrf-rebind.test.domain A 2>/dev/null | tr '\n' ',' >> "${REBIND_ANSWERS}"
    printf '\n' >> "${REBIND_ANSWERS}"
done
sed 's/^/      /' "${REBIND_ANSWERS}" | tee -a "${GROUP_LOG}"
N_60=$(grep -c '^172\.28\.0\.60,127\.0\.0\.1$' "${REBIND_ANSWERS}")
N_LO=$(grep -c '^127\.0\.0\.1,172\.28\.0\.60$' "${REBIND_ANSWERS}")
log "  orderings observed from PowerDNS: permitted-first=${N_60}  forbidden-first=${N_LO}"

J="${RAW}/${GROUP}/99-ssrf-rebind.test.domain.json"
client_json "${J}" -mode=connect -proxy="${VIP}:${CLIENT_PORT}" \
    -target-host=ssrf-rebind.test.domain -target-port=443 ${CERT_VALID} ${CA_POC} \
    -duration="${B4_REBIND_DURATION:-20s}" -rps=4 -concurrency=1 -timeout=6s \
    -label=b4-rebind >/dev/null
ATT=$(jget "${J}" "d['attempts']")
SUCC=$(jget "${J}" "d['success']")
CREJ=$(jget "${J}" "d['connect_rejected']")
CODES=$(jget "${J}" "d['connect_status_codes']")
log "  attempts=${ATT} success(permitted address)=${SUCC} connect_rejected=${CREJ}"
log "  connect_status_codes=${CODES}"

if [ "${B4_MODEL}" = "hardened" ]; then
    log "  (Both outcomes from ONE name would show the counterfactual decision followed the"
    log "   resolved address, not the attacker-chosen name.)"
    case "${CODES}" in
        *"'403'"*)
            pass "B4.rebind the forbidden address was refused BY THE POLICY at least once (Squid 403; ${CREJ} of ${ATT} attempts)" ;;
        *)
            fail "B4.rebind no 403 observed -- the policy was never reached (codes=${CODES}, attempts=${ATT})" ;;
    esac
    [ "${SUCC}" -gt 0 ]
    expect "B4.rebind the permitted answer was NOT collateral damage (it still succeeded ${SUCC}x)" $?
else
    log "  (In production there is no policy for the answer to follow: whichever address the name"
    log "   resolves to, the CONNECT is allowed. A 403 here would mean the stack is not running the"
    log "   production-faithful config.)"
    case "${CODES}" in
        *"'403'"*)
            N_REFUSED=$((N_REFUSED+1))
            fail "B4.rebind CONNECT to ssrf-rebind.test.domain was refused with 403 (codes=${CODES}) -- production does not refuse it, whatever it resolves to" ;;
        *)
            N_ALLOWED=$((N_ALLOWED+1))
            pass "B4.rebind allowed regardless of the resolved address (no 403; codes=${CODES}, ${SUCC} succeeded against the permitted answer)" ;;
    esac
    # Evidence quality, not a policy claim: the loopback answer is the SSRF
    # shape, and it is what production accepts. Recorded so the group log shows
    # which answers the run actually exercised rather than only the aggregate.
    log "  note: ${N_LO} of 12 resolver replies put 127.0.0.1 first, so this run did exercise the"
    log "        loopback answer. Any 200/503 from it is an ALLOWED CONNECT to a loopback destination."
fi

# ---------------------------------------------------------------------------
# The closing verdict. It is a banner rather than a line of prose because the
# number this file produces in production-faithful mode is an ALLOW count, and
# a reader skimming for "how did CURRENT do on security" could otherwise take
# a page of PASS lines for a clean result. It is not one.
# ---------------------------------------------------------------------------
log ""
if [ "${B4_MODEL}" = "hardened" ]; then
    log "================================================================================"
    log "COUNTERFACTUAL RESULT — NOT PRODUCTION CURRENT"
    log ""
    log "  This run tested squid.conf.hardened, the resolved-address policy that an"
    log "  earlier revision of this POC attributed to production and then benchmarked"
    log "  as CURRENT's security posture. It is not deployed anywhere."
    log "  No result above may be presented as the behaviour of CURRENT in production."
    log ""
    log "  Production's real policy is an open forward proxy; see"
    log "  configs/squid/squid-1/squid.conf, docs/adr/0028-production-config-fidelity.md,"
    log "  and tests/fidelity/run.sh (which measures both side by side)."
    log "================================================================================"
    [ "${N_REFUSED}" -gt 0 ]
    expect "B4.verdict the counterfactual policy refused the corpus (${N_REFUSED} names with 403)" $?
else
    log "================================================================================"
    log "FINDING — CURRENT ARCHITECTURE, CONFIRMED VULNERABILITY"
    log ""
    log "  Squid in CURRENT has NO destination validation. Of the SSRF corpus sent"
    log "  through the real HAProxy CONNECT listener (${VIP}:${CLIENT_PORT}):"
    log ""
    log "    names ALLOWED (no 403)     : ${N_ALLOWED}"
    log "    names REFUSED with 403     : ${N_REFUSED}"
    log "    names with no reply at all : ${N_SILENT} (timeouts; Squid answered nothing)"
    log ""
    log "  'Allowed' includes loopback, RFC1918, link-local and the cloud instance-"
    log "  metadata address 169.254.169.254, and it is not a timeout artefact: the"
    log "  baseline above served the legitimate endpoint on the same path, and the"
    log "  control above shows the ONE thing that is refused is a non-Safe PORT."
    log ""
    log "  This is production's real configuration reproduced end to end, not a POC"
    log "  artefact, and it is why TARGET's resolved-address policy is net-new"
    log "  security capability rather than a re-implementation of an existing control."
    log ""
    log "  Full write-up: docs/adr/0028-production-config-fidelity.md"
    log "  Stack-free reproduction of the ACLs themselves: tests/fidelity/run.sh"
    log "  (SQUID_CONF=${SQUID_CONF} for this run; set SQUID_CONF=squid.conf.hardened"
    log "   to see the counterfactual refusal instead.)"
    log "================================================================================"
    [ "${N_REFUSED}" -eq 0 ]
    expect "B4.verdict production-faithful Squid refused NOTHING in the SSRF corpus (open proxy confirmed; ${N_ALLOWED} allowed, ${N_REFUSED} refused, ${N_SILENT} silent)" $?
fi

summary
