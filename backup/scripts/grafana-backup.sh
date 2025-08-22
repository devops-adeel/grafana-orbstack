#!/bin/bash

# Grafana Observability Stack Backup Script
# This script backs up all Grafana configuration components:
# - SQLite database (grafana.db)
# - Dashboards (via API export)
# - Alert rules and notification policies
# - Datasource configurations

set -euo pipefail

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../configs/backup.conf"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Default configuration (will be overridden by config file if exists)
BACKUP_BASE_DIR="${HOME}/GrafanaBackups"
RETENTION_DAILY=7
RETENTION_WEEKLY=4
COMPOSE_PROJECT="grafana-orbstack"
GRAFANA_CONTAINER="grafana-main"
LOG_FILE="${SCRIPT_DIR}/../logs/backup-$(date +%Y%m%d-%H%M%S).log"

# Source config file if exists
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# Source environment variables for API keys
# Try multiple locations in order of preference
if [ -f "$HOME/.env" ]; then
    set -a
    source "$HOME/.env"
    set +a
elif [ -f "$PROJECT_ROOT/.env" ]; then
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
fi

# Create log directory if doesn't exist
mkdir -p "$(dirname "$LOG_FILE")"

# Parse command line arguments
SNAPSHOT_ONLY=false
EXPORT_ONLY=false
SKIP_VALIDATION=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --snapshot-only)
            SNAPSHOT_ONLY=true
            shift
            ;;
        --export-only)
            EXPORT_ONLY=true
            shift
            ;;
        --skip-validation)
            SKIP_VALIDATION=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--snapshot-only] [--export-only] [--skip-validation]"
            exit 1
            ;;
    esac
done

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Error handling
error_exit() {
    log "ERROR: $1"
    send_metrics "backup_failed" 1
    exit 1
}

# Send metrics to Alloy
send_metrics() {
    local metric_name="$1"
    local value="$2"
    
    if [ "${METRICS_ENABLED:-false}" = "true" ] && [ -n "${ALLOY_OTLP_HTTP:-}" ]; then
        # Send metric via OTLP HTTP
        local timestamp=$(date +%s%N)
        curl -s -X POST "${ALLOY_OTLP_HTTP}/v1/metrics" \
            -H "Content-Type: application/json" \
            -d "{
                \"resourceMetrics\": [{
                    \"scopeMetrics\": [{
                        \"metrics\": [{
                            \"name\": \"grafana_backup_${metric_name}\",
                            \"gauge\": {
                                \"dataPoints\": [{
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

# Check if Grafana container is running
check_container() {
    log "Checking Grafana container status..."
    
    if ! docker ps --format "{{.Names}}" | grep -q "${GRAFANA_CONTAINER}"; then
        error_exit "Grafana container '${GRAFANA_CONTAINER}' is not running. Please start it first."
    fi
    
    log "Container '${GRAFANA_CONTAINER}' is running."
}

# Create backup directory with timestamp
create_backup_dir() {
    local backup_type="${1:-full}"
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_path
    
    if [ "$backup_type" = "snapshot" ]; then
        # Determine if this is a daily or weekly snapshot
        local day_of_week=$(date +%u)
        if [ "$day_of_week" = "7" ]; then
            backup_path="${SCRIPT_DIR}/../snapshots/weekly/snapshot-${timestamp}"
        else
            backup_path="${SCRIPT_DIR}/../snapshots/daily/snapshot-${timestamp}"
        fi
    else
        backup_path="${BACKUP_BASE_DIR}/backup-${timestamp}"
        mkdir -p "$backup_path"/{sqlite,exports,configs}
    fi
    
    mkdir -p "$backup_path"
    log "Created backup directory: $backup_path"
    
    echo "$backup_path"
}

# Backup SQLite database
backup_sqlite() {
    local backup_dir="$1"
    
    if [ "${BACKUP_SQLITE:-true}" != "true" ]; then
        log "SQLite backup disabled in configuration."
        return
    fi
    
    log "Starting SQLite database backup..."
    
    # Use OrbStack direct volume access
    local sqlite_path="${ORBSTACK_VOLUMES}/${GRAFANA_VOLUME}/_data/grafana.db"
    
    if [ -f "$sqlite_path" ]; then
        # Copy and compress the database
        cp "$sqlite_path" "$backup_dir/grafana.db"
        
        # Validate the copy
        if sqlite3 "$backup_dir/grafana.db" "PRAGMA integrity_check" > /dev/null 2>&1; then
            # Compress the database
            gzip -${COMPRESSION_LEVEL:-6} "$backup_dir/grafana.db"
            log "SQLite backup completed successfully."
            
            # Get size for logging and metrics
            local size=$(du -h "$backup_dir/grafana.db.gz" | cut -f1)
            log "SQLite backup size: $size"
            
            # Send metrics
            local size_bytes=$(stat -f%z "$backup_dir/grafana.db.gz" 2>/dev/null || stat -c%s "$backup_dir/grafana.db.gz" 2>/dev/null)
            send_metrics "sqlite_size_bytes" "$size_bytes"
        else
            error_exit "SQLite database integrity check failed."
        fi
    else
        log "WARNING: SQLite database not found at expected location: $sqlite_path"
        log "Trying alternative method via Docker exec..."
        
        # Alternative: Copy from container
        docker cp "${GRAFANA_CONTAINER}:/var/lib/grafana/grafana.db" "$backup_dir/grafana.db" 2>/dev/null || {
            error_exit "Failed to backup SQLite database from container."
        }
        
        gzip -${COMPRESSION_LEVEL:-6} "$backup_dir/grafana.db"
        log "SQLite backup completed via container copy."
    fi
}

# Export dashboards via API
export_dashboards() {
    local backup_dir="$1"
    
    if [ "${BACKUP_DASHBOARDS:-true}" != "true" ]; then
        log "Dashboard export disabled in configuration."
        return
    fi
    
    log "Starting dashboard export via API..."
    
    # Get authentication header
    local auth_header=""
    if [ -n "${GRAFANA_API_KEY:-}" ]; then
        auth_header="Authorization: Bearer ${GRAFANA_API_KEY}"
    else
        auth_header="Authorization: Basic $(echo -n "${GRAFANA_USER}:${GRAFANA_PASSWORD}" | base64)"
    fi
    
    # Get list of all dashboards
    local dashboards_json=$(curl -s -H "$auth_header" \
        "${GRAFANA_HOST}/api/search?type=dash-db" 2>/dev/null || echo "[]")
    
    # Export each dashboard
    local count=0
    echo "$dashboards_json" | jq -c '.[]' | while read -r dashboard; do
        local uid=$(echo "$dashboard" | jq -r '.uid')
        local title=$(echo "$dashboard" | jq -r '.title' | sed 's/[^a-zA-Z0-9-]/_/g')
        
        if [ -n "$uid" ]; then
            log "Exporting dashboard: $title (UID: $uid)"
            
            curl -s -H "$auth_header" \
                "${GRAFANA_HOST}/api/dashboards/uid/${uid}" \
                | jq '.dashboard' \
                > "$backup_dir/exports/dashboards/${title}_${uid}.json" 2>/dev/null || {
                    log "WARNING: Failed to export dashboard $title"
                    continue
                }
            
            ((count++)) || true
        fi
    done
    
    log "Exported $count dashboards."
    send_metrics "dashboards_exported" "$count"
}

# Export alert rules
export_alerts() {
    local backup_dir="$1"
    
    if [ "${BACKUP_ALERTS:-true}" != "true" ]; then
        log "Alert export disabled in configuration."
        return
    fi
    
    log "Exporting alert rules..."
    
    # Export all alert rules in provisioning format
    curl -s "${GRAFANA_HOST}/api/v1/provisioning/alert-rules/export" \
        -o "$backup_dir/exports/alerts/alert-rules.yaml" 2>/dev/null || {
            log "WARNING: Failed to export alert rules"
            return
        }
    
    # Export notification policies
    if [ "${BACKUP_NOTIFICATIONS:-true}" = "true" ]; then
        curl -s "${GRAFANA_HOST}/api/v1/provisioning/policies/export" \
            -o "$backup_dir/exports/alerts/notification-policies.yaml" 2>/dev/null || {
                log "WARNING: Failed to export notification policies"
            }
        
        # Export contact points
        curl -s "${GRAFANA_HOST}/api/v1/provisioning/contact-points/export" \
            -o "$backup_dir/exports/alerts/contact-points.yaml" 2>/dev/null || {
                log "WARNING: Failed to export contact points"
            }
    fi
    
    log "Alert configuration export completed."
}

# Export datasources
export_datasources() {
    local backup_dir="$1"
    
    if [ "${BACKUP_DATASOURCES:-true}" != "true" ]; then
        log "Datasource export disabled in configuration."
        return
    fi
    
    log "Exporting datasource configurations..."
    
    # Get authentication header
    local auth_header=""
    if [ -n "${GRAFANA_API_KEY:-}" ]; then
        auth_header="Authorization: Bearer ${GRAFANA_API_KEY}"
    else
        auth_header="Authorization: Basic $(echo -n "${GRAFANA_USER}:${GRAFANA_PASSWORD}" | base64)"
    fi
    
    # Export all datasources (without secrets)
    curl -s -H "$auth_header" \
        "${GRAFANA_HOST}/api/datasources" \
        | jq 'map(del(.password, .basicAuthPassword, .secureJsonData))' \
        > "$backup_dir/exports/datasources/datasources.json" 2>/dev/null || {
            log "WARNING: Failed to export datasources"
        }
    
    log "Datasource export completed."
}

# Validate backups
validate_backup() {
    local backup_dir="$1"
    local errors=0
    
    if [ "$SKIP_VALIDATION" = "true" ]; then
        log "Skipping validation (--skip-validation flag set)"
        return 0
    fi
    
    log "Validating backup..."
    
    # Validate SQLite backup
    if [ "${VALIDATE_SQLITE:-true}" = "true" ] && [ -f "$backup_dir/grafana.db.gz" ]; then
        if gzip -t "$backup_dir/grafana.db.gz" 2>/dev/null; then
            log "✓ SQLite backup is valid"
        else
            log "✗ SQLite backup is corrupted"
            ((errors++))
        fi
    fi
    
    # Validate JSON exports
    if [ "${VALIDATE_JSON:-true}" = "true" ]; then
        local json_files=$(find "$backup_dir" -name "*.json" 2>/dev/null)
        if [ -n "$json_files" ]; then
            local invalid=0
            for file in $json_files; do
                if ! jq empty "$file" 2>/dev/null; then
                    log "✗ Invalid JSON: $file"
                    ((invalid++))
                fi
            done
            
            if [ $invalid -eq 0 ]; then
                log "✓ All JSON files are valid"
            else
                log "✗ Found $invalid invalid JSON files"
                ((errors+=$invalid))
            fi
        fi
    fi
    
    # Validate Git status
    if [ "${VALIDATE_GIT:-true}" = "true" ]; then
        cd "$PROJECT_ROOT"
        if git diff --quiet config/ dashboards/; then
            log "✓ Git repository is clean"
        else
            log "⚠ Uncommitted changes in config/ or dashboards/"
        fi
    fi
    
    if [ $errors -eq 0 ]; then
        log "✓ Backup validation completed successfully"
        send_metrics "validation_status" 1
        return 0
    else
        log "✗ Backup validation found $errors errors"
        send_metrics "validation_status" 0
        return 1
    fi
}

# Clean old backups
cleanup_old_backups() {
    log "Cleaning up old backups..."
    
    # Clean daily snapshots older than RETENTION_DAILY days
    find "${SCRIPT_DIR}/../snapshots/daily" -name "snapshot-*" -type d -mtime +$RETENTION_DAILY -exec rm -rf {} \; 2>/dev/null || true
    
    # Clean weekly snapshots older than RETENTION_WEEKLY weeks
    local weekly_days=$((RETENTION_WEEKLY * 7))
    find "${SCRIPT_DIR}/../snapshots/weekly" -name "snapshot-*" -type d -mtime +$weekly_days -exec rm -rf {} \; 2>/dev/null || true
    
    # Clean old exports
    if [ -n "${RETENTION_EXPORTS:-}" ]; then
        find "${SCRIPT_DIR}/../exports" -name "*.json" -type f -mtime +$RETENTION_EXPORTS -delete 2>/dev/null || true
        find "${SCRIPT_DIR}/../exports" -name "*.yaml" -type f -mtime +$RETENTION_EXPORTS -delete 2>/dev/null || true
    fi
    
    # Clean old logs
    find "${SCRIPT_DIR}/../logs" -name "*.log" -type f -mtime +${LOG_RETENTION:-30} -delete 2>/dev/null || true
    
    log "Cleanup completed."
}

# Create backup metadata
create_metadata() {
    local backup_dir="$1"
    
    cat > "$backup_dir/backup-metadata.json" << EOF
{
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "compose_project": "$COMPOSE_PROJECT",
    "backup_type": "$([ "$SNAPSHOT_ONLY" = "true" ] && echo "snapshot" || echo "full")",
    "components": {
        "sqlite": $([ -f "$backup_dir/grafana.db.gz" ] && echo "true" || echo "false"),
        "dashboards": $(ls -1 "$backup_dir/exports/dashboards"/*.json 2>/dev/null | wc -l),
        "alerts": $([ -f "$backup_dir/exports/alerts/alert-rules.yaml" ] && echo "true" || echo "false"),
        "datasources": $([ -f "$backup_dir/exports/datasources/datasources.json" ] && echo "true" || echo "false")
    },
    "size": "$(du -sh "$backup_dir" 2>/dev/null | cut -f1)",
    "git_commit": "$(cd "$PROJECT_ROOT" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")"
}
EOF
    
    log "Created backup metadata."
}

# Main backup process
main() {
    log "========================================="
    log "Starting Grafana backup process"
    log "========================================="
    
    # Check prerequisites
    check_container
    
    # Determine backup type and create directory
    local backup_dir
    if [ "$SNAPSHOT_ONLY" = "true" ]; then
        backup_dir=$(create_backup_dir "snapshot")
        backup_sqlite "$backup_dir"
    elif [ "$EXPORT_ONLY" = "true" ]; then
        backup_dir=$(create_backup_dir "export")
        mkdir -p "$backup_dir/exports/"{dashboards,alerts,datasources}
        export_dashboards "$backup_dir"
        export_alerts "$backup_dir"
        export_datasources "$backup_dir"
    else
        # Full backup
        backup_dir=$(create_backup_dir "full")
        backup_sqlite "$backup_dir/sqlite"
        mkdir -p "$backup_dir/exports/"{dashboards,alerts,datasources}
        export_dashboards "$backup_dir"
        export_alerts "$backup_dir"
        export_datasources "$backup_dir"
    fi
    
    # Create metadata
    create_metadata "$backup_dir"
    
    # Validate backup
    validate_backup "$backup_dir"
    
    # Clean old backups
    cleanup_old_backups
    
    # Create latest symlink for snapshots
    if [ "$SNAPSHOT_ONLY" = "true" ]; then
        ln -sfn "$backup_dir" "${SCRIPT_DIR}/../snapshots/latest"
    else
        ln -sfn "$backup_dir" "$BACKUP_BASE_DIR/latest"
    fi
    
    # Send success metrics
    send_metrics "last_success_timestamp" "$(date +%s)"
    
    log "========================================="
    log "Backup completed successfully!"
    log "Location: $backup_dir"
    log "Size: $(du -sh "$backup_dir" 2>/dev/null | cut -f1)"
    log "========================================="
}

# Run main function
main "$@"