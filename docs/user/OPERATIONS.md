# Operations Guide

Consolidated guide for operating and troubleshooting the AI observability stack.

## Quick Start

```bash
# Start stack
docker compose -f docker-compose.grafana.yml up -d

# Verify health
curl -s http://prometheus.local:9090/api/v1/query?query=up | jq '.data.result[].metric.job'

# Open Grafana
open http://grafana.local  # admin/admin
```

## Visual Pattern Recognition

### 🔴 Memory Loop Pattern
**Visual**: Rapid red/yellow alternating bars in memory operations panel
**Metric**: >120 operations/minute
**Query**:
```promql
rate(mcp_memory_operations_total[1m]) > 2
```
**Fix**: Restart service or clear GraphRAG state

### 🟡 Slow Response Pattern
**Visual**: Latency graph trending upward
**Metric**: P95 >5 seconds
**Query**:
```promql
histogram_quantile(0.95, mcp_tool_duration_bucket)
```
**Fix**: Check downstream services, resource constraints

### 🔵 Resource Saturation
**Visual**: CPU/Memory approaching limits
**Metric**: Container memory >80% of limit
**Query**:
```promql
container_memory_usage_bytes / container_spec_memory_limit_bytes > 0.8
```
**Fix**: Scale resources or optimize queries

## Dashboard Navigation

### AI Operations Dashboard
- **URL**: http://grafana.local/d/ai-ops-unified/
- **Key Panels**:
  - Tool invocation rate (top left)
  - Memory operations (top right)
  - Latency percentiles (middle)
  - Resource usage (bottom)

### Trace Explorer
- **URL**: http://grafana.local/explore?datasource=tempo
- **Search by**:
  - Trace ID from Langfuse
  - Service name
  - Operation name
  - Duration >5s

## Common Issues & Solutions

### No Metrics Appearing
```bash
# Check scrape targets
curl http://prometheus.local/targets

# Verify OTLP receiving data
curl http://alloy.local:4318/v1/metrics
```

### Traces Not Correlating
- Ensure trace IDs match W3C format
- Check time sync between services
- Verify OTLP endpoints in both systems

### High Memory Usage
```bash
# Check which container
docker stats --no-stream

# Inspect specific container
docker inspect <container> | jq '.[0].HostConfig.Memory'
```

### Container Restart Loop
```bash
# Check logs
docker logs <container> --tail 100

# Common fixes:
docker compose down
docker volume prune  # WARNING: Removes data
docker compose up -d
```

## Monitoring Queries

### Essential Metrics
```promql
# Tool usage rate
sum(rate(mcp_tool_invocations_total[5m])) by (tool)

# Error rate
sum(rate(mcp_tool_invocations_total{status="error"}[5m]))

# Active requests
mcp_active_requests

# Cache efficiency
rate(redis_keyspace_hits_total[5m]) / rate(redis_commands_processed_total{cmd="get"}[5m])
```

### Alert Conditions
| Condition | Query | Threshold |
|-----------|-------|-----------|
| Memory Loop | `rate(mcp_memory_operations_total[1m])` | >2/sec |
| High Latency | `histogram_quantile(0.95, mcp_tool_duration_bucket)` | >5s |
| Low Cache Hit | `redis_keyspace_hits_ratio` | <0.7 |
| Resource Limit | `container_memory_usage_bytes/limit` | >0.9 |

## Backup Operations

### Quick Backup
```bash
make backup-snapshot  # SQLite only
make backup-all      # Complete backup
```

### Restore
```bash
make backup-restore  # Interactive
make backup-status   # Check health
```

See [Backup Quick Reference](../../backup/QUICK-REFERENCE.md) for details.

## Integration Points

### With Langfuse
- Traces share IDs via OTLP
- Find slow LLM call → Get tempo_trace_id → Query infrastructure

### With MCP Servers
- All tools auto-instrumented
- Context propagated through calls
- Performance baselines enforced

## Emergency Procedures

### Complete Reset
```bash
docker compose down
docker volume rm $(docker volume ls -q | grep grafana-orbstack)
docker compose up -d
```

### Export Current State
```bash
# Dashboards
curl -s http://grafana.local/api/dashboards/db/ai-ops-unified | jq . > dashboard-backup.json

# Metrics snapshot
curl -s http://prometheus.local/api/v1/query_range?query=up > metrics-backup.json
```

## Performance Tuning

### Reduce Memory Usage
- Lower retention: Edit docker-compose.grafana.yml
- Reduce scrape frequency: Edit config/alloy-config.alloy
- Disable unused exporters

### Improve Query Speed
- Add recording rules for common queries
- Use downsampling for historical data
- Index high-cardinality labels properly

## External Resources

- [Grafana Docs](https://grafana.com/docs/)
- [Tempo Troubleshooting](https://grafana.com/docs/tempo/latest/troubleshooting/)
- [Prometheus Best Practices](https://prometheus.io/docs/practices/)