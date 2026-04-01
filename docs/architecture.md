# System Architecture — Card Risk Platform

> **Scope:** End-to-end transaction risk scoring, fraud detection, and case management  
> **Scale:** 15,000+ TPS peak, 99.95% uptime SLA, < 200ms P99 latency

---

## Architecture Overview

```
                        ┌─────────────────────────────────────────────┐
                        │            Client Networks                   │
                        │   (Issuer Banks, Payment Processors)         │
                        └──────────────────┬──────────────────────────┘
                                           │
                                    F5 Load Balancer
                                    (SSL Termination)
                                           │
                        ┌──────────────────┼──────────────────────────┐
                        │                  │                          │
                  ┌─────▼─────┐    ┌───────▼───────┐    ┌────────────▼───┐
                  │   Risk    │    │   Feedzai     │    │  Rule Manager  │
                  │  Gateway  │    │   Gateway     │    │   Service      │
                  │ (Router)  │    │ (ML Scoring)  │    │ (Biz Rules)    │
                  └─────┬─────┘    └───────┬───────┘    └────────┬───────┘
                        │                  │                      │
                        └──────────┬───────┘──────────────────────┘
                                   │
                        ┌──────────▼──────────┐
                        │   Falcon Scoring    │
                        │     Engine          │
                        │  (FICO Real-time)   │
                        └──────────┬──────────┘
                                   │
                  ┌────────────────┼────────────────────┐
                  │                │                     │
         ┌────────▼────────┐  ┌───▼────────────┐  ┌────▼───────────┐
         │ Oracle Coherence│  │  Oracle 19c    │  │   Couchbase    │
         │ Distributed     │  │  (Primary DB)  │  │   (NoSQL)      │
         │ Cache (12 nodes)│  │                │  │                │
         └─────────────────┘  └───────┬────────┘  └────────────────┘
                                      │
                               Oracle GoldenGate
                               (Real-time Replication)
                                      │
                              ┌───────▼────────┐
                              │  Oracle 19c    │
                              │  (DR Standby)  │
                              └────────────────┘
```

---

## Component Details

### Application Tier

| Component | Technology | Nodes | Purpose |
|-----------|-----------|-------|---------|
| Risk Gateway | Java 11 / WebSphere 9 | 2 | Transaction routing, protocol translation |
| Falcon Scoring | Java 11 / WebSphere 9 | 4 | Real-time fraud scoring (FICO model) |
| Feedzai Gateway | Java 11 / JBoss EAP 7 | 2 | ML-based fraud detection |
| Rule Manager | Java 11 / WebSphere 9 | 2 | Business rule evaluation engine |
| Case Management | Java 11 / JBoss EAP 7 | 2 | Fraud case investigation workflow |

### Data Tier

| Component | Technology | Nodes | Purpose |
|-----------|-----------|-------|---------|
| Oracle Coherence | Coherence 14c | 12 | Distributed in-memory cache for scoring data |
| Oracle Database | Oracle 19c RAC | 2 (Active-Passive) | Persistent store, source-of-truth |
| Couchbase | Couchbase 7.x | 3 | NoSQL store for transaction history, session data |
| GoldenGate | OGG 21c | 2 (Source + Target) | Real-time replication to DR site |

### Infrastructure

| Component | Technology | Purpose |
|-----------|-----------|---------|
| Load Balancer | F5 BIG-IP | SSL termination, traffic distribution, health monitoring |
| Batch Scheduler | Control-M | Job scheduling, dependency management, SLA tracking |
| Monitoring | Splunk Enterprise | Log aggregation, alerting, dashboards |
| APM | Dynatrace | Application performance, JVM monitoring, service flow |
| Network Analytics | ExtraHop | Wire data analysis, network performance |
| On-Call | PagerDuty | Incident alerting, escalation, on-call rotation |

---

## Data Flow

### Real-Time Transaction Scoring (< 200ms SLA)

1. Client sends transaction via API to **Risk Gateway**
2. Risk Gateway routes to **Falcon Scoring Engine**
3. Falcon checks **Coherence Cache** for customer risk profile (cache hit: ~5ms)
4. If cache miss → falls back to **Oracle DB** read (~50-100ms)
5. Falcon executes scoring model, returns risk score
6. Risk Gateway may additionally route to **Feedzai** for ML scoring
7. **Rule Manager** evaluates business rules against combined scores
8. Final decision (approve/decline/review) returned to client

### Batch Processing (Nightly)

1. **Control-M** triggers EOD batch jobs at scheduled times
2. `RISK_EOD_RECON` — reconciles daily transactions against issuer files
3. `RISK_DAILY_SCORING` — recalculates risk scores with updated model parameters
4. `RISK_CACHE_WARMUP` — pre-populates Coherence cache from Oracle for next day
5. `RISK_FRAUD_REPORT` — generates fraud summary reports for operations team
6. `RISK_ARCHIVE_PURGE` — archives aged data, purges staging tables

### Replication

1. **Oracle GoldenGate** captures changes from primary Oracle in real-time
2. Trail files shipped to DR site (RPO < 5 minutes)
3. **Couchbase XDCR** replicates NoSQL data bi-directionally
4. **Coherence** DR cluster maintained via scheduled full-sync jobs

---

## Network Architecture

```
Production Zone (prod-east-1)
├── DMZ (F5 LB, Risk Gateway)
├── Application Zone (Falcon, Feedzai, Rule Manager, Case Mgmt)
├── Cache Zone (Coherence, Couchbase)
├── Database Zone (Oracle RAC, GoldenGate)
└── Management Zone (Splunk, Dynatrace, Control-M, PagerDuty)

DR Zone (prod-west-1)
├── Mirrored architecture (warm standby)
├── GoldenGate replication target
└── Couchbase XDCR target
```

---

## Capacity Baseline (Current)

| Metric | Current | Peak | Capacity Limit | Headroom |
|--------|---------|------|----------------|----------|
| Transactions/sec | 12,000 | 18,000 | 25,000 | 39% |
| Scoring latency P99 | 45ms | 180ms | 200ms (SLA) | 11% at peak |
| Coherence heap (per node) | 6GB / 12GB | 8GB / 12GB | 12GB | 33% |
| Oracle sessions | 120 | 200 | 500 | 60% |
| Couchbase ops/sec | 5,000 | 8,000 | 15,000 | 47% |
| Disk (Oracle data) | 2.1TB | — | 5TB | 58% |

---

| Date | Version | Change | Author |
|------|---------|--------|--------|
| 2026-03-31 | 1.0 | Initial architecture document | Nitin Madagi |
