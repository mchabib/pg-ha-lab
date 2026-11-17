#!/usr/bin/env bash
# Planned switchover (maintenance): move leadership gracefully to a replica.
# Usage: scripts/switchover.sh [candidate]
set -euo pipefail
cd "$(dirname "$0")/.."

ARGS=(--force)
[[ -n "${1:-}" ]] && ARGS+=(--candidate "$1")

docker compose exec -T pg1 patronictl -c /etc/patroni/patroni.yml list
docker compose exec -T pg1 patronictl -c /etc/patroni/patroni.yml switchover "${ARGS[@]}"
sleep 5
docker compose exec -T pg1 patronictl -c /etc/patroni/patroni.yml list
