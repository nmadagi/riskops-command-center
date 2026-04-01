# Coherence & Couchbase Cache Recovery Runbook

> **Scope:** Oracle Coherence distributed cache and Couchbase NoSQL store  
> **Criticality:** P1 — Cache failures directly impact transaction scoring latency

---

## Scenario 1: Coherence Node Departure

**Symptoms:** Splunk alert for departed member, latency spike on scoring endpoints

```bash
# 1. Identify departed node
curl -s "http://coherence-mgmt:30000/management/coherence/cluster/members" | \
  jq '.items[] | select(.status != "running") | {name, status, lastHeartbeat}'

# 2. Check if partition rebalance is in progress
curl -s "http://coherence-mgmt:30000/management/coherence/cluster/services/RiskScoringCache/partition" | \
  jq '{orphaned: .orphanedPartitions, endangered: .endangeredPartitions, transferring: .partitionsTransferring}'

# 3. If node is recoverable — restart
ssh <departed-node> "systemctl restart coherence-member"

# 4. If node is not recoverable — remove from cluster and scale
# Update coherence-override.xml to remove node from well-known-addresses
# Coherence will automatically redistribute partitions

# 5. Validate cluster health
./scripts/coherence_monitor.sh --verbose
```

## Scenario 2: Split-Brain Detection

**Symptoms:** Members reporting different cluster sizes, duplicate cache entries

```bash
# 1. Identify which members are in which partition
curl -s "http://coherence-mgmt:30000/management/coherence/cluster/members" | \
  jq '[.items[] | {name, clusterSize, memberCount}] | group_by(.clusterSize)'

# 2. Determine which partition has the senior member (first to join)
# The partition with the lowest member ID is authoritative

# 3. Kill the minority partition
# Stop members that are NOT in the authoritative partition
for node in <minority-partition-nodes>; do
  ssh $node "systemctl stop coherence-member"
done

# 4. Wait for partition redistribution (monitor orphaned count)
watch -n 5 'curl -s "http://coherence-mgmt:30000/management/coherence/cluster/services/RiskScoringCache/partition" | jq .orphanedPartitions'

# 5. Restart killed members — they will rejoin the surviving cluster
for node in <minority-partition-nodes>; do
  ssh $node "systemctl start coherence-member"
  sleep 30  # Allow time for partition transfer
done

# 6. Full validation
./scripts/coherence_monitor.sh --verbose
./scripts/health_check.sh --verbose
```

## Scenario 3: Cache Corruption / Full Rebuild

**Symptoms:** Inconsistent scoring results, cache checksum mismatches

```bash
# 1. Halt dependent services (prevent reads from corrupted cache)
for svc in falcon-scoring feedzai-gateway; do
  curl -sk -X POST "https://${svc}.prod.internal/admin/circuit-breaker/open?cache=true"
done

# 2. Clear all cache entries
curl -X POST "http://coherence-mgmt:30000/management/coherence/cluster/services/RiskScoringCache/caches/*/truncate"

# 3. Trigger full reload from Oracle source-of-truth
curl -sk -X POST -H "Authorization: Bearer $CTM_TOKEN" \
  "$CONTROLM_API/run/jobs/runNow?jobname=RISK_CACHE_WARMUP&params=FULL_RELOAD=true"

# 4. Monitor warmup progress
watch -n 10 'curl -s "http://coherence-mgmt:30000/management/coherence/cluster/services/RiskScoringCache/caches" | jq ".items[] | {name, size}"'

# 5. Re-enable dependent services
for svc in falcon-scoring feedzai-gateway; do
  curl -sk -X POST "https://${svc}.prod.internal/admin/circuit-breaker/close?cache=true"
done

# 6. Validate cache hit ratio recovers
# SPL: index=risk_platform sourcetype=coherence_stats | timechart span=1m avg(hit_ratio)
```

## Scenario 4: Couchbase Bucket Recovery

**Symptoms:** Couchbase node failure, bucket quota exceeded, rebalance stuck

```bash
# 1. Check cluster status
curl -s -u "$CB_USER:$CB_PASS" "http://couchbase-01:8091/pools/default" | \
  jq '{nodes: [.nodes[] | {hostname, status, clusterMembership}], buckets: .buckets.uri}'

# 2. Check bucket health
curl -s -u "$CB_USER:$CB_PASS" "http://couchbase-01:8091/pools/default/buckets/txn_cache" | \
  jq '{name, quota: .quota, basicStats}'

# 3. If node failed — initiate failover
curl -s -X POST -u "$CB_USER:$CB_PASS" \
  "http://couchbase-01:8091/controller/failOver" \
  -d "otpNode=ns_1@couchbase-03.prod.internal"

# 4. Rebalance after failover
curl -s -X POST -u "$CB_USER:$CB_PASS" \
  "http://couchbase-01:8091/controller/rebalance" \
  -d "knownNodes=ns_1@couchbase-01,ns_1@couchbase-02"

# 5. Monitor rebalance progress
watch -n 5 'curl -s -u "$CB_USER:$CB_PASS" "http://couchbase-01:8091/pools/default/rebalanceProgress"'
```

---

| Date | Version | Change | Author |
|------|---------|--------|--------|
| 2026-03-31 | 1.0 | Initial cache recovery runbook | Nitin Madagi |
