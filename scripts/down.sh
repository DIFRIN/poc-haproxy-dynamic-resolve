#!/usr/bin/env bash
# ============================================================================
# down.sh [extra docker compose args] — tear down every service of BOTH
# architectures.
#
# All three compose files are passed so nothing is left behind when switching
# between CURRENT and TARGET: the two stacks share container names and static
# addresses, so a leftover container from the other architecture would hold an
# address the new stack needs.
#
# Volumes are NOT removed, so the 1M-record PostgreSQL dataset survives. Use
#   docker compose -f compose.yaml down -v
# if you want a genuinely blank start and a fresh seed.
# ============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

docker compose -f compose.yaml -f compose.current.yaml -f compose.bench.yaml \
    down --remove-orphans "$@"
