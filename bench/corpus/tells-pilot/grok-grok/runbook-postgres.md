The alert **PostgreSQL replication lag above 60 seconds** means a streaming replica that serves production reads is more than 60 seconds behind the primary. Northline runs one primary in us-east-1 and two replicas. replica-a is in the same region and is the default read pool. replica-b is in eu-west-1 and is both the regional read target and the failover candidate. At 60 seconds, shipment-status and invoice queries can return stale rows. The primary can still be healthy. Do not promote a replica because this alert fired.

## Confirm the alert

Note which host fired, the lag in seconds, and whether the graph is rising, flat, or falling. The dashboard can trail the database by about a minute, so confirm on the host before you change anything.

On the primary, connect as the monitoring role:

```sql
SELECT application_name, client_addr, state, sync_state,
       sent_lsn, write_lsn, flush_lsn, replay_lsn,
       write_lag, flush_lag, replay_lag
FROM pg_stat_replication
ORDER BY application_name;
```

On the replica named in the alert:

```sql
SELECT now() - pg_last_xact_replay_timestamp() AS replay_age,
       pg_is_in_recovery() AS in_recovery,
       pg_last_wal_receive_lsn() AS receive_lsn,
       pg_last_wal_replay_lsn() AS replay_lsn;
```

Read the two results together.

- `state` is `streaming`, `write_lag` is near zero, and `replay_lag` is high: WAL is arriving and apply is slow.
- `write_lag` and `replay_lag` are both high, or `state` is not `streaming`: the replica is not receiving WAL.
- `pg_is_in_recovery()` is false: stop. That host is not a replica. You are on the primary, or a promotion already happened.

Check the deploy log and the job runner for the last 30 minutes. Look for a migration, a backfill, a large `VACUUM`, or a failover. Check free disk on the primary and the WAL growth rate. A stuck replica holds WAL on the primary through its replication slot. If the primary volume is above 80 percent full, treat disk as the urgent problem even though lag is what paged you.

## A batch write on the primary

A backfill, a large `UPDATE`, a `COPY`, or an index build can emit WAL faster than a replica can replay it. The usual picture is `replay_lag` rising on both replicas, a busy primary, and one session with an old `xact_start`.

On the primary:

```sql
SELECT pid, usename, application_name, state,
       wait_event_type, wait_event,
       now() - xact_start AS xact_age,
       left(query, 200) AS query
FROM pg_stat_activity
WHERE state <> 'idle'
  AND backend_type = 'client backend'
ORDER BY xact_start NULLS LAST
LIMIT 20;
```

If that list shows the backfill or migration, pause that job. Do not cancel unrelated application sessions. Watch `replay_lag` for ten minutes after the job stops. Lag should fall without a restart. If the work still has to finish, ask the owner to run it again in batches of a few thousand rows per transaction, not one multi-hour transaction. Leave a running index build in place when lag is falling and primary disk is healthy. Cancel it only when disk risk is real. A cancel throws away the work, and the replica still has to replay WAL that was already generated.

## The replica cannot apply WAL quickly enough

`write_lag` stays low and `replay_lag` stays high, often on only one replica. The usual reasons are a saturated data volume, a recovery conflict with a long read, or `max_standby_streaming_delay` holding replay behind a query while `hot_standby_feedback` is off.

On the replica, look for `active` sessions with an old `query_start`. Check iowait and disk utilization on the host. If the Postgres log shows `recovery conflict` and one reporting query is the blocker, cancel that query on the replica. A cancel there does not change data on the primary. Remove that replica from the read pool so traffic uses the other one. Leave it out until `replay_lag` stays under 5 seconds for ten minutes, then add it back. If disk is the limit, do not restart Postgres. A restart does not make replay faster and can widen the gap. If the volume cannot keep up with the normal WAL rate, escalate.

## Replication is not streaming

`pg_stat_replication.state` is `startup`, `catchup`, or `stopping`, or the row for that replica is missing. `write_lag` is null or large. The wal receiver may have exited, a network rule may have cut the path, or a deploy may have exhausted `max_wal_senders`.

Read the last 100 lines of the replica log. Look for `could not receive data`, `requested WAL segment has already been removed`, or connection attempts that repeat. On the primary, confirm a `walsender` exists for that `application_name`. If a network change in the last hour lines up with the start of the lag, restore the path from the replica to the primary on port 5432.

If the log says the WAL segment is already gone, waiting will not help. Do not drop the replication slot. The slot is what keeps the primary from recycling WAL this replica still needs. A missing segment means you rebuild that replica from a new base backup. Start the documented rebuild for that host and keep reads off it until `state` is `streaming` and lag is under 5 seconds. If free disk on the primary is still falling while you wait, escalate now. A full primary disk is an outage, and a rebuild is slower than catch-up.

## When to escalate

Page the database on-call and post in #incidents when any of these are true:

- Lag is still rising 15 minutes after you paused the job or removed the replica from the pool.
- Replay lag is above 10 minutes on replica-a during business hours, or above 5 minutes on replica-b while it is the only healthy replica in that region.
- Free disk on the primary is under 20 percent, or the WAL volume is growing because a slot is stuck.
- The replica log says a required WAL segment has already been removed.
- `pg_is_in_recovery()` is false on a host that should be a replica, or you are about to promote.
- You are not sure which host is the primary. Do not promote, do not drop a slot, and do not restart the primary.

You do not need a root cause to escalate. Send the alert name, the host, both query outputs, whether lag is rising or falling, primary free disk, and what you already changed. Stay on the incident until the database on-call acknowledges the page.

If lag peaked above 60 seconds and is now under 5 seconds, and both replicas are `streaming`, resolve the page. Record the peak lag, the host, and the cause in the incident channel. Put the replica back in the pool once lag has stayed low.
