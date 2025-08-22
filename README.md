# Grafana Observability Stack for AI Agents

Comprehensive observability platform for monitoring AI-agentic systems including GTD Coach, Langfuse, FalkorDB, and MCP servers using Grafana, Prometheus, Tempo, and Loki.

## Quick Start

```bash
# Start the observability stack
docker compose -f docker-compose.grafana.yml up -d

# Wait for services to be healthy (about 30 seconds)
docker ps | grep grafana-orbstack

# Open Grafana dashboard
open http://grafana.local
# Login: admin / admin
```

## Architecture

This platform provides unified observability for:
- **AI Agents**: GTD Coach, MCP servers
- **LLM Tracking**: Langfuse observability
- **Graph Database**: FalkorDB (GraphRAG)
- **Knowledge Graphs**: Graphiti-core temporal memory

Data flows through:
1. **Collection**: Grafana Alloy (OTLP receiver on ports 4317/4318)
2. **Storage**: Prometheus (metrics), Tempo (traces), Loki (logs)
3. **Visualization**: Grafana dashboards

## Documentation

### 🚀 Quick Reference
- **[User Quick Reference Cards](docs/user/QUICK-REFERENCE-CARDS.md)** - 🆕 Copy-paste solutions for critical issues
- **[Developer Quick Reference](docs/dev/QUICK-REFERENCE-DEV.md)** - 🆕 API reference, debugging, integration patterns

### 📖 Detailed Guides
- **[Technical Reference](docs/dev/README.md)** - Architecture, service inventory, metrics catalog
- **[AI Operations Guide](docs/user/AI-OPERATIONS-GUIDE.md)** - Operational patterns and debug scenarios
- **[Troubleshooting](docs/user/TROUBLESHOOTING.md)** - Problem-solution reference with queries

## Key Features

- **Unified AI Operations Dashboard** - Single pane of glass for AI agent monitoring
- **Auto-Discovery** - Service inventory updates automatically
- **Visual Pattern Recognition** - Identify memory loops, slow responses, context loss
- **Inline Documentation** - Operational patterns embedded in configs

## Services

| Service | URL | Purpose |
|---------|-----|---------|
| Grafana | http://grafana.local | Visualization dashboard |
| Prometheus | http://prometheus.local | Metrics storage |
| Tempo | http://tempo.local | Distributed tracing |
| Loki | http://loki.local | Log aggregation |
| Alloy | http://alloy.local | OTLP collector |

## Quick Health Check

```bash
# Check all services are running
curl -s http://prometheus.local:9090/api/v1/query?query=up | \
  jq '.data.result[] | select(.value[1]=="0") | .metric.job' || \
  echo "✅ All exporters up"

# Check current AI operations load
curl -s http://prometheus.local:9090/api/v1/query?query='rate(mcp_tool_invocations_total[1m])' | \
  jq '.data.result[0].value[1]' | \
  xargs printf "Tool calls/min: %.0f\n"
```

## Requirements

- Docker with Docker Compose
- OrbStack (for automatic *.local domains)
- 4GB RAM minimum, 8GB recommended

## Configuration

- **Metrics Retention**: 90 days (Prometheus)
- **Trace Retention**: 30 days (Tempo)
- **Log Retention**: 3 days (Loki)
- **Scrape Intervals**: 15-30 seconds

## License

Private project - All rights reserved