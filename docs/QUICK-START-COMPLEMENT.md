# Quick Start: Unified AI Observability

This guide shows how Grafana Stack + Langfuse provide complete observability for AI systems in 5 minutes.

## The Complete Picture

```
┌─────────────────────────────────────────────────────────┐
│                   Your AI Application                    │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  [LLM Calls] ──────────────> Langfuse                  │
│      ↓                         (Prompts, Tokens)        │
│  [Trace ID]                                            │
│      ↓                                                  │
│  [MCP Tools] ──────────────> Grafana Stack            │
│      ↓                         (Infrastructure)        │
│  [Services] ───────────────> Tempo + Prometheus       │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

## 5-Minute Setup

### Step 1: Start Infrastructure Stack
```bash
cd /Users/adeel/Documents/1_projects/grafana-orbstack
docker compose -f docker-compose.grafana.yml up -d
```

### Step 2: Configure Dual Instrumentation
```python
# In your MCP server or AI application
from langfuse import Langfuse
from mcp-instrumentation.otel_wrapper import instrument_mcp_tool, tracer

# Initialize both
langfuse = Langfuse()

@langfuse.observe()  # LLM observability
@instrument_mcp_tool  # Infrastructure tracing
async def your_mcp_tool(query: str):
    # Your tool logic
    pass
```

### Step 3: Link Trace IDs
```python
# Share trace context between systems
from opentelemetry import trace

def linked_operation():
    # Get current trace context
    span_context = trace.get_current_span().get_span_context()
    
    # Add to Langfuse
    langfuse.trace(
        metadata={"tempo_trace_id": format(span_context.trace_id, '032x')}
    )
```

### Step 4: Import Dashboards
1. Open http://grafana.local (admin/admin)
2. Go to Dashboards → Import
3. Upload `/dashboards/ai-operations-unified.json`

## Your First Correlated Trace

### Scenario: Debugging Slow AI Response

1. **In Langfuse** (http://langfuse.local):
   - Find slow LLM call (>5s response)
   - Copy trace ID from metadata

2. **In Grafana Tempo** (http://grafana.local):
   ```
   Search: {trace_id="<langfuse_trace_id>"}
   ```
   - See full service waterfall
   - Identify bottleneck (DB query, memory search, etc.)

3. **Correlation Query**:
   ```promql
   # In Grafana, find infrastructure metrics during that trace
   rate(mcp_tool_duration_bucket[1m]) 
     * on(trace_id) group_left() 
     traces{trace_id="<id>"}
   ```

## What You Can Now See

### From Langfuse
- Token usage and costs
- Prompt/completion pairs
- Model performance metrics
- User feedback scores

### From This Stack
- Which services were called
- How long each hop took
- Resource usage during the call
- Network latency impacts
- Cache hit/miss patterns

### Together
- Full request journey from prompt to infrastructure
- Cost vs performance trade-offs
- Root cause of slow responses
- Memory loop patterns in GraphRAG

## Common Integration Patterns

### Pattern 1: Memory Loop Detection
```python
# Detects when GraphRAG gets stuck
from mcp-instrumentation.otel_wrapper import trace_memory_operation

if operation_count > 100:
    span.set_attribute("alert.memory_loop", True)
    span.add_event("Potential memory loop detected")
```

### Pattern 2: Cost Attribution
```python
# Link infrastructure costs to LLM operations
span.set_attributes({
    "langfuse.trace_id": langfuse_trace.id,
    "cost.compute_ms": compute_time,
    "cost.memory_mb": memory_used
})
```

### Pattern 3: Service Dependencies
```python
# Track which MCP tools call which services
with tracer.start_as_current_span("mcp.search") as span:
    span.set_attribute("upstream.service", "falkordb")
    span.set_attribute("downstream.service", "embedding-api")
```

## Quick Verification

```bash
# Check both systems are receiving data
curl -s http://prometheus.local:9090/api/v1/query?query='mcp_tool_invocations_total' | \
  jq '.data.result | length' && echo "Infrastructure: ✓"

curl -s http://langfuse.local/api/public/health | \
  jq '.status' && echo "Langfuse: ✓"
```

## Next Steps

- [Trace Correlation Guide](dev/TRACE-CORRELATION-GUIDE.md) - Advanced correlation techniques
- [MCP Instrumentation](dev/MCP-INSTRUMENTATION.md) - Full instrumentation reference
- [Integration Examples](../INTEGRATION-EXAMPLES.md) - Real-world scenarios

## Troubleshooting

### Traces Not Correlating
- Ensure both systems use the same trace ID format (W3C)
- Check OTLP endpoint configuration in both systems
- Verify time synchronization between services

### Missing Infrastructure Metrics
- Confirm Alloy is receiving OTLP data: `curl http://alloy.local:4318/v1/traces`
- Check scrape targets in Prometheus: http://prometheus.local/targets

### High Memory Usage
- Reduce trace sampling rate in production
- Configure shorter retention periods
- Use head sampling for high-volume services