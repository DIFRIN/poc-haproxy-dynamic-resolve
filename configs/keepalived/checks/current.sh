#!/bin/sh
# ============================================================================
# CURRENT node health check — decides whether THIS node keeps the VIP.
#
# Checks ONLY the local HAProxy process.
#
# SQUID IS DELIBERATELY EXCLUDED. The Squid pair is a shared fate domain BELOW
# a highly-available frontend: whichever HAProxy owns the VIP uses the whole
# Squid layer, and losing both Squids takes the datacenter down regardless of
# what Keepalived does. Making a shared component part of a per-node check
# would bounce the VIP between two nodes that are equally unable to serve --
# adding an outage window on top of an outage, and moving the VIP for a fault
# that VIP movement cannot fix. See docs/architecture.md §4.
#
# Exit 0 = healthy (keep the VIP). Non-zero = this node's local stack is broken.
# ============================================================================
set -u

pidof haproxy >/dev/null 2>&1 || exit 1

exit 0
