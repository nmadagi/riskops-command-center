# Disaster Recovery — Cache Cluster Corruption

> **RTO:** 30 minutes | **RPO:** 0 (stateless cache, Oracle is source-of-truth)  
> **Scenario:** Coherence or Couchbase data corruption affecting transaction scoring accuracy

---

## Detection

- Splunk alert: cache checksum mismatch or inconsistent scoring results
- Dynatrace: anomalous response patterns from scoring engine
- Client report: transactions getting incorrect risk scores

## Recovery Steps

### Step 1: Isolate Corrupted Nodes (T+0 to T+5 min)

```bash
# Identify which nodes have inconsistent data
curl -s "http://coherence-mgmt:30000/management/coherence/cluster/services/RiskScoringCache/caches" | \
  jq '.items[] | {name, size}' > /tmp/cache_sizes.json

# Compare cache sizes across nodes — outliers indicate corruption
# Enable circuit breaker on scoring services to prevent reads from bad cache
for svc in falcon-scoring feedzai-gateway; do
  curl -sk -X POST "https://${svc}.prod.internal/admin/circuit-breaker/open?cache=true"
done
```

### Step 2: Purge and Rebuild (T+5 to T+20 min)

```bash
# Truncate all cache entries
curl -X POST "http://coherence-mgmt:30000/management/coherence/cluster/services/RiskScoringCache/caches/*/truncate"

# Trigger full cache reload from Oracle
curl -sk -X POST -H "Authorization: Bearer $CTM_TOKEN" \
  "$CONTROLM_API/run/jobs/runNow?jobname=RISK_CACHE_WARMUP&params=FULL_RELOAD=true"

# Monitor reload progress
watch -n 10 'curl -s "http://coherence-mgmt:30000/management/coherence/cluster/services/RiskScoringCache/caches" | \
  jq ".items[] | {name, size}"'
```

### Step 3: Validate and Restore (T+20 to T+30 min)

```bash
# Verify cache consistency across all nodes
./scripts/coherence_monitor.sh --verbose

# Close circuit breakers
for svc in falcon-scoring feedzai-gateway; do
  curl -sk -X POST "https://${svc}.prod.internal/admin/circuit-breaker/close?cache=true"
done

# Run scoring smoke test
curl -sk -X POST -H "Content-Type: application/json" \
  -d '{"testMode":true,"txnId":"CACHE-REBUILD-001","amount":100.00}' \
  "https://falcon-scoring.prod.internal:8443/api/v1/score"

# Monitor hit ratio recovery
# SPL: index=risk_platform sourcetype=coherence_stats | timechart span=1m avg(hit_ratio)
```

---

| Date | Version | Change | Author |
|------|---------|--------|--------|
| 2026-03-31 | 1.0 | Initial document | Nitin Madagi |
