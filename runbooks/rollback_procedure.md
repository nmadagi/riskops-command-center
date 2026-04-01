# Rollback Procedure — Risk Scoring Platform

> **When to use:** Deployment validation failure, post-deploy SLA breach, or critical defect  
> **Authorization:** On-call engineer (P1) or Release Manager (P2+)  
> **Target time:** < 30 minutes from decision to rolled-back state

---

## Decision Criteria

Initiate rollback when ANY of the following occur within 1 hour of deployment:

- Post-deploy validation suite fails (`deploy_validator.sh` exits non-zero)
- Transaction scoring latency P99 exceeds 500ms for > 5 minutes
- Error rate exceeds 1% for any risk service
- Coherence cache orphaned partitions detected
- GoldenGate replication lag exceeds 60 seconds
- Any client reports transaction processing failures
- Batch job RISK_DAILY_SCORING or RISK_EOD_RECON fails

---

## Rollback Steps

### Step 1: Announce and Coordinate

```bash
# Post to Slack #risk-ops-critical
"ROLLBACK INITIATED for release vX.Y.Z — [reason]. Bridge call: [dial-in]"

# Acknowledge in PagerDuty if incident triggered
```

### Step 2: Halt Traffic and Batch Jobs

```bash
# Hold all risk batch jobs
curl -sk -X POST -H "Authorization: Bearer $CTM_TOKEN" \
  "$CONTROLM_API/run/jobs/hold?folder=RISK_PLATFORM"

# Drain active transactions (wait for in-flight to complete)
curl -sk "https://risk-gw.prod.internal:9443/gateway/admin/drain"
sleep 60
```

### Step 3: Redeploy Previous Version

```bash
PREV_VERSION="v3.14.2"  # Set to actual previous version

for node in falcon-{01..04}.prod.internal; do
  echo "Rolling back $node..."
  
  # Stop application
  ssh $node "systemctl stop websphere-risk"
  
  # Deploy previous artifact
  scp "/opt/releases/risk-platform/${PREV_VERSION}/risk-scoring-engine.war" \
    "${node}:/opt/fiserv/falcon/deployments/"
  
  # Restore configuration
  ssh $node "cd /opt/fiserv/falcon/config && \
    git checkout pre-deploy-\$(date +%Y%m%d) -- ."
  
  # Start application
  ssh $node "systemctl start websphere-risk"
  
  # Health gate
  for i in $(seq 1 30); do
    code=$(curl -sk -o /dev/null -w "%{http_code}" \
      "https://${node}:8443/actuator/health" 2>/dev/null)
    [[ "$code" == "200" ]] && echo "  $node healthy" && break
    sleep 10
  done
done
```

### Step 4: Cache Rebuild

```bash
# Clear and rebuild Coherence cache from Oracle source
ssh coherence-mgmt.prod.internal \
  "/opt/oracle/coherence/bin/cache-clear.sh --service RiskScoringCache --confirm"

# Trigger cache warmup
curl -sk -X POST -H "Authorization: Bearer $CTM_TOKEN" \
  "$CONTROLM_API/run/jobs/runNow?jobname=RISK_CACHE_WARMUP"
```

### Step 5: Validate Rollback

```bash
# Run validation suite against previous version
./scripts/deploy_validator.sh --release "$PREV_VERSION" --verbose

# Verify SLA compliance
./scripts/health_check.sh --verbose
./scripts/coherence_monitor.sh --verbose
```

### Step 6: Resume Operations

```bash
# Release batch job holds
curl -sk -X POST -H "Authorization: Bearer $CTM_TOKEN" \
  "$CONTROLM_API/run/jobs/free?folder=RISK_PLATFORM"

# Re-enable traffic
curl -sk "https://risk-gw.prod.internal:9443/gateway/admin/resume"
```

### Step 7: Post-Rollback

- [ ] Monitor for 1 hour — confirm stability
- [ ] Update incident ticket with rollback details
- [ ] Close Change Request as "rolled back"
- [ ] Schedule post-mortem within 48 hours
- [ ] Notify stakeholders: rollback complete, service restored

---

## Rollback Verification Checklist

- [ ] All service endpoints returning HTTP 200
- [ ] Deployed version matches previous release
- [ ] Coherence cluster fully formed (12/12 members)
- [ ] No orphaned cache partitions
- [ ] GoldenGate replication lag < 5 seconds
- [ ] Splunk log ingestion active
- [ ] Dynatrace agents all reporting
- [ ] Batch jobs resumed and executing
- [ ] Transaction P99 latency < 200ms
- [ ] Error rate < 0.1%

---

| Date | Version | Change | Author |
|------|---------|--------|--------|
| 2026-03-31 | 1.0 | Initial rollback procedure | Nitin Madagi |
