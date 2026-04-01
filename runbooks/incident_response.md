# Incident Response Guide — Risk Platform On-Call

> **Audience:** On-call engineers, production support team  
> **Process:** ITIL Incident Management aligned  
> **Escalation:** PagerDuty → Slack #risk-ops-critical → Bridge call

---

## Incident Severity Classification

| Severity | Criteria | Response SLA | Examples |
|----------|----------|-------------|----------|
| **P1 — Critical** | Service outage or SLA breach affecting transaction processing | 15 min response, 1 hr resolution target | Falcon scoring down, Coherence cluster split-brain, GoldenGate replication break |
| **P2 — High** | Degraded performance or partial service impact | 30 min response, 4 hr resolution target | P99 latency > 500ms, batch job P1 failure, cache hit ratio < 90% |
| **P3 — Medium** | Non-critical component degraded, no client impact | 2 hr response, next business day | Monitoring agent disconnect, non-critical batch failure, disk space warning |
| **P4 — Low** | Informational, maintenance tasks | Next business day | Certificate renewal, documentation updates |

---

## Incident Lifecycle

### 1. Detection
- **Automated:** Splunk alert → PagerDuty → On-call page + Slack notification
- **Manual:** Client report → Service Desk → On-call assignment
- **Monitoring:** Dynatrace anomaly detection → auto-incident creation

### 2. Triage (Target: < 5 minutes)

```
1. Acknowledge PagerDuty alert
2. Join Slack #risk-ops-critical
3. Quick assessment:
   - Which service is affected?
   - What is the blast radius (# clients, # transactions)?
   - Is this a known issue pattern?
4. Classify severity (P1-P4)
5. If P1/P2: Start bridge call, page additional resources
```

### 3. Investigation

**First 5 minutes — Quick Diagnostics:**
```bash
# Service health overview
./scripts/health_check.sh --verbose

# Check recent error spikes in Splunk
# SPL: index=risk_platform level=ERROR earliest=-15m | top service_name

# Check JVM status
ssh falcon-01.prod.internal "jstat -gcutil $(pgrep -f websphere) 1000 5"

# Check Coherence cluster
./scripts/coherence_monitor.sh --verbose

# Check batch jobs
./scripts/batch_monitor.sh
```

**Common Investigation Paths:**

| Symptom | First Check | Likely Cause |
|---------|------------|-------------|
| Latency spike | Dynatrace service flow → JVM heap/GC | Full GC pauses, cache miss storm |
| Transaction failures | Splunk error logs → stack traces | Downstream service timeout, bad deploy |
| Cache errors | Coherence monitor → partition status | Node departure, split-brain |
| Batch failures | Control-M log → exit codes | Data dependency, disk space, lock contention |
| Replication lag | GoldenGate trail files → extract/replicat | Network issue, apply lag, trail corruption |

### 4. Mitigation

**Principle: Restore service first, root cause later.**

Common mitigation actions:
- **JVM issues:** Rolling restart of affected nodes with health gates
- **Cache corruption:** Isolate node, force partition rebalance
- **Batch failure:** Rerun with dependency override or manual trigger
- **DB replication:** Pause replicat, re-position from last good checkpoint
- **Full outage:** Activate DR failover procedure (see `dr-plans/`)

### 5. Resolution

```
1. Confirm service restored — all health checks passing
2. Verify SLA metrics returning to baseline
3. Monitor for 30 minutes post-resolution
4. Stand down bridge call
5. Update incident ticket with timeline and resolution
```

### 6. Post-Mortem (within 48 hours)

Use the RCA template in `rca-templates/rca_template.md`:
- Timeline reconstruction
- Root cause identification (5 Whys)
- Impact assessment
- Action items with owners and deadlines
- Prevention recommendations

---

## Escalation Matrix

```
T+0 min    On-call engineer paged (PagerDuty)
T+5 min    If no acknowledgment → backup on-call paged
T+15 min   P1: Platform lead + Release manager paged
T+30 min   P1: Engineering manager joined
T+60 min   P1 unresolved: Director + Client services notified
T+4 hr     P1 unresolved: VP notification, DR consideration
```

---

## On-Call Toolkit Quick Reference

```bash
# Where are logs?
/opt/fiserv/falcon/logs/                  # Falcon scoring
/opt/fiserv/feedzai/logs/                 # Feedzai gateway
/opt/oracle/coherence/logs/               # Coherence cache
/opt/IBM/WebSphere/AppServer/profiles/*/logs/  # WebSphere

# Quick Splunk searches (via CLI)
splunk search "index=risk_platform level=ERROR earliest=-30m | stats count by service_name, error_code"
splunk search "index=risk_platform sourcetype=falcon_scoring | timechart span=1m p99(response_time_ms)"

# Coherence JMX (via jconsole or jolokia)
curl -s "http://coherence-mgmt:30000/management/coherence/cluster" | jq '.clusterSize'

# Control-M quick status
curl -sk -H "Authorization: Bearer $CTM_TOKEN" "$CONTROLM_API/run/jobs/status?folder=RISK_PLATFORM" | jq '.statuses[] | {name, status}'

# GoldenGate status
ssh ogg-host "cd /opt/oracle/ogg && ./ggsci << EOF
info all
EOF"
```

---

## Revision History

| Date | Version | Change | Author |
|------|---------|--------|--------|
| 2026-03-31 | 1.0 | Initial incident response guide | Nitin Madagi |
