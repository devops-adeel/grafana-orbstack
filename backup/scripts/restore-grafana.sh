#!/bin/bash

# Grafana Restoration Script
# Restores Grafana configuration from backups

set -euo pipefail

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../configs/backup.conf"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Default configuration
BACKUP_BASE_DIR="${HOME}/GrafanaBackups"
COMPOSE_PROJECT="grafana-orbstack"
GRAFANA_CONTAINER="grafana-main"
COMPOSE_FILE="docker-compose.grafana.yml"
GRAFANA_HOST="${GRAFANA_HOST:-http://localhost:3001}"
GRAFANA_USER="${GRAFANA_USER:-admin}"
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-admin}"

# Source config file if exists
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# Source environment variables
if [ -f "$HOME/.env" ]; then
    set -a
    source "$HOME/.env"
    set +a
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse command line arguments
RESTORE_SQLITE=false
RESTORE_DASHBOARDS=false
RESTORE_ALERTS=false
RESTORE_DATASOURCES=false
RESTORE_ALL=false
BACKUP_PATH=""
FORCE=false
DRY_RUN=false

print_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --all                 Restore everything (SQLite + exports)"
    echo "  --sqlite              Restore SQLite database only"
    echo "  --dashboards          Restore dashboards only"
    echo "  --alerts              Restore alert configurations only"
    echo "  --datasources         Restore datasource configurations only"
    echo "  --from PATH           Specify backup path to restore from"
    echo "  --force               Skip confirmation prompts"
    echo "  --dry-run             Show what would be restored without doing it"
    echo ""
    echo "Examples:"
    echo "  $0 --all                    # Restore latest backup completely"
    echo "  $0 --sqlite --from /path    # Restore SQLite from specific backup"
    echo "  $0 --dashboards --dry-run   # Preview dashboard restoration"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --all)
            RESTORE_ALL=true
            shift
            ;;
        --sqlite)
            RESTORE_SQLITE=true
            shift
            ;;
        --dashboards)
            RESTORE_DASHBOARDS=true
            shift
            ;;
        --alerts)
            RESTORE_ALERTS=true
            shift
            ;;
        --datasources)
            RESTORE_DATASOURCES=true
            shift
            ;;
        --from)
            BACKUP_PATH="$2"
            shift 2
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            print_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            print_usage
            exit 1
            ;;
    esac
done

# If --all is specified, enable all components
if [ "$RESTORE_ALL" = "true" ]; then
    RESTORE_SQLITE=true
    RESTORE_DASHBOARDS=true
    RESTORE_ALERTS=true
    RESTORE_DATASOURCES=true
fi

# If no components specified, show usage
if [ "$RESTORE_SQLITE" = "false" ] && [ "$RESTORE_DASHBOARDS" = "false" ] && \
   [ "$RESTORE_ALERTS" = "false" ] && [ "$RESTORE_DATASOURCES" = "false" ]; then
    echo -e "${RED}Error: No restore components specified${NC}"
    print_usage
    exit 1
fi

# Logging function
log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Find backup to restore from
find_backup() {
    if [ -n "$BACKUP_PATH" ]; then
        if [ ! -d "$BACKUP_PATH" ] && [ ! -f "$BACKUP_PATH" ]; then
            log "${RED}Error: Specified backup path does not exist: $BACKUP_PATH${NC}"
            exit 1
        fi
        echo "$BACKUP_PATH"
    else
        # Find latest backup
        local latest_backup=""
        
        # Check for latest SQLite snapshot
        if [ "$RESTORE_SQLITE" = "true" ] && [ -L "${SCRIPT_DIR}/../snapshots/latest" ]; then
            latest_backup=$(readlink "${SCRIPT_DIR}/../snapshots/latest")
            if [ -d "$latest_backup" ]; then
                echo "$latest_backup"
                return
            fi
        fi
        
        # Check main backup directory
        if [ -d "$BACKUP_BASE_DIR" ]; then
            latest_backup=$(ls -dt "$BACKUP_BASE_DIR"/backup-* 2>/dev/null | head -1)
            if [ -n "$latest_backup" ]; then
                echo "$latest_backup"
                return
            fi
        fi
        
        log "${RED}Error: No backups found to restore from${NC}"
        log "Use --from to specify a backup path"
        exit 1
    fi
}

# Confirm restoration
confirm_restore() {
    if [ "$FORCE" = "true" ] || [ "$DRY_RUN" = "true" ]; then
        return 0
    fi
    
    echo -e "${YELLOW}⚠️  WARNING: This will restore Grafana configuration${NC}"
    echo "Components to restore:"
    [ "$RESTORE_SQLITE" = "true" ] && echo "  - SQLite database (will overwrite current)"
    [ "$RESTORE_DASHBOARDS" = "true" ] && echo "  - Dashboards"
    [ "$RESTORE_ALERTS" = "true" ] && echo "  - Alert configurations"
    [ "$RESTORE_DATASOURCES" = "true" ] && echo "  - Datasource configurations"
    echo ""
    echo "Backup source: $1"
    echo ""
    read -p "Are you sure you want to continue? (yes/no): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Restoration cancelled by user"
        exit 0
    fi
}

# Stop Grafana container
stop_grafana() {
    if [ "$DRY_RUN" = "true" ]; then
        log "${BLUE}[DRY RUN] Would stop Grafana container${NC}"
        return
    fi
    
    log "${BLUE}Stopping Grafana container...${NC}"
    cd "$PROJECT_ROOT"
    docker compose -f "$COMPOSE_FILE" stop grafana || true
    sleep 2
}

# Start Grafana container
start_grafana() {
    if [ "$DRY_RUN" = "true" ]; then
        log "${BLUE}[DRY RUN] Would start Grafana container${NC}"
        return
    fi
    
    log "${BLUE}Starting Grafana container...${NC}"
    cd "$PROJECT_ROOT"
    docker compose -f "$COMPOSE_FILE" up -d grafana
    
    # Wait for Grafana to be ready
    log "Waiting for Grafana to be ready..."
    local max_attempts=60
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if curl -s -o /dev/null -w "%{http_code}" "${GRAFANA_HOST}/api/health" 2>/dev/null | grep -q "200"; then
            log "${GREEN}✓ Grafana is ready${NC}"
            return
        fi
        ((attempt++))
        sleep 1
    done
    
    log "${YELLOW}⚠ Grafana may not be fully ready${NC}"
}

# Restore SQLite database
restore_sqlite() {
    local backup_path="$1"
    
    log "${BLUE}Restoring SQLite database...${NC}"
    
    # Find the SQLite backup file
    local sqlite_backup=""
    if [ -f "$backup_path/grafana.db.gz" ]; then
        sqlite_backup="$backup_path/grafana.db.gz"
    elif [ -f "$backup_path/sqlite/grafana.db.gz" ]; then
        sqlite_backup="$backup_path/sqlite/grafana.db.gz"
    else
        log "${RED}Error: SQLite backup not found in $backup_path${NC}"
        return 1
    fi
    
    if [ "$DRY_RUN" = "true" ]; then
        log "${BLUE}[DRY RUN] Would restore SQLite from: $sqlite_backup${NC}"
        return
    fi
    
    # Create temp directory for extraction
    local temp_dir=$(mktemp -d)
    trap "rm -rf $temp_dir" EXIT
    
    # Extract SQLite database
    log "Extracting SQLite backup..."
    gunzip -c "$sqlite_backup" > "$temp_dir/grafana.db"
    
    # Validate the database
    if ! sqlite3 "$temp_dir/grafana.db" "PRAGMA integrity_check" > /dev/null 2>&1; then
        log "${RED}Error: SQLite backup integrity check failed${NC}"
        return 1
    fi
    
    # Stop Grafana before replacing database
    stop_grafana
    
    # Backup current database
    local current_db="${ORBSTACK_VOLUMES}/${GRAFANA_VOLUME}/_data/grafana.db"
    if [ -f "$current_db" ]; then
        log "Backing up current database..."
        cp "$current_db" "$current_db.backup-$(date +%Y%m%d-%H%M%S)"
    fi
    
    # Copy new database
    log "Copying restored database..."
    cp "$temp_dir/grafana.db" "$current_db"
    
    # Set proper permissions (Grafana runs as UID 472)
    chown 472:472 "$current_db" 2>/dev/null || true
    
    # Start Grafana
    start_grafana
    
    log "${GREEN}✓ SQLite database restored successfully${NC}"
}

# Get authentication header
get_auth_header() {
    if [ -n "${GRAFANA_API_KEY:-}" ]; then
        echo "Authorization: Bearer ${GRAFANA_API_KEY}"
    else
        echo "Authorization: Basic $(echo -n "${GRAFANA_USER}:${GRAFANA_PASSWORD}" | base64)"
    fi
}

# Restore dashboards
restore_dashboards() {
    local backup_path="$1"
    
    log "${BLUE}Restoring dashboards...${NC}"
    
    # Find dashboard exports
    local dashboard_dir=""
    if [ -d "$backup_path/exports/dashboards" ]; then
        # Find most recent timestamp directory
        dashboard_dir=$(ls -dt "$backup_path/exports/dashboards"/20* 2>/dev/null | head -1)
    elif [ -d "${SCRIPT_DIR}/../exports/dashboards" ]; then
        dashboard_dir=$(ls -dt "${SCRIPT_DIR}/../exports/dashboards"/20* 2>/dev/null | head -1)
    fi
    
    if [ -z "$dashboard_dir" ] || [ ! -d "$dashboard_dir" ]; then
        log "${YELLOW}⚠ No dashboard exports found${NC}"
        return
    fi
    
    if [ "$DRY_RUN" = "true" ]; then
        log "${BLUE}[DRY RUN] Would restore dashboards from: $dashboard_dir${NC}"
        local count=$(find "$dashboard_dir" -name "*.json" -not -name "*.meta.json" -not -name "manifest.json" | wc -l)
        log "${BLUE}[DRY RUN] Would restore $count dashboards${NC}"
        return
    fi
    
    local auth_header=$(get_auth_header)
    local restored=0
    local failed=0
    
    # Restore each dashboard
    find "$dashboard_dir" -name "*.json" -not -name "*.meta.json" -not -name "manifest.json" | while read -r dashboard_file; do
        local dashboard_name=$(basename "$dashboard_file" .json)
        log "  Restoring dashboard: $dashboard_name"
        
        # Prepare the import payload
        local import_payload=$(jq '{
            dashboard: .,
            overwrite: true,
            inputs: [],
            folderId: 0
        }' "$dashboard_file")
        
        # Import dashboard
        local response=$(curl -s -X POST \
            -H "$auth_header" \
            -H "Content-Type: application/json" \
            -d "$import_payload" \
            "${GRAFANA_HOST}/api/dashboards/db" 2>/dev/null)
        
        if echo "$response" | jq -e '.status == "success"' > /dev/null 2>&1; then
            ((restored++))
        else
            log "${YELLOW}    ⚠ Failed to restore: $dashboard_name${NC}"
            ((failed++))
        fi
    done
    
    log "${GREEN}✓ Restored $restored dashboards${NC}"
    [ $failed -gt 0 ] && log "${YELLOW}⚠ Failed to restore $failed dashboards${NC}"
}

# Restore alert configurations
restore_alerts() {
    local backup_path="$1"
    
    log "${BLUE}Restoring alert configurations...${NC}"
    
    # Find alert exports
    local alert_dir=""
    if [ -d "$backup_path/exports/alerts" ]; then
        alert_dir=$(ls -dt "$backup_path/exports/alerts"/20* 2>/dev/null | head -1)
    elif [ -d "${SCRIPT_DIR}/../exports/alerts" ]; then
        alert_dir=$(ls -dt "${SCRIPT_DIR}/../exports/alerts"/20* 2>/dev/null | head -1)
    fi
    
    if [ -z "$alert_dir" ] || [ ! -d "$alert_dir" ]; then
        log "${YELLOW}⚠ No alert exports found${NC}"
        return
    fi
    
    if [ "$DRY_RUN" = "true" ]; then
        log "${BLUE}[DRY RUN] Would restore alerts from: $alert_dir${NC}"
        [ -f "$alert_dir/alert-rules.yaml" ] && log "${BLUE}[DRY RUN] Would restore alert rules${NC}"
        [ -f "$alert_dir/notification-policies.yaml" ] && log "${BLUE}[DRY RUN] Would restore notification policies${NC}"
        [ -f "$alert_dir/contact-points.yaml" ] && log "${BLUE}[DRY RUN] Would restore contact points${NC}"
        return
    fi
    
    # Note: Grafana's provisioning API for alerts is limited
    # For full restoration, you might need to use file-based provisioning
    log "${YELLOW}⚠ Alert restoration via API is limited${NC}"
    log "For full alert restoration, copy YAML files to provisioning directory:"
    log "  cp $alert_dir/*.yaml $PROJECT_ROOT/config/provisioning/alerting/"
    
    # Create provisioning directory if it doesn't exist
    mkdir -p "$PROJECT_ROOT/config/provisioning/alerting"
    
    # Copy alert configurations
    if [ -f "$alert_dir/alert-rules.yaml" ]; then
        cp "$alert_dir/alert-rules.yaml" "$PROJECT_ROOT/config/provisioning/alerting/"
        log "${GREEN}✓ Copied alert rules to provisioning directory${NC}"
    fi
    
    if [ -f "$alert_dir/notification-policies.yaml" ]; then
        cp "$alert_dir/notification-policies.yaml" "$PROJECT_ROOT/config/provisioning/alerting/"
        log "${GREEN}✓ Copied notification policies to provisioning directory${NC}"
    fi
    
    if [ -f "$alert_dir/contact-points.yaml" ]; then
        cp "$alert_dir/contact-points.yaml" "$PROJECT_ROOT/config/provisioning/alerting/"
        log "${GREEN}✓ Copied contact points to provisioning directory${NC}"
    fi
    
    # Restart Grafana to load provisioned alerts
    log "Restarting Grafana to load alert configurations..."
    docker restart "$GRAFANA_CONTAINER"
    sleep 5
}

# Restore datasources
restore_datasources() {
    local backup_path="$1"
    
    log "${BLUE}Restoring datasource configurations...${NC}"
    
    # Find datasource exports
    local datasource_file=""
    if [ -f "$backup_path/exports/datasources/datasources.json" ]; then
        datasource_file="$backup_path/exports/datasources/datasources.json"
    else
        # Find most recent export
        local datasource_dir=$(ls -dt "${SCRIPT_DIR}/../exports/datasources"/20* 2>/dev/null | head -1)
        if [ -n "$datasource_dir" ] && [ -f "$datasource_dir/datasources.json" ]; then
            datasource_file="$datasource_dir/datasources.json"
        fi
    fi
    
    if [ -z "$datasource_file" ] || [ ! -f "$datasource_file" ]; then
        log "${YELLOW}⚠ No datasource exports found${NC}"
        return
    fi
    
    if [ "$DRY_RUN" = "true" ]; then
        local count=$(jq '. | length' "$datasource_file")
        log "${BLUE}[DRY RUN] Would restore $count datasources from: $datasource_file${NC}"
        return
    fi
    
    local auth_header=$(get_auth_header)
    local restored=0
    local failed=0
    
    # Restore each datasource
    jq -c '.[]' "$datasource_file" | while read -r datasource; do
        local name=$(echo "$datasource" | jq -r '.name')
        log "  Restoring datasource: $name"
        
        # Check if datasource already exists
        local existing=$(curl -s -H "$auth_header" \
            "${GRAFANA_HOST}/api/datasources/name/$(echo $name | sed 's/ /%20/g')" 2>/dev/null)
        
        if echo "$existing" | jq -e '.id' > /dev/null 2>&1; then
            # Update existing datasource
            local id=$(echo "$existing" | jq -r '.id')
            local response=$(curl -s -X PUT \
                -H "$auth_header" \
                -H "Content-Type: application/json" \
                -d "$datasource" \
                "${GRAFANA_HOST}/api/datasources/${id}" 2>/dev/null)
        else
            # Create new datasource
            local response=$(curl -s -X POST \
                -H "$auth_header" \
                -H "Content-Type: application/json" \
                -d "$datasource" \
                "${GRAFANA_HOST}/api/datasources" 2>/dev/null)
        fi
        
        if echo "$response" | jq -e '.message == "Datasource added" or .message == "Datasource updated"' > /dev/null 2>&1; then
            ((restored++))
        else
            log "${YELLOW}    ⚠ Failed to restore: $name${NC}"
            ((failed++))
        fi
    done
    
    log "${GREEN}✓ Restored $restored datasources${NC}"
    [ $failed -gt 0 ] && log "${YELLOW}⚠ Failed to restore $failed datasources${NC}"
}

# Main restoration process
main() {
    log "========================================="
    log "Grafana Restoration Process"
    log "========================================="
    
    # Find backup to restore from
    BACKUP_SOURCE=$(find_backup)
    log "Backup source: $BACKUP_SOURCE"
    
    # Confirm restoration
    confirm_restore "$BACKUP_SOURCE"
    
    if [ "$DRY_RUN" = "true" ]; then
        log ""
        log "${BLUE}===== DRY RUN MODE =====${NC}"
    fi
    
    # Perform restorations
    if [ "$RESTORE_SQLITE" = "true" ]; then
        log ""
        restore_sqlite "$BACKUP_SOURCE"
    fi
    
    if [ "$RESTORE_DASHBOARDS" = "true" ]; then
        log ""
        restore_dashboards "$BACKUP_SOURCE"
    fi
    
    if [ "$RESTORE_ALERTS" = "true" ]; then
        log ""
        restore_alerts "$BACKUP_SOURCE"
    fi
    
    if [ "$RESTORE_DATASOURCES" = "true" ]; then
        log ""
        restore_datasources "$BACKUP_SOURCE"
    fi
    
    log ""
    log "========================================="
    if [ "$DRY_RUN" = "true" ]; then
        log "${BLUE}Dry run completed - no changes made${NC}"
    else
        log "${GREEN}Restoration completed successfully!${NC}"
        log ""
        log "Next steps:"
        log "1. Verify Grafana is accessible at: ${GRAFANA_HOST}"
        log "2. Check that dashboards and datasources are working"
        log "3. Test alert rules if restored"
        log "4. Create a new backup of the restored state"
    fi
    log "========================================="
}

# Run main function
main "$@"