CedarCart uses PostgreSQL with one primary and two direct, asynchronous physical standbys. Standbys serve catalog reads and provide failover capacity. This procedure covers the alert **“PostgreSQL replication lag above 60 seconds.”**

The alert fires when a standby’s replicated heartbeat remains over 60 seconds old for five minutes. The primary updates this heartbeat every five seconds. The service on-call engineer owns the initial response.

### Diagnose the alert

1. **Acknowledge the alert.** Record the cluster, affected standby, alert start time, and current lag in the incident log. Check whether customers receive stale results or read errors.

2. **Protect affected reads.** Remove the standby from read traffic if stale results affect customers. Route reads only to a healthy destination with spare capacity. Do not promote a standby solely to clear this alert.

3. **Validate the measurement.** Check that the heartbeat advances on the primary. Check monitoring freshness and clock synchronization. A failed heartbeat job can produce this alert without a replication failure.

   Do not use `now() - pg_last_xact_replay_timestamp()` alone to confirm lag. That value increases during idle periods, even when the standby has no outstanding transactions.

4. **Inspect replication on the primary.** Use the approved monitoring account:

   ```sql
   SELECT application_name,
          client_addr,
          state,
          sync_state,
          sent_lsn,
          write_lsn,
          flush_lsn,
          replay_lsn,
          pg_wal_lsn_diff(
            pg_current_wal_lsn(), replay_lsn
          ) AS pending_bytes
   FROM pg_stat_replication;
   ```

   Identify the affected standby by its registered name and address. A missing row means the primary has no active WAL sender for that standby.

5. **Inspect the affected standby.**

   ```sql
   SELECT pg_is_in_recovery() AS is_standby,
          pg_last_wal_receive_lsn() AS received_lsn,
          pg_last_wal_replay_lsn() AS replayed_lsn,
          pg_get_wal_replay_pause_state() AS pause_state;
   ```

   If `is_standby` is false, stop corrective actions and escalate. The server role differs from the expected topology.

6. **Repeat both samples after 30 seconds.** Use separate transactions so each sample receives fresh statistics. Log sequence numbers, or LSNs, identify positions in the write-ahead log (WAL).

   If received WAL trails the primary, investigate delivery or write capacity. If received WAL advances but replay stalls, investigate replay delays. If both advance slowly, compare WAL production with standby processing capacity.

   Byte differences show outstanding WAL volume, not elapsed time. PostgreSQL’s [replication statistics](https://www.postgresql.org/docs/current/monitoring-stats.html#MONITORING-PG-STAT-REPLICATION-VIEW) describe `replay_lag` as recent replay delay, not recovery time. A null value does not prove that replication is healthy.

7. **Compare supporting evidence.** Check CPU, storage latency, free space, network errors, WAL production, and database logs. Compare the alert start time with deployments, bulk imports, backups, and scheduled reports.

### Likely cause 1: The standby cannot process the WAL volume

**Evidence:** Outstanding WAL grows while replay continues. Standby CPU or storage reaches capacity. A bulk import, backup, or reporting workload coincides with the increase.

**Fix:** Pause the identified nonessential report or backup through its approved control. Ask the application owner to reduce bulk writes if WAL production exceeds standby capacity. Preserve essential application traffic.

Check whether outstanding WAL decreases across three consecutive samples. If it does not, involve the database engineer for storage or instance capacity changes.

If storage approaches exhaustion, escalate immediately. Do not delete files from `pg_wal` or remove replication slots to recover space.

### Likely cause 2: A query or administrative pause delays replay

**Evidence:** Received WAL advances while replay remains stationary. Logs report recovery conflicts, or the pause state shows `paused` or `pause requested`.

**Fix:** For a pause, check the maintenance record and identify its owner. Resume replay only after the owner confirms that the pause can end:

```sql
SELECT pg_wal_replay_resume();
```

For query conflicts, inspect `pg_stat_activity`, recovery logs, and changes in `pg_stat_database_conflicts`. Conflict counters record cancellations, so their absence does not exclude a current replay delay.

Identify the conflicting session before any cancellation. Cancel an expendable report with `pg_cancel_backend(pid)` under CedarCart’s incident authority. Coordinate with its owner when possible. Do not cancel sessions based only on duration.

### Likely cause 3: WAL delivery stops

**Evidence:** The primary lacks the standby’s replication row, received WAL stops, or logs show connection failures. Errors may identify authentication failures, network failures, or unavailable WAL segments.

**Fix:** Check `pg_stat_wal_receiver` on the standby and replication logs on both servers. Restore the failed network path or approved replication configuration through its owning team.

If required WAL no longer exists on the primary, involve the database engineer. Recover available WAL from the archive or use the approved standby rebuild procedure.

### Escalation and recovery

Page the database engineer immediately if:

- Lag exceeds five minutes.
- Both standbys are affected.
- Storage will exhaust within 30 minutes.
- Logs report missing WAL or corruption.
- Server roles differ from the expected topology.

Declare a major incident if customer impact persists or the primary becomes unstable. Escalate if outstanding WAL does not decrease within 15 minutes after acknowledgment.

Close the incident after heartbeat lag remains below 10 seconds for 15 minutes. Confirm normal resource use and read behavior. Restore traffic gradually. Record the cause, corrective actions, evidence, and preventive work.
