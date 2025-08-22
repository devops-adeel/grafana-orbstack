# Troubleshooting Guide

## Quick Diagnostics

```bash
# Is everything running?
docker ps | grep -E "grafana|prometheus|tempo|loki|alloy" | wc -l
# Expected: 5 services

# Are metrics flowing?
curl -s http://prometheus.local:9090/api/v1/query?query=up | jq '.data.result | length'
# Expected: >3 targets

# Quick health dashboard
open http://grafana.local/d/ai-ops-unified/ai-operations
```

## Problem → Solution Reference

### 🔴 Services Not Starting

**Symptoms:**
- Containers restarting continuously
- Port conflicts on 3001, 4317, or 4318

**Quick Check:**
```bash
docker logs grafana-local --tail 20
docker logs grafana-alloy --tail 20
```

**Solutions:**
1. **Port conflict:**
   ```bash
   lsof -i :3001  # Check what's using the port
   docker compose -f docker-compose.grafana.yml down
   docker compose -f docker-compose.grafana.yml up -d
   ```

2. **Volume permissions:**
   ```bash
   docker compose -f docker-compose.grafana.yml down -v
   docker compose -f docker-compose.grafana.yml up -d
   ```

---

### 🔴 No Metrics in Grafana

**Symptoms:**
- Empty dashboards
- "No data" in all panels

**Quick Check:**
```bash
# Test Prometheus directly
curl -s "http://prometheus.local:9090/api/v1/query?query=mcp_tool_invocations_total" | jq '.status'
# Expected: "success"

# Check Alloy is receiving
curl -s http://alloy.local:12345/metrics | grep otlp_receiver | head -5
```

**Solutions:**
1. **OTLP not configured in AI services:**
   ```bash
   # Verify environment variables in GTD Coach
   docker exec gtd-coach-1 env | grep OTLP
   # Should see: OTLP_ENDPOINT=alloy.local:4317
   ```

2. **Prometheus remote write failing:**
   ```bash
   docker logs grafana-alloy | grep "remote_write" | tail -10
   # Fix: Restart Alloy
   docker restart grafana-alloy
   ```

---

### 🔴 High Memory Usage

**Symptoms:**
- Container using >3GB RAM
- Host system sluggish
- Docker Desktop memory warnings

**Quick Check:**
```bash
# Memory usage by container
docker stats --no-stream | grep grafana-orbstack
```

**PromQL Query:**
```promql
# FalkorDB memory usage
redis_memory_used_bytes{job="falkordb"} / 1024 / 1024 / 1024
```

**Solutions:**
1. **FalkorDB memory growth:**
   ```bash
   # Check key count
   docker exec falkordb redis-cli DBSIZE
   
   # If >100k keys, consider cleanup
   docker exec falkordb redis-cli --scan --pattern "old_memory:*" | \
     xargs -L 100 docker exec -i falkordb redis-cli DEL
   ```

2. **Prometheus retention:**
   ```bash
   # Current size
   docker exec prometheus-local du -sh /prometheus
   
   # If >10GB, reduce retention
   # Edit docker-compose.grafana.yml: --storage.tsdb.retention.time=30d
   docker compose -f docker-compose.grafana.yml up -d prometheus
   ```

---

### 🟡 Slow Dashboard Loading

**Symptoms:**
- Dashboards take >5s to load
- Timeouts on complex queries

**Quick Check:**
```bash
# Test query performance
time curl -s "http://prometheus.local:9090/api/v1/query_range?query=rate(mcp_tool_invocations_total[5m])&start=$(date -u -v-1H '+%Y-%m-%dT%H:%M:%SZ')&end=$(date -u '+%Y-%m-%dT%H:%M:%SZ')&step=60" > /dev/null
# Should be <1s
```

**Solutions:**
1. **Too many metrics:**
   ```promql
   # Check cardinality
   prometheus_tsdb_symbol_table_size_bytes / 1024 / 1024
   # If >100MB, reduce scrape targets
   ```

2. **Optimize queries:**
   ```promql
   # Bad: Unbounded query
   mcp_tool_invocations_total
   
   # Good: Rate with time window
   rate(mcp_tool_invocations_total[5m])
   ```

---

### 🟡 Missing Traces

**Symptoms:**
- No traces in Tempo
- Trace to metrics not working

**Quick Check:**
```bash
# Check Tempo is receiving
curl -s http://tempo.local:3200/ready
# Expected: "ready"

# Search recent traces
curl -s "http://tempo.local:3200/api/search?limit=20" | jq '.traces | length'
```

**Solutions:**
1. **OTLP trace export not configured:**
   ```bash
   # Check Alloy trace forwarding
   docker logs grafana-alloy | grep "traces" | tail -5
   ```

2. **Tempo storage issue:**
   ```bash
   docker exec tempo-local ls -la /var/tempo
   # Fix permissions if needed
   docker exec tempo-local chown -R 10001:10001 /var/tempo
   ```

---

### 🟡 Logs Not Appearing

**Symptoms:**
- No logs in Loki datasource
- Container logs not collected

**Quick Check:**
```bash
# Test Loki directly
curl -s "http://loki.local:3100/loki/api/v1/query?query={job=\"docker\"}" | jq '.status'
```

**Solutions:**
1. **Docker labels missing:**
   ```yaml
   # Add to your service in docker-compose
   labels:
     - prometheus.io.scrape=true
     - prometheus.io.job=my-service
   ```

2. **Loki pipeline blocked:**
   ```bash
   docker logs loki-local | grep -i error | tail -10
   # Common fix: restart
   docker restart loki-local
   ```

---

## Performance Bottlenecks

### CPU Spikes
```bash
# Identify culprit
docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}" | sort -k2 -hr

# Usually caused by:
# 1. Graphiti memory loops → restart gtd-coach-1
# 2. Query storms → check dashboard refresh rates
# 3. Scrape interval too aggressive → increase to 30s minimum
```

### Network Issues
```bash
# Check container network connectivity
docker exec grafana-local ping -c 1 prometheus.local
docker exec grafana-alloy curl -s http://prometheus:9090/api/v1/query?query=up

# Fix network isolation
docker network connect observability <container-name>
```

### Disk Space
```bash
# Check volume usage
docker system df -v | grep grafana

# Clean up if needed
docker compose -f docker-compose.grafana.yml down
docker volume prune -f
docker compose -f docker-compose.grafana.yml up -d
```

## Emergency Recovery

### Complete Reset
```bash
# ⚠️  This deletes all data
cd /Users/adeel/Documents/1_projects/grafana-orbstack
docker compose -f docker-compose.grafana.yml down -v
docker compose -f docker-compose.grafana.yml up -d

# Wait for health
sleep 30
docker ps | grep grafana-orbstack
```

### Selective Service Restart
```bash
# Restart just problematic service
docker compose -f docker-compose.grafana.yml restart alloy
# or
docker compose -f docker-compose.grafana.yml restart prometheus
```

### Export Critical Dashboards
```bash
# Before reset, save dashboards
curl -s http://admin:admin@grafana.local:3001/api/dashboards/uid/ai-ops-unified | \
  jq '.dashboard' > dashboard-backup.json
```

## Common PromQL Queries

```promql
# Tool invocation rate
rate(mcp_tool_invocations_total[5m])

# Memory operation patterns
sum by(operation) (rate(mcp_memory_operations_total[1m]))

# Cache hit ratio
redis_keyspace_hits_total / (redis_keyspace_hits_total + redis_keyspace_misses_total)

# P95 latency
histogram_quantile(0.95, rate(mcp_tool_duration_bucket[5m]))

# Error rate
rate(mcp_errors_total[5m]) / rate(mcp_tool_invocations_total[5m])

# Active requests
mcp_active_requests

# Container memory usage
container_memory_usage_bytes{name=~".*grafana.*"} / 1024 / 1024
```

## Verification Commands

```bash
# All services healthy?
for service in grafana prometheus tempo loki alloy; do
  echo -n "$service: "
  docker ps | grep -q "$service-" && echo "✓" || echo "✗"
done

# Metrics endpoints accessible?
for endpoint in prometheus:9090 tempo:3200 loki:3100 alloy:12345; do
  echo -n "$endpoint: "
  curl -s -o /dev/null -w "%{http_code}" http://$endpoint/ready | grep -q "200" && echo "✓" || echo "✗"
done

# Recent errors in logs?
for container in grafana-local prometheus-local tempo-local loki-local grafana-alloy; do
  echo "$container errors:"
  docker logs $container 2>&1 | grep -i error | tail -2
done
```

## Related Resources
- [AI Operations Guide](AI-OPERATIONS-GUIDE.md) - Operational patterns and thresholds
- [Technical Documentation](../dev/README.md) - Architecture and configuration details
- [Grafana Troubleshooting](https://grafana.com/docs/grafana/latest/troubleshooting/) - Official docs