# Trace Correlation Guide

Link traces between Langfuse and Grafana Tempo for complete observability.

## Core Concepts

### Trace ID Propagation
Both systems support W3C Trace Context standard:
- **Format**: 32 hex characters (128-bit)
- **Header**: `traceparent: 00-{trace_id}-{span_id}-{flags}`

### Context Carriers
- **HTTP**: Headers
- **MCP**: Tool parameters
- **Async**: Message metadata

## Implementation Patterns

### Pattern 1: Dual Instrumentation
```python
from langfuse.decorators import observe, langfuse_context
from opentelemetry import trace, baggage
from opentelemetry.trace import Status, StatusCode
from otel_wrapper import instrument_mcp_tool

# Get OTel tracer
tracer = trace.get_tracer(__name__)

@observe()  # Langfuse decorator
@instrument_mcp_tool  # OTel decorator
async def search_memory(query: str, filters: dict = None):
    """Captured in both Langfuse and Tempo"""
    
    # Get current OTel span
    current_span = trace.get_current_span()
    span_context = current_span.get_span_context()
    
    # Add OTel trace ID to Langfuse
    langfuse_context.update_current_trace(
        metadata={
            "tempo_trace_id": format(span_context.trace_id, '032x'),
            "tempo_span_id": format(span_context.span_id, '016x')
        }
    )
    
    # Add Langfuse ID to OTel span
    if langfuse_trace := langfuse_context.get_current_trace():
        current_span.set_attribute("langfuse.trace_id", langfuse_trace.id)
        baggage.set_baggage("langfuse_trace_id", langfuse_trace.id)
    
    # Your tool logic
    results = await perform_search(query, filters)
    return results
```

### Pattern 2: Manual Correlation
```python
def correlate_traces(langfuse_trace_id: str, otel_trace_id: str):
    """Create bidirectional link between trace systems"""
    
    # Update Langfuse trace
    langfuse.trace(
        id=langfuse_trace_id,
        metadata={"tempo_trace_id": otel_trace_id}
    )
    
    # Add event to OTel span
    span = trace.get_current_span()
    span.add_event(
        "Correlated with Langfuse",
        attributes={"langfuse.trace_id": langfuse_trace_id}
    )
    
    # Store correlation for queries
    return {
        "langfuse_url": f"http://langfuse.local/trace/{langfuse_trace_id}",
        "tempo_url": f"http://grafana.local/explore?traceID={otel_trace_id}"
    }
```

### Pattern 3: Async Context Propagation
```python
import asyncio
from contextvars import ContextVar

# Context variables maintain trace context across async boundaries
trace_context = ContextVar('trace_context', default={})

async def parent_operation():
    # Set context
    ctx = {
        'langfuse_id': langfuse_context.get_current_trace().id,
        'otel_trace_id': format(trace.get_current_span().get_span_context().trace_id, '032x')
    }
    trace_context.set(ctx)
    
    # Spawn async tasks
    tasks = [
        process_chunk(chunk, i) 
        for i, chunk in enumerate(data_chunks)
    ]
    await asyncio.gather(*tasks)

async def process_chunk(chunk, index):
    # Retrieve context
    ctx = trace_context.get()
    
    # Create child span with parent context
    with tracer.start_as_current_span(f"process_chunk_{index}") as span:
        span.set_attribute("parent.langfuse_id", ctx['langfuse_id'])
        span.set_attribute("parent.otel_trace_id", ctx['otel_trace_id'])
        # Process...
```

## Service Mesh Correlation

### MCP Server to Service
```python
class InstrumentedMCPServer:
    def __init__(self):
        self.tracer = trace.get_tracer("mcp-server")
    
    async def handle_tool_call(self, tool_name: str, params: dict):
        # Extract trace context from params if provided
        trace_parent = params.pop('_trace_parent', None)
        
        # Start span with parent context
        with self.tracer.start_as_current_span(
            f"mcp.{tool_name}",
            context=extract_context(trace_parent)
        ) as span:
            # Set standard attributes
            span.set_attributes({
                "mcp.tool": tool_name,
                "mcp.params": json.dumps(params),
                "service.name": "mcp-server"
            })
            
            # Call downstream services
            if tool_name == "search":
                await self.call_elasticsearch(params, span)
            elif tool_name == "compute":
                await self.call_compute_service(params, span)
    
    async def call_elasticsearch(self, params, parent_span):
        # Propagate context to downstream service
        headers = {}
        inject_trace_context(headers)
        
        async with aiohttp.ClientSession() as session:
            async with session.post(
                "http://elasticsearch:9200/_search",
                headers=headers,
                json=params
            ) as response:
                parent_span.set_attribute("elasticsearch.status", response.status)
```

## Grafana Queries

### Find Correlated Traces
```promql
# Find all spans with specific Langfuse trace ID
{langfuse.trace_id="lf_abc123"}

# Find slow operations from Langfuse traces
histogram_quantile(0.95,
  sum(rate(mcp_tool_duration_bucket[5m])) by (le, langfuse_trace_id)
)
```

### TraceQL Examples
```traceql
# Find traces that include both Langfuse and MCP spans
{ .langfuse.trace_id != "" && .mcp.tool != "" }

# Find traces with memory loops
{ .mcp.tool = "memory_search" } | count() > 10

# Correlate slow LLM calls with infrastructure
{ .langfuse.model = "gpt-4" && duration > 5s }
```

## Debugging Workflows

### Workflow 1: Slow LLM Response
1. Identify in Langfuse: Response >5s
2. Get tempo_trace_id from metadata
3. Query Tempo:
   ```traceql
   { trace:id = "abc123" }
   ```
4. Analyze waterfall for bottlenecks

### Workflow 2: Memory Loop Detection
```python
def detect_memory_loop(trace_id: str) -> bool:
    """Check if trace shows memory loop pattern"""
    
    # Query Tempo for span count
    query = f'{{ trace:id = "{trace_id}" && name = "memory_search" }}'
    spans = tempo_client.search(query)
    
    if len(spans) > 50:
        # Alert on potential loop
        alert_memory_loop(trace_id, len(spans))
        return True
    return False
```

### Workflow 3: Cost Attribution
```python
def calculate_trace_cost(langfuse_id: str, tempo_id: str):
    """Combine LLM costs with infrastructure costs"""
    
    # Get LLM costs from Langfuse
    llm_cost = langfuse.get_trace_cost(langfuse_id)
    
    # Get infrastructure metrics from Prometheus
    query = f'sum(rate(container_cpu_usage_seconds_total{{trace_id="{tempo_id}"}}[5m]))'
    cpu_usage = prometheus.query(query)
    
    # Calculate total
    return {
        "llm_tokens": llm_cost["tokens"],
        "llm_cost_usd": llm_cost["cost"],
        "cpu_seconds": cpu_usage,
        "estimated_compute_cost": cpu_usage * 0.0001  # $/cpu-second
    }
```

## Best Practices

### DO:
- Always propagate trace context through async boundaries
- Use baggage for cross-cutting concerns
- Set sampling rates appropriately (100% dev, 10% prod)
- Include service.name in all spans
- Use semantic conventions for attributes

### DON'T:
- Store sensitive data in trace attributes
- Create spans for trivial operations (<10ms)
- Use high-cardinality attributes (user IDs, etc.)
- Forget to handle trace context in error paths
- Mix trace ID formats between systems

## Troubleshooting

### Missing Correlations
```bash
# Verify OTLP is receiving traces
curl -X POST http://alloy.local:4318/v1/traces \
  -H "Content-Type: application/json" \
  -d '{"resourceSpans":[]}'

# Check Langfuse OTLP endpoint
curl http://langfuse.local/api/public/otel/v1/traces
```

### Context Loss in Async
```python
# Use contextvars to maintain context
from contextvars import copy_context

ctx = copy_context()
await ctx.run(async_function)
```

### Performance Impact
- Reduce sampling: `TraceIdRatioBased(0.1)`  # 10% sampling
- Use head sampling for high-volume endpoints
- Batch span exports: `BatchSpanProcessor(export_interval_millis=5000)`

## References

- [W3C Trace Context](https://www.w3.org/TR/trace-context/)
- [OpenTelemetry Python Context](https://opentelemetry.io/docs/languages/python/instrumentation/#context-propagation)
- [Langfuse Trace IDs](https://langfuse.com/docs/observability/features/trace-ids-and-distributed-tracing)