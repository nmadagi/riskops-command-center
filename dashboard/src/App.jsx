import { useState, useEffect, useCallback, useRef } from "react";

// ─── DATA GENERATORS ────────────────────────────────────────────────────────
const SERVICES = [
  { id: "falcon-scoring", name: "Falcon Scoring Engine", type: "java", port: 8443, cluster: "prod-east-1" },
  { id: "feedzai-gateway", name: "Feedzai Risk Gateway", type: "java", port: 9090, cluster: "prod-east-1" },
  { id: "rule-manager", name: "Rule Manager Service", type: "java", port: 8080, cluster: "prod-west-1" },
  { id: "case-mgmt", name: "Case Management API", type: "java", port: 8081, cluster: "prod-west-1" },
  { id: "coherence-cache", name: "Coherence Cache Cluster", type: "cache", port: 7574, cluster: "prod-east-1" },
  { id: "batch-processor", name: "Batch Job Processor", type: "batch", port: 0, cluster: "prod-east-1" },
  { id: "oracle-golden", name: "Oracle GoldenGate Replication", type: "db", port: 1521, cluster: "prod-db-1" },
  { id: "couchbase-store", name: "Couchbase NoSQL Store", type: "nosql", port: 8091, cluster: "prod-east-1" },
];

const ALERT_TEMPLATES = [
  { severity: "critical", msg: "Coherence cache node OOR — partition transfer stalled", service: "coherence-cache", sla: "15min" },
  { severity: "critical", msg: "Falcon scoring latency > 500ms (SLA: 200ms)", service: "falcon-scoring", sla: "15min" },
  { severity: "high", msg: "GoldenGate replication lag exceeds 30s threshold", service: "oracle-golden", sla: "30min" },
  { severity: "high", msg: "JVM heap utilization at 92% on rule-manager-node-03", service: "rule-manager", sla: "30min" },
  { severity: "medium", msg: "Control-M batch job RISK_EOD_RECON failed — exit code 1", service: "batch-processor", sla: "60min" },
  { severity: "medium", msg: "Couchbase bucket 'txn_cache' approaching quota (87%)", service: "couchbase-store", sla: "60min" },
  { severity: "low", msg: "Dynatrace agent disconnected on feedzai-gw-node-02", service: "feedzai-gateway", sla: "4hr" },
  { severity: "low", msg: "SSL certificate renewal due in 14 days for risk-gateway", service: "feedzai-gateway", sla: "7d" },
];

const INCIDENT_PHASES = ["Detected", "Triaging", "Investigating", "Mitigating", "Resolved", "Post-Mortem"];

const RUNBOOK_STEPS = [
  { phase: "Pre-Deploy", steps: ["Validate release artifact checksums (SHA256)", "Confirm Change Advisory Board approval", "Notify on-call team and stakeholders", "Snapshot current config in Git"] },
  { phase: "Deploy", steps: ["Stop batch schedulers (Control-M hold)", "Deploy WAR to WebSphere nodes (rolling)", "Clear Coherence cache partitions", "Restart JVM instances sequentially"] },
  { phase: "Validate", steps: ["Health check all endpoints (HTTP 200)", "Verify Splunk log ingestion active", "Confirm Dynatrace metrics baseline", "Run smoke test transaction suite"] },
  { phase: "Rollback", steps: ["Redeploy previous artifact version", "Restore config snapshot from Git", "Restart affected JVM instances", "Validate rollback with smoke tests"] },
];

const DR_SCENARIOS = [
  { name: "Primary DC Failure", rto: "4 hours", rpo: "< 5 min", steps: ["Activate DNS failover to DR site", "Verify GoldenGate replication caught up", "Start application clusters in DR", "Redirect client traffic via F5 LB", "Validate transaction flow end-to-end"] },
  { name: "Cache Cluster Corruption", rto: "30 min", rpo: "0 (stateless)", steps: ["Isolate corrupted nodes from cluster", "Force partition rebalance on healthy nodes", "Rebuild cache from Oracle source-of-truth", "Validate cache consistency checksums", "Re-enable client-facing endpoints"] },
  { name: "Database Replication Break", rto: "1 hour", rpo: "< 1 min", steps: ["Identify break point in GoldenGate trail", "Pause dependent batch jobs in Control-M", "Re-extract from source checkpoint", "Apply pending transactions to target", "Resume replication and validate lag"] },
];

const SHELL_SCRIPTS = {
  healthCheck: `#!/bin/bash
# health_check.sh — Production Health Check Script
# Maps to JD: "Detect, troubleshoot, and resolve production issues"

LOG_DIR="/var/log/risk-apps"
SPLUNK_HEC="https://splunk.fiserv.internal:8088/services/collector"
ALERT_THRESHOLD_MS=200
SERVICES=("falcon-scoring:8443" "feedzai-gateway:9090" "rule-manager:8080" "case-mgmt:8081")

check_service() {
  local svc=\$1 port=\$2
  local start_ms=\$(date +%s%N)
  local http_code=\$(curl -sk -o /dev/null -w "%{http_code}" \\
    --connect-timeout 5 "https://\${svc}.prod.internal:\${port}/health")
  local end_ms=\$(date +%s%N)
  local latency_ms=$(( (end_ms - start_ms) / 1000000 ))

  if [[ "\$http_code" != "200" ]] || [[ \$latency_ms -gt \$ALERT_THRESHOLD_MS ]]; then
    echo "ALERT: \$svc — HTTP \$http_code, latency \${latency_ms}ms"
    send_splunk_alert "\$svc" "\$http_code" "\$latency_ms"
    return 1
  fi
  echo "OK: \$svc — HTTP \$http_code, \${latency_ms}ms"
}

send_splunk_alert() {
  curl -sk -H "Authorization: Splunk \${SPLUNK_TOKEN}" \\
    -d "{\\"event\\": {\\"service\\": \\"\$1\\", \\"status\\": \\"\$2\\", \\"latency_ms\\": \$3}}" \\
    "\$SPLUNK_HEC"
}

for entry in "\${SERVICES[@]}"; do
  IFS=':' read -r svc port <<< "\$entry"
  check_service "\$svc" "\$port"
done`,

  cacheMonitor: `#!/bin/bash
# coherence_monitor.sh — Coherence Cache Health Monitor
# Maps to JD: "Coherence cache management"

COHERENCE_MGMT="http://coherence-mgmt.prod:30000/management/coherence/cluster"
PARTITION_THRESHOLD=257
HEAP_WARN_PCT=85

check_cluster_health() {
  local cluster_json=\$(curl -s "\$COHERENCE_MGMT/members")
  local member_count=\$(echo "\$cluster_json" | jq '.items | length')
  local departed=\$(echo "\$cluster_json" | jq '[.items[] | select(.status != "running")] | length')

  echo "Cluster: \$member_count members, \$departed departed"
  [[ \$departed -gt 0 ]] && alert "WARN" "Departed members detected: \$departed"

  # Check partition distribution
  local partitions=\$(curl -s "\$COHERENCE_MGMT/services/RiskCache/partition")
  local orphaned=\$(echo "\$partitions" | jq '.orphanedPartitions')
  [[ \$orphaned -gt 0 ]] && alert "CRITICAL" "Orphaned partitions: \$orphaned"

  # JVM heap per node
  echo "\$cluster_json" | jq -r '.items[] | "\\(.name): heap \\(.memoryUsedMB)/\\(.memoryMaxMB)MB"' | \\
    while read line; do
      local used=\$(echo \$line | grep -oP '\\d+(?=/)')
      local max=\$(echo \$line | grep -oP '(?<=/)\\d+(?=MB)')
      local pct=$((used * 100 / max))
      [[ \$pct -gt \$HEAP_WARN_PCT ]] && alert "HIGH" "Heap at \${pct}%: \$line"
    done
}

alert() { logger -p local0."\$1" "COHERENCE_MONITOR: \$2"; }
check_cluster_health`,

  batchMonitor: `#!/bin/bash
# batch_monitor.sh — Control-M Batch Job Monitor
# Maps to JD: "batch job monitoring"

CONTROLM_API="https://controlm.prod.internal:8443/automation-api"
RISK_JOBS=("RISK_EOD_RECON" "RISK_DAILY_SCORING" "RISK_FRAUD_REPORT" "RISK_ARCHIVE_PURGE")

check_job_status() {
  local job=\$1
  local status=\$(curl -sk -H "Authorization: Bearer \$CTM_TOKEN" \\
    "\$CONTROLM_API/run/jobs/status?jobname=\$job" | jq -r '.statuses[0].status')

  case "\$status" in
    "Ended OK") echo "✓ \$job: Completed successfully" ;;
    "Executing") echo "◎ \$job: Currently running" ;;
    "Wait Condition") echo "◌ \$job: Waiting on dependency" ;;
    *) echo "✗ \$job: FAILED (\$status)" && escalate "\$job" "\$status" ;;
  esac
}

escalate() {
  # PagerDuty integration for failed batch jobs
  curl -s -X POST "https://events.pagerduty.com/v2/enqueue" \\
    -H "Content-Type: application/json" \\
    -d "{\\"routing_key\\": \\"\$PD_KEY\\", \\"event_action\\": \\"trigger\\",
         \\"payload\\": {\\"summary\\": \\"Batch job \$1 failed: \$2\\",
                        \\"severity\\": \\"high\\", \\"source\\": \\"controlm-monitor\\"}}"
}

for job in "\${RISK_JOBS[@]}"; do check_job_status "\$job"; done`,
};

const SPLUNK_QUERIES = [
  { name: "Transaction Latency P99", query: 'index=risk sourcetype=falcon_scoring | stats p99(response_time_ms) as p99_latency by host | where p99_latency > 200' },
  { name: "Error Rate by Service", query: 'index=risk level=ERROR | timechart span=5m count by service_name | where count > 50' },
  { name: "Cache Hit Ratio", query: 'index=risk sourcetype=coherence_stats | stats avg(hit_ratio) as avg_hit_rate by cache_name | where avg_hit_rate < 0.95' },
  { name: "GoldenGate Replication Lag", query: 'index=oracle sourcetype=ogg_stats | stats latest(lag_seconds) as lag by trail_name | where lag > 30' },
  { name: "JVM GC Pause Duration", query: 'index=risk sourcetype=jvm_gc | stats max(gc_pause_ms) as max_gc by host | where max_gc > 500' },
];

// ─── UTILITY FUNCTIONS ──────────────────────────────────────────────────────
const randBetween = (min, max) => Math.floor(Math.random() * (max - min + 1)) + min;
const randFloat = (min, max) => (Math.random() * (max - min) + min).toFixed(1);
const ts = () => new Date().toLocaleTimeString("en-US", { hour12: false, hour: "2-digit", minute: "2-digit", second: "2-digit" });

const generateMetrics = () => ({
  tps: randBetween(12000, 18000),
  latencyP50: randBetween(8, 25),
  latencyP99: randBetween(80, 220),
  errorRate: randFloat(0, 0.8),
  cacheHitRate: randFloat(94, 99.9),
  uptime: "99.97%",
  activeNodes: randBetween(22, 24),
  totalNodes: 24,
  openIncidents: randBetween(0, 3),
  mttr: randBetween(8, 22),
  batchJobsOk: randBetween(42, 48),
  batchJobsTotal: 48,
  replicationLag: randFloat(0.1, 3.5),
});

// ─── COMPONENTS ─────────────────────────────────────────────────────────────
const SeverityBadge = ({ severity }) => {
  const colors = { critical: "#ff3b30", high: "#ff9500", medium: "#ffcc00", low: "#34c759" };
  return (
    <span style={{
      display: "inline-block", padding: "2px 10px", borderRadius: "4px", fontSize: "11px",
      fontWeight: 700, textTransform: "uppercase", letterSpacing: "0.5px",
      background: `${colors[severity]}22`, color: colors[severity], border: `1px solid ${colors[severity]}44`,
    }}>{severity}</span>
  );
};

const MetricCard = ({ label, value, unit, status, sub }) => (
  <div style={{
    background: "rgba(255,255,255,0.03)", border: "1px solid rgba(255,255,255,0.08)",
    borderRadius: "8px", padding: "16px", position: "relative", overflow: "hidden",
  }}>
    {status && <div style={{
      position: "absolute", top: 0, left: 0, right: 0, height: "3px",
      background: status === "ok" ? "#34c759" : status === "warn" ? "#ff9500" : "#ff3b30",
    }} />}
    <div style={{ fontSize: "11px", color: "#8e8e93", textTransform: "uppercase", letterSpacing: "1px", marginBottom: "8px" }}>{label}</div>
    <div style={{ fontSize: "28px", fontWeight: 700, fontFamily: "'JetBrains Mono', 'SF Mono', monospace", color: "#f5f5f7" }}>
      {value}<span style={{ fontSize: "14px", color: "#8e8e93", marginLeft: "4px" }}>{unit}</span>
    </div>
    {sub && <div style={{ fontSize: "12px", color: "#8e8e93", marginTop: "4px" }}>{sub}</div>}
  </div>
);

const Terminal = ({ lines, title }) => (
  <div style={{
    background: "#0a0a0a", borderRadius: "8px", border: "1px solid #222", overflow: "hidden", fontFamily: "'JetBrains Mono', 'SF Mono', monospace",
  }}>
    <div style={{ background: "#1a1a1a", padding: "8px 14px", display: "flex", alignItems: "center", gap: "8px", borderBottom: "1px solid #222" }}>
      <div style={{ width: 12, height: 12, borderRadius: "50%", background: "#ff5f56" }} />
      <div style={{ width: 12, height: 12, borderRadius: "50%", background: "#ffbd2e" }} />
      <div style={{ width: 12, height: 12, borderRadius: "50%", background: "#27c93f" }} />
      <span style={{ marginLeft: "8px", fontSize: "12px", color: "#8e8e93" }}>{title || "terminal"}</span>
    </div>
    <div style={{ padding: "14px", fontSize: "12px", lineHeight: "1.7", maxHeight: "350px", overflowY: "auto" }}>
      {lines.map((l, i) => (
        <div key={i} style={{ color: l.startsWith("#") ? "#6a9955" : l.includes("ALERT") || l.includes("✗") ? "#ff3b30" : l.includes("OK") || l.includes("✓") ? "#34c759" : l.includes("WARN") || l.includes("◎") ? "#ffcc00" : "#d4d4d4", whiteSpace: "pre-wrap" }}>{l}</div>
      ))}
    </div>
  </div>
);

const IncidentTimeline = ({ incident }) => (
  <div style={{ display: "flex", flexDirection: "column", gap: "12px", padding: "16px 0" }}>
    {INCIDENT_PHASES.map((phase, i) => {
      const active = i <= incident.currentPhase;
      const current = i === incident.currentPhase;
      return (
        <div key={phase} style={{ display: "flex", alignItems: "center", gap: "14px" }}>
          <div style={{
            width: 28, height: 28, borderRadius: "50%", display: "flex", alignItems: "center", justifyContent: "center",
            background: current ? "#0a84ff" : active ? "#34c759" : "rgba(255,255,255,0.06)",
            border: `2px solid ${current ? "#0a84ff" : active ? "#34c759" : "#333"}`,
            fontSize: "12px", fontWeight: 700, color: active ? "#fff" : "#555",
            animation: current ? "pulse 2s ease-in-out infinite" : "none",
          }}>{active ? (current ? "●" : "✓") : i + 1}</div>
          <div>
            <div style={{ fontSize: "14px", fontWeight: current ? 700 : 400, color: active ? "#f5f5f7" : "#555" }}>{phase}</div>
            {current && <div style={{ fontSize: "11px", color: "#0a84ff", marginTop: "2px" }}>In Progress — {incident.elapsed}m elapsed</div>}
          </div>
        </div>
      );
    })}
  </div>
);

// ─── JD SKILL MAPPING COMPONENT ─────────────────────────────────────────────
const SkillMatrix = () => {
  const mapping = [
    { jd: "UNIX/Linux production support", demo: "Shell scripts for health checks, cache monitoring, batch job tracking", tab: "scripts" },
    { jd: "Java-based platforms (web services)", demo: "JVM metrics dashboard, WebSphere/JBoss deployment runbook", tab: "dashboard" },
    { jd: "Coherence cache management", demo: "Real-time cache hit ratio monitoring, partition health checks", tab: "scripts" },
    { jd: "Batch job monitoring", demo: "Control-M job status tracker with PagerDuty escalation", tab: "scripts" },
    { jd: "SLA tracking & incident resolution", demo: "Live SLA compliance dashboard, incident lifecycle tracker", tab: "incidents" },
    { jd: "Deploy/validate/rollback releases", demo: "Interactive deployment runbook with phase tracking", tab: "runbook" },
    { jd: "Post-mortems/RCA", demo: "Structured RCA template with timeline and action items", tab: "incidents" },
    { jd: "Splunk/Dynatrace/ExtraHop monitoring", demo: "Pre-built Splunk SPL queries, Dynatrace metric alerts", tab: "monitoring" },
    { jd: "Automation & scripting", demo: "Shell-based automation scripts with Splunk HEC integration", tab: "scripts" },
    { jd: "Disaster Recovery planning", demo: "DR scenario planner with RTO/RPO tracking", tab: "dr" },
    { jd: "Capacity planning & performance tuning", demo: "Live capacity metrics, node utilization tracking", tab: "dashboard" },
    { jd: "Oracle GoldenGate", demo: "Replication lag monitoring, trail break recovery runbook", tab: "dr" },
    { jd: "NoSQL (Couchbase/Coherence)", demo: "Couchbase bucket monitoring, Coherence cluster health", tab: "monitoring" },
    { jd: "CI/CD & configuration management", demo: "Release pipeline visualization, Git-based config snapshots", tab: "runbook" },
    { jd: "ITIL production support", demo: "Incident → Problem → Change workflow with SLA tracking", tab: "incidents" },
  ];

  return (
    <div style={{ overflowX: "auto" }}>
      <table style={{ width: "100%", borderCollapse: "collapse", fontSize: "13px" }}>
        <thead>
          <tr style={{ borderBottom: "2px solid #333" }}>
            <th style={{ textAlign: "left", padding: "10px 12px", color: "#8e8e93", fontWeight: 600, fontSize: "11px", textTransform: "uppercase", letterSpacing: "0.5px" }}>JD Requirement</th>
            <th style={{ textAlign: "left", padding: "10px 12px", color: "#8e8e93", fontWeight: 600, fontSize: "11px", textTransform: "uppercase", letterSpacing: "0.5px" }}>Demonstrated In Project</th>
            <th style={{ textAlign: "left", padding: "10px 12px", color: "#8e8e93", fontWeight: 600, fontSize: "11px", textTransform: "uppercase", letterSpacing: "0.5px" }}>Tab</th>
          </tr>
        </thead>
        <tbody>
          {mapping.map((m, i) => (
            <tr key={i} style={{ borderBottom: "1px solid rgba(255,255,255,0.06)" }}>
              <td style={{ padding: "10px 12px", color: "#f5f5f7", fontWeight: 500 }}>{m.jd}</td>
              <td style={{ padding: "10px 12px", color: "#a1a1a6" }}>{m.demo}</td>
              <td style={{ padding: "10px 12px" }}>
                <span style={{ background: "#0a84ff22", color: "#0a84ff", padding: "2px 8px", borderRadius: "4px", fontSize: "11px", fontWeight: 600 }}>{m.tab}</span>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
};

// ─── MAIN APP ───────────────────────────────────────────────────────────────
export default function RiskOpsCommandCenter() {
  const [activeTab, setActiveTab] = useState("dashboard");
  const [metrics, setMetrics] = useState(generateMetrics());
  const [alerts, setAlerts] = useState(() =>
    ALERT_TEMPLATES.slice(0, 4).map((a, i) => ({ ...a, id: i, time: ts(), ack: false }))
  );
  const [incident] = useState({ id: "INC-20260331-001", title: "Falcon scoring latency spike — SLA breach risk", currentPhase: 2, elapsed: 14, severity: "critical" });
  const [deployPhase, setDeployPhase] = useState(0);
  const [drScenario, setDrScenario] = useState(0);
  const [scriptView, setScriptView] = useState("healthCheck");
  const timerRef = useRef(null);

  useEffect(() => {
    timerRef.current = setInterval(() => setMetrics(generateMetrics()), 3000);
    return () => clearInterval(timerRef.current);
  }, []);

  const ackAlert = (id) => setAlerts((prev) => prev.map((a) => a.id === id ? { ...a, ack: true } : a));

  const tabs = [
    { id: "dashboard", label: "Operations Dashboard" },
    { id: "incidents", label: "Incident Management" },
    { id: "runbook", label: "Deployment Runbook" },
    { id: "scripts", label: "Automation Scripts" },
    { id: "monitoring", label: "Monitoring & Alerts" },
    { id: "dr", label: "Disaster Recovery" },
    { id: "skillmap", label: "JD Skill Map" },
  ];

  return (
    <div style={{
      minHeight: "100vh", background: "#000", color: "#f5f5f7",
      fontFamily: "'Inter', -apple-system, BlinkMacSystemFont, sans-serif",
    }}>
      <style>{`
        @import url('https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700;800&family=JetBrains+Mono:wght@400;500;600;700&display=swap');
        * { box-sizing: border-box; margin: 0; padding: 0; }
        ::-webkit-scrollbar { width: 6px; }
        ::-webkit-scrollbar-track { background: transparent; }
        ::-webkit-scrollbar-thumb { background: #333; border-radius: 3px; }
        @keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.5; } }
        @keyframes slideIn { from { opacity: 0; transform: translateY(8px); } to { opacity: 1; transform: translateY(0); } }
      `}</style>

      {/* HEADER */}
      <div style={{
        borderBottom: "1px solid rgba(255,255,255,0.08)", padding: "16px 24px",
        display: "flex", alignItems: "center", justifyContent: "space-between",
        background: "rgba(0,0,0,0.8)", backdropFilter: "blur(20px)", position: "sticky", top: 0, zIndex: 100,
      }}>
        <div style={{ display: "flex", alignItems: "center", gap: "14px" }}>
          <div style={{ width: 36, height: 36, borderRadius: "8px", background: "linear-gradient(135deg, #0a84ff, #5e5ce6)", display: "flex", alignItems: "center", justifyContent: "center", fontWeight: 800, fontSize: "16px" }}>R</div>
          <div>
            <div style={{ fontSize: "16px", fontWeight: 700, letterSpacing: "-0.3px" }}>RiskOps Command Center</div>
            <div style={{ fontSize: "11px", color: "#8e8e93" }}>Card Risk Platform — Production Support Dashboard</div>
          </div>
        </div>
        <div style={{ display: "flex", alignItems: "center", gap: "16px" }}>
          <div style={{ display: "flex", alignItems: "center", gap: "6px" }}>
            <div style={{ width: 8, height: 8, borderRadius: "50%", background: "#34c759", animation: "pulse 2s infinite" }} />
            <span style={{ fontSize: "12px", color: "#34c759", fontWeight: 600 }}>PROD</span>
          </div>
          <span style={{ fontSize: "12px", color: "#8e8e93", fontFamily: "'JetBrains Mono', monospace" }}>{new Date().toLocaleDateString()}</span>
        </div>
      </div>

      {/* TAB NAV */}
      <div style={{
        display: "flex", gap: "2px", padding: "12px 24px", overflowX: "auto",
        borderBottom: "1px solid rgba(255,255,255,0.06)", background: "rgba(0,0,0,0.6)",
      }}>
        {tabs.map((t) => (
          <button key={t.id} onClick={() => setActiveTab(t.id)} style={{
            padding: "8px 16px", borderRadius: "6px", border: "none", cursor: "pointer",
            fontSize: "13px", fontWeight: activeTab === t.id ? 600 : 400, whiteSpace: "nowrap",
            background: activeTab === t.id ? "rgba(10,132,255,0.15)" : "transparent",
            color: activeTab === t.id ? "#0a84ff" : "#8e8e93",
            transition: "all 0.2s",
          }}>{t.label}</button>
        ))}
      </div>

      {/* CONTENT */}
      <div style={{ padding: "24px", maxWidth: "1400px", margin: "0 auto", animation: "slideIn 0.3s ease" }}>

        {/* ─── DASHBOARD TAB ──────────────────────────────────────────── */}
        {activeTab === "dashboard" && (
          <div style={{ display: "flex", flexDirection: "column", gap: "24px" }}>
            <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(180px, 1fr))", gap: "14px" }}>
              <MetricCard label="Transactions/sec" value={metrics.tps.toLocaleString()} unit="TPS" status="ok" />
              <MetricCard label="Latency P50" value={metrics.latencyP50} unit="ms" status="ok" />
              <MetricCard label="Latency P99" value={metrics.latencyP99} unit="ms" status={metrics.latencyP99 > 200 ? "critical" : "ok"} sub={`SLA: < 200ms`} />
              <MetricCard label="Error Rate" value={metrics.errorRate} unit="%" status={metrics.errorRate > 0.5 ? "warn" : "ok"} />
              <MetricCard label="Cache Hit Rate" value={metrics.cacheHitRate} unit="%" status={metrics.cacheHitRate < 95 ? "warn" : "ok"} />
              <MetricCard label="Platform Uptime" value={metrics.uptime} unit="" status="ok" sub="SLA: 99.95%" />
              <MetricCard label="Active Nodes" value={`${metrics.activeNodes}/${metrics.totalNodes}`} unit="" status={metrics.activeNodes < 23 ? "warn" : "ok"} />
              <MetricCard label="MTTR" value={metrics.mttr} unit="min" status={metrics.mttr > 15 ? "warn" : "ok"} sub="Target: < 15min" />
            </div>

            <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: "16px" }}>
              <div style={{ background: "rgba(255,255,255,0.03)", border: "1px solid rgba(255,255,255,0.08)", borderRadius: "8px", padding: "18px" }}>
                <h3 style={{ fontSize: "14px", fontWeight: 600, marginBottom: "14px", color: "#f5f5f7" }}>Service Health Map</h3>
                <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: "8px" }}>
                  {SERVICES.map((s) => {
                    const healthy = Math.random() > 0.15;
                    return (
                      <div key={s.id} style={{
                        padding: "10px 12px", borderRadius: "6px", display: "flex", alignItems: "center", gap: "10px",
                        background: healthy ? "rgba(52,199,89,0.06)" : "rgba(255,59,48,0.08)",
                        border: `1px solid ${healthy ? "rgba(52,199,89,0.15)" : "rgba(255,59,48,0.2)"}`,
                      }}>
                        <div style={{ width: 8, height: 8, borderRadius: "50%", background: healthy ? "#34c759" : "#ff3b30", flexShrink: 0 }} />
                        <div>
                          <div style={{ fontSize: "12px", fontWeight: 500, color: "#f5f5f7" }}>{s.name}</div>
                          <div style={{ fontSize: "10px", color: "#8e8e93" }}>{s.cluster} · :{s.port || "N/A"}</div>
                        </div>
                      </div>
                    );
                  })}
                </div>
              </div>

              <div style={{ background: "rgba(255,255,255,0.03)", border: "1px solid rgba(255,255,255,0.08)", borderRadius: "8px", padding: "18px" }}>
                <h3 style={{ fontSize: "14px", fontWeight: 600, marginBottom: "14px", color: "#f5f5f7" }}>Live Alerts</h3>
                <div style={{ display: "flex", flexDirection: "column", gap: "8px", maxHeight: "280px", overflowY: "auto" }}>
                  {alerts.map((a) => (
                    <div key={a.id} style={{
                      padding: "10px 12px", borderRadius: "6px", display: "flex", alignItems: "flex-start", justifyContent: "space-between", gap: "10px",
                      background: a.ack ? "rgba(255,255,255,0.02)" : "rgba(255,255,255,0.04)",
                      border: `1px solid ${a.ack ? "rgba(255,255,255,0.04)" : "rgba(255,255,255,0.08)"}`,
                      opacity: a.ack ? 0.5 : 1,
                    }}>
                      <div style={{ flex: 1 }}>
                        <div style={{ display: "flex", alignItems: "center", gap: "8px", marginBottom: "4px" }}>
                          <SeverityBadge severity={a.severity} />
                          <span style={{ fontSize: "10px", color: "#8e8e93", fontFamily: "monospace" }}>{a.time}</span>
                        </div>
                        <div style={{ fontSize: "12px", color: "#d1d1d6" }}>{a.msg}</div>
                      </div>
                      {!a.ack && (
                        <button onClick={() => ackAlert(a.id)} style={{
                          padding: "4px 10px", borderRadius: "4px", border: "1px solid #333",
                          background: "transparent", color: "#8e8e93", fontSize: "11px", cursor: "pointer", whiteSpace: "nowrap",
                        }}>ACK</button>
                      )}
                    </div>
                  ))}
                </div>
              </div>
            </div>

            <div style={{ background: "rgba(255,255,255,0.03)", border: "1px solid rgba(255,255,255,0.08)", borderRadius: "8px", padding: "18px" }}>
              <h3 style={{ fontSize: "14px", fontWeight: 600, marginBottom: "14px", color: "#f5f5f7" }}>Batch Job Status (Control-M)</h3>
              <div style={{ display: "flex", alignItems: "center", gap: "8px", marginBottom: "14px" }}>
                <span style={{ fontSize: "24px", fontWeight: 700, fontFamily: "monospace", color: "#34c759" }}>{metrics.batchJobsOk}</span>
                <span style={{ fontSize: "14px", color: "#8e8e93" }}>/ {metrics.batchJobsTotal} jobs completed</span>
              </div>
              <div style={{ display: "flex", gap: "3px", height: "8px", borderRadius: "4px", overflow: "hidden" }}>
                {Array.from({ length: metrics.batchJobsTotal }).map((_, i) => (
                  <div key={i} style={{
                    flex: 1, borderRadius: "2px",
                    background: i < metrics.batchJobsOk ? "#34c759" : i < metrics.batchJobsOk + 2 ? "#ffcc00" : "#ff3b30",
                  }} />
                ))}
              </div>
            </div>
          </div>
        )}

        {/* ─── INCIDENTS TAB ─────────────────────────────────────────── */}
        {activeTab === "incidents" && (
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: "20px" }}>
            <div style={{ background: "rgba(255,255,255,0.03)", border: "1px solid rgba(255,255,255,0.08)", borderRadius: "8px", padding: "20px" }}>
              <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: "16px" }}>
                <h3 style={{ fontSize: "16px", fontWeight: 600 }}>Active Incident</h3>
                <SeverityBadge severity={incident.severity} />
              </div>
              <div style={{ fontSize: "11px", color: "#8e8e93", fontFamily: "monospace", marginBottom: "6px" }}>{incident.id}</div>
              <div style={{ fontSize: "14px", fontWeight: 500, marginBottom: "20px" }}>{incident.title}</div>
              <IncidentTimeline incident={incident} />
            </div>

            <div style={{ display: "flex", flexDirection: "column", gap: "16px" }}>
              <div style={{ background: "rgba(255,255,255,0.03)", border: "1px solid rgba(255,255,255,0.08)", borderRadius: "8px", padding: "20px" }}>
                <h3 style={{ fontSize: "14px", fontWeight: 600, marginBottom: "14px" }}>Root Cause Analysis Template</h3>
                <div style={{ fontSize: "13px", color: "#a1a1a6", lineHeight: "1.8" }}>
                  <div style={{ fontWeight: 600, color: "#f5f5f7", marginBottom: "6px" }}>RCA-2026-0331 — Falcon Latency Spike</div>
                  <div><span style={{ color: "#0a84ff" }}>Impact:</span> P99 latency exceeded 500ms for 8 minutes, affecting ~12,000 transactions</div>
                  <div><span style={{ color: "#0a84ff" }}>Root Cause:</span> Coherence cache partition transfer during rolling restart caused temporary data locality miss</div>
                  <div><span style={{ color: "#0a84ff" }}>Detection:</span> Splunk alert fired at T+45s, PagerDuty escalation at T+60s</div>
                  <div><span style={{ color: "#0a84ff" }}>Resolution:</span> Forced partition rebalance, confirmed all nodes healthy</div>
                  <div><span style={{ color: "#0a84ff" }}>Action Items:</span></div>
                  <div style={{ paddingLeft: "16px" }}>
                    • Add pre-restart cache warmup step to runbook<br />
                    • Implement staggered restart with health gate between nodes<br />
                    • Add Dynatrace alert for partition transfer duration &gt; 30s
                  </div>
                </div>
              </div>

              <div style={{ background: "rgba(255,255,255,0.03)", border: "1px solid rgba(255,255,255,0.08)", borderRadius: "8px", padding: "20px" }}>
                <h3 style={{ fontSize: "14px", fontWeight: 600, marginBottom: "14px" }}>ITIL Incident Metrics</h3>
                <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: "12px" }}>
                  <MetricCard label="Open P1/P2" value="1" unit="" status="critical" />
                  <MetricCard label="MTTR (30d)" value="14" unit="min" status="ok" />
                  <MetricCard label="SLA Compliance" value="99.8" unit="%" status="ok" />
                  <MetricCard label="Recurring Issues" value="2" unit="" status="warn" />
                </div>
              </div>
            </div>
          </div>
        )}

        {/* ─── RUNBOOK TAB ───────────────────────────────────────────── */}
        {activeTab === "runbook" && (
          <div style={{ display: "flex", flexDirection: "column", gap: "20px" }}>
            <div style={{ background: "rgba(255,255,255,0.03)", border: "1px solid rgba(255,255,255,0.08)", borderRadius: "8px", padding: "20px" }}>
              <h3 style={{ fontSize: "16px", fontWeight: 600, marginBottom: "4px" }}>Release Deployment Runbook</h3>
              <div style={{ fontSize: "12px", color: "#8e8e93", marginBottom: "20px" }}>v3.14.2 → v3.15.0 | Risk Scoring Engine | CAB-2026-0331</div>

              <div style={{ display: "flex", gap: "4px", marginBottom: "24px" }}>
                {RUNBOOK_STEPS.map((_, i) => (
                  <div key={i} style={{ flex: 1, height: "4px", borderRadius: "2px", background: i <= deployPhase ? "#0a84ff" : "#222", transition: "background 0.3s" }} />
                ))}
              </div>

              {RUNBOOK_STEPS.map((phase, pi) => (
                <div key={pi} style={{ marginBottom: "20px", opacity: pi <= deployPhase ? 1 : 0.4, transition: "opacity 0.3s" }}>
                  <div style={{
                    display: "flex", alignItems: "center", gap: "10px", marginBottom: "10px", cursor: "pointer",
                  }} onClick={() => setDeployPhase(pi)}>
                    <div style={{
                      width: 24, height: 24, borderRadius: "50%", display: "flex", alignItems: "center", justifyContent: "center",
                      background: pi < deployPhase ? "#34c759" : pi === deployPhase ? "#0a84ff" : "#222",
                      fontSize: "11px", fontWeight: 700, color: "#fff",
                    }}>{pi < deployPhase ? "✓" : pi + 1}</div>
                    <span style={{ fontSize: "14px", fontWeight: 600, color: pi <= deployPhase ? "#f5f5f7" : "#555" }}>{phase.phase}</span>
                    {pi === 3 && <span style={{ fontSize: "11px", color: "#ff9500", fontWeight: 600, marginLeft: "8px" }}>⚠ EMERGENCY ONLY</span>}
                  </div>
                  {pi <= deployPhase && (
                    <div style={{ paddingLeft: "38px", display: "flex", flexDirection: "column", gap: "6px" }}>
                      {phase.steps.map((step, si) => (
                        <div key={si} style={{ display: "flex", alignItems: "center", gap: "8px", fontSize: "13px", color: "#a1a1a6" }}>
                          <span style={{ width: 16, height: 16, borderRadius: "4px", border: "1px solid #444", display: "flex", alignItems: "center", justifyContent: "center", fontSize: "10px", color: pi < deployPhase ? "#34c759" : "#555" }}>
                            {pi < deployPhase ? "✓" : ""}
                          </span>
                          {step}
                        </div>
                      ))}
                    </div>
                  )}
                </div>
              ))}

              <div style={{ display: "flex", gap: "10px", marginTop: "10px" }}>
                <button onClick={() => setDeployPhase(Math.min(3, deployPhase + 1))} style={{
                  padding: "8px 20px", borderRadius: "6px", border: "none", cursor: "pointer",
                  background: "#0a84ff", color: "#fff", fontWeight: 600, fontSize: "13px",
                }}>Advance Phase →</button>
                <button onClick={() => setDeployPhase(0)} style={{
                  padding: "8px 20px", borderRadius: "6px", border: "1px solid #444",
                  background: "transparent", color: "#8e8e93", fontWeight: 500, fontSize: "13px", cursor: "pointer",
                }}>Reset</button>
              </div>
            </div>
          </div>
        )}

        {/* ─── SCRIPTS TAB ───────────────────────────────────────────── */}
        {activeTab === "scripts" && (
          <div style={{ display: "flex", flexDirection: "column", gap: "16px" }}>
            <div style={{ display: "flex", gap: "8px" }}>
              {Object.keys(SHELL_SCRIPTS).map((key) => (
                <button key={key} onClick={() => setScriptView(key)} style={{
                  padding: "6px 14px", borderRadius: "6px", border: "none", cursor: "pointer",
                  background: scriptView === key ? "rgba(10,132,255,0.15)" : "rgba(255,255,255,0.05)",
                  color: scriptView === key ? "#0a84ff" : "#8e8e93", fontSize: "13px", fontWeight: 500,
                }}>
                  {key === "healthCheck" ? "Health Check" : key === "cacheMonitor" ? "Cache Monitor" : "Batch Monitor"}
                </button>
              ))}
            </div>
            <Terminal lines={SHELL_SCRIPTS[scriptView].split("\n")} title={`${scriptView}.sh — production automation`} />
            <div style={{ background: "rgba(10,132,255,0.06)", border: "1px solid rgba(10,132,255,0.15)", borderRadius: "8px", padding: "14px", fontSize: "13px", color: "#a1a1a6" }}>
              <span style={{ color: "#0a84ff", fontWeight: 600 }}>JD Mapping:</span> These scripts demonstrate UNIX/Linux shell scripting, Splunk HEC integration, Coherence cache management, Control-M batch monitoring, and PagerDuty alerting — directly addressing the "10+ years UNIX/Linux" and "automation and monitoring" requirements.
            </div>
          </div>
        )}

        {/* ─── MONITORING TAB ────────────────────────────────────────── */}
        {activeTab === "monitoring" && (
          <div style={{ display: "flex", flexDirection: "column", gap: "20px" }}>
            <div style={{ background: "rgba(255,255,255,0.03)", border: "1px solid rgba(255,255,255,0.08)", borderRadius: "8px", padding: "20px" }}>
              <h3 style={{ fontSize: "16px", fontWeight: 600, marginBottom: "16px" }}>Splunk SPL Queries — Risk Platform Monitoring</h3>
              {SPLUNK_QUERIES.map((q, i) => (
                <div key={i} style={{ marginBottom: "14px" }}>
                  <div style={{ fontSize: "13px", fontWeight: 600, color: "#f5f5f7", marginBottom: "6px" }}>{q.name}</div>
                  <div style={{
                    background: "#0a0a0a", borderRadius: "6px", padding: "10px 14px", border: "1px solid #222",
                    fontFamily: "'JetBrains Mono', monospace", fontSize: "12px", color: "#d4d4d4", overflowX: "auto",
                  }}>{q.query}</div>
                </div>
              ))}
            </div>

            <div style={{ background: "rgba(255,255,255,0.03)", border: "1px solid rgba(255,255,255,0.08)", borderRadius: "8px", padding: "20px" }}>
              <h3 style={{ fontSize: "14px", fontWeight: 600, marginBottom: "14px" }}>Observability Stack Integration</h3>
              <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr 1fr", gap: "12px" }}>
                {[
                  { tool: "Splunk", role: "Log aggregation, alerting, dashboards", status: "Active", metrics: "47 saved searches, 12 alerts" },
                  { tool: "Dynatrace", role: "APM, JVM monitoring, service flow", status: "Active", metrics: "24 hosts, 8 services monitored" },
                  { tool: "ExtraHop", role: "Network analytics, wire data", status: "Active", metrics: "3.2TB/day wire data analyzed" },
                ].map((t, i) => (
                  <div key={i} style={{ background: "rgba(255,255,255,0.03)", borderRadius: "8px", padding: "14px", border: "1px solid rgba(255,255,255,0.06)" }}>
                    <div style={{ fontSize: "14px", fontWeight: 600, color: "#f5f5f7", marginBottom: "4px" }}>{t.tool}</div>
                    <div style={{ fontSize: "12px", color: "#8e8e93", marginBottom: "8px" }}>{t.role}</div>
                    <div style={{ display: "flex", alignItems: "center", gap: "6px" }}>
                      <div style={{ width: 6, height: 6, borderRadius: "50%", background: "#34c759" }} />
                      <span style={{ fontSize: "11px", color: "#34c759" }}>{t.status}</span>
                    </div>
                    <div style={{ fontSize: "11px", color: "#8e8e93", marginTop: "4px" }}>{t.metrics}</div>
                  </div>
                ))}
              </div>
            </div>
          </div>
        )}

        {/* ─── DR TAB ────────────────────────────────────────────────── */}
        {activeTab === "dr" && (
          <div style={{ display: "flex", flexDirection: "column", gap: "20px" }}>
            <div style={{ display: "flex", gap: "8px" }}>
              {DR_SCENARIOS.map((s, i) => (
                <button key={i} onClick={() => setDrScenario(i)} style={{
                  padding: "8px 16px", borderRadius: "6px", border: "none", cursor: "pointer",
                  background: drScenario === i ? "rgba(255,59,48,0.12)" : "rgba(255,255,255,0.05)",
                  color: drScenario === i ? "#ff3b30" : "#8e8e93", fontSize: "13px", fontWeight: 500,
                }}>{s.name}</button>
              ))}
            </div>

            <div style={{ background: "rgba(255,255,255,0.03)", border: "1px solid rgba(255,255,255,0.08)", borderRadius: "8px", padding: "20px" }}>
              <h3 style={{ fontSize: "16px", fontWeight: 600, marginBottom: "16px" }}>{DR_SCENARIOS[drScenario].name}</h3>
              <div style={{ display: "flex", gap: "20px", marginBottom: "20px" }}>
                <div style={{ background: "rgba(255,59,48,0.08)", borderRadius: "8px", padding: "14px", flex: 1, border: "1px solid rgba(255,59,48,0.15)" }}>
                  <div style={{ fontSize: "11px", color: "#8e8e93", textTransform: "uppercase", letterSpacing: "0.5px" }}>Recovery Time Objective</div>
                  <div style={{ fontSize: "24px", fontWeight: 700, color: "#ff3b30", fontFamily: "monospace" }}>{DR_SCENARIOS[drScenario].rto}</div>
                </div>
                <div style={{ background: "rgba(10,132,255,0.08)", borderRadius: "8px", padding: "14px", flex: 1, border: "1px solid rgba(10,132,255,0.15)" }}>
                  <div style={{ fontSize: "11px", color: "#8e8e93", textTransform: "uppercase", letterSpacing: "0.5px" }}>Recovery Point Objective</div>
                  <div style={{ fontSize: "24px", fontWeight: 700, color: "#0a84ff", fontFamily: "monospace" }}>{DR_SCENARIOS[drScenario].rpo}</div>
                </div>
              </div>

              <h4 style={{ fontSize: "13px", fontWeight: 600, marginBottom: "12px", color: "#f5f5f7" }}>Recovery Procedure</h4>
              <div style={{ display: "flex", flexDirection: "column", gap: "10px" }}>
                {DR_SCENARIOS[drScenario].steps.map((step, i) => (
                  <div key={i} style={{ display: "flex", alignItems: "flex-start", gap: "12px" }}>
                    <div style={{
                      width: 24, height: 24, borderRadius: "50%", display: "flex", alignItems: "center", justifyContent: "center",
                      background: "rgba(255,59,48,0.12)", color: "#ff3b30", fontSize: "11px", fontWeight: 700, flexShrink: 0,
                    }}>{i + 1}</div>
                    <div style={{ fontSize: "13px", color: "#d1d1d6", paddingTop: "2px" }}>{step}</div>
                  </div>
                ))}
              </div>
            </div>

            <div style={{ background: "rgba(10,132,255,0.06)", border: "1px solid rgba(10,132,255,0.15)", borderRadius: "8px", padding: "14px", fontSize: "13px", color: "#a1a1a6" }}>
              <span style={{ color: "#0a84ff", fontWeight: 600 }}>JD Mapping:</span> DR planning with RTO/RPO targets, Oracle GoldenGate recovery, Coherence cache rebuild procedures, and batch job dependency management — directly addressing the "Risk Disaster Recovery Plan" and "capacity planning" requirements.
            </div>
          </div>
        )}

        {/* ─── SKILL MAP TAB ────────────────────────────────────────── */}
        {activeTab === "skillmap" && (
          <div style={{ display: "flex", flexDirection: "column", gap: "20px" }}>
            <div style={{ background: "rgba(255,255,255,0.03)", border: "1px solid rgba(255,255,255,0.08)", borderRadius: "8px", padding: "20px" }}>
              <h3 style={{ fontSize: "16px", fontWeight: 600, marginBottom: "4px" }}>JD → Project Skills Matrix</h3>
              <p style={{ fontSize: "12px", color: "#8e8e93", marginBottom: "16px" }}>Every requirement from the Fiserv Risk Application Support Advisor JD is demonstrated in this project.</p>
              <SkillMatrix />
            </div>

            <div style={{ background: "rgba(52,199,89,0.06)", border: "1px solid rgba(52,199,89,0.15)", borderRadius: "8px", padding: "20px" }}>
              <h3 style={{ fontSize: "14px", fontWeight: 600, color: "#34c759", marginBottom: "10px" }}>GitHub Repository Structure</h3>
              <Terminal title="project structure" lines={[
                "riskops-command-center/",
                "├── README.md                    # Project overview + JD skill mapping",
                "├── dashboard/                   # React monitoring dashboard",
                "│   ├── src/App.jsx             # Main dashboard (this file)",
                "│   └── package.json",
                "├── scripts/                     # Production automation scripts",
                "│   ├── health_check.sh          # Service health + Splunk alerting",
                "│   ├── coherence_monitor.sh     # Cache cluster monitoring",
                "│   ├── batch_monitor.sh         # Control-M job tracker",
                "│   ├── log_rotator.sh           # Automated log management",
                "│   └── deploy_validator.sh      # Post-deploy validation suite",
                "├── runbooks/                    # Operational runbooks (Markdown)",
                "│   ├── deployment_runbook.md",
                "│   ├── rollback_procedure.md",
                "│   ├── cache_recovery.md",
                "│   └── dr_playbook.md",
                "├── monitoring/                  # Observability configs",
                "│   ├── splunk/                  # Saved searches + alert configs",
                "│   ├── dynatrace/               # Custom metric definitions",
                "│   └── alerting_rules.yaml",
                "├── rca-templates/               # Post-mortem templates",
                "│   └── rca_template.md",
                "├── dr-plans/                    # Disaster recovery documentation",
                "│   ├── primary_dc_failure.md",
                "│   ├── cache_corruption.md",
                "│   └── replication_break.md",
                "├── ci-cd/                       # CI/CD pipeline configs",
                "│   ├── Jenkinsfile",
                "│   └── deployment_pipeline.yaml",
                "└── docs/                        # Architecture & capacity planning",
                "    ├── architecture.md",
                "    └── capacity_model.xlsx",
              ]} />
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
