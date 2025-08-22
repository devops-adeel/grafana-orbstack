#!/bin/bash

# Grafana Runtime Configuration Export Script
# Exports runtime configurations via Grafana API
# This is a lightweight script focused only on API exports

set -euo pipefail

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../configs/backup.conf"

# Default configuration
GRAFANA_HOST="${GRAFANA_HOST:-http://localhost:3001}"
GRAFANA_USER="${GRAFANA_USER:-admin}"
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-admin}"
EXPORT_DIR="${SCRIPT_DIR}/../exports"

# Source config file if exists
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# Source environment variables for API keys
if [ -f "$HOME/.env" ]; then
    set -a
    source "$HOME/.env"
    set +a
fi

# Create export directories
mkdir -p "$EXPORT_DIR"/{dashboards,alerts,datasources}

# Timestamp for this export
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Get authentication header
get_auth_header() {
    if [ -n "${GRAFANA_API_KEY:-}" ]; then
        echo "Authorization: Bearer ${GRAFANA_API_KEY}"
    else
        echo "Authorization: Basic $(echo -n "${GRAFANA_USER}:${GRAFANA_PASSWORD}" | base64)"
    fi
}

# Export all dashboards
export_dashboards() {
    echo "Exporting dashboards..."
    local auth_header=$(get_auth_header)
    local export_subdir="$EXPORT_DIR/dashboards/$TIMESTAMP"
    mkdir -p "$export_subdir"
    
    # Get list of all dashboards
    local dashboards=$(curl -s -H "$auth_header" \
        "${GRAFANA_HOST}/api/search?type=dash-db" 2>/dev/null || echo "[]")
    
    local count=0
    echo "$dashboards" | jq -c '.[]' | while read -r dashboard; do
        local uid=$(echo "$dashboard" | jq -r '.uid')
        local title=$(echo "$dashboard" | jq -r '.title' | sed 's/[^a-zA-Z0-9-]/_/g')
        local folder=$(echo "$dashboard" | jq -r '.folderTitle // "General"' | sed 's/[^a-zA-Z0-9-]/_/g')
        
        if [ -n "$uid" ] && [ "$uid" != "null" ]; then
            echo "  - Exporting: $folder/$title (UID: $uid)"
            
            # Create folder structure
            mkdir -p "$export_subdir/$folder"
            
            # Export dashboard with full metadata
            local dashboard_json=$(curl -s -H "$auth_header" \
                "${GRAFANA_HOST}/api/dashboards/uid/${uid}" 2>/dev/null)
            
            if [ -n "$dashboard_json" ] && [ "$dashboard_json" != "null" ]; then
                # Save dashboard
                echo "$dashboard_json" | jq '.dashboard' > "$export_subdir/$folder/${title}.json"
                
                # Save metadata separately
                echo "$dashboard_json" | jq '{
                    meta: .meta,
                    uid: .dashboard.uid,
                    version: .dashboard.version,
                    exported_at: "'$TIMESTAMP'"
                }' > "$export_subdir/$folder/${title}.meta.json"
                
                ((count++)) || true
            fi
        fi
    done
    
    echo "  ✓ Exported $count dashboards to $export_subdir"
    
    # Create a manifest file
    cat > "$export_subdir/manifest.json" << EOF
{
    "export_timestamp": "$TIMESTAMP",
    "dashboard_count": $count,
    "grafana_host": "$GRAFANA_HOST",
    "folders": $(find "$export_subdir" -type d -mindepth 1 -maxdepth 1 | xargs -I {} basename {} | jq -R . | jq -s .)
}
EOF
}

# Export alert rules and notification policies
export_alerts() {
    echo "Exporting alert configurations..."
    local export_subdir="$EXPORT_DIR/alerts/$TIMESTAMP"
    mkdir -p "$export_subdir"
    
    # Export alert rules
    echo "  - Exporting alert rules..."
    curl -s "${GRAFANA_HOST}/api/v1/provisioning/alert-rules/export?download=false" \
        -o "$export_subdir/alert-rules.yaml" 2>/dev/null && \
        echo "  ✓ Alert rules exported" || \
        echo "  ⚠ Failed to export alert rules"
    
    # Export notification policies
    echo "  - Exporting notification policies..."
    curl -s "${GRAFANA_HOST}/api/v1/provisioning/policies/export?download=false" \
        -o "$export_subdir/notification-policies.yaml" 2>/dev/null && \
        echo "  ✓ Notification policies exported" || \
        echo "  ⚠ Failed to export notification policies"
    
    # Export contact points
    echo "  - Exporting contact points..."
    curl -s "${GRAFANA_HOST}/api/v1/provisioning/contact-points/export?download=false" \
        -o "$export_subdir/contact-points.yaml" 2>/dev/null && \
        echo "  ✓ Contact points exported" || \
        echo "  ⚠ Failed to export contact points"
    
    # Export mute timings
    echo "  - Exporting mute timings..."
    curl -s "${GRAFANA_HOST}/api/v1/provisioning/mute-timings/export?download=false" \
        -o "$export_subdir/mute-timings.yaml" 2>/dev/null && \
        echo "  ✓ Mute timings exported" || \
        echo "  ⚠ Failed to export mute timings"
}

# Export datasources
export_datasources() {
    echo "Exporting datasource configurations..."
    local auth_header=$(get_auth_header)
    local export_subdir="$EXPORT_DIR/datasources/$TIMESTAMP"
    mkdir -p "$export_subdir"
    
    # Get all datasources
    local datasources=$(curl -s -H "$auth_header" \
        "${GRAFANA_HOST}/api/datasources" 2>/dev/null || echo "[]")
    
    if [ "$datasources" != "[]" ]; then
        # Save all datasources (without secrets)
        echo "$datasources" | jq 'map(del(.password, .basicAuthPassword, .secureJsonData))' \
            > "$export_subdir/datasources.json"
        
        # Save individual datasource files for easier management
        echo "$datasources" | jq -c '.[]' | while read -r ds; do
            local name=$(echo "$ds" | jq -r '.name' | sed 's/[^a-zA-Z0-9-]/_/g')
            local type=$(echo "$ds" | jq -r '.type')
            
            echo "  - Exporting: $name (type: $type)"
            echo "$ds" | jq 'del(.password, .basicAuthPassword, .secureJsonData)' \
                > "$export_subdir/${name}.json"
        done
        
        local count=$(echo "$datasources" | jq '. | length')
        echo "  ✓ Exported $count datasources"
    else
        echo "  ⚠ No datasources found or failed to export"
    fi
}

# Export folders structure
export_folders() {
    echo "Exporting folder structure..."
    local auth_header=$(get_auth_header)
    local export_subdir="$EXPORT_DIR/folders"
    mkdir -p "$export_subdir"
    
    # Get all folders
    local folders=$(curl -s -H "$auth_header" \
        "${GRAFANA_HOST}/api/folders" 2>/dev/null || echo "[]")
    
    if [ "$folders" != "[]" ] && [ "$folders" != "null" ]; then
        echo "$folders" > "$export_subdir/folders-${TIMESTAMP}.json"
        local count=$(echo "$folders" | jq '. | length')
        echo "  ✓ Exported $count folders"
    else
        echo "  ℹ No custom folders found"
    fi
}

# Export annotations
export_annotations() {
    echo "Exporting annotations..."
    local auth_header=$(get_auth_header)
    local export_subdir="$EXPORT_DIR/annotations"
    mkdir -p "$export_subdir"
    
    # Get annotations (last 30 days)
    local from_timestamp=$(($(date +%s) - 2592000))000  # 30 days ago in milliseconds
    local to_timestamp=$(date +%s)000  # Now in milliseconds
    
    local annotations=$(curl -s -H "$auth_header" \
        "${GRAFANA_HOST}/api/annotations?from=${from_timestamp}&to=${to_timestamp}" 2>/dev/null || echo "[]")
    
    if [ "$annotations" != "[]" ] && [ "$annotations" != "null" ]; then
        echo "$annotations" > "$export_subdir/annotations-${TIMESTAMP}.json"
        local count=$(echo "$annotations" | jq '. | length')
        echo "  ✓ Exported $count annotations"
    else
        echo "  ℹ No annotations found"
    fi
}

# Clean old exports
clean_old_exports() {
    if [ -n "${RETENTION_EXPORTS:-}" ] && [ "${RETENTION_EXPORTS}" -gt 0 ]; then
        echo "Cleaning exports older than ${RETENTION_EXPORTS} days..."
        
        # Clean old dashboard exports
        find "$EXPORT_DIR/dashboards" -type d -name "20*" -mtime +${RETENTION_EXPORTS} -exec rm -rf {} \; 2>/dev/null || true
        
        # Clean old alert exports
        find "$EXPORT_DIR/alerts" -type d -name "20*" -mtime +${RETENTION_EXPORTS} -exec rm -rf {} \; 2>/dev/null || true
        
        # Clean old datasource exports
        find "$EXPORT_DIR/datasources" -type d -name "20*" -mtime +${RETENTION_EXPORTS} -exec rm -rf {} \; 2>/dev/null || true
        
        # Clean old folder exports
        find "$EXPORT_DIR/folders" -type f -name "*.json" -mtime +${RETENTION_EXPORTS} -delete 2>/dev/null || true
        
        # Clean old annotation exports
        find "$EXPORT_DIR/annotations" -type f -name "*.json" -mtime +${RETENTION_EXPORTS} -delete 2>/dev/null || true
        
        echo "  ✓ Cleanup completed"
    fi
}

# Create export summary
create_summary() {
    local summary_file="$EXPORT_DIR/latest-export.json"
    
    # Count exported items
    local dashboard_count=$(find "$EXPORT_DIR/dashboards/$TIMESTAMP" -name "*.json" -not -name "*.meta.json" -not -name "manifest.json" 2>/dev/null | wc -l | tr -d ' ')
    local alert_files=$(find "$EXPORT_DIR/alerts/$TIMESTAMP" -name "*.yaml" 2>/dev/null | wc -l | tr -d ' ')
    local datasource_count=$(find "$EXPORT_DIR/datasources/$TIMESTAMP" -name "*.json" -not -name "datasources.json" 2>/dev/null | wc -l | tr -d ' ')
    
    cat > "$summary_file" << EOF
{
    "timestamp": "$TIMESTAMP",
    "grafana_host": "$GRAFANA_HOST",
    "exports": {
        "dashboards": $dashboard_count,
        "alert_configurations": $alert_files,
        "datasources": $datasource_count
    },
    "export_locations": {
        "dashboards": "dashboards/$TIMESTAMP",
        "alerts": "alerts/$TIMESTAMP",
        "datasources": "datasources/$TIMESTAMP"
    }
}
EOF
    
    echo ""
    echo "Export Summary:"
    echo "  - Dashboards: $dashboard_count"
    echo "  - Alert configurations: $alert_files files"
    echo "  - Datasources: $datasource_count"
    echo "  - Summary saved to: $summary_file"
}

# Main execution
main() {
    echo "========================================="
    echo "Grafana Runtime Export - $TIMESTAMP"
    echo "========================================="
    echo "Host: $GRAFANA_HOST"
    echo ""
    
    # Check if Grafana is accessible
    if ! curl -s -o /dev/null -w "%{http_code}" "${GRAFANA_HOST}/api/health" | grep -q "200"; then
        echo "⚠️  Warning: Grafana may not be accessible at ${GRAFANA_HOST}"
        echo "Continuing anyway..."
    fi
    
    # Perform exports
    export_dashboards
    echo ""
    export_alerts
    echo ""
    export_datasources
    echo ""
    export_folders
    echo ""
    export_annotations
    echo ""
    
    # Clean old exports
    clean_old_exports
    echo ""
    
    # Create summary
    create_summary
    
    echo ""
    echo "========================================="
    echo "Export completed successfully!"
    echo "Location: $EXPORT_DIR"
    echo "========================================="
}

# Run main function
main "$@"