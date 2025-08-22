# 🛠️ Developer Quick Reference - Grafana AI Observability Stack

> **Purpose**: Technical reference for extending, debugging, and integrating with the observability stack  
> **Audience**: Developers adding new services, creating dashboards, or debugging integrations  
> **Updated**: 2024-08-22

---

## 🏗️ ARCHITECTURE QUICK REFERENCE

### 📊 Data Flow Pipeline
```bash
AI Services → OTLP (4317/4318) → Alloy → Storage → Grafana
                                      ├── Prometheus (metrics:9090)
                                      ├── Tempo (traces:3200)  
                                      └── Loki (logs:3100)
```

### 🔌 Key Ports Reference
```bash
# OTLP Collection
4317 - OTLP gRPC (high volume)
4318 - OTLP HTTP (testing/browser)

# Storage Backends
9090 - Prometheus metrics
3200 - Tempo traces
3100 - Loki logs

# Visualization
3001 - Grafana UI (mapped from 3000)

# Exporters
9121 - Redis/FalkorDB exporter
9116 - ClickHouse/Langfuse exporter
```

---

## 🚀 ADDING NEW SERVICES

### 📦 Add Service to Monitoring
**Step 1: Add exporter to docker-compose.grafana.yml**
```yaml
  your-service-exporter:
    image: prom/node-exporter:latest  # or specific exporter
    container_name: your-service-exporter
    labels:
      - dev.orbstack.domains=your-exporter.local
    ports:
      - "9xxx:9xxx"  # Choose unused port
    environment:
      - YOUR_SERVICE_URL=http://your-service:port
    networks:
      - observability
    restart: unless-stopped
```

**Step 2: Add Prometheus scrape config**
```bash
# Edit config/prometheus.yml
vi config/prometheus.yml

# Add scrape job:
  - job_name: 'your-service'
    static_configs:
      - targets: ['your-service-exporter:9xxx']
    scrape_interval: 30s
```

**Step 3: Apply changes**
```bash
docker compose -f docker-compose.grafana.yml up -d your-service-exporter
docker exec prometheus-local kill -HUP 1  # Reload Prometheus config
```

**Step 4: Verify metrics**
```bash
curl http://prometheus.local:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="your-service")'
curl http://prometheus.local:9090/api/v1/label/__name__ | jq '.data[] | select(startswith("your_service_"))'
```

---

## 📈 DASHBOARD DEVELOPMENT

### 🎨 Create New Dashboard
```bash
# Export existing dashboard as template
curl -s http://grafana.local/api/dashboards/uid/ai-operations-unified | jq '.dashboard' > dashboard-template.json

# Key panel types for AI monitoring:
# - stat: Current values (active requests, cache hit rate)
# - timeseries: Trends (invocation rate, latency)
# - gauge: Thresholds (memory usage, CPU)
# - table: Detailed breakdowns (per-operation metrics)
```

### 📊 Essential PromQL Queries
```promql
# Rate calculations (per minute)
rate(mcp_tool_invocations_total[1m]) * 60

# Percentile latencies
histogram_quantile(0.95, rate(mcp_tool_duration_bucket[5m]))

# Memory operation patterns
sum by(operation) (rate(mcp_memory_operations_total[1m]))

# Cache hit rate
rate(redis_keyspace_hits_total[5m]) / rate(redis_commands_processed_total{cmd="get"}[5m])

# Container resources
container_memory_usage_bytes{name=~"grafana-.*"} / 1024 / 1024 / 1024
```

### 🏷️ Add Dashboard to Provisioning
```bash
# Copy dashboard to provisioning directory
cp your-dashboard.json dashboards/

# Dashboard will auto-load on Grafana restart
docker compose -f docker-compose.grafana.yml restart grafana
```

---

## 🔧 OTLP INSTRUMENTATION

### 🐍 Python MCP Server Wrapper
```python
# Example OTLP instrumentation for MCP servers
from opentelemetry import trace, metrics
from opentelemetry.exporter.otlp.proto.grpc import (
    trace_exporter, metrics_exporter
)

# Configure OTLP endpoint
OTLP_ENDPOINT = "http://localhost:4317"

# Initialize tracer
tracer = trace.get_tracer("mcp.server.name")

# Instrument function
@tracer.start_as_current_span("tool_invocation")
def handle_tool(tool_name: str, params: dict):
    span = trace.get_current_span()
    span.set_attribute("tool.name", tool_name)
    span.set_attribute("tool.params", str(params))
    # Tool logic here
```

### 📡 Test OTLP Connection
```bash
# Send test metric via OTLP HTTP
curl -X POST http://localhost:4318/v1/metrics \
  -H "Content-Type: application/json" \
  -d '{
    "resourceMetrics": [{
      "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "test"}}]},
      "scopeMetrics": [{
        "metrics": [{
          "name": "test.metric",
          "unit": "1",
          "sum": {
            "dataPoints": [{
              "asInt": "1",
              "timeUnixNano": "'$(date +%s%N)'"
            }]
          }
        }]
      }]
    }]
  }'

# Verify in Prometheus
curl -s http://prometheus.local:9090/api/v1/query?query=test_metric
```

---

## 🐛 DEBUGGING

### 🔍 Trace Request Flow
```bash
# Check Alloy received data
docker logs grafana-alloy --tail 100 | grep -E "received|processed"

# Check Prometheus ingestion
curl http://prometheus.local:9090/api/v1/query?query='prometheus_tsdb_symbol_table_symbols_count'

# Check Tempo traces
curl http://tempo-local:3200/api/traces/v1/metrics | jq

# Check Loki logs
curl "http://loki-local:3100/loki/api/v1/query_range?query={job=\"docker\"}" | jq '.data.result'
```

### 📝 Enable Debug Logging
```bash
# Grafana debug mode
docker exec grafana-main grafana-cli admin data-migration encrypt-datasource-passwords
docker exec -it grafana-main sed -i 's/level = info/level = debug/g' /etc/grafana/grafana.ini
docker restart grafana-main

# Prometheus debug
docker run -d --name prometheus-debug \
  --network observability \
  prom/prometheus:latest \
  --config.file=/etc/prometheus/prometheus.yml \
  --log.level=debug

# View debug logs
docker logs prometheus-debug --tail 100 | grep -i debug
```

### 🧪 Test Metrics Pipeline
```bash
# Generate test load
for i in {1..100}; do
  curl -s http://localhost:4318/v1/metrics \
    -H "Content-Type: application/json" \
    -d '{"resourceMetrics":[{"resource":{},"scopeMetrics":[{"metrics":[{"name":"test.counter","sum":{"dataPoints":[{"asInt":"'$i'"}]}}]}]}]}' &
done

# Monitor ingestion rate
watch -n 1 'curl -s http://prometheus.local:9090/api/v1/query?query=prometheus_tsdb_head_samples_appended_total | jq ".data.result[0].value[1]"'
```

---

## 🔐 API REFERENCE

### 📡 Grafana API
```bash
# Get all dashboards
curl -H "Authorization: Basic $(echo -n admin:admin | base64)" \
  http://grafana.local/api/search?type=dash-db

# Export dashboard
curl http://grafana.local/api/dashboards/uid/YOUR-UID | jq '.dashboard' > dashboard.json

# Import dashboard
curl -X POST http://grafana.local/api/dashboards/db \
  -H "Content-Type: application/json" \
  -H "Authorization: Basic $(echo -n admin:admin | base64)" \
  -d @dashboard.json

# Create API key
curl -X POST http://grafana.local/api/auth/keys \
  -H "Content-Type: application/json" \
  -H "Authorization: Basic $(echo -n admin:admin | base64)" \
  -d '{"name":"dev-key","role":"Admin"}'
```

### 📡 Prometheus API
```bash
# Query instant value
curl 'http://prometheus.local:9090/api/v1/query?query=up'

# Query range
curl 'http://prometheus.local:9090/api/v1/query_range?query=rate(mcp_tool_invocations_total[5m])&start='$(date -u -d '1 hour ago' +%s)'&end='$(date +%s)'&step=60'

# Get metric metadata
curl http://prometheus.local:9090/api/v1/metadata?metric=mcp_tool_invocations_total

# Get all metrics
curl http://prometheus.local:9090/api/v1/label/__name__/values | jq
```

---

## 🔄 CI/CD INTEGRATION

### 🚦 Health Check Script
```bash
#!/bin/bash
# health-check.sh - Add to CI/CD pipeline

SERVICES=("grafana:3001" "prometheus:9090" "tempo:3200" "loki:3100" "alloy:4317")
FAILED=0

for service in "${SERVICES[@]}"; do
  name="${service%%:*}"
  port="${service##*:}"
  if curl -s -f -o /dev/null "http://localhost:$port/ready" || curl -s -f -o /dev/null "http://localhost:$port/api/health"; then
    echo "✅ $name is healthy"
  else
    echo "❌ $name is not responding on port $port"
    FAILED=$((FAILED + 1))
  fi
done

exit $FAILED
```

### 📊 Metrics Validation
```bash
# Verify critical metrics exist
REQUIRED_METRICS=(
  "mcp_tool_invocations_total"
  "mcp_memory_operations_total"
  "redis_commands_processed_total"
  "up"
)

for metric in "${REQUIRED_METRICS[@]}"; do
  COUNT=$(curl -s "http://prometheus.local:9090/api/v1/query?query=$metric" | jq '.data.result | length')
  if [ "$COUNT" -gt 0 ]; then
    echo "✅ Metric $metric found ($COUNT series)"
  else
    echo "❌ Metric $metric missing"
  fi
done
```

---

## 🔗 CONFIGURATION FILES

### 📁 Key Configuration Locations
```bash
# Grafana provisioning
./dashboards/*.json                     # Dashboard definitions
./config/datasources.yml                # Data source configs

# Collection pipeline
./config/alloy-config.alloy            # OTLP receiver config

# Storage configs
./config/prometheus.yml                 # Scrape configs
./config/tempo.yaml                     # Trace storage
./config/loki-config.yaml              # Log aggregation

# Service definitions
./docker-compose.grafana.yml           # Stack composition
```

### 🔧 Environment Variables
```bash
# Grafana customization
GF_SECURITY_ADMIN_USER=admin
GF_SECURITY_ADMIN_PASSWORD=your-password
GF_FEATURE_TOGGLES_ENABLE=traceToMetrics,traceToLogs

# Prometheus settings
--storage.tsdb.retention.time=90d
--web.enable-remote-write-receiver
--enable-feature=exemplar-storage

# Resource limits (add to docker-compose)
deploy:
  resources:
    limits:
      memory: 2G
      cpus: '1.0'
```

---

## 📚 DEVELOPMENT RESOURCES

### 🔗 Documentation
- **Grafana Docs**: https://grafana.com/docs/grafana/latest/
- **Prometheus Docs**: https://prometheus.io/docs/
- **OpenTelemetry**: https://opentelemetry.io/docs/
- **OrbStack**: https://docs.orbstack.dev/

### 🛠️ Useful Tools
```bash
# PromQL tester
docker run -p 9091:9090 prom/prometheus

# Grafana Explorer
http://grafana.local/explore

# OTLP CLI tool
go install github.com/open-telemetry/opentelemetry-collector-contrib/cmd/otelcontribcol@latest

# Metrics generator for testing
docker run -d --name fake-metrics \
  --network observability \
  -p 8080:8080 \
  prom/node-exporter
```

---

## 🐞 COMMON DEVELOPMENT ISSUES

### ❌ Metrics Not Appearing
```bash
# Check 1: Exporter is scraping
curl http://your-exporter:9xxx/metrics  # Should return Prometheus format

# Check 2: Prometheus can reach exporter
docker exec prometheus-local wget -O- http://your-exporter:9xxx/metrics

# Check 3: Scrape config is loaded
curl http://prometheus.local:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="your-service")'

# Check 4: Metrics are stored
curl "http://prometheus.local:9090/api/v1/query?query=your_metric_name"
```

### ❌ Dashboard Not Loading
```bash
# Check datasource
curl http://grafana.local/api/datasources | jq '.[].name'

# Validate JSON
jq . < dashboards/your-dashboard.json

# Check provisioning
docker exec grafana-main ls -la /etc/grafana/provisioning/dashboards/

# Force reload
docker exec grafana-main kill -HUP 1
```

### ❌ OTLP Data Not Received
```bash
# Test OTLP endpoint
nc -zv localhost 4317  # gRPC
curl http://localhost:4318/  # HTTP should return 404

# Check Alloy logs
docker logs grafana-alloy --tail 100 | grep -E "otlp|grpc|http"

# Verify Alloy config
docker exec grafana-alloy cat /etc/alloy/config.alloy | grep -A5 "otlp"
```

---

> **Last Updated**: 2024-08-22  
> **Version**: 1.0.0  
> **Next Review**: 2024-09-22