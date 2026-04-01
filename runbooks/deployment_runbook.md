# Deployment Runbook — Risk Scoring Platform

> **Document Owner:** Production Support Team  
> **Last Updated:** 2026-03-31  
> **Approval:** Change Advisory Board (CAB)

---

## Pre-Deployment Checklist

### T-24 Hours
- [ ] Change Request (CR) approved by CAB with scheduled maintenance window
- [ ] Release notes reviewed — all JIRA tickets verified as QA-signed-off
- [ ] Rollback plan documented and reviewed by on-call engineer
- [ ] Release artifact checksums (SHA256) verified against build server
- [ ] Notify stakeholders: ops team, client services, on-call rotation

### T-1 Hour
- [ ] Confirm current production health via `health_check.sh` — all services green
- [ ] Snapshot current configuration in Git (`git tag pre-deploy-$(date +%Y%m%d)`)
- [ ] Verify Splunk dashboards accessible and baseline metrics recorded
- [ ] Confirm Dynatrace service flow shows normal transaction patterns
- [ ] Verify GoldenGate replication lag < 5 seconds
- [ ] Notify on-call team: deployment starting in 1 hour

---

## Deployment Procedure

### Phase 1: Prepare Environment

```bash
# 1. Verify artifact on deployment server
ssh deploy-host.prod.internal
ls -la /opt/releases/risk-platform/v3.15.0/
sha256sum /opt/releases/risk-platform/v3.15.0/risk-scoring-engine.war

# 2. Hold batch jobs in Control-M
curl -sk -X POST -H "Authorization: Bearer $CTM_TOKEN" \
  "$CONTROLM_API/run/jobs/hold?folder=RISK_PLATFORM"

# 3. Confirm no active transactions in flight (wait for drain)
curl -sk "https://risk-gw.prod.internal:9443/gateway/metrics" | \
  jq '.activeTransactions'
# Wait until activeTransactions == 0 (typical drain: 30-60s)
```

### Phase 2: Deploy Application

```bash
# 4. Stop application servers (rolling — one node at a time)
for node in falcon-{01..04}.prod.internal; do
  ssh $node "systemctl stop websphere-risk"
  sleep 10
  # Verify node removed from load balancer
  curl -sk "https://f5-lb.prod.internal/api/pool/risk-scoring/members" | \
    jq ".members[] | select(.name == \"$node\") | .state"
done

# 5. Deploy WAR file to each node
for node in falcon-{01..04}.prod.internal; do
  scp /opt/releases/risk-platform/v3.15.0/risk-scoring-engine.war \
    $node:/opt/fiserv/falcon/deployments/
done

# 6. Clear Coherence cache (coordinated shutdown)
ssh coherence-mgmt.prod.internal \
  "/opt/oracle/coherence/bin/cache-clear.sh --service RiskScoringCache --confirm"

# 7. Start application servers (sequential with health gates)
for node in falcon-{01..04}.prod.internal; do
  ssh $node "systemctl start websphere-risk"
  
  # Health gate: wait for node to pass health check
  for attempt in $(seq 1 30); do
    status=$(curl -sk -o /dev/null -w "%{http_code}" \
      "https://${node}:8443/actuator/health" 2>/dev/null)
    [[ "$status" == "200" ]] && break
    sleep 10
  done
  
  [[ "$status" != "200" ]] && echo "ALERT: $node failed health gate" && exit 1
  echo "Node $node is healthy — proceeding to next node"
done
```

### Phase 3: Validate Deployment

```bash
# 8. Run post-deployment validation suite
./scripts/deploy_validator.sh --release v3.15.0 --verbose

# 9. Monitor dashboards for 15 minutes
# - Splunk: Transaction latency P99 < 200ms
# - Dynatrace: No new error patterns
# - ExtraHop: Network latency baseline maintained

# 10. Release batch job holds
curl -sk -X POST -H "Authorization: Bearer $CTM_TOKEN" \
  "$CONTROLM_API/run/jobs/free?folder=RISK_PLATFORM"

# 11. Run cache warmup job
curl -sk -X POST -H "Authorization: Bearer $CTM_TOKEN" \
  "$CONTROLM_API/run/jobs/runNow?jobname=RISK_CACHE_WARMUP"
```

### Phase 4: Post-Deployment

- [ ] Confirm all batch jobs resume successfully
- [ ] Verify GoldenGate replication lag returns to baseline (< 2s)
- [ ] Monitor for 1 hour — no SLA breaches
- [ ] Update CMDB with new version
- [ ] Close Change Request
- [ ] Send deployment completion notification to stakeholders

---

## Rollback Procedure

> **Trigger:** Any Phase 3 validation failure, SLA breach within 1 hour, or on-call escalation

```bash
# 1. Announce rollback
# Notify Slack #risk-ops-critical: "ROLLBACK initiated for v3.15.0"

# 2. Hold batch jobs
curl -sk -X POST -H "Authorization: Bearer $CTM_TOKEN" \
  "$CONTROLM_API/run/jobs/hold?folder=RISK_PLATFORM"

# 3. Redeploy previous version
for node in falcon-{01..04}.prod.internal; do
  ssh $node "systemctl stop websphere-risk"
  scp /opt/releases/risk-platform/v3.14.2/risk-scoring-engine.war \
    $node:/opt/fiserv/falcon/deployments/
  ssh $node "systemctl start websphere-risk"
  # Health gate (same as deploy)
done

# 4. Restore config from Git snapshot
git checkout pre-deploy-$(date +%Y%m%d) -- config/

# 5. Validate rollback
./scripts/deploy_validator.sh --release v3.14.2 --verbose

# 6. Release batch holds and notify
```

---

## Contacts

| Role | Name | Phone | Escalation |
|------|------|-------|------------|
| On-Call Engineer | Rotation | PagerDuty | Auto-page on P1 |
| Release Manager | TBD | ext. 4421 | T+15min if no ack |
| Platform Architect | TBD | ext. 4455 | T+30min for P1 |
| Client Services | TBD | ext. 4400 | Notify on SLA breach |

---

## Revision History

| Date | Version | Change | Author |
|------|---------|--------|--------|
| 2026-03-31 | 1.0 | Initial runbook creation | Nitin Madagi |
