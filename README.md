# Grafana Observability Stack for AI Infrastructure

Infrastructure observability that **complements Langfuse** for complete AI system visibility. While Langfuse tracks LLM interactions, this stack monitors the distributed systems, service mesh, and infrastructure beneath.

## Why This + Langfuse = Complete Observability

| Layer | Langfuse Provides | This Stack Provides |
|-------|------------------|-------------------|
| **LLM** | Prompts, completions, token usage | - |
| **Application** | LLM call traces, evaluations | Service dependencies, distributed traces |
| **Infrastructure** | - | Container metrics, network I/O, resource usage |
| **Data** | - | GraphRAG performance, cache efficiency |
| **Automation** | - | Backup health, git hook triggers |

**Key Integration**: Both systems share trace IDs via OTLP, enabling end-to-end debugging from LLM call to infrastructure.

## Quick Start (3 Commands)

```bash
# 1. Start the stack
docker compose -f docker-compose.grafana.yml up -d

# 2. Verify health
curl -s http://prometheus.local:9090/api/v1/query?query=up | jq '.data.result[].metric.job'

# 3. Open Grafana
open http://grafana.local  # Login: admin/admin
```

## What Makes This Unique

- **Service Dependency Mapping** - See what calls what in your AI architecture
- **Distributed Transaction Tracing** - Follow requests across MCP servers, databases, and services  
- **Memory Loop Detection** - GraphRAG-specific patterns not visible in LLM traces
- **Infrastructure Correlation** - Link slow AI responses to resource constraints
- **Automated Backup System** - Git-driven configuration management with health monitoring

## Documentation

### 🚀 Getting Started
- **[Quick Start Guide](docs/QUICK-START-COMPLEMENT.md)** - 5-minute setup with Langfuse integration
- **[Trace Correlation](docs/dev/TRACE-CORRELATION-GUIDE.md)** - Link Langfuse and Tempo traces
- **[MCP Instrumentation](docs/dev/MCP-INSTRUMENTATION.md)** - OpenTelemetry for MCP servers

### 📚 References  
- **[Operations Guide](docs/user/OPERATIONS.md)** - Visual patterns and troubleshooting
- **[Integration Examples](docs/INTEGRATION-EXAMPLES.md)** - Real-world scenarios
- **[Learn More](docs/LEARN-MORE.md)** - External resources and documentation

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