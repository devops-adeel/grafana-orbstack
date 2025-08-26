#!/bin/bash

# Grafana Observability Stack - Backup Verification Script
# Validates backup integrity and provides status report
# Usage: ./verify-backups.sh [--verbose] [--test-restore]

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BACKUP_BASE="${HOME}/GrafanaBackups"
EXTERNAL_DRIVE="/Volumes/${EXTERNAL_DRIVE:-SanDisk}/GrafanaBackups"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
VERBOSE=false
TEST_RESTORE=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --verbose)
            VERBOSE=true
            shift
            ;;
        --test-restore)
            TEST_RESTORE=true
            shift
            ;;
        --help)
            echo "Usage: $0 [--verbose] [--test-restore]"
            echo "  --verbose      Show detailed output"
            echo "  --test-restore Test restore procedure (dry run)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Logging function
log() {
    local level=$1
    shift
    local message="$*"
    
    case $level in
        INFO)
            echo -e "${BLUE}[INFO]${NC} $message"
            ;;
        SUCCESS)
            echo -e "${GREEN}[✓]${NC} $message"
            ;;
        WARNING)
            echo -e "${YELLOW}[⚠]${NC} $message"
            ;;
        ERROR)
            echo -e "${RED}[✗]${NC} $message"
            ;;
    esac
}

# Check if backup directories exist
check_directories() {
    log INFO "Checking backup directories..."
    
    if [ -d "$BACKUP_BASE" ]; then
        log SUCCESS "Primary backup directory exists: $BACKUP_BASE"
        
        # Check subdirectories
        for dir in critical bulk manual; do
            if [ -d "$BACKUP_BASE/$dir" ]; then
                local count=$(ls -1 "$BACKUP_BASE/$dir"/*.tar.* 2>/dev/null | wc -l)
                log SUCCESS "  $dir: $count backups found"
            else
                log WARNING "  $dir: Directory not found"
            fi
        done
    else
        log ERROR "Primary backup directory not found: $BACKUP_BASE"
        return 1
    fi
    
    # Check external drive
    if [ -d "$EXTERNAL_DRIVE" ]; then
        log SUCCESS "External drive mounted: $EXTERNAL_DRIVE"
        
        for dir in critical bulk; do
            if [ -d "$EXTERNAL_DRIVE/$dir" ]; then
                local count=$(ls -1 "$EXTERNAL_DRIVE/$dir"/*.tar.* 2>/dev/null | wc -l)
                log SUCCESS "  External $dir: $count backups"
            fi
        done
    else
        log WARNING "External drive not mounted at: $EXTERNAL_DRIVE"
    fi
}

# Verify latest backups
verify_latest_backups() {
    log INFO "Verifying latest backups..."
    
    # Check critical backup (should be daily)
    if [ -L "$BACKUP_BASE/critical/critical-latest.tar.gz" ]; then
        local latest_critical=$(readlink "$BACKUP_BASE/critical/critical-latest.tar.gz")
        local size=$(du -h "$BACKUP_BASE/critical/$latest_critical" 2>/dev/null | cut -f1)
        local age_hours=$(( ($(date +%s) - $(stat -f%m "$BACKUP_BASE/critical/$latest_critical" 2>/dev/null || stat -c%Y "$BACKUP_BASE/critical/$latest_critical" 2>/dev/null)) / 3600 ))
        
        if [ $age_hours -lt 48 ]; then
            log SUCCESS "Critical backup: $latest_critical ($size, ${age_hours}h old)"
        else
            log WARNING "Critical backup is ${age_hours}h old (expected <48h)"
        fi
        
        # Test archive integrity
        if tar -tzf "$BACKUP_BASE/critical/$latest_critical" > /dev/null 2>&1; then
            log SUCCESS "  Archive integrity: OK"
            
            # Check for expected content
            if tar -tzf "$BACKUP_BASE/critical/$latest_critical" | grep -q "backup/grafana"; then
                log SUCCESS "  Contains Grafana data: ✓"
            else
                log ERROR "  Missing Grafana data!"
            fi
            
            if tar -tzf "$BACKUP_BASE/critical/$latest_critical" | grep -q "backup/prometheus-snapshot"; then
                log SUCCESS "  Contains Prometheus snapshot: ✓"
            else
                log WARNING "  Missing Prometheus snapshot (may not have run yet)"
            fi
            
            if tar -tzf "$BACKUP_BASE/critical/$latest_critical" | grep -q "backup/metrics"; then
                log SUCCESS "  Contains failsafe metrics: ✓"
            else
                log WARNING "  Missing failsafe metrics"
            fi
        else
            log ERROR "  Archive corrupted!"
        fi
    else
        log WARNING "No critical-latest symlink found"
    fi
    
    # Check bulk backup (should be weekly)
    if [ -L "$BACKUP_BASE/bulk/bulk-latest.tar.zst" ]; then
        local latest_bulk=$(readlink "$BACKUP_BASE/bulk/bulk-latest.tar.zst")
        local size=$(du -h "$BACKUP_BASE/bulk/$latest_bulk" 2>/dev/null | cut -f1)
        local age_days=$(( ($(date +%s) - $(stat -f%m "$BACKUP_BASE/bulk/$latest_bulk" 2>/dev/null || stat -c%Y "$BACKUP_BASE/bulk/$latest_bulk" 2>/dev/null)) / 86400 ))
        
        if [ $age_days -lt 8 ]; then
            log SUCCESS "Bulk backup: $latest_bulk ($size, ${age_days}d old)"
        else
            log WARNING "Bulk backup is ${age_days}d old (expected <8d)"
        fi
        
        # Test zstd archive
        if command -v zstd > /dev/null && tar -I zstd -tf "$BACKUP_BASE/bulk/$latest_bulk" > /dev/null 2>&1; then
            log SUCCESS "  Archive integrity (zstd): OK"
        else
            log WARNING "  Cannot verify zstd archive (install zstd for verification)"
        fi
    else
        log WARNING "No bulk-latest symlink found"
    fi
}

# Check backup containers
check_containers() {
    log INFO "Checking backup containers..."
    
    for container in backup-critical backup-bulk backup-metrics; do
        if docker ps --format "{{.Names}}" | grep -q "^${container}$"; then
            local status=$(docker inspect "$container" --format='{{.State.Status}}')
            local uptime=$(docker inspect "$container" --format='{{.State.StartedAt}}')
            
            if [ "$status" = "running" ]; then
                log SUCCESS "$container: Running (since $uptime)"
            else
                log WARNING "$container: Status = $status"
            fi
            
            # Check recent logs for errors
            if [ "$VERBOSE" = true ]; then
                local errors=$(docker logs "$container" 2>&1 --since=24h | grep -i error | wc -l)
                if [ $errors -gt 0 ]; then
                    log WARNING "  Found $errors errors in last 24h"
                    docker logs "$container" 2>&1 --since=24h | grep -i error | head -3
                fi
            fi
        else
            log WARNING "$container: Not running"
        fi
    done
}

# Check Prometheus snapshot capability
check_prometheus_snapshot() {
    log INFO "Checking Prometheus snapshot API..."
    
    # Check if admin API is enabled
    if curl -s "http://localhost:9090/api/v1/admin/tsdb/snapshot" 2>/dev/null | grep -q "Admin APIs disabled"; then
        log ERROR "Prometheus admin API is disabled! Snapshots won't work."
        log INFO "  Add '--web.enable-admin-api' to Prometheus command flags"
    else
        log SUCCESS "Prometheus admin API is enabled"
        
        # Check if we can create a test snapshot
        if [ "$TEST_RESTORE" = true ]; then
            log INFO "  Creating test snapshot..."
            response=$(curl -XPOST -s "http://localhost:9090/api/v1/admin/tsdb/snapshot" 2>/dev/null)
            
            if echo "$response" | jq -r '.status' 2>/dev/null | grep -q "success"; then
                snapshot_name=$(echo "$response" | jq -r '.data.name')
                log SUCCESS "  Test snapshot created: $snapshot_name"
                
                # Clean up test snapshot
                docker exec prometheus-local rm -rf "/prometheus/snapshots/$snapshot_name" 2>/dev/null || true
                log INFO "  Test snapshot cleaned up"
            else
                log ERROR "  Failed to create test snapshot"
            fi
        fi
    fi
}

# Check storage usage
check_storage() {
    log INFO "Checking storage usage..."
    
    # Primary storage
    if [ -d "$BACKUP_BASE" ]; then
        local used=$(du -sh "$BACKUP_BASE" 2>/dev/null | cut -f1)
        local available=$(df -h "$BACKUP_BASE" | awk 'NR==2 {print $4}')
        log INFO "Primary storage: $used used, $available available"
        
        # Check each category
        for dir in critical bulk manual; do
            if [ -d "$BACKUP_BASE/$dir" ]; then
                local size=$(du -sh "$BACKUP_BASE/$dir" 2>/dev/null | cut -f1)
                log INFO "  $dir: $size"
            fi
        done
    fi
    
    # External storage
    if [ -d "$EXTERNAL_DRIVE" ]; then
        local used=$(du -sh "$EXTERNAL_DRIVE" 2>/dev/null | cut -f1)
        local available=$(df -h "$EXTERNAL_DRIVE" | awk 'NR==2 {print $4}')
        log INFO "External storage: $used used, $available available"
    fi
}

# Test restore procedure (dry run)
test_restore() {
    if [ "$TEST_RESTORE" != true ]; then
        return
    fi
    
    log INFO "Testing restore procedure (dry run)..."
    
    # Find latest critical backup
    local latest_backup="$BACKUP_BASE/critical/$(readlink $BACKUP_BASE/critical/critical-latest.tar.gz 2>/dev/null)"
    
    if [ -f "$latest_backup" ]; then
        log INFO "Would restore from: $latest_backup"
        
        # List contents
        log INFO "Archive contents:"
        tar -tzf "$latest_backup" | head -20
        
        # Test extraction to temp directory
        local temp_restore="/tmp/backup-restore-test-$$"
        mkdir -p "$temp_restore"
        
        log INFO "Extracting to temporary location: $temp_restore"
        if tar -xzf "$latest_backup" -C "$temp_restore"; then
            log SUCCESS "Test extraction successful"
            
            # Check extracted structure
            if [ -d "$temp_restore/backup/grafana" ]; then
                log SUCCESS "  Grafana data structure intact"
            fi
            if [ -d "$temp_restore/backup/prometheus-snapshot" ]; then
                log SUCCESS "  Prometheus snapshot structure intact"
            fi
            
            # Cleanup
            rm -rf "$temp_restore"
            log INFO "Test directory cleaned up"
        else
            log ERROR "Test extraction failed!"
        fi
    else
        log ERROR "No backup found for restore test"
    fi
}

# Generate summary report
generate_summary() {
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " BACKUP VERIFICATION SUMMARY"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    
    # Count total backups
    local critical_count=$(ls -1 "$BACKUP_BASE/critical"/*.tar.* 2>/dev/null | wc -l)
    local bulk_count=$(ls -1 "$BACKUP_BASE/bulk"/*.tar.* 2>/dev/null | wc -l)
    
    echo "📊 Backup Statistics:"
    echo "  Critical backups: $critical_count"
    echo "  Bulk backups: $bulk_count"
    
    # Check if backups are current
    local latest_critical_age=$(find "$BACKUP_BASE/critical" -name "*.tar.gz" -type f -exec stat -f%m {} \; 2>/dev/null | sort -n | tail -1)
    if [ -n "$latest_critical_age" ]; then
        local hours_old=$(( ($(date +%s) - $latest_critical_age) / 3600 ))
        if [ $hours_old -lt 48 ]; then
            echo -e "  Latest critical: ${GREEN}✓${NC} (${hours_old}h old)"
        else
            echo -e "  Latest critical: ${YELLOW}⚠${NC} (${hours_old}h old)"
        fi
    fi
    
    # Container status
    echo
    echo "🐳 Container Status:"
    for container in backup-critical backup-bulk backup-metrics; do
        if docker ps --format "{{.Names}}" | grep -q "^${container}$"; then
            echo -e "  $container: ${GREEN}Running${NC}"
        else
            echo -e "  $container: ${RED}Stopped${NC}"
        fi
    done
    
    # Storage status
    echo
    echo "💾 Storage Status:"
    if [ -d "$BACKUP_BASE" ]; then
        echo -e "  Primary: ${GREEN}Available${NC}"
    else
        echo -e "  Primary: ${RED}Not found${NC}"
    fi
    
    if [ -d "$EXTERNAL_DRIVE" ]; then
        echo -e "  External: ${GREEN}Mounted${NC}"
    else
        echo -e "  External: ${YELLOW}Not mounted${NC}"
    fi
    
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Main execution
main() {
    echo "🔍 Grafana Observability Stack - Backup Verification"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    
    check_directories
    echo
    
    verify_latest_backups
    echo
    
    check_containers
    echo
    
    check_prometheus_snapshot
    echo
    
    check_storage
    echo
    
    test_restore
    
    generate_summary
}

# Run main function
main "$@"