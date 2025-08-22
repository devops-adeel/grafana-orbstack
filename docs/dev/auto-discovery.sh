#!/bin/bash

# Auto-discovery script for Grafana Observability Platform
# Updates service inventory in README.md based on docker-compose.grafana.yml

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMPOSE_FILE="$PROJECT_ROOT/docker-compose.grafana.yml"
README_FILE="$SCRIPT_DIR/README.md"

echo "🔍 Auto-discovering services from docker-compose.grafana.yml..."

# Check if files exist
if [ ! -f "$COMPOSE_FILE" ]; then
    echo "❌ Error: docker-compose.grafana.yml not found at $COMPOSE_FILE"
    exit 1
fi

if [ ! -f "$README_FILE" ]; then
    echo "❌ Error: README.md not found at $README_FILE"
    exit 1
fi

# Extract services using docker compose config
echo "📋 Extracting service inventory..."

# Generate the service table
SERVICE_TABLE="| Service | Container Name | OrbStack Domain | Port | Purpose |
|---------|---------------|-----------------|------|---------|"

# Parse services from docker-compose using docker compose config
cd "$PROJECT_ROOT"
SERVICES=$(docker compose -f docker-compose.grafana.yml config --services 2>/dev/null || true)

if [ -z "$SERVICES" ]; then
    echo "⚠️  Warning: No services found or docker compose not available"
    echo "   Using fallback method..."
    
    # Fallback: manually parse known services
    SERVICE_TABLE="$SERVICE_TABLE
| Grafana | grafana-local | grafana.local | 3000 | Visualization dashboard |
| Prometheus | prometheus-local | prometheus.local | 9090 | Metrics storage |
| Tempo | tempo-local | tempo.local | 3200 | Distributed tracing |
| Loki | loki-local | loki.local | 3100 | Log aggregation |
| Alloy | grafana-alloy | alloy.local | 4317/4318 | OTLP collector |
| Redis Exporter | redis-exporter | redis-exporter.local | 9121 | FalkorDB metrics |
| ClickHouse Exporter | clickhouse-exporter | clickhouse-exporter.local | 9116 | Langfuse metrics |"
else
    # Process each service
    while IFS= read -r service; do
        # Get container name and domain from docker-compose config
        CONTAINER=$(docker compose -f docker-compose.grafana.yml config | \
            grep -A20 "^  $service:" | \
            grep "container_name:" | \
            head -1 | \
            awk '{print $2}' || echo "$service")
        
        DOMAIN=$(docker compose -f docker-compose.grafana.yml config | \
            grep -A20 "^  $service:" | \
            grep "dev.orbstack.domains" | \
            head -1 | \
            sed 's/.*dev.orbstack.domains=//' | \
            tr -d '"' || echo "N/A")
        
        # Map service to its primary port and purpose
        case "$service" in
            grafana)
                PORT="3000"
                PURPOSE="Visualization dashboard"
                ;;
            prometheus)
                PORT="9090"
                PURPOSE="Metrics storage"
                ;;
            tempo)
                PORT="3200"
                PURPOSE="Distributed tracing"
                ;;
            loki)
                PORT="3100"
                PURPOSE="Log aggregation"
                ;;
            alloy)
                PORT="4317/4318"
                PURPOSE="OTLP collector"
                ;;
            redis-exporter)
                PORT="9121"
                PURPOSE="FalkorDB metrics"
                ;;
            clickhouse-exporter)
                PORT="9116"
                PURPOSE="Langfuse metrics"
                ;;
            *)
                PORT="N/A"
                PURPOSE="Unknown"
                ;;
        esac
        
        # Format service name nicely
        SERVICE_NAME=$(echo "$service" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1')
        
        SERVICE_TABLE="$SERVICE_TABLE
| $SERVICE_NAME | $CONTAINER | $DOMAIN | $PORT | $PURPOSE |"
    done <<< "$SERVICES"
fi

# Create a temporary file with updated content
TEMP_FILE=$(mktemp)

# Read the README and replace the service inventory section
awk -v table="$SERVICE_TABLE" '
/^## Service Inventory$/ {
    print
    print ""
    print table
    # Skip lines until we find the next section
    while (getline && !/^## /) {}
    print ""
    print
    next
}
{ print }
' "$README_FILE" > "$TEMP_FILE"

# Update the README
mv "$TEMP_FILE" "$README_FILE"

echo "✅ Service inventory updated in README.md"

# Also extract and display current metrics being collected
echo ""
echo "📊 Current metrics being scraped:"
if [ -f "$PROJECT_ROOT/config/alloy-config.alloy" ]; then
    grep -E "prometheus.scrape|job =" "$PROJECT_ROOT/config/alloy-config.alloy" | \
        grep -E 'job = "' | \
        sed 's/.*job = "\([^"]*\)".*/  - \1/' | \
        sort -u
fi

echo ""
echo "🎯 Quick status check:"
echo "  - Services defined: $(echo "$SERVICES" | wc -l | xargs)"
echo "  - README location: $README_FILE"
echo "  - Last updated: $(date)"

# Make the script executable for future runs
chmod +x "$SCRIPT_DIR/auto-discovery.sh"