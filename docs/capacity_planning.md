# Capacity Planning — Risk Scoring Platform

> **Planning Horizon:** Q2-Q4 2026  
> **Review Cadence:** Quarterly  
> **Owner:** Production Support + Platform Architecture

---

## Current Capacity Baseline

| Resource | Current Usage | Peak Usage | Limit | Utilization % | Status |
|----------|-------------|------------|-------|---------------|--------|
| Transaction TPS | 12,000 | 18,000 | 25,000 | 72% peak | OK |
| Falcon Scoring Nodes | 4 active | 4 active | 8 (license) | 50% | OK |
| Coherence Heap (total) | 72GB / 144GB | 96GB / 144GB | 144GB | 67% peak | WATCH |
| Coherence Cache Entries | 2.1B | 2.1B | ~3B (estimated) | 70% | WATCH |
| Oracle DB Storage | 2.1TB / 5TB | — | 5TB | 42% | OK |
| Oracle Sessions | 120 avg | 200 peak | 500 max | 40% peak | OK |
| Couchbase Memory | 12GB / 20GB | 15GB / 20GB | 20GB | 75% peak | WATCH |
| Couchbase Ops/sec | 5,000 | 8,000 | 15,000 | 53% peak | OK |
| Network (inter-node) | 2Gbps | 4Gbps | 10Gbps | 40% peak | OK |
| GoldenGate Trail Disk | 180GB / 500GB | 250GB / 500GB | 500GB | 50% peak | OK |

---

## Growth Projections

### Transaction Volume

Based on client onboarding pipeline and historical growth:

| Quarter | Projected TPS (Peak) | Growth vs Current | Capacity Action |
|---------|---------------------|-------------------|-----------------|
| Q2 2026 | 20,000 | +11% | Monitor — within capacity |
| Q3 2026 | 22,500 | +25% | **Scale Falcon to 6 nodes** |
| Q4 2026 | 25,000 | +39% | Approach limit — **scale to 8 nodes** |

### Cache Growth

Coherence cache dataset growing ~15% per quarter due to new client onboarding:

| Quarter | Estimated Cache Size | Heap Required | Nodes Required |
|---------|---------------------|---------------|----------------|
| Q2 2026 | 2.4B entries / 85GB | 10GB/node × 12 = 120GB | 12 (current) |
| Q3 2026 | 2.8B entries / 98GB | 10GB/node × 12 = 120GB | 12 — **tight** |
| Q4 2026 | 3.2B entries / 112GB | **Exceeds 12-node capacity** | **Scale to 16 nodes** |

### Database Growth

| Quarter | Projected DB Size | Growth Rate | Action |
|---------|------------------|-------------|--------|
| Q2 2026 | 2.4TB | +300GB/quarter | Normal growth |
| Q3 2026 | 2.7TB | +300GB/quarter | Normal growth |
| Q4 2026 | 3.0TB | +300GB/quarter | Plan tablespace expansion |

---

## Scaling Recommendations

### Q2 2026 (Immediate)

1. **Coherence heap tuning:** Increase per-node heap from 12GB to 16GB
   - Requires JVM restart (rolling, with health gates)
   - Estimated downtime: 0 (rolling restart)
   - Cost: $0 (existing hardware has 32GB RAM per node)

2. **Couchbase bucket quota increase:** Raise txn_cache from 20GB to 30GB
   - Online operation, no restart needed
   - Requires RAM available on Couchbase nodes

### Q3 2026 (Planned)

3. **Falcon scoring horizontal scale:** Add 2 nodes (4 → 6)
   - Provision 2 new RHEL servers with WebSphere
   - Update F5 pool configuration
   - Estimated lead time: 3 weeks (procurement + config)
   - Cost: ~$15K/month (server + license)

4. **Oracle GoldenGate trail disk expansion:** Increase from 500GB to 1TB
   - Online LVM extend
   - No service impact

### Q4 2026 (Strategic)

5. **Coherence cluster expansion:** Add 4 nodes (12 → 16)
   - Provision hardware, install Coherence
   - Partition redistribution will occur automatically
   - Monitor partition transfer time (may spike latency temporarily)
   - Cost: ~$20K/month (4 servers)

6. **Falcon scoring scale to 8 nodes** if TPS exceeds 23,000
   - Same procedure as Q3 scaling
   - Consider license implications with FICO

---

## Performance Tuning Recommendations

### JVM Tuning (All Java Services)

```
# Current settings
-Xms8g -Xmx12g -XX:+UseG1GC -XX:MaxGCPauseMillis=200

# Recommended for Q2 (after heap increase)
-Xms12g -Xmx16g -XX:+UseG1GC -XX:MaxGCPauseMillis=150
-XX:G1HeapRegionSize=16m
-XX:InitiatingHeapOccupancyPercent=45
-XX:+ParallelRefProcEnabled
```

### Coherence Tuning

```xml
<!-- Increase partition count for better distribution across 16 nodes -->
<partition-count>509</partition-count>  <!-- Prime number, from current 257 -->

<!-- Enable near-cache for frequently accessed scoring parameters -->
<near-scheme>
  <front-scheme>
    <local-scheme>
      <high-units>10000</high-units>
      <expiry-delay>60s</expiry-delay>
    </local-scheme>
  </front-scheme>
</near-scheme>
```

### Oracle Tuning

```sql
-- Increase SGA for better buffer cache hit ratio
ALTER SYSTEM SET sga_target = 32G SCOPE=SPFILE;

-- Add index for scoring parameter lookups
CREATE INDEX idx_risk_params_customer ON RISK_SCORING_PARAMS(customer_id, param_type)
  TABLESPACE RISK_IDX PARALLEL 4 NOLOGGING;
```

---

## Monitoring for Capacity Alerts

| Metric | Warning Threshold | Critical Threshold | Splunk Alert |
|--------|-------------------|-------------------|--------------|
| TPS | > 20,000 sustained 1hr | > 23,000 sustained 15min | Yes |
| Coherence heap per node | > 80% | > 90% | Yes |
| Cache entry count | > 2.5B | > 2.8B | Yes |
| Oracle tablespace usage | > 70% | > 85% | Yes |
| Couchbase bucket quota | > 80% | > 90% | Yes |
| GoldenGate trail disk | > 70% | > 85% | Yes |
| Scoring latency P99 | > 150ms | > 200ms | Yes (SLA) |

---

| Date | Version | Change | Author |
|------|---------|--------|--------|
| 2026-03-31 | 1.0 | Initial capacity plan | Nitin Madagi |
