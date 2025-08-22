# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Start observability stack
docker compose -f docker-compose.grafana.yml up -d

# Health check - verify all exporters are up
curl -s http://prometheus.local:9090/api/v1/query?query=up | jq '.data.result[] | select(.value[1]=="0") | .metric.job' || echo "✅ All exporters up"

# Check AI operations load
curl -s http://prometheus.local:9090/api/v1/query?query='rate(mcp_tool_invocations_total[1m])' | jq '.data.result[0].value[1]' | xargs printf "Tool calls/min: %.0f\n"

# Update service inventory documentation
docs/dev/auto-discovery.sh

# Generate changelog from conventional commits
git cliff --output CHANGELOG.md

# View container logs
docker logs <container-name> --tail 50

# Restart specific service
docker compose -f docker-compose.grafana.yml restart <service>
```

## Architecture

**Data Flow**: AI Services (GTD Coach, Langfuse, FalkorDB, MCP Servers) → Grafana Alloy (OTLP ports 4317/4318) → Storage Backends (Prometheus metrics, Tempo traces, Loki logs) → Grafana visualization

**Service Access**: All services available at `*.local` domains via OrbStack (grafana.local, prometheus.local, tempo.local, loki.local, alloy.local)

**Retention Policies**: Prometheus 90 days, Tempo 30 days, Loki 3 days

**Resource Constraints**: Keep total memory under 4GB normal, 8GB peak

## AI Monitoring Patterns

### MCP Tool Instrumentation
```python
# Use decorator for async functions
@instrument_mcp_tool
async def your_tool_function(param1, param2):
    # Tool logic here
    
# Or use context manager for granular control
with trace_tool_invocation("tool_name", param1=value1):
    # Tool execution
```

### Memory Operation Tracking
```python
# Track GraphRAG/Graphiti operations
trace_memory_operation("search", source="gtd_coach", count=5)
trace_memory_operation("capture", source="coding_assistant", count=1)
```

### Cross-Domain Correlation
```python
# Link GTD tasks to coding solutions
trace_cross_domain_correlation("gtd", "coding", correlation_score=0.85)
```

### Key Metrics to Monitor
- `mcp_tool_invocations_total` - Tool usage patterns (normal: 10-50/min, warning: >100/min)
- `mcp_memory_operations_total` - Memory system activity (normal: 5-30/min, critical: >120/min)
- `redis_keyspace_hits_total` - GraphRAG cache efficiency (normal: >85% hit rate)
- `mcp_active_requests` - Concurrent operations (normal: 0-5, warning: >10)

## Development Workflows

### Adding New Service Monitoring
1. Add exporter to `docker-compose.grafana.yml`:
```yaml
service-exporter:
  container_name: service-exporter
  labels:
    - dev.orbstack.domains=service-exporter.local
  networks:
    - observability
```

2. Add scraper to `config/alloy-config.alloy`:
```alloy
prometheus.scrape "service_name" {
  targets = [{__address__ = "service-exporter:9xxx", job = "service_name"}]
  forward_to = [prometheus.remote_write.local.receiver]
  scrape_interval = "30s"
  // NORMAL: metric <threshold
  // WARNING: metric >threshold  
  // CRITICAL: metric >critical_threshold
}
```

3. Run `docs/dev/auto-discovery.sh` to update documentation

### Dashboard Development
- Dashboards in `/dashboards/*.json` with traffic light thresholds
- Focus on visual pattern recognition for memory loops and slow responses
- Link traces to logs via trace_id, metrics to traces via exemplars

## Troubleshooting Queries

```promql
# AI operations rate
rate(mcp_tool_invocations_total[1m])

# Memory loop detection - sudden spikes indicate loops
rate(mcp_memory_operations_total[1m]) > 2

# GraphRAG cache performance
rate(redis_keyspace_hits_total[5m]) / rate(redis_commands_processed_total{cmd="get"}[5m])

# Service health matrix
up{job=~".*exporter|prometheus|alloy"}

# Container resource usage
container_memory_usage_bytes{name=~"grafana-.*"} / 1024 / 1024 / 1024
```

## Key Files and Patterns

- **OTLP Instrumentation**: `/mcp-instrumentation/otel_wrapper.py` - Python wrapper for MCP servers
- **Alloy Pipeline**: `/config/alloy-config.alloy` - OTLP receiver → batch processor → exporters
- **Dashboards**: `/dashboards/ai-operations-unified.json` - Main AI operations dashboard
- **Operational Guide**: `/docs/user/AI-OPERATIONS-GUIDE.md` - Visual patterns and debug scenarios

## Commit Standards

Use conventional commits with git-cliff for changelog generation:
- `feat:` New features
- `fix:` Bug fixes  
- `docs:` Documentation changes
- `refactor:` Code refactoring
- `test:` Test additions/changes
- `chore:` Maintenance tasks

## Important Notes

- This is a development/monitoring stack, not a production deployment
- All inline operational documentation in configs should be preserved
- Auto-discovery script maintains service inventory - don't manually edit that section in docs/dev/README.md
- Memory loop detection relies on rate changes in `mcp_memory_operations_total`
- Cross-domain correlation tracking helps identify when GTD insights apply to coding tasks