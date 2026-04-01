#!/bin/bash
# ============================================================================
# log_rotator.sh — Automated Log Rotation & Archival
# ============================================================================
# Purpose:  Manages log rotation for risk platform services across UNIX/Linux
#           clusters. Compresses aged logs, archives to NFS, purges old files,
#           and validates disk space thresholds post-rotation.
#
# Usage:    ./log_rotator.sh [--verbose] [--dry-run]
# Schedule: Cron daily at 03:00: 0 3 * * * /opt/riskops/scripts/log_rotator.sh
# ============================================================================

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
LOG_FILE="/var/log/riskops/log_rotator.log"
ARCHIVE_DIR="/nfs/log-archive/risk-platform"
DISK_WARN_PCT=80
DISK_CRIT_PCT=90
RETENTION_DAYS=30
ARCHIVE_RETENTION_DAYS=90
VERBOSE=false
DRY_RUN=false

# Directories to manage
declare -A LOG_DIRS=(
    [falcon-scoring]="/opt/fiserv/falcon/logs"
    [feedzai-gateway]="/opt/fiserv/feedzai/logs"
    [rule-manager]="/opt/fiserv/rule-manager/logs"
    [case-management]="/opt/fiserv/case-mgmt/logs"
    [risk-gateway]="/opt/fiserv/risk-gateway/logs"
    [coherence-cache]="/opt/oracle/coherence/logs"
    [websphere]="/opt/IBM/WebSphere/AppServer/profiles/RiskProfile/logs"
    [controlm-agent]="/opt/controlm/agent/log"
)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose|-v) VERBOSE=true; shift ;;
        --dry-run)    DRY_RUN=true; shift ;;
        *) shift ;;
    esac
done

timestamp() { date '+%Y-%m-%dT%H:%M:%S%z'; }
log() { echo "[$(timestamp)] [$1] $2" | tee -a "$LOG_FILE"; }

# ─── Pre-flight: Disk Space Check ────────────────────────────────────────────
check_disk_space() {
    local path="$1" label="$2"
    local usage_pct
    usage_pct=$(df "$path" 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')

    if [[ "$usage_pct" -ge "$DISK_CRIT_PCT" ]]; then
        log "CRITICAL" "Disk usage at ${usage_pct}% for $label ($path) — CRITICAL"
        return 2
    elif [[ "$usage_pct" -ge "$DISK_WARN_PCT" ]]; then
        log "WARN" "Disk usage at ${usage_pct}% for $label ($path)"
        return 1
    fi
    [[ "$VERBOSE" == true ]] && log "DEBUG" "Disk usage at ${usage_pct}% for $label ($path) — OK"
    return 0
}

# ─── Rotate Logs ─────────────────────────────────────────────────────────────
rotate_service_logs() {
    local service="$1" log_dir="$2"
    local compressed=0 archived=0 purged=0

    [[ ! -d "$log_dir" ]] && log "WARN" "Log directory not found: $log_dir ($service)" && return

    log "INFO" "Processing $service: $log_dir"

    # Step 1: Compress logs older than 1 day that aren't already compressed
    while IFS= read -r -d '' file; do
        if [[ "$DRY_RUN" == true ]]; then
            log "DRY-RUN" "Would compress: $file"
        else
            gzip "$file" 2>/dev/null && ((compressed++))
        fi
    done < <(find "$log_dir" -name "*.log" -mtime +1 -not -name "*.gz" -print0 2>/dev/null)

    # Step 2: Archive compressed logs older than retention period to NFS
    local archive_dest="${ARCHIVE_DIR}/${service}/$(date +%Y/%m)"
    [[ "$DRY_RUN" == false ]] && mkdir -p "$archive_dest"

    while IFS= read -r -d '' file; do
        if [[ "$DRY_RUN" == true ]]; then
            log "DRY-RUN" "Would archive: $file → $archive_dest/"
        else
            cp "$file" "$archive_dest/" 2>/dev/null && ((archived++))
        fi
    done < <(find "$log_dir" -name "*.gz" -mtime +"$RETENTION_DAYS" -print0 2>/dev/null)

    # Step 3: Purge archived files from local after confirmed archive
    while IFS= read -r -d '' file; do
        local basename_file
        basename_file=$(basename "$file")
        if [[ -f "${archive_dest}/${basename_file}" || "$DRY_RUN" == true ]]; then
            if [[ "$DRY_RUN" == true ]]; then
                log "DRY-RUN" "Would purge local: $file"
            else
                rm -f "$file" && ((purged++))
            fi
        fi
    done < <(find "$log_dir" -name "*.gz" -mtime +"$RETENTION_DAYS" -print0 2>/dev/null)

    # Step 4: Purge archive files beyond archive retention
    if [[ "$DRY_RUN" == false ]]; then
        find "${ARCHIVE_DIR}/${service}" -name "*.gz" -mtime +"$ARCHIVE_RETENTION_DAYS" -delete 2>/dev/null || true
    fi

    printf "  %-22s compressed=%-3d  archived=%-3d  purged=%-3d\n" "$service" "$compressed" "$archived" "$purged"
}

# ─── Main ────────────────────────────────────────────────────────────────────
main() {
    mkdir -p "$(dirname "$LOG_FILE")"
    [[ "$DRY_RUN" == false ]] && mkdir -p "$ARCHIVE_DIR"

    echo "═══════════════════════════════════════════════════════════════"
    echo "  Log Rotation & Archival — $(timestamp)"
    echo "  Mode: $([[ "$DRY_RUN" == true ]] && echo "DRY-RUN" || echo "LIVE")"
    echo "  Retention: ${RETENTION_DAYS}d local, ${ARCHIVE_RETENTION_DAYS}d archive"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    echo "  ── Pre-flight Disk Check ────────────────────────────"
    for service in "${!LOG_DIRS[@]}"; do
        check_disk_space "${LOG_DIRS[$service]}" "$service" || true
    done

    echo ""
    echo "  ── Log Rotation ─────────────────────────────────────"
    for service in "${!LOG_DIRS[@]}"; do
        rotate_service_logs "$service" "${LOG_DIRS[$service]}"
    done

    echo ""
    echo "  ── Post-rotation Disk Check ─────────────────────────"
    for service in "${!LOG_DIRS[@]}"; do
        check_disk_space "${LOG_DIRS[$service]}" "$service" || true
    done

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Log rotation complete — $(timestamp)"
    echo "═══════════════════════════════════════════════════════════════"
}

main "$@"
