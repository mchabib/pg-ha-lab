#!/usr/bin/env bash
# Failover demo: keep writing through HAProxy :5000, kill the leader,
# and measure how long writes were unavailable. Then bring the old leader
# back and show it rejoin as a replica (pg_rewind).
#
# Usage: scripts/failover-demo.sh [stop|kill]   (default: kill = hard crash)
set -euo pipefail

cd "$(dirname "$0")/.."
MODE="${1:-kill}"
DC=(docker compose)
LOG=/tmp/writes.log

patronictl() { "${DC[@]}" exec -T pg1 patronictl -c /etc/patroni/patroni.yml "$@" 2>/dev/null \
            || "${DC[@]}" exec -T pg2 patronictl -c /etc/patroni/patroni.yml "$@" 2>/dev/null \
            || "${DC[@]}" exec -T pg3 patronictl -c /etc/patroni/patroni.yml "$@"; }

leader() {
  patronictl list -f json | python3 -c 'import json,sys; print(next(m["Member"] for m in json.load(sys.stdin) if m["Role"]=="Leader"))'
}

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

step "Cluster before"
patronictl list
OLD="$(leader)"
echo "Leader: $OLD"

step "Start writer: one INSERT every 100 ms through haproxy:5000"
"${DC[@]}" exec -T client psql -qc \
  "CREATE TABLE IF NOT EXISTS ticks(id bigserial PRIMARY KEY, at timestamptz DEFAULT clock_timestamp(),
                                    served_by text DEFAULT inet_server_addr()::text);
   TRUNCATE ticks" >/dev/null
"${DC[@]}" exec -T client sh -c "rm -f $LOG; nohup sh -c '
  while :; do
    t=\$(date +%s%3N)
    if psql -XAtqc \"INSERT INTO ticks DEFAULT VALUES RETURNING served_by\" >/tmp/out 2>/dev/null
    then echo \"\$t ok \$(cat /tmp/out)\" >> $LOG
    else echo \"\$t fail\" >> $LOG; fi
    sleep 0.1
  done' >/dev/null 2>&1 &"
sleep 3

now_ms() { date +%s%3N; }

step "${MODE^^} the leader ($OLD)"
KILL_MS=$(now_ms)
if [[ "$MODE" == stop ]]; then "${DC[@]}" stop "$OLD"; else "${DC[@]}" kill "$OLD"; fi

echo -n "Waiting for a new leader"
NEW=""
for _ in $(seq 1 120); do
  NEW="$(leader 2>/dev/null || true)"
  [[ -n "$NEW" && "$NEW" != "$OLD" ]] && break
  NEW=""; echo -n "."; sleep 1
done
LEADER_MS=$(now_ms)
echo; echo "New leader: ${NEW:-none} after $(( (LEADER_MS - KILL_MS) / 1000 )) s"

echo -n "Waiting for writes to succeed again"
for _ in $(seq 1 120); do
  # shellcheck disable=SC2016  # awk program, not shell
  "${DC[@]}" exec -T client awk -v t="$KILL_MS" '$2 == "ok" && $1 > t { f = 1 } END { exit !f }' "$LOG" && break
  echo -n "."; sleep 1
done
echo
sleep 3   # a few more writes on the new leader

# pkill runs directly (no wrapping shell), so its own command line can't match
"${DC[@]}" exec -T client pkill -f 'INSERT INTO ticks' >/dev/null 2>&1 || true

step "Write availability"
"${DC[@]}" exec -T client cat "$LOG" | awk -v kill="$KILL_MS" '
  $2 == "ok" && $1 <= kill { last_before = $1 }
  $2 == "ok" && $1 >  kill && !first_after { first_after = $1 }
  $2 == "ok"   { ok++ }
  $2 == "fail" { fail++ }
  END {
    printf "writes ok: %d, failed attempts: %d\n", ok, fail
    if (!first_after) { print "writes did NOT recover"; exit 1 }
    printf "write downtime: %.1f s (last ok before the crash -> first ok after)\n", (first_after - last_before) / 1000
  }'
"${DC[@]}" exec -T client psql -XAtc \
  "SELECT served_by, count(*) FROM ticks GROUP BY 1 ORDER BY min(at)" | sed 's/^/served by /'

step "Cluster after failover"
patronictl list

step "Bring $OLD back: it should rejoin as a replica"
"${DC[@]}" start "$OLD"
for _ in $(seq 1 60); do
  patronictl list -f json | python3 -c "import json,sys; m=[x for x in json.load(sys.stdin) if x['Member']=='$OLD']; sys.exit(0 if m and m[0]['State'] in ('streaming','running') and m[0]['Role']!='Leader' else 1)" && break
  sleep 2
done
patronictl list
