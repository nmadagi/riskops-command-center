#!/bin/bash
# ============================================================================
# health_check.sh — Production Service Health Check
# ============================================================================
# Purpose:  Monitors all risk platform services, checks HTTP health endpoints,
#           measures response latency, and sends alerts to Splunk HEC and
#           PagerDuty when thresholds are breached.
#
# Usage:    ./health_check.sh [--verbose] [--dry-run] [--service <name>]
# Schedule: Cron every 60 seconds via: * * * * * /opt/riskops/scripts/health_check.sh
#
# Dependencies: curl, jq, logger
# Splunk HEC Token: Set via environment variable SPLUNK_HEC_TOKEN
# PagerDuty Key:    Set via environment variable PD_ROUTING_KEY
# ============================================================================

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
SCRIPT_NAME="$(basename "$0")"
LOG_DIR="/var/log/riskops"
LOG_FILE="${LOG_DIR}/health_check.log"
SPLUNK_HEC_URL="${SPLUNK_HEC_URL:-https://splunk.prod.internal:8088/services/collector/event}"
SPLUNK_HEC_TOKEN="${SPLUNK_HEC_TOKEN:-}"
PD_ROUTING_KEY="${PD_ROUTING_KEY:-}"

# Thresholds
LATENCY_WARN_MS=150
LATENCY_CRIT_MS=300
CONNECT_TIMEOUT=5
MAX_TIMEOUT=10

# Verbosity
VERBOSE=false
DRY_RUN=false
FILTER_SERVICE=""

# ─── Service Registry ────────────────────────────────────────────────────────
# Format: name|host|port|health_path|expected_status|sla_ms
declare -a SERVICES=(
    "falcon-scoring|falcon-scoring.prod.internal|8443|/actuator/health|200|200"
    "feedzai-gateway|feedzai-gw.prod.internal|9090|/api/health|200|150"
    "rule-manager|rule-mgr.prod.internal|8080|/health|200|100"
    "case-management|case-mgmt.prod.internal|8081|/api/v1/health|200|200"
    "risk-gateway|risk-gw.prod.internal|9443|/gateway/health|200|100"
    "coherence-mgmt|coherence-mgmt.prod.internal|30000|/management/coherence/cluster|200|500"
    "couchbase-admin|couchbase-01.prod.internal|8091|/pools|200|300"
)

# ─── Argument Parsing ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose|-v) VERBOSE=true; shift ;;
        --dry-run)    DRY_RUN=true; shift ;;
        --service)    FILTER_SERVICE="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $SCRIPT_NAME [--verbose] [--dry-run] [--service <name>]"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ─── Utility Functions ───────────────────────────────────────────────────────
timestamp() { date '+%Y-%m-%dT%H:%M:%S%z'; }

log() {
    local level="$1" msg="$2"
    echo "[$(timestamp)] [$level] $msg" | tee -a "$LOG_FILE"
}

log_verbose() {
    [[ "$VERBOSE" == true ]] && log "DEBUG" "$1"
}

# ─── Splunk HEC Integration ─────────────────────────────────────────────────
send_to_splunk() {
    local service="$1" status_code="$2" latency_ms="$3" check_result="$4"

    [[ -z "$SPLUNK_HEC_TOKEN" ]] && log_verbose "Splunk HEC token not set, skipping" && return 0
    [[ "$DRY_RUN" == true ]] && log "DRY-RUN" "Would send to Splunk: $service status=$check_result" && return 0

    local payload
    payload=$(jq -n \
        --arg host "$(hostname)" \
        --arg source "$SCRIPT_NAME" \
        --arg sourcetype "riskops:health_check" \
        --arg index "risk_platform" \
        --arg service "$service" \
        --argjson status_code "$status_code" \
        --argjson latency_ms "$latency_ms" \
        --arg result "$check_result" \
        --arg timestamp "$(date +%s)" \
        '{
            time: $timestamp,
            host: $host,
            source: $source,
            sourcetype: $sourcetype,
            index: $index,
            event: {
                service: $service,
                http_status: $status_code,
                latency_ms: $latency_ms,
                check_result: $result,
                hostname: $host
            }
        }')

    curl -sk -o /dev/null -w "%{http_code}" \
        -H "Authorization: Splunk ${SPLUNK_HEC_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$SPLUNK_HEC_URL" > /dev/null 2>&1 &
}

# ─── PagerDuty Escalation ───────────────────────────────────────────────────
trigger_pagerduty() {
    local service="$1" summary="$2" severity="$3"

    [[ -z "$PD_ROUTING_KEY" ]] && log_verbose "PagerDuty key not set, skipping" && return 0
    [[ "$DRY_RUN" == true ]] && log "DRY-RUN" "Would trigger PagerDuty: $summary" && return 0

    curl -s -X POST "https://events.pagerduty.com/v2/enqueue" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
            --arg key "$PD_ROUTING_KEY" \
            --arg summary "$summary" \
            --arg severity "$severity" \
            --arg source "$service" \
            --arg component "risk-platform" \
            '{
                routing_key: $key,
                event_action: "trigger",
                payload: {
                    summary: $summary,
                    severity: $severity,
                    source: $source,
                    component: $component,
                    group: "production-support",
                    class: "health_check_failure"
                }
            }')" > /dev/null 2>&1 &
}

# ─── Health Check Logic ─────────────────────────────────────────────────────
check_service() {
    local entry="$1"
    IFS='|' read -r name host port path expected_status sla_ms <<< "$entry"

    # Filter if specific service requested
    [[ -n "$FILTER_SERVICE" && "$name" != "$FILTER_SERVICE" ]] && return 0

    local url="https://${host}:${port}${path}"
    local start_ns end_ns latency_ms http_code result

    log_verbose "Checking $name at $url"

    start_ns=$(date +%s%N)

    http_code=$(curl -sk -o /dev/null -w "%{http_code}" \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$MAX_TIMEOUT" \
        "$url" 2>/dev/null) || http_code=0

    end_ns=$(date +%s%N)
    latency_ms=$(( (end_ns - start_ns) / 1000000 ))

    # Evaluate result
    if [[ "$http_code" -eq 0 ]]; then
        result="UNREACHABLE"
        log "CRITICAL" "$name — Connection failed (timeout after ${CONNECT_TIMEOUT}s)"
        trigger_pagerduty "$name" "Health check UNREACHABLE: $name at $url" "critical"
    elif [[ "$http_code" -ne "$expected_status" ]]; then
        result="UNHEALTHY"
        log "CRITICAL" "$name — HTTP $http_code (expected $expected_status), ${latency_ms}ms"
        trigger_pagerduty "$name" "Health check UNHEALTHY: $name returned HTTP $http_code" "critical"
    elif [[ "$latency_ms" -gt "$LATENCY_CRIT_MS" ]]; then
        result="DEGRADED_CRITICAL"
        log "HIGH" "$name — HTTP $http_code but latency ${latency_ms}ms > ${LATENCY_CRIT_MS}ms threshold"
        trigger_pagerduty "$name" "Latency CRITICAL: $name at ${latency_ms}ms (SLA: ${sla_ms}ms)" "high"
    elif [[ "$latency_ms" -gt "$LATENCY_WARN_MS" ]]; then
        result="DEGRADED_WARN"
        log "WARN" "$name — HTTP $http_code, latency ${latency_ms}ms > ${LATENCY_WARN_MS}ms warning"
    else
        result="HEALTHY"
        log_verbose "$name — HTTP $http_code, ${latency_ms}ms — HEALTHY"
    fi

    # Always send metrics to Splunk (healthy or not)
    send_to_splunk "$name" "$http_code" "$latency_ms" "$result"

    # Console output
    case "$result" in
        HEALTHY)            printf "  ✓ %-20s HTTP %s  %4dms  HEALTHY\n" "$name" "$http_code" "$latency_ms" ;;
        DEGRADED_WARN)      printf "  ◎ %-20s HTTP %s  %4dms  DEGRADED (warn)\n" "$name" "$http_code" "$latency_ms" ;;
        DEGRADED_CRITICAL)  printf "  ✗ %-20s HTTP %s  %4dms  DEGRADED (critical)\n" "$name" "$http_code" "$latency_ms" ;;
        UNHEALTHY)          printf "  ✗ %-20s HTTP %s  %4dms  UNHEALTHY\n" "$name" "$http_code" "$latency_ms" ;;
        UNREACHABLE)        printf "  ✗ %-20s TIMEOUT          UNREACHABLE\n" "$name" ;;
    esac
}

# ─── Main Execution ──────────────────────────────────────────────────────────
main() {
    mkdir -p "$LOG_DIR"

    echo "═══════════════════════════════════════════════════════════════"
    echo "  RiskOps Health Check — $(timestamp)"
    echo "  Host: $(hostname) | Mode: $([[ "$DRY_RUN" == true ]] && echo "DRY-RUN" || echo "LIVE")"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    local total=0 healthy=0 degraded=0 failed=0

    for entry in "${SERVICES[@]}"; do
        check_service "$entry"
        ((total++))
    done

    echo ""
    echo "───────────────────────────────────────────────────────────────"
    echo "  Summary: $total services checked | $(timestamp)"
    echo "═══════════════════════════════════════════════════════════════"

    log "INFO" "Health check complete: $total services checked"
}

main "$@"
