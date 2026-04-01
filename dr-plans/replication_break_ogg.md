# Disaster Recovery — Oracle GoldenGate Replication Break

> **RTO:** 1 hour | **RPO:** < 1 minute  
> **Scenario:** GoldenGate extract or replicat process failure, trail file corruption, or network-induced replication break

---

## Detection

- Splunk alert: `GoldenGate Replication Lag` saved search triggers at > 30s lag
- Coherence monitoring shows stale data (scoring decisions based on outdated risk parameters)
- GoldenGate management API reports ABENDED or STOPPED process

## Severity Assessment

| Lag Duration | Severity | Action |
|---|---|---|
| 30s - 60s | Medium | Monitor, investigate root cause |
| 60s - 5 min | High | Active intervention required |
| > 5 min | Critical | Pause dependent jobs, begin recovery |

## Recovery Procedure

### Step 1: Assess the Break (T+0 to T+10 min)

```bash
# SSH to GoldenGate host
ssh ogg-host.prod.internal

# Check all process status
cd /opt/oracle/ogg
./ggsci << EOF
info all
EOF

# Check specific extract/replicat lag
./ggsci << EOF
lag extract ERISK1
lag replicat RRISK1
EOF

# Check trail file integrity
./ggsci << EOF
info trail /opt/oracle/ogg/dirdat/rt
EOF

# Check for error in GoldenGate error log
tail -100 /opt/oracle/ogg/ggserr.log | grep -E "ERROR|ABEND|WARNING"
```

### Step 2: Pause Dependent Systems (T+10 to T+15 min)

```bash
# Hold batch jobs that depend on replicated data
curl -sk -X POST -H "Authorization: Bearer $CTM_TOKEN" \
  "$CONTROLM_API/run/jobs/hold?jobname=RISK_DAILY_SCORING"
curl -sk -X POST -H "Authorization: Bearer $CTM_TOKEN" \
  "$CONTROLM_API/run/jobs/hold?jobname=RISK_EOD_RECON"

# Note: Do NOT stop the scoring engines — they use cached data
# Cache staleness is acceptable for short periods
```

### Step 3: Recover Based on Failure Type

**Type A: Extract ABENDED (source side)**
```bash
./ggsci << EOF
# Check extract checkpoint
info extract ERISK1, detail
# Restart from last checkpoint
start extract ERISK1
EOF

# If checkpoint is corrupted — re-position
./ggsci << EOF
alter extract ERISK1, begin now
start extract ERISK1
EOF
```

**Type B: Replicat ABENDED (target side)**
```bash
./ggsci << EOF
# Check replicat status and error
info replicat RRISK1, detail
view report RRISK1
EOF

# Common fix: skip the offending transaction
./ggsci << EOF
# If caused by duplicate key / constraint violation
alter replicat RRISK1, extrba <trail_file>, extseqno <seq>, extrba <rba>
start replicat RRISK1
EOF
```

**Type C: Trail file corruption**
```bash
# Identify corrupted trail
./ggsci << EOF
info trail /opt/oracle/ogg/dirdat/rt
EOF

# Re-extract from source checkpoint
./ggsci << EOF
stop extract ERISK1
alter extract ERISK1, etrollover
start extract ERISK1
EOF

# Reposition replicat to new trail
./ggsci << EOF
alter replicat RRISK1, begin now
start replicat RRISK1
EOF
```

**Type D: Network interruption**
```bash
# Verify network connectivity to target
ping -c 5 ogg-target.prod.internal
traceroute ogg-target.prod.internal

# GoldenGate will auto-recover once network is restored
# Monitor trail file accumulation on source
ls -lrt /opt/oracle/ogg/dirdat/rt* | tail -10

# Once network is back, verify processes auto-resume
./ggsci << EOF
info all
lag extract ERISK1
lag replicat RRISK1
EOF
```

### Step 4: Validate Recovery (T+30 to T+60 min)

```bash
# Confirm replication caught up (lag < 5s)
./ggsci << EOF
lag extract ERISK1
lag replicat RRISK1
EOF

# Validate data consistency with spot check
# Compare row counts on key tables
sqlplus risk_user@source << EOF
SELECT COUNT(*) FROM RISK_SCORING_PARAMS WHERE updated_dt > SYSDATE - 1/24;
EOF

sqlplus risk_user@target << EOF
SELECT COUNT(*) FROM RISK_SCORING_PARAMS WHERE updated_dt > SYSDATE - 1/24;
EOF

# Resume batch jobs
curl -sk -X POST -H "Authorization: Bearer $CTM_TOKEN" \
  "$CONTROLM_API/run/jobs/free?jobname=RISK_DAILY_SCORING"
curl -sk -X POST -H "Authorization: Bearer $CTM_TOKEN" \
  "$CONTROLM_API/run/jobs/free?jobname=RISK_EOD_RECON"

# Trigger cache refresh to pick up any missed updates
curl -sk -X POST -H "Authorization: Bearer $CTM_TOKEN" \
  "$CONTROLM_API/run/jobs/runNow?jobname=RISK_CACHE_WARMUP"
```

---

## Prevention Measures

- Splunk alert on replication lag > 30s (already implemented)
- Daily GoldenGate health check in batch schedule
- Trail file disk space monitoring (alert at 80% usage)
- Network redundancy between source and target OGG hosts
- Monthly trail file integrity validation

---

| Date | Version | Change | Author |
|------|---------|--------|--------|
| 2026-03-31 | 1.0 | Initial document | Nitin Madagi |
