# Runbook: PostgreSQL replication lag above 60 seconds

**Alert**: `pg_replication_lag_seconds > 60` for more than 5 minutes on any streaming replica in the `meridian` production cluster at Northwind Logistics.
**Severity**: High during business hours (07:00 to 19:00 UTC). Medium outside those hours.
**Impact**: Read queries routed to the lagging replica return stale data. Failover to this replica risks data loss up to the lag amount.

## What this alert means

The primary ships write-ahead log (WAL) records to each replica over streaming replication. The replica replays those records to stay current. The alert fires when the replay position trails the primary write position by more than 60 seconds. Lag has three possible points of origin: the primary is not sending, the network is not carrying, or the replica is not applying [PGDOCS-MON].

## Diagnosis

Run these steps in order. Each step takes under two minutes.

**Step 1: Identify the lagging replica.** The alert names the instance. Confirm from the primary:

```sql
SELECT application_name, state, sync_state,
       sent_lsn, write_lsn, flush_lsn, replay_lsn,
       now() - pg_last_xact_replay_timestamp() AS replay_delay
FROM pg_stat_replication;
```

Compare `sent_lsn` against `replay_lsn`. If `sent_lsn` is current but `replay_lsn` is behind, the replica receives WAL but cannot apply it. If `sent_lsn` itself is behind, the problem is upstream of the replica [PGDOCS-MON].

**Step 2: Check whether the receiver and WAL sender are alive.** On the replica:

```sql
SELECT status, receive_start_lsn, written_lsn, flushed_lsn
FROM pg_stat_wal_receiver;
```

If this returns no rows, streaming has stopped entirely. Go to cause: replication slot or WAL sender failure [PGDOCS-RECV].

**Step 3: Check for replay conflicts.** On the replica:

```sql
SELECT datname, confl_lock, confl_snapshot, confl_bufferpin, confl_deadlock
FROM pg_stat_database_conflicts;
```

Rising counters, especially `confl_lock` or `confl_snapshot`, mean a query on the replica blocks replay. Go to cause: long-running query on the replica [PGDOCS-CONF].

**Step 4: Check WAL volume.** Compare the lag trend against write traffic:

```sql
SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
FROM pg_stat_replication;
```

Large `lag_bytes` during a bulk load, backfill, or index build points to cause: write burst exceeds apply capacity.

## Cause: long-running query on the replica

A reporting query or dashboard holds a snapshot or lock on the replica. Replay must wait when it needs to remove rows that the query can still see.

**Confirm**: Step 3 shows rising conflict counters. `pg_stat_activity` on the replica shows a query older than the lag duration.

**Fix**:

1. Identify the query: `SELECT pid, usename, now() - query_start AS age, query FROM pg_stat_activity WHERE state = 'active' ORDER BY query_start;`
2. If the query is safe to kill, terminate it: `SELECT pg_terminate_backend(<pid>);`
3. Watch `replay_lsn` catch up within a few minutes.

**Prevent**: Set `hot_standby_feedback = on` on the replica so the primary keeps rows that standby queries need [PGDOCS-HS]. If that grows table bloat on the primary, instead cap how long replay waits with `max_standby_streaming_delay` and accept that some standby queries get canceled.

## Cause: replication slot or WAL sender failure

The replication slot on the primary has gone inactive, or the WAL sender process has died. The replica receives nothing.

**Confirm**: Step 2 returns no rows. On the primary, `SELECT * FROM pg_replication_slots;` shows the slot `active = false`, or the slot is missing [PGDOCS-SLOT].

**Fix**:

1. Check the replica log at `/var/log/postgresql/` for the disconnect reason. Common entries are a dropped connection or a slot removed by mistake.
2. If the slot exists but is inactive, restart the replica: `pg_ctl restart -D /var/lib/postgresql/data`. Streaming resumes from the slot position.
3. If the slot is gone, recreate it and rebuild the replica with `pg_basebackup` if the required WAL is no longer retained. Check `pg_settings` for `wal_keep_size` before you rebuild; the needed WAL may still be on disk.

**Prevent**: Alert on inactive replication slots. Retain enough WAL with `wal_keep_size` so a short outage never forces a rebuild.

## Cause: write burst exceeds apply capacity

A bulk load, migration, or `CREATE INDEX` on the primary generates WAL faster than the replica can replay it. Replay is single-threaded, so it falls behind even on healthy hardware [PGDOCS-MON].

**Confirm**: Step 4 shows large `lag_bytes` that grows during a known write job. Replica CPU and disk I/O sit near saturation. No conflicts in step 3.

**Fix**:

1. Wait, if the burst is short and finite. Lag drains once the job ends. Estimate drain time from the apply rate: watch `replay_lsn` advance over one minute and divide remaining `lag_bytes` by that rate.
2. If a migration is running, throttle it or pause it until the replica catches up. Coordinate with the deploy owner in `#meridian-deploys`.
3. If the replica disk is the bottleneck (check `iostat -x 5`, utilization above 90 percent), move WAL replay pressure by adding memory or faster storage at the next maintenance window.

**Prevent**: Schedule large backfills outside business hours. Route read traffic away from the replica during planned bulk loads.

## Escalation

Escalate to the database on-call engineer under any of these conditions:

- Lag exceeds 600 seconds or keeps growing after you apply the fix for the matching cause.
- More than one replica lags at the same time. This points at the primary, not the replicas.
- The replication slot is missing and WAL is no longer retained, so a full `pg_basebackup` rebuild is required.
- The primary shows errors in its own log, or `pg_stat_replication` on the primary returns no rows for a replica that should be connected.

Escalate immediately to the incident commander if the primary also reports problems, because failover planning then takes priority over replica health. Page through PagerDuty service `meridian-postgres`. Post a status line in `#meridian-ops` when you start, when you identify the cause, and when lag returns below 60 seconds.

## Notes

Do not fail over to a lagging replica unless the primary is down. A planned failover to a replica 60 seconds behind discards up to 60 seconds of committed writes.

[PGDOCS-MON]: https://www.postgresql.org/docs/current/monitoring-stats.html
[PGDOCS-RECV]: https://www.postgresql.org/docs/current/monitoring-stats.html#MONITORING-PG-STAT-WAL-RECEIVER-VIEW
[PGDOCS-CONF]: https://www.postgresql.org/docs/current/monitoring-stats.html#MONITORING-PG-STAT-DATABASE-CONFLICTS-VIEW
[PGDOCS-SLOT]: https://www.postgresql.org/docs/current/view-pg-replication-slots.html
[PGDOCS-HS]: https://www.postgresql.org/docs/current/hot-standby.html
