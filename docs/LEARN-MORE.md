# External Resources

Curated links to official documentation, tutorials, and community resources.

## Official Documentation

### Grafana Stack
- [Grafana Documentation](https://grafana.com/docs/grafana/latest/)
- [Tempo Distributed Tracing](https://grafana.com/docs/tempo/latest/)
- [Prometheus Metrics](https://prometheus.io/docs/)
- [Loki Log Aggregation](https://grafana.com/docs/loki/latest/)
- [Grafana Alloy](https://grafana.com/docs/alloy/latest/)

### OpenTelemetry
- [OpenTelemetry Documentation](https://opentelemetry.io/docs/)
- [Python SDK](https://opentelemetry.io/docs/languages/python/)
- [Semantic Conventions](https://opentelemetry.io/docs/concepts/semantic-conventions/)
- [W3C Trace Context](https://www.w3.org/TR/trace-context/)

### MCP (Model Context Protocol)
- [MCP Specification](https://modelcontextprotocol.io/docs)
- [MCP Architecture](https://modelcontextprotocol.io/docs/learn/architecture)
- [MCP GitHub](https://github.com/modelcontextprotocol)
- [MCP OpenTelemetry Proposal](https://github.com/modelcontextprotocol/modelcontextprotocol/discussions/269)

### Langfuse
- [Langfuse Documentation](https://langfuse.com/docs)
- [Trace IDs & Distributed Tracing](https://langfuse.com/docs/observability/features/trace-ids-and-distributed-tracing)
- [OpenTelemetry Integration](https://langfuse.com/integrations/native/opentelemetry)

## Tutorials & Guides

### Distributed Tracing
- [Intro to Distributed Tracing with Tempo](https://grafana.com/blog/2021/09/23/intro-to-distributed-tracing-with-tempo-opentelemetry-and-grafana-cloud/)
- [Distributed Tracing Best Practices](https://grafana.com/docs/tempo/latest/getting-started/best-practices/)
- [TraceQL Query Language](https://grafana.com/docs/tempo/latest/traceql/)

### LLM Observability
- [Mastering LLM Observability: Langfuse vs OpenTelemetry](https://oleg-dubetcky.medium.com/mastering-llm-observability-a-hands-on-guide-to-langfuse-and-opentelemetry-comparison-33f63ce0a636)
- [LLM Observability with OpenTelemetry](https://www.opsmatters.com/videos/perform-distributed-tracing-your-mcp-system-opentelemetry)

### Service Mesh Monitoring
- [End-to-End Distributed Tracing in Kubernetes](https://www.civo.com/learn/distributed-tracing-kubernetes-grafana-tempo-opentelemetry)

## Community Resources

### Blog Posts & Articles
- [A Beginner's Guide to Distributed Tracing](https://grafana.com/blog/2021/01/25/a-beginners-guide-to-distributed-tracing-and-how-it-can-increase-an-applications-performance/)
- [Getting Started with Grafana Tempo](https://www.greasyguide.com/cloud-computing/getting-started-with-grafana-tempo/)
- [OpenTelemetry MCP Server](https://lobehub.com/mcp/liatrio-labs-otel-instrumentation-mcp)

### GitHub Repositories
- [OpenTelemetry Python](https://github.com/open-telemetry/opentelemetry-python)
- [Grafana Tempo](https://github.com/grafana/tempo)
- [MCP Servers](https://github.com/modelcontextprotocol/servers)
- [Langfuse](https://github.com/langfuse/langfuse)

### Tools & Utilities
- [OTEL MCP Server](https://glama.ai/mcp/servers/@ryu1maniwa/opentelemetry-documentation-mcp-server)
- [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/)
- [Jaeger UI](https://www.jaegertracing.io/)

## Quick Reference Cards

### PromQL Queries
```promql
# Tool performance
histogram_quantile(0.95, mcp_tool_duration_bucket)

# Memory operations
rate(mcp_memory_operations_total[1m])

# Service dependencies
sum by(service) (rate(http_requests_total[5m]))
```

### TraceQL Queries
```traceql
# Find slow operations
{duration > 5s}

# Service dependencies
{.service.name = "mcp-server"} | by(.service.downstream)

# Correlated traces
{.langfuse.trace_id != ""}
```

### OTLP Configuration
```yaml
# For Alloy
otlp:
  grpc: localhost:4317
  http: localhost:4318

# For Langfuse
endpoint: /api/public/otel
```

## Related Projects

- [OpenLit](https://github.com/openlit/openlit) - OpenTelemetry-native LLM Observability
- [OpenLLMetry](https://github.com/traceloop/openllmetry) - Open-source observability for LLM applications
- [SigNoz](https://signoz.io/blog/mcp-observability-with-otel/) - MCP Observability with OpenTelemetry

## Video Resources

- [Distributed Tracing for MCP](https://www.opsmatters.com/videos/perform-distributed-tracing-your-mcp-system-opentelemetry)
- [Grafana Tempo Deep Dive](https://www.youtube.com/watch?v=search-for-tempo-tutorials)

## Support & Community

- [Grafana Community Forum](https://community.grafana.com/)
- [OpenTelemetry Slack](https://cloud-native.slack.com/archives/CJFCJHG4Q)
- [MCP Discord](https://discord.gg/mcp-community)
- [Langfuse Discord](https://discord.gg/langfuse)