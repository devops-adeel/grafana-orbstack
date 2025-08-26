#!/bin/bash

# Prometheus TSDB Restore Script
# Restores Prometheus data from backup snapshots created by offen/docker-volume-backup
# 
# CRITICAL: This will DELETE current Prometheus data!
# Usage: ./restore-prometheus.sh <backup-file.tar.gz> [--force]

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PROMETHEUS_CONTAINER="prometheus-local"
PROMETHEUS_VOLUME="grafana-orbstack_prometheus-data"
TEMP_RESTORE_DIR="/tmp/prometheus-restore-$$"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Parse arguments
if [ $# -lt 1 ]; then
    echo "Usage: $0 <backup-file.tar.gz> [--force]"
    echo ""
    echo "Example:"
    echo "  $0 ~/GrafanaBackups/critical/critical-2024-01-15_02-00-00.tar.gz"
    echo "  $0 ~/GrafanaBackups/critical/critical-latest.tar.gz --force"
    echo ""
    echo "Options:"
    echo "  --force    Skip confirmation prompts (use with caution!)"
    exit 1
fi

BACKUP_FILE="$1"
FORCE_MODE=false

if [ "${2:-}" = "--force" ]; then
    FORCE_MODE=true
fi

# Validate backup file
if [ ! -f "$BACKUP_FILE" ]; then
    echo -e "${RED}[ERROR]${NC} Backup file not found: $BACKUP_FILE"
    exit 1
fi

# Resolve symlink if necessary
if [ -L "$BACKUP_FILE" ]; then
    BACKUP_FILE=$(readlink "$BACKUP_FILE")
    echo -e "${BLUE}[INFO]${NC} Resolved symlink to: $BACKUP_FILE"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " PROMETHEUS RESTORE PROCEDURE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo -e "${YELLOW}[WARNING]${NC} This procedure will:"
echo "  1. Stop Prometheus container"
echo "  2. DELETE all current Prometheus data"
echo "  3. Restore from backup: $(basename $BACKUP_FILE)"
echo "  4. Restart Prometheus"
echo ""

# Check if Prometheus is running
if docker ps --format "{{.Names}}" | grep -q "^${PROMETHEUS_CONTAINER}$"; then
    echo -e "${GREEN}[✓]${NC} Prometheus container found: $PROMETHEUS_CONTAINER"
    
    # Get current data size
    current_size=$(docker exec "$PROMETHEUS_CONTAINER" du -sh /prometheus 2>/dev/null | cut -f1 || echo "unknown")
    echo -e "${BLUE}[INFO]${NC} Current data size: $current_size"
else
    echo -e "${RED}[ERROR]${NC} Prometheus container not running: $PROMETHEUS_CONTAINER"
    echo "Start the container first with: docker compose -f docker-compose.grafana.yml up -d prometheus"
    exit 1
fi

# Confirmation
if [ "$FORCE_MODE" != true ]; then
    echo ""
    read -p "Are you ABSOLUTELY SURE you want to proceed? Type 'yes' to continue: " confirmation
    if [ "$confirmation" != "yes" ]; then
        echo -e "${YELLOW}[INFO]${NC} Restore cancelled by user"
        exit 0
    fi
fi

echo ""
echo -e "${BLUE}[INFO]${NC} Starting restore procedure..."

# Step 1: Extract backup to temporary location
echo -e "${BLUE}[1/6]${NC} Extracting backup to temporary location..."
mkdir -p "$TEMP_RESTORE_DIR"

# Check if backup contains prometheus snapshot
if tar -tzf "$BACKUP_FILE" | grep -q "backup/prometheus-snapshot/"; then
    echo -e "${GREEN}[✓]${NC} Backup contains Prometheus snapshot data"
    
    # Extract prometheus snapshot
    tar -xzf "$BACKUP_FILE" -C "$TEMP_RESTORE_DIR" --strip-components=1 "backup/prometheus-snapshot/" 2>/dev/null || \
    tar -xzf "$BACKUP_FILE" -C "$TEMP_RESTORE_DIR" "backup/prometheus-snapshot/" 2>/dev/null
    
    # Check what was extracted
    if [ -d "$TEMP_RESTORE_DIR/prometheus-snapshot" ]; then
        SNAPSHOT_DIR="$TEMP_RESTORE_DIR/prometheus-snapshot"
    elif [ -d "$TEMP_RESTORE_DIR" ] && [ -f "$TEMP_RESTORE_DIR/wal/00000000" ]; then
        SNAPSHOT_DIR="$TEMP_RESTORE_DIR"
    else
        echo -e "${RED}[ERROR]${NC} Unexpected backup structure. Contents:"
        ls -la "$TEMP_RESTORE_DIR"
        rm -rf "$TEMP_RESTORE_DIR"
        exit 1
    fi
    
    echo -e "${GREEN}[✓]${NC} Snapshot extracted to: $SNAPSHOT_DIR"
    
    # Verify snapshot contains expected TSDB structure
    if [ -d "$SNAPSHOT_DIR/wal" ] || [ -d "$SNAPSHOT_DIR/chunks_head" ]; then
        echo -e "${GREEN}[✓]${NC} Valid TSDB structure found"
    else
        echo -e "${RED}[ERROR]${NC} Invalid TSDB structure in backup. Expected wal/ or chunks_head/ directories"
        ls -la "$SNAPSHOT_DIR"
        rm -rf "$TEMP_RESTORE_DIR"
        exit 1
    fi
else
    echo -e "${RED}[ERROR]${NC} Backup does not contain Prometheus snapshot data"
    echo "Looking for 'backup/prometheus-snapshot/' in archive..."
    tar -tzf "$BACKUP_FILE" | head -20
    rm -rf "$TEMP_RESTORE_DIR"
    exit 1
fi

# Step 2: Stop Prometheus
echo -e "${BLUE}[2/6]${NC} Stopping Prometheus container..."
docker stop "$PROMETHEUS_CONTAINER"
echo -e "${GREEN}[✓]${NC} Prometheus stopped"

# Step 3: Backup current data (safety measure)
echo -e "${BLUE}[3/6]${NC} Creating safety backup of current data..."
SAFETY_BACKUP="/tmp/prometheus-safety-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
docker run --rm \
    -v "$PROMETHEUS_VOLUME:/data:ro" \
    -v "/tmp:/backup" \
    alpine tar -czf "/backup/$(basename $SAFETY_BACKUP)" -C /data . 2>/dev/null || true
    
if [ -f "$SAFETY_BACKUP" ]; then
    echo -e "${GREEN}[✓]${NC} Safety backup created: $SAFETY_BACKUP"
    echo -e "${YELLOW}[NOTE]${NC} Keep this file until you verify the restore was successful"
else
    echo -e "${YELLOW}[WARNING]${NC} Could not create safety backup, proceeding anyway..."
fi

# Step 4: Clear existing data
echo -e "${BLUE}[4/6]${NC} Clearing existing Prometheus data..."
docker run --rm \
    -v "$PROMETHEUS_VOLUME:/prometheus" \
    alpine sh -c 'rm -rf /prometheus/*'
echo -e "${GREEN}[✓]${NC} Existing data cleared"

# Step 5: Restore snapshot data
echo -e "${BLUE}[5/6]${NC} Restoring snapshot data to volume..."

# Copy the snapshot contents to the volume
# Note: We need to preserve the exact directory structure
docker run --rm \
    -v "$PROMETHEUS_VOLUME:/prometheus" \
    -v "$SNAPSHOT_DIR:/restore:ro" \
    alpine sh -c 'cp -a /restore/* /prometheus/ && chown -R nobody:nobody /prometheus'

echo -e "${GREEN}[✓]${NC} Snapshot data restored"

# Verify restored data
docker run --rm \
    -v "$PROMETHEUS_VOLUME:/prometheus:ro" \
    alpine sh -c 'ls -la /prometheus/ | head -10'

# Step 6: Start Prometheus
echo -e "${BLUE}[6/6]${NC} Starting Prometheus..."
docker start "$PROMETHEUS_CONTAINER"

# Wait for Prometheus to be ready
echo -e "${BLUE}[INFO]${NC} Waiting for Prometheus to be ready..."
for i in {1..30}; do
    if curl -s "http://localhost:9090/-/ready" 2>/dev/null | grep -q "Prometheus Server is Ready"; then
        echo -e "${GREEN}[✓]${NC} Prometheus is ready!"
        break
    fi
    echo -n "."
    sleep 2
done
echo ""

# Verify Prometheus is working
echo -e "${BLUE}[INFO]${NC} Verifying Prometheus operation..."

# Check if API is responding
if curl -s "http://localhost:9090/api/v1/query?query=up" | grep -q "success"; then
    echo -e "${GREEN}[✓]${NC} Prometheus API is responding"
    
    # Get some basic metrics
    metric_count=$(curl -s "http://localhost:9090/api/v1/label/__name__/values" | jq '.data | length' 2>/dev/null || echo "0")
    echo -e "${GREEN}[✓]${NC} Metrics available: $metric_count"
    
    # Check data time range
    oldest=$(curl -s "http://localhost:9090/api/v1/query?query=prometheus_tsdb_lowest_timestamp" | \
             jq -r '.data.result[0].value[1]' 2>/dev/null || echo "0")
    
    if [ "$oldest" != "0" ] && [ "$oldest" != "null" ]; then
        oldest_date=$(date -r $(echo "$oldest" | cut -d'.' -f1 | head -c10) "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "unknown")
        echo -e "${GREEN}[✓]${NC} Oldest data point: $oldest_date"
    fi
else
    echo -e "${YELLOW}[WARNING]${NC} Prometheus API not responding yet. Check logs:"
    echo "  docker logs --tail 50 $PROMETHEUS_CONTAINER"
fi

# Cleanup
echo -e "${BLUE}[INFO]${NC} Cleaning up temporary files..."
rm -rf "$TEMP_RESTORE_DIR"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN} RESTORE COMPLETED SUCCESSFULLY${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Next steps:"
echo "  1. Verify metrics in Grafana: http://grafana.local"
echo "  2. Check Prometheus targets: http://localhost:9090/targets"
echo "  3. Monitor logs: docker logs -f $PROMETHEUS_CONTAINER"
echo ""
echo -e "${YELLOW}[IMPORTANT]${NC} Safety backup saved at: $SAFETY_BACKUP"
echo "Keep this file until you confirm the restore was successful."
echo "To restore from safety backup if needed:"
echo "  $0 $SAFETY_BACKUP"
echo ""