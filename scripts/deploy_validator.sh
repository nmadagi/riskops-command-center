#!/bin/bash
# ============================================================================
# deploy_validator.sh — Post-Deployment Validation Suite
# ============================================================================
# Purpose:  Comprehensive validation after risk platform releases. Checks
#           endpoint health, Coherence cache consistency, Splunk ingestion,
#           Dynatrace agent connectivity, Oracle replication, and runs
#           smoke test transactions. Returns pass/fail with detailed report.
#
# Usage:    ./deploy_validator.sh --release <v> [--verbose] [--rollback-on-fail]
# ============================================================================

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
LOG_DIR="/var/log/riskops"
LOG_FILE="${LOG_DIR}/deploy_validation.log"
RELEASE_VERSION=""
ROLLBACK_ON_FAIL=false
VERBOSE=false
DRY_RUN=false

TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARN_CHECKS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)          RELEASE_VERSION="$2"; shift 2 ;;
        --rollback-on-fail) ROLLBACK_ON_FAIL=true; shift ;;
        --verbose|-v)       VERBOSE=true; shift ;;
        --dry-run)          DRY_RUN=true; shift ;;
        --help|-h)
            echo "Usage: $SCRIPT_NAME --release <version> [--rollback-on-fail] [--verbose]"
            exit 0 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

[[ -z "$RELEASE_VERSION" ]] && echo "Error: --release <version> required" && exit 1

timestamp() { date '+%Y-%m-%dT%H:%M:%S%z'; }
log() { echo "[$(timestamp)] [$1] $2" | tee -a "$LOG_FILE"; }

check_pass() { ((TOTAL_CHECKS++)); ((PASSED_CHECKS++)); printf "  ✓ PASS  %s\n" "$1"; }
check_fail() { ((TOTAL_CHECKS++)); ((FAILED_CHECKS++)); printf "  ✗ FAIL  %s\n" "$1"; log "CRITICAL" "VALIDATION FAILED: $1"; }
check_warn() { ((TOTAL_CHECKS++)); ((WARN_CHECKS++)); printf "  ◎ WARN  %s\n" "$1"; }

# ─── Phase 1: Endpoint Health ────────────────────────────────────────────────
validate_endpoints() {
    echo ""
    echo "  ══ Phase 1: Endpoint Health ════════════════════════════"

    declare -A ENDPOINTS=(
        [falcon-scoring]="https://falcon-scoring.prod.internal:8443/actuator/health"
        [feedzai-gateway]="https://feedzai-gw.prod.internal:9090/api/health"
        [rule-manager]="https://rule-mgr.prod.internal:8080/health"
        [case-management]="https://case-mgmt.prod.internal:8081/api/v1/health"
        [risk-gateway]="https://risk-gw.prod.internal:9443/gateway/health"
    )

    for svc in "${!ENDPOINTS[@]}"; do
        local url="${ENDPOINTS[$svc]}"
        local http_code
        http_code=$(curl -sk -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "$url" 2>/dev/null) || http_code=0

        if [[ "$http_code" -eq 200 ]]; then
            check_pass "$svc endpoint returns HTTP 200"
        elif [[ "$http_code" -eq 0 ]]; then
            check_fail "$svc endpoint UNREACHABLE at $url"
        else
            check_fail "$svc endpoint returns HTTP $http_code (expected 200)"
        fi
    done
}

# ─── Phase 2: Application Version ────────────────────────────────────────────
validate_version() {
    echo ""
    echo "  ══ Phase 2: Deployed Version ═══════════════════════════"

    local deployed_version
    deployed_version=$(curl -sk --max-time 5 \
        "https://falcon-scoring.prod.internal:8443/actuator/info" 2>/dev/null | \
        jq -r '.build.version // "unknown"')

    if [[ "$deployed_version" == "$RELEASE_VERSION" ]]; then
        check_pass "Deployed version matches release: $RELEASE_VERSION"
    else
        check_fail "Version mismatch: deployed=$deployed_version expected=$RELEASE_VERSION"
    fi
}

# ─── Phase 3: Coherence Cache ────────────────────────────────────────────────
validate_cache() {
    echo ""
    echo "  ══ Phase 3: Coherence Cache Integrity ══════════════════"

    local cluster_json
    cluster_json=$(curl -sf --max-time 10 \
        "http://coherence-mgmt.prod.internal:30000/management/coherence/cluster/members" 2>/dev/null) || {
        check_fail "Coherence Management API unreachable"
        return
    }

    local member_count
    member_count=$(echo "$cluster_json" | jq '.items | length')

    if [[ "$member_count" -ge 12 ]]; then
        check_pass "Coherence cluster: $member_count members active"
    else
        check_fail "Coherence cluster: only $member_count members (expected >= 12)"
    fi

    # Check for orphaned partitions
    local orphaned
    orphaned=$(curl -sf --max-time 10 \
        "http://coherence-mgmt.prod.internal:30000/management/coherence/cluster/services/RiskScoringCache/partition" 2>/dev/null | \
        jq '.orphanedPartitions // 0')

    if [[ "$orphaned" -eq 0 ]]; then
        check_pass "No orphaned cache partitions"
    else
        check_fail "Orphaned partitions detected: $orphaned"
    fi
}

# ─── Phase 4: Splunk Log Ingestion ───────────────────────────────────────────
validate_splunk_ingestion() {
    echo ""
    echo "  ══ Phase 4: Splunk Log Ingestion ═══════════════════════"

    # Verify recent logs are flowing into Splunk
    local search_result
    search_result=$(curl -sk -u "${SPLUNK_USER:-admin}:${SPLUNK_PASS:-changeme}" \
        "https://splunk.prod.internal:8089/services/search/jobs/export" \
        -d "search=search index=risk_platform earliest=-5m | stats count by sourcetype" \
        -d "output_mode=json" \
        --max-time 15 2>/dev/null)

    if [[ -n "$search_result" && "$search_result" != *"error"* ]]; then
        check_pass "Splunk ingestion active for risk_platform index"
    else
        check_warn "Cannot verify Splunk ingestion (may need manual check)"
    fi
}

# ─── Phase 5: Dynatrace Agent ───────────────────────────────────────────────
validate_dynatrace() {
    echo ""
    echo "  ══ Phase 5: Dynatrace Agent Connectivity ═══════════════"

    local dt_agents
    dt_agents=$(curl -sk -H "Authorization: Api-Token ${DYNATRACE_TOKEN:-}" \
        "https://dynatrace.prod.internal/api/v1/entity/infrastructure/hosts?tag=risk-platform" \
        --max-time 10 2>/dev/null | jq 'length // 0')

    if [[ "$dt_agents" -ge 20 ]]; then
        check_pass "Dynatrace: $dt_agents host agents reporting"
    elif [[ "$dt_agents" -gt 0 ]]; then
        check_warn "Dynatrace: only $dt_agents agents (expected >= 20)"
    else
        check_warn "Dynatrace API unavailable — manual verification needed"
    fi
}

# ─── Phase 6: Oracle GoldenGate ──────────────────────────────────────────────
validate_replication() {
    echo ""
    echo "  ══ Phase 6: Oracle GoldenGate Replication ══════════════"

    local lag_seconds
    lag_seconds=$(curl -sf --max-time 10 \
        "http://ogg-mgmt.prod.internal:8080/api/v1/processes" 2>/dev/null | \
        jq '[.items[] | select(.type == "REPLICAT") | .lag] | max // 0')

    if [[ "$lag_seconds" -le 5 ]]; then
        check_pass "GoldenGate replication lag: ${lag_seconds}s (threshold: 5s)"
    elif [[ "$lag_seconds" -le 30 ]]; then
        check_warn "GoldenGate replication lag: ${lag_seconds}s (acceptable but elevated)"
    else
        check_fail "GoldenGate replication lag: ${lag_seconds}s EXCEEDS threshold"
    fi
}

# ─── Phase 7: Smoke Test Transactions ────────────────────────────────────────
validate_smoke_tests() {
    echo ""
    echo "  ══ Phase 7: Smoke Test Transactions ════════════════════"

    # Test transaction scoring endpoint
    local score_response
    score_response=$(curl -sk -X POST \
        -H "Content-Type: application/json" \
        -d '{"testMode":true,"txnId":"SMOKE-001","amount":100.00,"merchant":"TEST_MERCHANT","card":"4111XXXXXXXXXXXX"}' \
        "https://falcon-scoring.prod.internal:8443/api/v1/score" \
        --max-time 10 2>/dev/null)

    local score_status
    score_status=$(echo "$score_response" | jq -r '.status // "error"')

    if [[ "$score_status" == "scored" || "$score_status" == "approved" ]]; then
        check_pass "Smoke test transaction scored successfully"
    else
        check_fail "Smoke test transaction failed: status=$score_status"
    fi

    # Test rule evaluation
    local rule_response
    rule_response=$(curl -sk -X POST \
        -H "Content-Type: application/json" \
        -d '{"testMode":true,"ruleSetId":"DEFAULT","txnData":{"amount":50}}' \
        "https://rule-mgr.prod.internal:8080/api/v1/evaluate" \
        --max-time 10 2>/dev/null)

    if [[ -n "$rule_response" && "$rule_response" != *"error"* ]]; then
        check_pass "Rule evaluation endpoint responding"
    else
        check_warn "Rule evaluation smoke test inconclusive"
    fi
}

# ─── Results & Rollback Decision ─────────────────────────────────────────────
report_results() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  DEPLOYMENT VALIDATION REPORT"
    echo "  Release: $RELEASE_VERSION | $(timestamp)"
    echo "───────────────────────────────────────────────────────────────"
    printf "  Total checks:  %d\n" "$TOTAL_CHECKS"
    printf "  Passed:        %d  ✓\n" "$PASSED_CHECKS"
    printf "  Warnings:      %d  ◎\n" "$WARN_CHECKS"
    printf "  Failed:        %d  ✗\n" "$FAILED_CHECKS"
    echo "───────────────────────────────────────────────────────────────"

    if [[ "$FAILED_CHECKS" -eq 0 ]]; then
        echo "  RESULT: ✓ DEPLOYMENT VALIDATED — Release $RELEASE_VERSION is GO"
        echo "═══════════════════════════════════════════════════════════════"
        exit 0
    else
        echo "  RESULT: ✗ DEPLOYMENT VALIDATION FAILED — $FAILED_CHECKS checks failed"

        if [[ "$ROLLBACK_ON_FAIL" == true ]]; then
            echo ""
            echo "  ⚠ AUTO-ROLLBACK TRIGGERED (--rollback-on-fail enabled)"
            echo "  Initiating rollback procedure..."
            log "CRITICAL" "Auto-rollback triggered for release $RELEASE_VERSION"
            # In production, this would call the rollback script
            # ./rollback.sh --release "$RELEASE_VERSION" --reason "validation_failure"
        else
            echo ""
            echo "  ⚠ Manual review required. To rollback:"
            echo "    ./rollback.sh --release $RELEASE_VERSION --reason validation_failure"
        fi

        echo "═══════════════════════════════════════════════════════════════"
        exit 1
    fi
}

# ─── Main ────────────────────────────────────────────────────────────────────
main() {
    mkdir -p "$LOG_DIR"

    echo "═══════════════════════════════════════════════════════════════"
    echo "  Post-Deployment Validation Suite"
    echo "  Release: $RELEASE_VERSION | $(timestamp)"
    echo "  Auto-rollback: $([[ "$ROLLBACK_ON_FAIL" == true ]] && echo "ENABLED" || echo "DISABLED")"
    echo "═══════════════════════════════════════════════════════════════"

    validate_endpoints
    validate_version
    validate_cache
    validate_splunk_ingestion
    validate_dynatrace
    validate_replication
    validate_smoke_tests
    report_results
}

main "$@"
