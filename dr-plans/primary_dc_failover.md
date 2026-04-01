# Disaster Recovery Plan — Primary Data Center Failover

> **RTO:** 4 hours | **RPO:** < 5 minutes  
> **Last DR Test:** 2026-02-15 (passed)  
> **Next DR Test:** 2026-05-15  
> **Approval:** VP Engineering + CISO

---

## Trigger Criteria

Activate this DR plan when:
- Primary DC (prod-east-1) loses connectivity for > 15 minutes
- Multiple core services simultaneously unreachable (Falcon + Feedzai + Risk Gateway)
- Facility-level event (power, network, physical security)
- Directed by VP Engineering or Incident Commander

---

## Architecture Overview

```
PRIMARY (prod-east-1)              DR SITE (prod-west-1)
┌──────────────────────┐           ┌──────────────────────┐
│ Falcon Scoring (4)   │──OGG──→  │ Falcon Scoring (4)   │
│ Feedzai Gateway (2)  │──OGG──→  │ Feedzai Gateway (2)  │
│ Rule Manager (2)     │──OGG──→  │ Rule Manager (2)     │
│ Coherence Cache (12) │──sync──→ │ Coherence Cache (12) │
│ Oracle DB (Primary)  │──OGG──→  │ Oracle DB (Standby)  │
│ Couchbase (3-node)   │──XDCR─→ │ Couchbase (3-node)   │
└──────────────────────┘           └──────────────────────┘
         │                                    │
    F5 Load Balancer ◄──── DNS Failover ────► F5 Load Balancer
```

---

## Failover Procedure

### Phase 1: Assessment and Declaration (T+0 to T+15 min)

```
1. On-call confirms primary DC outage via multiple paths:
   - Direct health checks from DR site
   - Network team confirmation
   - Data center operations contact

2. Incident Commander declares DR activation:
   - Notify VP Engineering and CISO
   - Open bridge call: [dial-in]
   - Post to Slack #dr-activation

3. Confirm DR site readiness:
   ssh dr-admin.prod-west-1 "./dr_readiness_check.sh"
```

### Phase 2: Database Failover (T+15 to T+45 min)

```bash
# 1. Verify GoldenGate replication is caught up
ssh ogg-dr.prod-west-1 "cd /opt/oracle/ogg && ./ggsci << EOF
info all
lag replicat RRISK1
EOF"
# Acceptable lag: < 5 minutes of data

# 2. Stop GoldenGate processes (prevent split-brain on recovery)
ssh ogg-dr.prod-west-1 "cd /opt/oracle/ogg && ./ggsci << EOF
stop extract *
stop replicat *
EOF"

# 3. Activate Oracle Data Guard standby → primary
ssh oracle-dr.prod-west-1 "sqlplus / as sysdba << EOF
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE FINISH;
ALTER DATABASE ACTIVATE STANDBY DATABASE;
ALTER DATABASE OPEN;
EOF"

# 4. Verify database is open read-write
ssh oracle-dr.prod-west-1 "sqlplus / as sysdba << EOF
SELECT OPEN_MODE, DATABASE_ROLE FROM V\$DATABASE;
EOF"
# Expected: READ WRITE / PRIMARY

# 5. Verify Couchbase XDCR replication status
curl -s -u "$CB_USER:$CB_PASS" \
  "http://couchbase-dr-01:8091/pools/default/remoteClusters" | \
  jq '.[].uuid'
```

### Phase 3: Application Startup (T+45 to T+2 hr)

```bash
# 6. Start Coherence cache cluster in DR
for node in coherence-dr-{01..12}.prod-west-1; do
  ssh $node "systemctl start coherence-member"
  sleep 15  # Staggered start for orderly cluster formation
done

# Verify cluster formation
curl -s "http://coherence-dr-mgmt:30000/management/coherence/cluster" | \
  jq '{clusterSize, memberCount: (.members | length)}'

# 7. Populate cache from DR Oracle
curl -sk -X POST -H "Authorization: Bearer $CTM_DR_TOKEN" \
  "$CONTROLM_DR_API/run/jobs/runNow?jobname=DR_CACHE_WARMUP&params=FULL_RELOAD=true"

# 8. Start application services
for svc in falcon-scoring feedzai-gateway rule-manager case-management risk-gateway; do
  for node in ${svc}-dr-{01..04}.prod-west-1; do
    ssh $node "systemctl start websphere-risk"
    # Health gate
    for i in $(seq 1 30); do
      code=$(curl -sk -o /dev/null -w "%{http_code}" \
        "https://${node}:8443/actuator/health" 2>/dev/null)
      [[ "$code" == "200" ]] && break
      sleep 10
    done
  done
done
```

### Phase 4: Traffic Cutover (T+2 hr to T+2.5 hr)

```bash
# 9. Update DNS to point to DR site
# Via DNS management API or manual update
# risk-scoring.fiserv.com → DR site F5 VIP

# 10. Update F5 load balancer pools
# Activate DR pool members, deactivate primary pool

# 11. Verify traffic flowing to DR site
curl -sk "https://risk-scoring.fiserv.com/actuator/health" | \
  jq '.details.hostname'
# Should show DR hostnames

# 12. Monitor transaction processing
# Splunk: index=risk_platform host=*-dr-* | timechart span=1m count
```

### Phase 5: Validation (T+2.5 hr to T+4 hr)

```bash
# 13. Run full validation suite against DR site
./scripts/deploy_validator.sh --release current --verbose

# 14. Verify batch jobs can execute
curl -sk -X POST -H "Authorization: Bearer $CTM_DR_TOKEN" \
  "$CONTROLM_DR_API/run/jobs/runNow?jobname=DR_SMOKE_TEST"

# 15. Client-facing smoke tests
# Run test transactions through each client's integration

# 16. Confirm SLA metrics
# - Latency P99 < 200ms
# - Error rate < 0.1%
# - TPS within expected range
```

---

## Failback Procedure (Primary DC Recovery)

> Executed only after primary DC is confirmed stable for 24+ hours

1. Re-establish GoldenGate replication: DR → Primary
2. Allow replication to catch up completely (lag = 0)
3. Coordinate maintenance window with client services
4. Reverse DNS / F5 configuration
5. Stop DR applications (after traffic confirmed on primary)
6. Re-establish normal replication direction: Primary → DR
7. Full validation on primary site

---

## DR Test Schedule

| Quarter | Test Type | Scope | Duration |
|---------|-----------|-------|----------|
| Q1 | Tabletop exercise | Full team walkthrough | 2 hours |
| Q2 | Partial failover | DB + 1 app service | 4 hours |
| Q3 | Full DR test | Complete failover + client smoke tests | 8 hours |
| Q4 | Tabletop + lessons learned review | All stakeholders | 3 hours |

---

## Contacts for DR Activation

| Role | Contact | After Hours |
|------|---------|-------------|
| Incident Commander | On-call rotation | PagerDuty |
| DBA Team | Oracle DBA on-call | PagerDuty |
| Network Team | NOC | 24/7 hotline |
| Client Services | Client ops lead | PagerDuty |
| VP Engineering | [Name] | Cell phone |

---

| Date | Version | Change | Author |
|------|---------|--------|--------|
| 2026-03-31 | 1.0 | Initial DR plan | Nitin Madagi |
