#!/usr/bin/env bash
# Show where HAProxy sends reads and writes right now.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "Writes (:5000) go to:"
docker compose exec -T client psql -p 5000 -XAtc \
  "SELECT inet_server_addr() || '  pg_is_in_recovery=' || pg_is_in_recovery()"

echo "Reads (:5001), 6 connections:"
for _ in 1 2 3 4 5 6; do
  docker compose exec -T client psql -p 5001 -XAtc \
    "SELECT '  ' || inet_server_addr() || '  pg_is_in_recovery=' || pg_is_in_recovery()"
done

echo "Replication (from leader):"
docker compose exec -T client psql -p 5000 -XAc \
  "SELECT application_name, state, sync_state, replay_lag FROM pg_stat_replication ORDER BY 1"
