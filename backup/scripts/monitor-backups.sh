#!/bin/bash

# Grafana Backup Monitoring Script
# Checks backup health, validates integrity, and sends alerts

set -euo pipefail

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../configs/backup.conf"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Default configuration
BACKUP_BASE_DIR="${HOME}/GrafanaBackups"
LOG_DIR="${SCRIPT_DIR}/../logs"
ALERT_THRESHOLD_HOURS=26  # Alert if no backup in 26 hours
SIZE_WARNING_GB=1         # Warn if total backups exceed this size

# Source config file if exists
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# Parse command line arguments
VALIDATE_ONLY=false
JSON_OUTPUT=false
SEND_METRICS=true

while [[ $# -gt 0 ]]; do
    case $1 in
        --validate)
            VALIDATE_ONLY=true
            shift
            ;;
        --json)
            JSON_OUTPUT=true
            shift
            ;;
        --no-metrics)
            SEND_METRICS=false
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--validate] [--json] [--no-metrics]"
            exit 1
            ;;
    esac
done

# Colors for output (disabled if JSON output)
if [ "$JSON_OUTPUT" = "false" ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

# Status tracking
OVERALL_STATUS="HEALTHY"
ISSUES=()

# JSON output buffer
JSON_BUFFER='{'

# Output function
output() {
    if [ "$JSON_OUTPUT" = "false" ]; then
        echo -e "$1"
    fi
}

# Send metrics to Alloy
send_metric() {
    local metric_name="$1"
    local value="$2"
    local labels="${3:-}"
    
    if [ "$SEND_METRICS" = "true" ] && [ "${METRICS_ENABLED:-false}" = "true" ] && [ -n "${ALLOY_OTLP_HTTP:-}" ]; then
        local timestamp=$(date +%s%N)
        local labels_json=""
        
        if [ -n "$labels" ]; then
            labels_json="\"attributes\": $labels,"
        fi
        
        curl -s -X POST "${ALLOY_OTLP_HTTP}/v1/metrics" \
            -H "Content-Type: application/json" \
            -d "{
                \"resourceMetrics\": [{
                    \"scopeMetrics\": [{
                        \"metrics\": [{
                            \"name\": \"grafana_backup_${metric_name}\",
                            \"gauge\": {
                                \"dataPoints\": [{
                                    $labels_json
                                    \"timeUnixNano\": \"${timestamp}\",
                                    \"asDouble\": ${value}
                                }]
                            }
                        }]
                    }]
                }]
            }" > /dev/null 2>&1 || true
    fi
}

# Check last backup time
check_last_backup() {
    output "${BLUE}📅 Checking backup schedule...${NC}"
    
    local latest_snapshot=""
    local latest_time=0
    local status="ok"
    local message=""
    
    # Check SQLite snapshots
    if [ -L "${SCRIPT_DIR}/../snapshots/latest" ]; then
        latest_snapshot=$(readlink "${SCRIPT_DIR}/../snapshots/latest")
        if [ -e "$latest_snapshot" ]; then
            latest_time=$(stat -f %m "$latest_snapshot" 2>/dev/null || stat -c %Y "$latest_snapshot" 2>/dev/null)
        fi
    fi
    
    # If no snapshots, check main backup directory
    if [ $latest_time -eq 0 ] && [ -d "$BACKUP_BASE_DIR" ]; then
        for backup_dir in "$BACKUP_BASE_DIR"/backup-*/; do
            if [ -d "$backup_dir" ]; then
                dir_time=$(stat -f %m "$backup_dir" 2>/dev/null || stat -c %Y "$backup_dir" 2>/dev/null)
                if [ $dir_time -gt $latest_time ]; then
                    latest_time=$dir_time
                    latest_snapshot="$backup_dir"
                fi
            fi
        done
    fi
    
    if [ $latest_time -eq 0 ]; then
        output "${RED}✗ No backups found${NC}"
        OVERALL_STATUS="CRITICAL"
        ISSUES+=("No backups exist")
        status="critical"
        message="No backups found"
    else
        # Calculate age
        current_time=$(date +%s)
        age_seconds=$((current_time - latest_time))
        age_hours=$((age_seconds / 3600))
        age_days=$((age_hours / 24))
        
        # Format age for display
        local age_display=""
        if [ $age_days -gt 0 ]; then
            age_display="${age_days}d ${$((age_hours % 24))}h"
        else
            age_display="${age_hours}h"
        fi
        
        if [ $age_hours -gt $ALERT_THRESHOLD_HOURS ]; then
            output "${RED}✗ Last backup is $age_display old (threshold: ${ALERT_THRESHOLD_HOURS}h)${NC}"
            output "  Location: $latest_snapshot"
            OVERALL_STATUS="WARNING"
            ISSUES+=("Backup overdue")
            status="warning"
            message="Last backup is $age_display old"
        else
            output "${GREEN}✓ Last backup is $age_display old${NC}"
            output "  Location: $latest_snapshot"
            message="Last backup is $age_display old"
        fi
        
        # Send metric
        send_metric "age_hours" "$age_hours"
    fi
    
    if [ "$JSON_OUTPUT" = "true" ]; then
        JSON_BUFFER="${JSON_BUFFER}\"backup_schedule\":{\"status\":\"$status\",\"message\":\"$message\",\"age_hours\":$age_hours,\"location\":\"$latest_snapshot\"},"
    fi
}

# Check backup sizes
check_backup_sizes() {
    output "${BLUE}💾 Checking storage usage...${NC}"
    
    local total_size_bytes=0
    local status="ok"
    local details=[]
    
    # Calculate snapshot sizes
    if [ -d "${SCRIPT_DIR}/../snapshots" ]; then
        local snapshot_size=$(du -s "${SCRIPT_DIR}/../snapshots" 2>/dev/null | cut -f1)
        total_size_bytes=$((total_size_bytes + snapshot_size * 1024))
    fi
    
    # Calculate export sizes
    if [ -d "${SCRIPT_DIR}/../exports" ]; then
        local export_size=$(du -s "${SCRIPT_DIR}/../exports" 2>/dev/null | cut -f1)
        total_size_bytes=$((total_size_bytes + export_size * 1024))
    fi
    
    # Calculate main backup directory size
    if [ -d "$BACKUP_BASE_DIR" ]; then
        local main_size=$(du -s "$BACKUP_BASE_DIR" 2>/dev/null | cut -f1)
        total_size_bytes=$((total_size_bytes + main_size * 1024))
    fi
    
    # Convert to GB
    local total_size_gb=$((total_size_bytes / 1024 / 1024 / 1024))
    local total_size_mb=$((total_size_bytes / 1024 / 1024))
    
    # Display size
    local size_display=""
    if [ $total_size_gb -gt 0 ]; then
        size_display="${total_size_gb}GB"
    else
        size_display="${total_size_mb}MB"
    fi
    
    if [ $total_size_gb -gt ${SIZE_WARNING_GB} ]; then
        output "${YELLOW}⚠ Total backup size: ${size_display} (warning: >${SIZE_WARNING_GB}GB)${NC}"
        OVERALL_STATUS="WARNING"
        ISSUES+=("Storage usage high")
        status="warning"
        
        # Show breakdown
        output "  Breakdown:"
        [ -d "${SCRIPT_DIR}/../snapshots" ] && output "    SQLite snapshots: $(du -sh "${SCRIPT_DIR}/../snapshots" 2>/dev/null | cut -f1)"
        [ -d "${SCRIPT_DIR}/../exports" ] && output "    API exports: $(du -sh "${SCRIPT_DIR}/../exports" 2>/dev/null | cut -f1)"
        [ -d "$BACKUP_BASE_DIR" ] && output "    Full backups: $(du -sh "$BACKUP_BASE_DIR" 2>/dev/null | cut -f1)"
    else
        output "${GREEN}✓ Total backup size: ${size_display}${NC}"
    fi
    
    # Send metric
    send_metric "total_size_bytes" "$total_size_bytes"
    
    if [ "$JSON_OUTPUT" = "true" ]; then
        JSON_BUFFER="${JSON_BUFFER}\"storage\":{\"status\":\"$status\",\"total_bytes\":$total_size_bytes,\"total_display\":\"$size_display\"},"
    fi
}

# Check backup integrity
check_backup_integrity() {
    output "${BLUE}✅ Checking backup integrity...${NC}"
    
    local errors=0
    local checks_performed=0
    local status="ok"
    local details=[]
    
    # Check latest SQLite snapshot
    if [ -L "${SCRIPT_DIR}/../snapshots/latest" ]; then
        local latest_snapshot=$(readlink "${SCRIPT_DIR}/../snapshots/latest")
        if [ -d "$latest_snapshot" ]; then
            # Check for grafana.db.gz
            if [ -f "$latest_snapshot/grafana.db.gz" ]; then
                ((checks_performed++))
                if gzip -t "$latest_snapshot/grafana.db.gz" 2>/dev/null; then
                    output "${GREEN}✓ SQLite backup is valid${NC}"
                else
                    output "${RED}✗ SQLite backup is corrupted${NC}"
                    ((errors++))
                fi
            fi
        fi
    fi
    
    # Check latest exports
    local latest_export_dir="${SCRIPT_DIR}/../exports"
    if [ -d "$latest_export_dir" ]; then
        # Check JSON validity in dashboard exports
        local json_count=0
        local json_errors=0
        
        for json_file in $(find "$latest_export_dir/dashboards" -name "*.json" -type f 2>/dev/null | head -10); do
            ((json_count++))
            ((checks_performed++))
            if ! jq empty "$json_file" 2>/dev/null; then
                ((json_errors++))
                ((errors++))
            fi
        done
        
        if [ $json_count -gt 0 ]; then
            if [ $json_errors -eq 0 ]; then
                output "${GREEN}✓ All checked JSON exports are valid ($json_count files)${NC}"
            else
                output "${RED}✗ Found $json_errors invalid JSON files${NC}"
            fi
        fi
    fi
    
    # Check git repository integrity
    cd "$PROJECT_ROOT"
    if git fsck --no-full 2>/dev/null; then
        output "${GREEN}✓ Git repository integrity OK${NC}"
        ((checks_performed++))
    else
        output "${RED}✗ Git repository has integrity issues${NC}"
        ((errors++))
    fi
    
    if [ $errors -gt 0 ]; then
        OVERALL_STATUS="CRITICAL"
        ISSUES+=("Integrity check failures: $errors")
        status="critical"
    elif [ $checks_performed -eq 0 ]; then
        output "${YELLOW}⚠ No backups to validate${NC}"
        status="warning"
    else
        output "${GREEN}✓ All integrity checks passed${NC}"
    fi
    
    # Send metric
    send_metric "integrity_errors" "$errors"
    
    if [ "$JSON_OUTPUT" = "true" ]; then
        JSON_BUFFER="${JSON_BUFFER}\"integrity\":{\"status\":\"$status\",\"checks_performed\":$checks_performed,\"errors\":$errors},"
    fi
}

# Check logs for errors
check_logs() {
    output "${BLUE}📝 Checking backup logs...${NC}"
    
    local status="ok"
    local error_count=0
    local warning_count=0
    
    if [ ! -d "$LOG_DIR" ]; then
        output "${YELLOW}⚠ Log directory not found${NC}"
        status="warning"
    else
        # Find most recent log
        local latest_log=$(ls -t "$LOG_DIR"/backup-*.log 2>/dev/null | head -1)
        
        if [ -z "$latest_log" ]; then
            output "${YELLOW}⚠ No backup logs found${NC}"
            status="warning"
        else
            # Check for errors and warnings
            error_count=$(grep -c "ERROR" "$latest_log" 2>/dev/null || echo 0)
            warning_count=$(grep -c "WARNING" "$latest_log" 2>/dev/null || echo 0)
            
            if [ "$error_count" -gt 0 ]; then
                output "${RED}✗ Found $error_count errors in latest log${NC}"
                output "  Log: $latest_log"
                output "  Recent errors:"
                grep "ERROR" "$latest_log" | tail -3 | while read -r line; do
                    output "    $line"
                done
                OVERALL_STATUS="WARNING"
                ISSUES+=("Log errors: $error_count")
                status="error"
            elif [ "$warning_count" -gt 0 ]; then
                output "${YELLOW}⚠ Found $warning_count warnings in latest log${NC}"
                output "  Log: $latest_log"
                status="warning"
            else
                output "${GREEN}✓ No errors in latest backup log${NC}"
                output "  Log: $latest_log"
            fi
        fi
    fi
    
    # Send metrics
    send_metric "log_errors" "$error_count"
    send_metric "log_warnings" "$warning_count"
    
    if [ "$JSON_OUTPUT" = "true" ]; then
        JSON_BUFFER="${JSON_BUFFER}\"logs\":{\"status\":\"$status\",\"error_count\":$error_count,\"warning_count\":$warning_count},"
    fi
}

# Check Grafana accessibility
check_grafana_status() {
    output "${BLUE}🌐 Checking Grafana status...${NC}"
    
    local status="ok"
    local response_code=$(curl -s -o /dev/null -w "%{http_code}" "${GRAFANA_HOST:-http://localhost:3001}/api/health" 2>/dev/null || echo "000")
    
    if [ "$response_code" = "200" ]; then
        output "${GREEN}✓ Grafana is accessible${NC}"
        send_metric "grafana_accessible" 1
    else
        output "${YELLOW}⚠ Grafana is not accessible (HTTP $response_code)${NC}"
        status="warning"
        send_metric "grafana_accessible" 0
    fi
    
    if [ "$JSON_OUTPUT" = "true" ]; then
        JSON_BUFFER="${JSON_BUFFER}\"grafana\":{\"status\":\"$status\",\"http_code\":\"$response_code\"},"
    fi
}

# Clean old logs and temporary files
clean_old_files() {
    output "${BLUE}🧹 Cleaning old files...${NC}"
    
    local cleaned=0
    
    # Clean old logs
    if [ -d "$LOG_DIR" ]; then
        local old_logs=$(find "$LOG_DIR" -name "*.log" -mtime +${LOG_RETENTION:-30} 2>/dev/null | wc -l)
        if [ $old_logs -gt 0 ]; then
            find "$LOG_DIR" -name "*.log" -mtime +${LOG_RETENTION:-30} -delete 2>/dev/null
            output "${GREEN}✓ Cleaned $old_logs old log files${NC}"
            ((cleaned+=old_logs))
        fi
    fi
    
    # Clean old exports based on retention policy
    if [ -n "${RETENTION_EXPORTS:-}" ] && [ -d "${SCRIPT_DIR}/../exports" ]; then
        local old_exports=$(find "${SCRIPT_DIR}/../exports" -type d -name "20*" -mtime +${RETENTION_EXPORTS} 2>/dev/null | wc -l)
        if [ $old_exports -gt 0 ]; then
            find "${SCRIPT_DIR}/../exports" -type d -name "20*" -mtime +${RETENTION_EXPORTS} -exec rm -rf {} \; 2>/dev/null || true
            output "${GREEN}✓ Cleaned $old_exports old export directories${NC}"
            ((cleaned+=old_exports))
        fi
    fi
    
    if [ $cleaned -eq 0 ]; then
        output "${GREEN}✓ No old files to clean${NC}"
    fi
    
    if [ "$JSON_OUTPUT" = "true" ]; then
        JSON_BUFFER="${JSON_BUFFER}\"cleanup\":{\"files_removed\":$cleaned},"
    fi
}

# Generate summary report
generate_report() {
    if [ "$JSON_OUTPUT" = "false" ]; then
        echo ""
        echo "========================================"
        echo "Grafana Backup Monitoring Report"
        echo "$(date '+%Y-%m-%d %H:%M:%S')"
        echo "========================================"
        echo ""
    fi
    
    check_grafana_status
    [ "$JSON_OUTPUT" = "false" ] && echo ""
    
    check_last_backup
    [ "$JSON_OUTPUT" = "false" ] && echo ""
    
    check_backup_sizes
    [ "$JSON_OUTPUT" = "false" ] && echo ""
    
    check_backup_integrity
    [ "$JSON_OUTPUT" = "false" ] && echo ""
    
    check_logs
    [ "$JSON_OUTPUT" = "false" ] && echo ""
    
    if [ "$VALIDATE_ONLY" = "false" ]; then
        clean_old_files
        [ "$JSON_OUTPUT" = "false" ] && echo ""
    fi
    
    # Final status
    if [ "$JSON_OUTPUT" = "true" ]; then
        # Remove trailing comma and close JSON
        JSON_BUFFER="${JSON_BUFFER%,}"
        JSON_BUFFER="${JSON_BUFFER},\"overall_status\":\"$OVERALL_STATUS\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
        echo "$JSON_BUFFER"
    else
        echo "========================================"
        if [ "$OVERALL_STATUS" = "HEALTHY" ]; then
            echo -e "${GREEN}Overall Status: HEALTHY ✓${NC}"
        elif [ "$OVERALL_STATUS" = "WARNING" ]; then
            echo -e "${YELLOW}Overall Status: WARNING ⚠${NC}"
            [ ${#ISSUES[@]} -gt 0 ] && echo "Issues: ${ISSUES[*]}"
        else
            echo -e "${RED}Overall Status: CRITICAL ✗${NC}"
            [ ${#ISSUES[@]} -gt 0 ] && echo "Issues: ${ISSUES[*]}"
        fi
        echo "========================================"
    fi
    
    # Send overall status metric
    local status_value=0
    [ "$OVERALL_STATUS" = "HEALTHY" ] && status_value=1
    [ "$OVERALL_STATUS" = "WARNING" ] && status_value=0.5
    send_metric "health_score" "$status_value"
}

# Main execution
main() {
    if [ "$VALIDATE_ONLY" = "true" ]; then
        check_backup_integrity
        
        if [ "$JSON_OUTPUT" = "true" ]; then
            echo "{${JSON_BUFFER%,}}"
        fi
    else
        generate_report
    fi
    
    # Return appropriate exit code
    if [ "$OVERALL_STATUS" = "CRITICAL" ]; then
        exit 2
    elif [ "$OVERALL_STATUS" = "WARNING" ]; then
        exit 1
    else
        exit 0
    fi
}

# Run main function
main "$@"