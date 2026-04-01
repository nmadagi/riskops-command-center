#!/bin/bash
# ============================================================================
# batch_monitor.sh — Control-M Batch Job Status Monitor
# ============================================================================
# Purpose:  Monitors risk platform batch jobs in Control-M scheduler.
#           Tracks job completion, detects failures, checks dependencies,
#           and escalates via PagerDuty for SLA-critical jobs.
#
# Usage:    ./batch_monitor.sh [--verbose] [--dry-run] [--job <n>]
# Schedule: Cron every 5 min: */5 * * * * /opt/riskops/scripts/batch_monitor.sh
#
# Dependencies: curl, jq, logger
# ============================================================================

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
SCRIPT_NAME="$(basename "$0")"
LOG_DIR="/var/log/riskops"
LOG_FILE="${LOG_DIR}/batch_monitor.log"

CONTROLM_API="${CONTROLM_API:-https://controlm.prod.internal:8443/automation-api}"
CONTROLM_TOKEN="${CONTROLM_TOKEN:-}"
SPLUNK_HEC_URL="${SPLUNK_HEC_URL:-https://splunk.prod.internal:8088/services/collector/event}"
SPLUNK_HEC_TOKEN="${SPLUNK_HEC_TOKEN:-}"
PD_ROUTING_KEY="${PD_ROUTING_KEY:-}"

VERBOSE=false
DRY_RUN=false
FILTER_JOB=""

# ─── Job Registry ────────────────────────────────────────────────────────────
# Format: job_name|schedule|sla_window|criticality|description
declare -a RISK_JOBS=(
    "RISK_EOD_RECON|daily:23:00|01:00|P1|End-of-day transaction reconciliation"
    "RISK_DAILY_SCORING|daily:02:00|03:00|P1|Daily batch fraud scoring recalculation"
    "RISK_FRAUD_REPORT|daily:06:00|07:30|P2|Fraud summary report generation for ops team"
    "RISK_ARCHIVE_PURGE|daily:04:00|05:00|P2|Archive aged transactions and purge staging"
    "RISK_MODEL_REFRESH|weekly:sun:01:00|03:00|P1|ML model parameter refresh from training pipeline"
    "RISK_GOLDEN_GATE_SYNC|daily:00:30|01:00|P1|GoldenGate replication checkpoint validation"
    "RISK_CACHE_WARMUP|daily:05:30|06:00|P2|Pre-populate Coherence cache from Oracle"
    "RISK_CLIENT_EXTRACT|daily:07:00|08:00|P2|Client-specific transaction extract and SFTP delivery"
    "RISK_SLA_REPORT|daily:08:00|08:30|P3|SLA compliance metrics report"
    "RISK_AUDIT_TRAIL|daily:01:00|02:00|P2|Audit trail export for compliance"
)

# ─── Argument Parsing ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose|-v) VERBOSE=true; shift ;;
        --dry-run)    DRY_RUN=true; shift ;;
        --job)        FILTER_JOB="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $SCRIPT_NAME [--verbose] [--dry-run] [--job <name>]"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ─── Utility Functions ───────────────────────────────────────────────────────
timestamp() { date '+%Y-%m-%dT%H:%M:%S%z'; }
log() { echo "[$(timestamp)] [$1] $2" | tee -a "$LOG_FILE"; }
log_verbose() { [[ "$VERBOSE" == true ]] && log "DEBUG" "$1"; }

controlm_api() {
    local endpoint="$1"
    curl -sk --connect-timeout 5 --max-time 15 \
        -H "Authorization: Bearer ${CONTROLM_TOKEN}" \
        -H "Content-Type: application/json" \
        "${CONTROLM_API}${endpoint}" 2>/dev/null
}

send_to_splunk() {
    local job="$1" status="$2" details="$3"
    [[ -z "$SPLUNK_HEC_TOKEN" || "$DRY_RUN" == true ]] && return 0

    curl -sk -o /dev/null \
        -H "Authorization: Splunk ${SPLUNK_HEC_TOKEN}" \
        -d "$(jq -n \
            --arg job "$job" --arg status "$status" --arg details "$details" \
            --arg host "$(hostname)" --arg source "$SCRIPT_NAME" \
            '{
                host: $host, source: $source,
                sourcetype: "riskops:batch_monitor",
                index: "risk_platform",
                event: { job: $job, status: $status, details: $details }
            }')" \
        "$SPLUNK_HEC_URL" 2>/dev/null &
}

trigger_pagerduty() {
    local job="$1" summary="$2" severity="$3"
    [[ -z "$PD_ROUTING_KEY" || "$DRY_RUN" == true ]] && return 0

    curl -s -X POST "https://events.pagerduty.com/v2/enqueue" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
            --arg key "$PD_ROUTING_KEY" \
            --arg summary "$summary" \
            --arg severity "$severity" \
            --arg source "$job" \
            '{
                routing_key: $key,
                event_action: "trigger",
                payload: {
                    summary: $summary,
                    severity: $severity,
                    source: $source,
                    component: "batch-scheduler",
                    group: "risk-platform"
                }
            }')" > /dev/null 2>&1 &
}

# ─── Job Status Check ───────────────────────────────────────────────────────
check_job() {
    local entry="$1"
    IFS='|' read -r job_name schedule sla_window criticality description <<< "$entry"

    [[ -n "$FILTER_JOB" && "$job_name" != "$FILTER_JOB" ]] && return 0

    log_verbose "Checking job: $job_name"

    local status_json
    status_json=$(controlm_api "/run/jobs/status?jobname=${job_name}&limit=1")

    if [[ -z "$status_json" || "$status_json" == "null" ]]; then
        printf "  ◌ %-28s %-12s  %s\n" "$job_name" "NO DATA" "Cannot retrieve status from Control-M"
        send_to_splunk "$job_name" "UNKNOWN" "Status unavailable"
        return 0
    fi

    local status end_time start_time run_count
    status=$(echo "$status_json" | jq -r '.statuses[0].status // "Unknown"')
    end_time=$(echo "$status_json" | jq -r '.statuses[0].endTime // "N/A"')
    start_time=$(echo "$status_json" | jq -r '.statuses[0].startTime // "N/A"')
    run_count=$(echo "$status_json" | jq -r '.statuses[0].numberOfRuns // 0')

    case "$status" in
        "Ended OK"|"Ended_OK")
            printf "  ✓ %-28s %-12s  ended=%s  [%s]\n" "$job_name" "COMPLETED" "$end_time" "$criticality"
            send_to_splunk "$job_name" "COMPLETED" "Ended OK at $end_time"
            ;;
        "Executing"|"EXECUTING")
            local elapsed=""
            if [[ "$start_time" != "N/A" ]]; then
                elapsed=" (running since $start_time)"
            fi
            printf "  ◎ %-28s %-12s  started=%s%s  [%s]\n" "$job_name" "RUNNING" "$start_time" "$elapsed" "$criticality"
            send_to_splunk "$job_name" "RUNNING" "Started at $start_time"
            ;;
        "Wait Condition"|"Wait_Condition"|"WAITING")
            printf "  ◌ %-28s %-12s  waiting on dependency  [%s]\n" "$job_name" "WAITING" "$criticality"
            send_to_splunk "$job_name" "WAITING" "Waiting on predecessor"
            ;;
        "Ended Not OK"|"Ended_Not_OK"|"FAILED")
            printf "  ✗ %-28s %-12s  FAILED at %s  [%s]\n" "$job_name" "FAILED" "$end_time" "$criticality"
            log "CRITICAL" "Batch job $job_name FAILED (criticality: $criticality)"
            send_to_splunk "$job_name" "FAILED" "Job failed at $end_time"

            # Escalate based on criticality
            case "$criticality" in
                P1) trigger_pagerduty "$job_name" "CRITICAL: Batch job $job_name FAILED — $description" "critical" ;;
                P2) trigger_pagerduty "$job_name" "HIGH: Batch job $job_name FAILED — $description" "high" ;;
                P3) log "WARN" "P3 job $job_name failed — logged but not escalated" ;;
            esac
            ;;
        *)
            printf "  ? %-28s %-12s  status=%s  [%s]\n" "$job_name" "UNKNOWN" "$status" "$criticality"
            send_to_splunk "$job_name" "UNKNOWN" "Unexpected status: $status"
            ;;
    esac
}

# ─── Dependency Chain Validation ─────────────────────────────────────────────
check_dependency_chain() {
    echo ""
    echo "  ── Dependency Chain Validation ──────────────────────"

    # Critical dependency: GoldenGate sync must complete before daily scoring
    local ogg_status
    ogg_status=$(controlm_api "/run/jobs/status?jobname=RISK_GOLDEN_GATE_SYNC&limit=1" | jq -r '.statuses[0].status // "Unknown"')

    local scoring_status
    scoring_status=$(controlm_api "/run/jobs/status?jobname=RISK_DAILY_SCORING&limit=1" | jq -r '.statuses[0].status // "Unknown"')

    if [[ "$ogg_status" != "Ended OK" && "$ogg_status" != "Ended_OK" && "$scoring_status" == "Executing" ]]; then
        alert "HIGH" "dependency" "RISK_DAILY_SCORING running but prerequisite RISK_GOLDEN_GATE_SYNC has not completed (status: $ogg_status)"
        printf "  ✗ GoldenGate sync → Daily Scoring: BROKEN (sync status: %s)\n" "$ogg_status"
    else
        printf "  ✓ GoldenGate sync → Daily Scoring: OK\n"
    fi

    # Cache warmup should complete before client extracts
    local cache_status
    cache_status=$(controlm_api "/run/jobs/status?jobname=RISK_CACHE_WARMUP&limit=1" | jq -r '.statuses[0].status // "Unknown"')

    if [[ "$cache_status" == "Ended OK" || "$cache_status" == "Ended_OK" ]]; then
        printf "  ✓ Cache warmup → Client extract: OK\n"
    else
        printf "  ◌ Cache warmup → Client extract: Pending (warmup status: %s)\n" "$cache_status"
    fi
}

# ─── SLA Compliance Check ───────────────────────────────────────────────────
check_sla_compliance() {
    echo ""
    echo "  ── SLA Window Compliance ────────────────────────────"

    local current_hour
    current_hour=$(date +%H)

    local overdue=0
    for entry in "${RISK_JOBS[@]}"; do
        IFS='|' read -r job_name schedule sla_window criticality description <<< "$entry"

        # Extract SLA deadline hour (simplified)
        local sla_hour
        sla_hour=$(echo "$sla_window" | cut -d: -f1)

        if [[ "$current_hour" -ge "$sla_hour" ]]; then
            local status
            status=$(controlm_api "/run/jobs/status?jobname=${job_name}&limit=1" | jq -r '.statuses[0].status // "Unknown"')

            if [[ "$status" != "Ended OK" && "$status" != "Ended_OK" ]]; then
                printf "  ✗ %-28s SLA window %s BREACHED (status: %s)\n" "$job_name" "$sla_window" "$status"
                ((overdue++))
            fi
        fi
    done

    [[ "$overdue" -eq 0 ]] && printf "  ✓ All jobs within SLA windows\n"
}

# ─── Main Execution ──────────────────────────────────────────────────────────
main() {
    mkdir -p "$LOG_DIR"

    echo "═══════════════════════════════════════════════════════════════"
    echo "  Control-M Batch Job Monitor — $(timestamp)"
    echo "  API: ${CONTROLM_API}"
    echo "  Mode: $([[ "$DRY_RUN" == true ]] && echo "DRY-RUN" || echo "LIVE")"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "  ── Job Status ───────────────────────────────────────"

    local total=0 completed=0 running=0 failed=0 waiting=0

    for entry in "${RISK_JOBS[@]}"; do
        check_job "$entry"
        ((total++))
    done

    check_dependency_chain
    check_sla_compliance

    echo ""
    echo "───────────────────────────────────────────────────────────────"
    echo "  Total: $total jobs monitored | $(timestamp)"
    echo "═══════════════════════════════════════════════════════════════"
}

main "$@"
