#!/bin/sh
# VRRP state-transition hook, invoked by keepalived on MASTER/BACKUP/FAULT/STOP.
#
# CAVEAT: this output is NOT the failover evidence. keepalived does not forward
# notify-script stdout to the container log, and busybox `date` (this image is
# Alpine) has no %N, so the timestamp below renders without fractional seconds.
# Failover timings are taken from keepalived's own console log instead -- see
# vrrp_events() in tests/lib.sh and tests/failover/FAILOVER-NOTES.txt.
STATE="${1:-UNKNOWN}"
printf '[vrrp] %s state=%s node=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "${STATE}" "$(hostname)"
