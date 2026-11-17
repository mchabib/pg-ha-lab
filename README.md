# pg-ha-lab

A PostgreSQL 16 high-availability cluster you can run on a laptop: **Patroni + etcd + HAProxy**, with scripts that kill the leader and measure how long writes are unavailable.

It mirrors the layout I run in production for hospital systems, scaled down to Docker Compose.

```
              app / psql
                  │
        ┌─────────┴─────────┐
        │      HAProxy      │   :5000  read-write  → GET :8008/primary == 200
        │                   │   :5001  read-only   → GET :8008/replica == 200
        └──┬──────┬──────┬──┘   :7000  stats
           │      │      │
         ┌─▼─┐  ┌─▼─┐  ┌─▼─┐
         │pg1│  │pg2│  │pg3│   PostgreSQL 16 + Patroni
         └─┬─┘  └─┬─┘  └─┬─┘   leader + sync standby + async replica
           └──────┼──────┘
         ┌────────┴────────┐
         │ etcd × 3 (DCS)  │   leader lock, cluster config
         └─────────────────┘
```

## Run it

```bash
docker compose up -d --build
docker compose exec pg1 patronictl -c /etc/patroni/patroni.yml list
scripts/check-routing.sh        # where :5000 and :5001 land, replication state
scripts/failover-demo.sh        # crash the leader while writing, measure the gap
scripts/switchover.sh pg2       # planned, graceful leader change
```

HAProxy stats: <http://127.0.0.1:7000>. All ports bind to `127.0.0.1`.

## What the failover demo does

1. Starts a writer that runs one `INSERT` every 100 ms through `haproxy:5000`, logging success or failure with a millisecond timestamp.
2. Finds the leader with `patronictl list` and kills it (`docker compose kill`, a hard crash) or stops it (`stop`).
3. Waits for Patroni to promote a replica, then reports:
   - **write downtime**: last successful write before the crash → first successful write after
   - how many rows each server accepted
4. Starts the old leader again and shows it rejoin as a replica through `pg_rewind`, without a full re-clone.

## Measured results

From a fresh cluster on a laptop (Docker, PostgreSQL 16, Patroni 4.1), one `INSERT` every 100 ms:

| Scenario | New leader after | Write downtime | Old leader |
|---|---|---|---|
| `failover-demo.sh kill`: leader crashes | 20 s | **20.7 s** | rejoins as replica |
| `failover-demo.sh stop`: leader shuts down cleanly | 3 s | **7.0 s** | rejoins as replica |

- A **crash** is bounded by the leader lock TTL (`ttl: 20`). Nobody can tell a dead leader from a slow one until the lock expires.
- A **clean shutdown** releases the lock right away, so a replica takes over in about one loop. The rest of the gap is HAProxy's health check (`inter 2s`, `rise 2`).
- In the crash run the writer counted 22 successful inserts, but the table had **23 rows**. The insert in flight at the moment of the crash was committed on the sync standby, but the connection died before the client got the reply. Synchronous replication kept the row. The client just couldn't know. Applications should retry with idempotent writes, not assume a failed commit means nothing happened.

### A bug the lab caught: DNS stalled the promotion

The first version addressed nodes by container name. During a failover the new leader logged `received promote request` and then took **43 s** to finish promotion, while Patroni already reported it as leader. HAProxy sent writes to it, and every one failed with `cannot execute INSERT in a read-only transaction`.

The cause: to finish promotion, PostgreSQL first stops the WAL receiver. The WAL receiver was blocked in a DNS lookup for the dead leader. Docker removes a stopped container's name, so the lookup fell through to the host resolver and waited for its timeout. The fix was static IPs for every node, in replication, HAProxy and the etcd host list. The same rule applies on real servers: a dead node must not make anything wait on DNS.

## Design choices

| Choice | Why |
|---|---|
| `synchronous_mode: true` | One standby confirms every commit, so a committed write is never lost on failover. Costs some write latency. |
| `ttl 20 / loop_wait 5 / retry_timeout 5` | Faster failover than the defaults (30/10/10) for the demo. Keeps `loop_wait + 2 × retry_timeout ≤ ttl`. |
| HAProxy health checks on the Patroni REST API | HAProxy asks Patroni who the leader is instead of checking TCP, so it never routes writes to a replica that still accepts connections. |
| `on-marked-down shutdown-sessions` | Old connections to a demoted node are cut right away instead of failing later. |
| `use_pg_rewind` + `wal_log_hints` + data checksums | The old leader can catch up from where the timelines diverged. |
| 3 etcd members | The DCS survives one member failing; with fewer, losing etcd quorum stops all failovers. |

## In production, also

- **keepalived** with a VIP in front of two HAProxy hosts, so the proxy is not a single point of failure. It's left out here because a VIP inside Docker doesn't behave like a real network.
- TLS between clients, HAProxy and PostgreSQL, and `pg_hba` limited to app subnets.
- Backups with restore drills, see [pg-backup-verified](https://github.com/mchabib/pg-backup-verified).
- Monitoring Patroni's `/metrics` endpoint and replication lag in Prometheus.

## Reset

```bash
docker compose down -v
```

## License

MIT
