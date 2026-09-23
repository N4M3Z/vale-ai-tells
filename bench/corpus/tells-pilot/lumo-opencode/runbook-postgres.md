# Runbook: PostgreSQL replication lag above 60 seconds

**Alert:** `pg_replication_lag > 60s` (fires for 5 minutes)
**Severity:** Warning during business hours, High outside them
**Oncall role:** Database reliability (fallback: platform on-call)

## What this alert means

The `metric_pg_replication_lag` alert measures the delay between the primary writing a WAL record and a standby replaying it. When lag exceeds 60 seconds, failover protection degrades: if the primary dies now, the standby may lose up to that many seconds of committed transactions. It does not mean replication is broken (that is the separate `pg_replication_down` alert), only that it has fallen behind.

## Initial triage (5 minutes)

1. **Confirm which standby is lagging.** Open the Replication dashboard in Grafana and check each standby. Lag on one replica is a local problem; lag on all replicas points at the primary or the network.

2. **Check whether lag is climbing or plateaued.** A flat 70-second lag that holds steady is less urgent than lag racing toward minutes. Climbing lag gets priority for the rest of this runbook.

3. **Identify what changed recently.** In the `#deploys` channel, look for deploys in the last two hours touching ingest paths, batch jobs, or the database schema. Check the query stats dashboard for any new query appearing since the lag began.

4. **Check the primary's load.** Look at primary CPU, WAL generation rate (dashboard panel "WAL bytes/sec"), and disk IO utilization. A spike in WAL generation is the most common trigger.

5. **Look for long-running queries or vacuums on the standby.** Hot standby replay can stall behind a query holding a conflicting lock. On the lagging standby run:

   ```sql
   SELECT pid, now() - query_start AS duration, state, query
   FROM pg_stat_activity
   WHERE state != 'idle'
   ORDER BY duration DESC
   LIMIT 10;
   ```

   Queries running longer than the lag value are suspects.

6. **Check the network.** From the standby, `ping` the primary and look at the `pg_network_rtt` panel. Sustained RTT above 50 ms or packet loss above 0.1% explains slow WAL shipping without anything being wrong with PostgreSQL itself.

## Likely causes and fixes

### Cause 1: Bulk write burst on the primary

A large migration, backfill, or batch job generated WAL faster than the standby could replay it. You will see high WAL generation rate on the primary and normal CPU on the standby, with lag climbing sharply at a specific timestamp.

**Fix:** Find the offending job (`pg_stat_activity` on the primary, sorted by WAL impact; the deploy log from triage step 3). If it is a scheduled job, let it finish; lag should decay steadily afterward, roughly at replay speed minus generation speed. If it is an ad-hoc query from a person, contact them and ask them to throttle it, or cancel it with `SELECT pg_cancel_backend(<pid>);` if they cannot be reached and lag is still climbing. Ask the job owner to add `commit_delay` batching or move the job to off-peak hours. Do not restart the standby; it discards the replay buffer and makes lag worse temporarily.

### Cause 2: Replay blocked by a long-running query on the standby

Replicas serve read traffic. A reporting query that conflicts with replayed WAL blocks replay until it finishes or hits `max_standby_streaming_delay` (we set 30s). When many such queries queue up, replay falls behind. You will see low network lag but growing replay lag, plus long-duration queries from step 5.

**Fix:** Identify the blocking queries. If they belong to the analytics service, kill the longest one: `SELECT pg_terminate_backend(<pid>);` and confirm lag begins dropping within a minute. If this happens repeatedly, file a ticket for the analytics team to add a statement timeout, and consider raising `hot_standby_feedback` off and lowering `max_standby_streaming_delay` after discussing with the query owners. Killing a read query loses no data; do not hesitate when lag is above five minutes.

### Cause 3: Network saturation between primary and standby

Cross-AZ or cross-region bandwidth caps, a snapshot backup saturating the same link, or DNS failover rerouting traffic can starve WAL shipping. You will see lag on subsets of standbys sharing a link, high network queue depth, and normal primary metrics.

**Fix:** Check the network dashboard for the affected path. If a backup or snapshot job is consuming the link, throttle it (`ethrottle` cron on the backup host) rather than stopping it. If the link itself is degraded, page network on-call (see escalation) and set `wal_sender_timeout` awareness aside; do not modify it under pressure. Once bandwidth frees up, lag drains automatically. Expect drain time roughly equal to accumulated lag divided by available headroom.

## When to escalate

- **Lag exceeds 15 minutes** or keeps climbing 30 minutes after you applied a fix: page the secondary database on-call and post in `#db-incidents`.
- **Network degradation confirmed** (packet loss, saturated link with no identifiable consumer): transfer to network on-call with the RTT graphs attached.
- **Primary health symptoms appear** (CPU saturation, WAL accumulation on disk, checkpoints falling behind): treat as a potential primary incident; declare an incident and bring in the DBRE lead immediately, since a failover under heavy lag risks data loss.
- **Lag persists after all causes are ruled out**: open a ticket to Datadog support with the `pg_stat_wal_receiver` output, but keep the alert acknowledged with a note in the oncall channel every hour until resolved.

After resolution, acknowledge the alert with a short postmortem note in `#db-incidents`: peak lag, root cause, fix, and any follow-up tickets filed.
