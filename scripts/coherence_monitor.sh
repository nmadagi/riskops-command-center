#!/bin/bash
# ============================================================================
# coherence_monitor.sh — Oracle Coherence Cache Cluster Monitor
# ============================================================================
# Purpose:  Monitors Coherence cache cluster health including member status,
#           partition distribution, heap utilization, cache hit ratios, and
#           detects split-brain scenarios. Sends alerts via Splunk HEC.
#
# Usage:    ./coherence_monitor.sh [--verbose] [--dry-run] [--cluster <name>]
# Schedule: Cron every 2 minutes: */2 * * * * /opt/riskops/scripts/coherence_monitor.sh
#
# Dependencies: curl, jq, bc, logger
# ============================================================================

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
SCRIPT_NAME="$(basename "$0")"
LOG_DIR="/var/log/riskops"
LOG_FILE="${LOG_DIR}/coherence_monitor.log"
SPLUNK_HEC_URL="${SPLUNK_HEC_URL:-https://splunk.prod.internal:8088/services/collector/event}"
SPLUNK_HEC_TOKEN="${SPLUNK_HEC_TOKEN:-}"

# Coherence Management REST API
COHERENCE_MGMT_HOST="${COHERENCE_MGMT_HOST:-coherence-mgmt.prod.internal}"
COHERENCE_MGMT_PORT="${COHERENCE_MGMT_PORT:-30000}"
COHERENCE_BASE_URL="http://${COHERENCE_MGMT_HOST}:${COHERENCE_MGMT_PORT}/management/coherence/cluster"

# Thresholds
HEAP_WARN_PCT=80
HEAP_CRIT_PCT=90
CACHE_HIT_WARN=0.95
CACHE_HIT_CRIT=0.90
PARTITION_ORPHAN_WARN=0
PARTITION_ENDANGERED_WARN=5
EXPECTED_MEMBER_COUNT=12
GC_PAUSE_WARN_MS=500

# Runtime
VERBOSE=false
DRY_RUN=false
EXIT_CODE=0

# ─── Argument Parsing ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose|-v) VERBOSE=true; shift ;;
        --dry-run)    DRY_RUN=true; shift ;;
        --help|-h)
            echo "Usage: $SCRIPT_NAME [--verbose] [--dry-run]"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ─── Utility Functions ───────────────────────────────────────────────────────
timestamp() { date '+%Y-%m-%dT%H:%M:%S%z'; }
log() { echo "[$(timestamp)] [$1] $2" | tee -a "$LOG_FILE"; }
log_verbose() { [[ "$VERBOSE" == true ]] && log "DEBUG" "$1"; }

alert() {
    local severity="$1" component="$2" message="$3"
    log "$severity" "[$component] $message"

    # Send to Splunk
    [[ -n "$SPLUNK_HEC_TOKEN" && "$DRY_RUN" == false ]] && \
    curl -sk -o /dev/null \
        -H "Authorization: Splunk ${SPLUNK_HEC_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
            --arg severity "$severity" \
            --arg component "$component" \
            --arg message "$message" \
            --arg host "$(hostname)" \
            --arg source "$SCRIPT_NAME" \
            '{
                host: $host,
                source: $source,
                sourcetype: "riskops:coherence_monitor",
                index: "risk_platform",
                event: {
                    severity: $severity,
                    component: $component,
                    message: $message
                }
            }')" \
        "$SPLUNK_HEC_URL" 2>/dev/null &
}

coherence_api() {
    local endpoint="$1"
    curl -sf --connect-timeout 5 --max-time 10 \
        "${COHERENCE_BASE_URL}${endpoint}" 2>/dev/null
}

# ─── Check: Cluster Membership ──────────────────────────────────────────────
check_cluster_members() {
    echo "  ── Cluster Membership ──────────────────────────────"

    local members_json
    members_json=$(coherence_api "/members") || {
        alert "CRITICAL" "cluster" "Cannot reach Coherence Management API at ${COHERENCE_BASE_URL}"
        printf "  ✗ Coherence Management API unreachable\n"
        EXIT_CODE=2
        return 1
    }

    local member_count departed_count
    member_count=$(echo "$members_json" | jq '.items | length')
    departed_count=$(echo "$members_json" | jq '[.items[] | select(.status != "running" and .status != "JOINED")] | length')

    printf "  %-30s %s\n" "Active members:" "$member_count / $EXPECTED_MEMBER_COUNT"

    if [[ "$member_count" -lt "$EXPECTED_MEMBER_COUNT" ]]; then
        local missing=$((EXPECTED_MEMBER_COUNT - member_count))
        alert "HIGH" "membership" "Cluster has $member_count members, expected $EXPECTED_MEMBER_COUNT ($missing missing)"
        printf "  ✗ %-30s %s members missing\n" "Member deficit:" "$missing"
        EXIT_CODE=1
    else
        printf "  ✓ %-30s All members present\n" "Cluster health:"
    fi

    if [[ "$departed_count" -gt 0 ]]; then
        alert "HIGH" "membership" "$departed_count departed/non-running members detected"
        printf "  ✗ %-30s %s nodes\n" "Departed members:" "$departed_count"
        EXIT_CODE=1
    fi

    # Check for split-brain (multiple clusters with same name)
    local cluster_size
    cluster_size=$(echo "$members_json" | jq '[.items[].clusterSize] | unique | length')
    if [[ "$cluster_size" -gt 1 ]]; then
        alert "CRITICAL" "split-brain" "SPLIT-BRAIN DETECTED: Members report different cluster sizes"
        printf "  ✗ %-30s POTENTIAL SPLIT-BRAIN\n" "Cluster integrity:"
        EXIT_CODE=2
    fi
}

# ─── Check: Partition Distribution ───────────────────────────────────────────
check_partitions() {
    echo ""
    echo "  ── Partition Distribution ───────────────────────────"

    local services_json
    services_json=$(coherence_api "/services") || {
        printf "  ✗ Cannot retrieve service partition info\n"
        return 1
    }

    echo "$services_json" | jq -r '.items[] | select(.type == "DistributedCache") | .name' | while read -r svc_name; do
        local partition_json
        partition_json=$(coherence_api "/services/${svc_name}/partition") || continue

        local orphaned endangered vulnerable
        orphaned=$(echo "$partition_json" | jq '.orphanedPartitions // 0')
        endangered=$(echo "$partition_json" | jq '.endangeredPartitions // 0')
        vulnerable=$(echo "$partition_json" | jq '.vulnerablePartitions // 0')

        printf "  %-30s orphaned=%s  endangered=%s  vulnerable=%s\n" "$svc_name:" "$orphaned" "$endangered" "$vulnerable"

        if [[ "$orphaned" -gt "$PARTITION_ORPHAN_WARN" ]]; then
            alert "CRITICAL" "partitions" "Service $svc_name has $orphaned ORPHANED partitions — data loss risk"
            EXIT_CODE=2
        fi

        if [[ "$endangered" -gt "$PARTITION_ENDANGERED_WARN" ]]; then
            alert "HIGH" "partitions" "Service $svc_name has $endangered endangered partitions"
            EXIT_CODE=1
        fi
    done
}

# ─── Check: JVM Heap Utilization ─────────────────────────────────────────────
check_heap_utilization() {
    echo ""
    echo "  ── JVM Heap Utilization ─────────────────────────────"

    local members_json
    members_json=$(coherence_api "/members") || return 1

    echo "$members_json" | jq -r '.items[] | "\(.memberName)|\(.memoryAvailableMB // 0)|\(.memoryMaxMB // 1)"' | while IFS='|' read -r name avail max; do
        [[ "$max" -eq 0 ]] && continue
        local used=$((max - avail))
        local pct=$((used * 100 / max))

        local status="✓"
        if [[ "$pct" -ge "$HEAP_CRIT_PCT" ]]; then
            status="✗"
            alert "CRITICAL" "heap" "Member $name heap at ${pct}% (${used}/${max}MB) — GC pressure imminent"
            EXIT_CODE=2
        elif [[ "$pct" -ge "$HEAP_WARN_PCT" ]]; then
            status="◎"
            alert "WARN" "heap" "Member $name heap at ${pct}% (${used}/${max}MB)"
        fi

        printf "  %s %-25s %3d%% (%dMB / %dMB)\n" "$status" "$name" "$pct" "$used" "$max"
    done
}

# ─── Check: Cache Hit Ratios ────────────────────────────────────────────────
check_cache_hit_ratios() {
    echo ""
    echo "  ── Cache Hit Ratios ─────────────────────────────────"

    local caches_json
    caches_json=$(coherence_api "/services/RiskScoringCache/caches") || {
        # Try alternate service name
        caches_json=$(coherence_api "/services/DistributedCache/caches") || {
            printf "  ◌ Cache stats endpoint not available\n"
            return 0
        }
    }

    echo "$caches_json" | jq -r '.items[] | "\(.name)|\(.totalGets // 0)|\(.totalHits // 0)|\(.size // 0)"' | while IFS='|' read -r name gets hits size; do
        local hit_ratio="N/A"
        local status="✓"

        if [[ "$gets" -gt 0 ]]; then
            hit_ratio=$(echo "scale=4; $hits / $gets" | bc)
            local hit_pct=$(echo "scale=1; $hit_ratio * 100" | bc)

            if (( $(echo "$hit_ratio < $CACHE_HIT_CRIT" | bc -l) )); then
                status="✗"
                alert "HIGH" "cache" "Cache $name hit ratio ${hit_pct}% below critical threshold"
                EXIT_CODE=1
            elif (( $(echo "$hit_ratio < $CACHE_HIT_WARN" | bc -l) )); then
                status="◎"
                alert "WARN" "cache" "Cache $name hit ratio ${hit_pct}% below warning threshold"
            fi

            printf "  %s %-25s hit_ratio=%s%%  size=%s entries\n" "$status" "$name" "$hit_pct" "$size"
        else
            printf "  ◌ %-25s no gets recorded yet\n" "$name"
        fi
    done
}

# ─── Check: GC Pause Times ──────────────────────────────────────────────────
check_gc_stats() {
    echo ""
    echo "  ── GC Pause Analysis ────────────────────────────────"

    local members_json
    members_json=$(coherence_api "/members") || return 1

    echo "$members_json" | jq -r '.items[] | "\(.memberName)|\(.lastGCPauseMillis // 0)|\(.totalGCCollections // 0)"' | while IFS='|' read -r name last_gc_ms total_gc; do
        local status="✓"
        if [[ "$last_gc_ms" -gt "$GC_PAUSE_WARN_MS" ]]; then
            status="◎"
            alert "WARN" "gc" "Member $name last GC pause ${last_gc_ms}ms (threshold: ${GC_PAUSE_WARN_MS}ms)"
        fi
        printf "  %s %-25s last_gc=%dms  total_collections=%d\n" "$status" "$name" "$last_gc_ms" "$total_gc"
    done
}

# ─── Main Execution ──────────────────────────────────────────────────────────
main() {
    mkdir -p "$LOG_DIR"

    echo "═══════════════════════════════════════════════════════════════"
    echo "  Coherence Cache Cluster Monitor — $(timestamp)"
    echo "  Target: ${COHERENCE_MGMT_HOST}:${COHERENCE_MGMT_PORT}"
    echo "  Mode: $([[ "$DRY_RUN" == true ]] && echo "DRY-RUN" || echo "LIVE")"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    check_cluster_members
    check_partitions
    check_heap_utilization
    check_cache_hit_ratios
    check_gc_stats

    echo ""
    echo "───────────────────────────────────────────────────────────────"
    echo "  Monitor complete — exit code: $EXIT_CODE"
    echo "═══════════════════════════════════════════════════════════════"

    exit "$EXIT_CODE"
}

main "$@"
