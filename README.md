# RiskOps Command Center

> Production support simulation platform for card-risk application platforms — monitoring, incident management, deployment automation, and disaster recovery.

Built to demonstrate end-to-end operational expertise for **enterprise financial services risk platforms** (Falcon, Feedzai, Rule Manager, Case Management, Risk Gateway) running on UNIX/Linux clusters with Java-based middleware.

![License](https://img.shields.io/badge/license-MIT-blue)
![Platform](https://img.shields.io/badge/platform-UNIX%2FLinux-green)
![Stack](https://img.shields.io/badge/stack-Java%20%7C%20Oracle%20%7C%20Coherence%20%7C%20Splunk-orange)

---

## What This Project Demonstrates

| Area | What's Included | Directory |
|------|----------------|-----------|
| **Production Monitoring** | Real-time dashboard tracking TPS, latency P50/P99, error rates, cache hit ratios, node health | `dashboard/` |
| **UNIX/Linux Automation** | Shell scripts for health checks, cache monitoring, batch job tracking, log rotation, deploy validation | `scripts/` |
| **Incident Management** | ITIL-aligned incident lifecycle, SLA tracking, escalation procedures | `runbooks/` |
| **Deployment & CI/CD** | Release runbooks with rollback procedures, Jenkins pipeline, config management | `ci-cd/`, `runbooks/` |
| **Observability Stack** | Splunk SPL saved searches, Dynatrace alerting rules, ExtraHop integration configs | `monitoring/` |
| **Root Cause Analysis** | Structured RCA/post-mortem templates with timeline reconstruction | `rca-templates/` |
| **Disaster Recovery** | DR playbooks for DC failover, cache corruption, replication breaks with RTO/RPO targets | `dr-plans/` |
| **Capacity Planning** | Performance baseline documentation, scaling models, provisioning guides | `docs/` |

---

## Technology Coverage

### Core Platform
- **Operating System:** RHEL/CentOS Linux (production clusters)
- **Application Runtime:** Java 11+ (WebSphere/JBoss application servers)
- **Database:** Oracle 19c with GoldenGate replication
- **Distributed Cache:** Oracle Coherence, Couchbase
- **Batch Scheduling:** Control-M, AutoSys

### Observability & Monitoring
- **Log Management:** Splunk (SPL queries, HEC integration, saved searches, alerts)
- **APM:** Dynatrace (JVM monitoring, service flow, custom metrics)
- **Network Analytics:** ExtraHop (wire data analysis)
- **Alerting:** PagerDuty integration for on-call escalation

### Automation & DevOps
- **Scripting:** Bash/Shell (production health checks, monitoring, automation)
- **CI/CD:** Jenkins pipelines, Git-based configuration management
- **RPA:** UIPath/Automation Anywhere workflow patterns
- **Change Management:** ITIL-aligned CAB process, runbook-driven deployments

### Risk Platforms (Domain Knowledge)
- Falcon (FICO) — real-time transaction scoring
- Feedzai — machine learning fraud detection
- Rule Manager — business rule engine for fraud policies
- Case Management — fraud investigation workflow
- Risk Gateway — transaction routing and decisioning

---

## Project Structure

```
riskops-command-center/
├── README.md                         # This file
├── dashboard/                        # React monitoring dashboard
│   ├── src/
│   │   └── App.jsx                  # Main dashboard application
│   └── package.json
├── scripts/                          # Production automation (Bash)
│   ├── health_check.sh              # Service health + Splunk alerting
│   ├── coherence_monitor.sh         # Coherence cache cluster monitor
│   ├── batch_monitor.sh             # Control-M job status tracker
│   ├── log_rotator.sh               # Automated log rotation + archival
│   └── deploy_validator.sh          # Post-deployment validation suite
├── runbooks/                         # Operational runbooks
│   ├── deployment_runbook.md        # Release deployment procedure
│   ├── rollback_procedure.md        # Emergency rollback steps
│   ├── incident_response.md         # On-call incident response guide
│   └── cache_recovery.md            # Coherence/Couchbase recovery
├── monitoring/                       # Observability configurations
│   ├── splunk/
│   │   ├── risk_platform_searches.conf   # Saved searches
│   │   └── alert_actions.conf            # Alert configurations
│   ├── dynatrace/
│   │   └── custom_alerting_rules.yaml    # Dynatrace alert profiles
│   └── pagerduty_escalation.yaml         # Escalation policies
├── rca-templates/                    # Post-mortem documentation
│   ├── rca_template.md              # Blank RCA template
│   └── sample_rca_coherence.md      # Example: cache partition incident
├── dr-plans/                         # Disaster recovery playbooks
│   ├── primary_dc_failover.md       # Data center failover procedure
│   ├── cache_cluster_corruption.md  # Coherence/Couchbase recovery
│   └── replication_break_ogg.md     # Oracle GoldenGate recovery
├── ci-cd/                            # CI/CD pipeline configurations
│   ├── Jenkinsfile                  # Declarative Jenkins pipeline
│   └── deployment_pipeline.yaml     # Pipeline stage definitions
└── docs/                             # Architecture & planning
    ├── architecture.md              # System architecture overview
    └── capacity_planning.md         # Capacity model & scaling guide
```

---

## Quick Start

### View the Dashboard
```bash
cd dashboard
npm install
npm start
# Opens at http://localhost:3000
```

### Run Automation Scripts
```bash
# Health check across all risk services
chmod +x scripts/*.sh
./scripts/health_check.sh

# Monitor Coherence cache cluster
./scripts/coherence_monitor.sh

# Check Control-M batch job status
./scripts/batch_monitor.sh
```

---

## Skills Matrix — JD Alignment

| JD Requirement | Demonstrated Here |
|---------------|-------------------|
| 10+ years UNIX/Linux production support | `scripts/` — 5 production-grade shell scripts |
| Java-based platform support | `dashboard/`, `monitoring/` — JVM metrics, WebSphere deployment |
| Coherence cache management | `scripts/coherence_monitor.sh`, `dr-plans/cache_cluster_corruption.md` |
| Batch job monitoring | `scripts/batch_monitor.sh` — Control-M integration |
| SLA tracking & incident resolution | `runbooks/incident_response.md`, dashboard SLA metrics |
| Deploy/validate/rollback releases | `runbooks/deployment_runbook.md`, `ci-cd/Jenkinsfile` |
| Post-mortems/RCA | `rca-templates/` — structured templates with examples |
| Splunk/Dynatrace/ExtraHop | `monitoring/` — SPL queries, Dynatrace alerts, ExtraHop configs |
| Automation & scripting | `scripts/` — Splunk HEC, PagerDuty, cron-ready automation |
| Disaster Recovery planning | `dr-plans/` — 3 scenarios with RTO/RPO targets |
| Oracle GoldenGate | `dr-plans/replication_break_ogg.md`, monitoring queries |
| NoSQL (Couchbase/Coherence) | Cache monitoring scripts, recovery runbooks |
| CI/CD & config management | `ci-cd/Jenkinsfile`, Git-based config snapshots |
| ITIL production support | `runbooks/incident_response.md` — ITIL incident lifecycle |
| Capacity planning | `docs/capacity_planning.md` — scaling models and baselines |

---

## Author

**Nitin Madagi**
MS Financial Mathematics | Quantitative Risk & Technology
[Portfolio](https://nmadagi.github.io) | [LinkedIn](https://linkedin.com/in/nitinmadagi)

---

## License

MIT License — see [LICENSE](LICENSE) for details.
