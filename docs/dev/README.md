# Grafana Observability Stack - Developer Reference

## Quick Links

- **[MCP Instrumentation](./MCP-INSTRUMENTATION.md)** - OpenTelemetry for MCP servers
- **[Trace Correlation](./TRACE-CORRELATION-GUIDE.md)** - Link Langfuse and Tempo traces
- **[Operations](../user/OPERATIONS.md)** - Troubleshooting and patterns

## Service Inventory

| Service | Domain | Port | Purpose |
|---------|--------|------|---------|
| Grafana | grafana.local | 3001 | Visualization |
| Prometheus | prometheus.local | 9090 | Metrics storage |
| Tempo | tempo.local | 3200 | Distributed tracing |
| Loki | loki.local | 3100 | Log aggregation |
| Alloy | alloy.local | 4317/4318 | OTLP collector |

## Configuration Deltas from Defaults

### Key Metrics
- `mcp_tool_invocations_total` - MCP tool usage (Normal: 10-50/min)
- `mcp_memory_operations_total` - GraphRAG ops (Warning: >120/min indicates loops)
- `redis_keyspace_hits_total` - Cache efficiency (Should be >85%)

See [MCP Instrumentation](./MCP-INSTRUMENTATION.md) for complete baselines.

### Custom Configuration
- **Retention**: Prometheus 90d, Tempo 30d, Loki 3d
- **OTLP**: Ports 4317 (gRPC) and 4318 (HTTP)
- **Scrape Intervals**: 15-30s depending on service
- **Batch Processing**: 5s export interval
- Loki: Default (3 days)

### Scrape Intervals
- FalkorDB metrics: 15s
- Netdata metrics: 30s
- ClickHouse metrics: 30s
- Self-monitoring: 30s

## Adding Services

1. Add exporter to `docker-compose.grafana.yml`
2. Add scraper to `config/alloy-config.alloy`
3. Run `docs/dev/auto-discovery.sh` to update inventory

Example patterns in [Integration Examples](../INTEGRATION-EXAMPLES.md).

## Quick Commands

```bash
# Health check
curl -s http://prometheus.local:9090/api/v1/query?query=up | jq .

# Container logs
docker logs grafana-alloy --tail 50

# Restart service
docker compose -f docker-compose.grafana.yml restart <service>
```

## External Resources

- [Grafana Alloy Docs](https://grafana.com/docs/alloy/latest/)
- [OpenTelemetry Semantic Conventions](https://opentelemetry.io/docs/concepts/semantic-conventions/)
- [OrbStack Networking](https://docs.orbstack.dev/docker/domains)