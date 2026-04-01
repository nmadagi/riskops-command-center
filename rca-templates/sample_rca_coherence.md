# Root Cause Analysis — Coherence Cache Partition Incident

> **Incident ID:** INC-2026-0328-001  
> **Date:** 2026-03-28  
> **Severity:** P1 — Critical  
> **Author:** Nitin Madagi  
> **Review Date:** 2026-03-30

---

## Executive Summary

On March 28, 2026, the Falcon transaction scoring service experienced a latency spike with P99 latency exceeding 500ms for 8 minutes, affecting approximately 12,000 transactions. The root cause was a Coherence cache partition transfer triggered during a rolling JVM restart that did not include a pre-restart cache warmup step, causing temporary data locality misses and increased Oracle database reads.

---

## Timeline

| Time (ET) | Event | Source |
|-----------|-------|--------|
| 14:32 | Planned JVM rolling restart initiated on falcon-scoring-03 | Change ticket CHG-4521 |
| 14:33 | Coherence partition transfer began (128 partitions moving) | Coherence MBean metrics |
| 14:34 | Falcon scoring P99 latency increased from 45ms to 180ms | Dynatrace |
| 14:35 | Splunk alert fired: "Transaction Latency P99 - SLA Breach" | Splunk |
| 14:35 | PagerDuty on-call engineer paged | PagerDuty |
| 14:36 | On-call acknowledged, joined bridge call | PagerDuty |
| 14:38 | Identified Coherence partition transfer in progress during restart | Coherence mgmt API |
| 14:39 | P99 latency peaked at 520ms — SLA breach (> 200ms) | Dynatrace |
| 14:40 | Decision: wait for partition transfer to complete vs force rebalance | Bridge call |
| 14:41 | Forced partition rebalance on healthy nodes | Manual intervention |
| 14:42 | Partition transfer completed, latency began decreasing | Coherence metrics |
| 14:43 | P99 latency returned to 95ms | Dynatrace |
| 14:45 | All scoring nodes confirmed healthy, cache hit ratio recovering | health_check.sh |
| 14:50 | Cache hit ratio back to 98.2% (normal: 99.1%) | Splunk |
| 15:05 | Monitoring confirmed stable — incident resolved | Dynatrace |

**Total duration:** 33 minutes  
**Time to detect (TTD):** 2 minutes (automated Splunk alert)  
**Time to mitigate (TTM):** 8 minutes  
**Time to resolve (TTR):** 33 minutes

---

## Impact Assessment

- **Services affected:** Falcon Scoring Engine (primary), Feedzai Gateway (secondary — increased response times)
- **Duration of impact:** 8 minutes of SLA breach (P99 > 200ms)
- **Transactions affected:** ~12,000 transactions experienced latency > 200ms; 0 transactions dropped
- **SLA impact:** Monthly SLA metric reduced from 99.98% to 99.94% (still within 99.95% contractual target)
- **Client notifications sent:** No — impact was within SLA tolerance
- **Revenue impact:** None — no transactions were rejected

---

## Root Cause

### What happened
During a planned rolling JVM restart of the Falcon scoring cluster, the Coherence cache node on falcon-scoring-03 was stopped and restarted. When the node departed the cluster, its 128 partitions were redistributed to the remaining 11 nodes. This partition transfer took approximately 8 minutes to complete. During this window, transactions that required data from the transferring partitions experienced cache misses, causing fallback reads to Oracle, which added 300-450ms per read.

### Why it happened (5 Whys)

1. **Why did latency spike?** Cache misses during Coherence partition transfer caused fallback to Oracle database reads.
2. **Why were there cache misses?** Partitions were being transferred between nodes and were temporarily unavailable for reads.
3. **Why did partition transfer take 8 minutes?** Each partition contained ~2.5GB of risk scoring data (total ~320GB transferred), and inter-node bandwidth was limited by the 10Gbps network link.
4. **Why wasn't the cache warmed up before restart?** The deployment runbook did not include a pre-restart cache warmup step — the assumption was that partition redistribution would be near-instant.
5. **Why was this assumption wrong?** The cache dataset has grown 3x in the last 6 months due to new client onboarding, and partition transfer times were never re-baselined.

### Contributing factors
- No health gate between node restarts (all nodes were restarted within 30 seconds of each other)
- Cache partition transfer duration not monitored with dedicated alerts
- Rolling restart runbook was written when dataset was 100GB, not current 320GB

---

## Resolution

1. Forced partition rebalance on healthy nodes to accelerate transfer completion
2. Confirmed all 12 cache members healthy and partition distribution balanced
3. Monitored cache hit ratio recovery for 20 minutes post-resolution
4. Completed the remaining rolling restarts with 5-minute health gates between nodes

---

## Action Items

| # | Action | Owner | Priority | Due Date | Status |
|---|--------|-------|----------|----------|--------|
| 1 | Add pre-restart cache warmup step to rolling restart runbook | N. Madagi | P1 | 2026-04-04 | Open |
| 2 | Implement staggered restart with health gate (wait for partition transfer < 5 before next node) | Platform Team | P1 | 2026-04-11 | Open |
| 3 | Add Dynatrace alert for Coherence partition transfer duration > 30 seconds | N. Madagi | P2 | 2026-04-07 | Open |
| 4 | Add Splunk saved search for partition orphan/endangered count | N. Madagi | P2 | 2026-04-07 | Open |
| 5 | Re-baseline cache dataset size and document growth trajectory for capacity planning | Platform Team | P2 | 2026-04-18 | Open |
| 6 | Evaluate Coherence read-through cache to reduce Oracle fallback latency | Architecture | P3 | 2026-04-30 | Open |

---

## Lessons Learned

### What went well
- Automated Splunk alert fired within 2 minutes of latency increase
- On-call engineer responded in under 1 minute
- Bridge call stood up quickly, decision made in < 5 minutes
- No transactions were dropped — system degraded gracefully

### What could be improved
- Runbook assumed partition transfers were fast — need to validate assumptions after data growth
- No dedicated monitoring for partition transfer progress
- Rolling restart should enforce health gates between nodes

### What was lucky
- The SLA breach was brief enough to stay within monthly target
- No concurrent batch jobs were running that would have compounded the Oracle load
