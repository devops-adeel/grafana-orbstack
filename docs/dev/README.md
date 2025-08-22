# Grafana Observability Platform - Technical Reference

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         AI Services Layer                        │
├─────────────┬──────────────┬──────────────┬────────────────────┤
│  GTD Coach  │   Langfuse   │   FalkorDB   │   MCP Servers      │
│  (AI Agent) │ (LLM Traces) │  (GraphRAG)  │ (Tool Execution)   │
└──────┬──────┴──────┬───────┴──────┬───────┴────────┬───────────┘
       │             │              │                │
       └─────────────┴──────────────┴────────────────┘
                            │
                    ┌───────▼────────┐
                    │  Grafana Alloy  │ ← OTLP Collector
                    │  (ports 4317/18) │
                    └───────┬────────┘
                            │
        ┌───────────────────┼───────────────────┐
        │                   │                   │
   ┌────▼────┐      ┌──────▼──────┐     ┌─────▼─────┐
   │Prometheus│      │    Tempo    │     │   Loki    │
   │ (Metrics)│      │  (Traces)   │     │  (Logs)   │
   └────┬────┘      └──────┬──────┘     └─────┬─────┘
        │                   │                   │
        └───────────────────┼───────────────────┘
                            │
                    ┌───────▼────────┐
                    │    Grafana     │
                    │  (Port 3001)   │
                    └────────────────┘
```

## Service Inventory

| Service | Container Name | OrbStack Domain | Port | Purpose |
|---------|---------------|-----------------|------|---------|
| Grafana | grafana-local | grafana.local | 3000 | Visualization dashboard |
| Prometheus | prometheus-local | prometheus.local | 9090 | Metrics storage |
| Tempo | tempo-local | tempo.local | 3200 | Distributed tracing |
| Loki | loki-local | loki.local | 3100 | Log aggregation |
| Alloy | grafana-alloy | alloy.local | 4317/4318 | OTLP collector |
| Redis Exporter | redis-exporter | redis-exporter.local | 9121 | FalkorDB metrics |
| ClickHouse Exporter | clickhouse-exporter | clickhouse-exporter.local | 9116 | Langfuse metrics |

## Key Metrics Catalog

### AI Agent Operations
| Metric | Normal Range | Warning | Critical | Location |
|--------|-------------|---------|----------|----------|
| `mcp_tool_invocations_total` | 10-50/min | >100/min | >200/min | MCP servers |
| `mcp_tool_duration_bucket` | P95 <1s | P95 >2s | P95 >5s | Tool latency |
| `mcp_memory_operations_total` | 5-30/min | >60/min | >120/min | Graphiti operations |
| `mcp_active_requests` | 0-5 | >10 | >20 | Concurrent operations |

### GraphRAG Performance
| Metric | Normal Range | Warning | Critical | Location |
|--------|-------------|---------|----------|----------|
| `redis_commands_processed_total` | 100-500/s | >1000/s | >2000/s | FalkorDB queries |
| `redis_keyspace_hits_total` | Hit rate >85% | <70% | <50% | Cache efficiency |
| `redis_memory_used_bytes` | <2GB | >2GB | >3GB | Memory consumption |
| `redis_connected_clients` | 1-10 | >20 | >50 | Connection pool |

### System Resources
| Metric | Normal Range | Warning | Critical | Location |
|--------|-------------|---------|----------|----------|
| Container CPU | <50% | >70% | >90% | All containers |
| Container Memory | <4GB total | >6GB | >8GB | All containers |
| Host CPU (Netdata) | <60% | >80% | >95% | macOS host |
| Network I/O | <10MB/s | >50MB/s | >100MB/s | Container network |

## Configuration Reference

### Grafana Alloy Pipeline
```
OTLP Receiver (4317/4318) → Batch Processor → Exporters
                                                ├── Prometheus (metrics)
                                                ├── Tempo (traces)
                                                └── Loki (logs)
```

### Data Retention
- Prometheus: 90 days (`--storage.tsdb.retention.time=90d`)
- Tempo: 30 days (`block_retention: 720h`)
- Loki: Default (3 days)

### Scrape Intervals
- FalkorDB metrics: 15s
- Netdata metrics: 30s
- ClickHouse metrics: 30s
- Self-monitoring: 30s

## Extension Patterns

### Adding New Service Monitoring

1. **Add Exporter to docker-compose.grafana.yml:**
```yaml
  service-exporter:
    image: exporter/image:latest
    container_name: service-exporter
    labels:
      - dev.orbstack.domains=service-exporter.local
    environment:
      - SERVICE_URL=service-name:port
    networks:
      - observability
```

2. **Add Scraper to alloy-config.alloy:**
```alloy
prometheus.scrape "service_name" {
  targets = [
    {__address__ = "service-exporter:9xxx", job = "service_name"},
  ]
  forward_to = [prometheus.remote_write.local.receiver]
  scrape_interval = "30s"
  // NORMAL: Metric X <threshold
  // WARNING: Metric X >threshold
  // CRITICAL: Metric X >critical_threshold
}
```

3. **Update Service Inventory:**
Run `docs/dev/auto-discovery.sh` to update this README automatically.

### Adding LMStudio Monitoring

```yaml
# 1. Create custom exporter (example using OTLP)
  lmstudio-instrumentation:
    image: python:3.11-slim
    container_name: lmstudio-metrics
    volumes:
      - ./mcp-instrumentation:/app
    environment:
      - OTLP_ENDPOINT=alloy.local:4317
      - LMSTUDIO_API=host.docker.internal:1234  # LMStudio on host
    command: python /app/lmstudio_exporter.py
    # Metrics to collect:
    # - llm.token.usage (consumption rate)
    # - llm.inference.latency (response time)
    # - llm.model.switches (model changes)
    # - llm.context.size (context window usage)
```

### Adding Custom Dashboard Panel

```json
{
  "title": "Your Metric",
  "targets": [
    {
      "expr": "rate(your_metric_total[5m])",
      "legendFormat": "{{label_name}}"
    }
  ],
  "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 }
}
```

## Troubleshooting Quick Reference

### Container Issues
```bash
# Check container status
docker ps | grep grafana-orbstack

# View logs
docker logs <container-name> --tail 50

# Restart specific service
docker compose -f docker-compose.grafana.yml restart <service>
```

### Metric Queries
```bash
# Quick metric check via curl
curl -s "http://prometheus.local:9090/api/v1/query?query=up" | jq .

# Check Alloy is receiving OTLP
curl -s http://alloy.local:12345/metrics | grep otlp_receiver
```

### Common Issues
- **Tempo restarting**: Check volume permissions, path should be `/var/tempo`
- **Alloy config errors**: Validate syntax with `docker logs grafana-alloy`
- **No metrics appearing**: Verify scrape targets are up and network connectivity

## Related Documentation
- [AI Operations Guide](../user/AI-OPERATIONS-GUIDE.md) - User-facing operational guide
- [Troubleshooting](../user/TROUBLESHOOTING.md) - Problem/solution reference
- [Grafana Alloy Docs](https://grafana.com/docs/alloy/latest/) - Official Alloy documentation
- [OrbStack Networking](https://docs.orbstack.dev/docker/domains) - Domain configuration