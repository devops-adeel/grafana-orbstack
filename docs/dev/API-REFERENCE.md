# OpenTelemetry Instrumentation API Reference

Complete API documentation for the AI service instrumentation library.

## Core Functions

### `setup_telemetry(service_name: str) -> tuple[Tracer, Meter]`

Initialize OpenTelemetry with OTLP export to Grafana Alloy.

**Parameters:**
- `service_name` (str): Name of your service (e.g., "mcp-memory", "ai-assistant")

**Returns:**
- `tuple[Tracer, Meter]`: OpenTelemetry tracer and meter instances

**Environment Variables:**
- `OTLP_ENDPOINT`: Collector endpoint (default: "http://alloy.local:4317")
- `MCP_SERVICE_NAME`: Override service name

**Example:**
```python
from otel_wrapper import setup_telemetry

tracer, meter = setup_telemetry("my-ai-service")
```

---

## Decorators

### `@instrument_mcp_tool`

Automatically instrument MCP tool functions with tracing and metrics.

**Supports:** Both sync and async functions

**Captured Data:**
- Span name: `mcp.tool.{function_name}`
- Duration histogram: `mcp.tool.duration`
- Invocation counter: `mcp.tool.invocations`
- Error traces with stack traces
- Function parameters as span attributes

**Example:**
```python
@instrument_mcp_tool
async def search_memory(query: str, limit: int = 10) -> list:
    # Automatically traced
    results = await db.search(query, limit)
    return results
```

**Span Attributes Added:**
- `mcp.tool.name`: Function name
- `mcp.service`: Service name
- `mcp.param.*`: All function parameters

---

## Context Managers

### `trace_tool_invocation(tool_name: str, **kwargs)`

Context manager for manual tool tracing with fine control.

**Parameters:**
- `tool_name` (str): Name of the tool being invoked
- `**kwargs`: Additional attributes to record

**Yields:**
- `Span`: OpenTelemetry span for adding custom attributes/events

**Example:**
```python
with trace_tool_invocation("complex_search", query=query) as span:
    # Preprocessing
    span.add_event("preprocessing_started")
    processed = preprocess(query)
    
    # Search
    results = search(processed)
    span.set_attribute("result_count", len(results))
    
    return results
```

---

### `async trace_llm_call(model: str, provider: str = "openai", **kwargs)`

Async context manager for tracing LLM API calls.

**Parameters:**
- `model` (str): Model identifier (e.g., "gpt-4", "claude-3")
- `provider` (str): LLM provider (default: "openai")
- `**kwargs`: Model parameters (temperature, max_tokens, etc.)

**Yields:**
- `Span`: Span for adding token counts and costs

**Example:**
```python
async with trace_llm_call("gpt-4", temperature=0.7) as span:
    response = await openai.chat.completions.create(...)
    
    # Add token metrics
    span.set_attribute("llm.tokens.prompt", response.usage.prompt_tokens)
    span.set_attribute("llm.tokens.completion", response.usage.completion_tokens)
    span.set_attribute("llm.tokens.total", response.usage.total_tokens)
```

**Automatic Attributes:**
- `llm.model`: Model name
- `llm.provider`: Provider name
- `llm.param.*`: Model parameters
- `llm.latency_ms`: Request duration

---

## Tracing Functions

### `trace_memory_operation(operation: str, source: str, count: int = 1, **kwargs)`

Track GraphRAG/memory system operations.

**Parameters:**
- `operation` (str): Operation type ("search", "capture", "update", "delete")
- `source` (str): Source system ("gtd_coach", "coding_assistant", etc.)
- `count` (int): Number of items affected (default: 1)
- `**kwargs`: Additional attributes to record

**Metrics Updated:**
- `mcp.memory.operations`: Counter by operation and source

**Example:**
```python
# Track search operation
trace_memory_operation("search", 
                      source="knowledge_graph",
                      count=5,
                      query="docker errors",
                      cache_hit=True)

# Track capture operation  
trace_memory_operation("capture",
                      source="user_insight", 
                      count=1,
                      concept="performance optimization")
```

---

### `trace_cross_domain_correlation(domain_from: str, domain_to: str, correlation_score: float, context: str = "")`

Track correlations between different AI domains.

**Parameters:**
- `domain_from` (str): Source domain (e.g., "gtd", "memory")
- `domain_to` (str): Target domain (e.g., "coding", "planning")
- `correlation_score` (float): Correlation strength (0.0 to 1.0)
- `context` (str): Optional description of the correlation

**Example:**
```python
trace_cross_domain_correlation(
    domain_from="gtd",
    domain_to="coding",
    correlation_score=0.85,
    context="Applied GTD principle to refactor module structure"
)
```

---

## Metrics

### Counters

#### `mcp.tool.invocations`
Total number of tool invocations.

**Labels:**
- `tool`: Tool name

**Usage:**
```promql
rate(mcp_tool_invocations_total[5m])
```

#### `mcp.memory.operations`
Count of memory operations.

**Labels:**
- `operation`: Operation type (search, capture, update, delete)
- `source`: Source system

**Usage:**
```promql
sum by (operation) (rate(mcp_memory_operations_total[5m]))
```

### Histograms

#### `mcp.tool.duration`
Tool execution duration in milliseconds.

**Labels:**
- `tool`: Tool name

**Buckets:** 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000 ms

**Usage:**
```promql
histogram_quantile(0.95, mcp_tool_duration_bucket)
```

### Gauges

#### `mcp.active_requests`
Number of currently active MCP requests.

**Labels:**
- `service`: Service name

**Usage:**
```promql
mcp_active_requests
```

---

## Span Attributes

### Standard Attributes

All spans include:
- `service.name`: Service identifier
- `service.version`: Service version
- `deployment.environment`: Environment (default: "orbstack")

### MCP Tool Attributes
- `mcp.tool.name`: Tool function name
- `mcp.service`: MCP service name
- `mcp.param.*`: Tool parameters

### LLM Attributes
- `llm.model`: Model identifier
- `llm.provider`: Provider name
- `llm.tokens.prompt`: Input token count
- `llm.tokens.completion`: Output token count
- `llm.tokens.total`: Total tokens
- `llm.latency_ms`: Request duration
- `llm.cost.usd`: Estimated cost in USD

### Memory Attributes
- `memory.operation`: Operation type
- `memory.source`: Source system
- `memory.count`: Items affected
- `memory.*`: Custom attributes

### Correlation Attributes
- `correlation.from`: Source domain
- `correlation.to`: Target domain
- `correlation.score`: Correlation strength (0.0-1.0)
- `correlation.context`: Description

---

## Environment Variables

### Required
- `OTLP_ENDPOINT`: OTLP gRPC endpoint (default: "http://alloy.local:4317")
- `MCP_SERVICE_NAME`: Service name for telemetry

### Optional
- `OTEL_LOG_LEVEL`: Logging level (debug, info, warning, error)
- `OTEL_TRACES_EXPORTER`: Trace exporter type (default: "otlp")
- `OTEL_METRICS_EXPORTER`: Metrics exporter type (default: "otlp")
- `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT`: Capture prompts/responses (default: false)

---

## Error Handling

All instrumentation functions handle errors gracefully:

1. **Decorator Errors**: Logged but don't affect function execution
2. **Span Errors**: Recorded with `span.record_exception()`
3. **Network Errors**: Buffered and retried by BatchSpanProcessor

**Example Error Handling:**
```python
@instrument_mcp_tool
async def risky_operation():
    try:
        result = await external_api_call()
        return result
    except Exception as e:
        # Automatically recorded by decorator
        # Re-raise to maintain function behavior
        raise
```

---

## Performance Considerations

### Overhead
- **Span Creation**: ~0.1ms per span
- **Attribute Setting**: ~0.01ms per attribute
- **Network Export**: Async, batched every 5 seconds

### Optimization Tips

1. **Batch Operations:**
```python
# Instead of multiple traces
for item in items:
    trace_memory_operation("capture", "batch", 1)  # ❌

# Single trace with count
trace_memory_operation("capture", "batch", len(items))  # ✅
```

2. **Sampling in Production:**
```python
from opentelemetry.sdk.trace.sampling import TraceIdRatioBased

# Sample 10% of traces
sampler = TraceIdRatioBased(0.1)
```

3. **Limit Attribute Size:**
```python
# Truncate large values
span.set_attribute("query", query[:200])  # Limit to 200 chars
```

---

## Integration Examples

### With FastAPI
```python
from fastapi import FastAPI
from otel_wrapper import setup_telemetry, instrument_mcp_tool

app = FastAPI()
tracer, meter = setup_telemetry("api-service")

@app.post("/search")
@instrument_mcp_tool
async def search_endpoint(query: str):
    # Automatically traced
    return {"results": await search(query)}
```

### With Background Jobs
```python
from celery import Celery
from opentelemetry import trace
from otel_wrapper import trace_tool_invocation

@app.task
def background_task(trace_id: str):
    # Continue trace from parent
    ctx = trace.set_span_in_context(trace_id)
    
    with trace_tool_invocation("background_job"):
        # Job logic
        pass
```

### With Streaming Responses
```python
async def stream_with_telemetry(prompt: str):
    async with trace_llm_call("gpt-4") as span:
        stream = await openai.chat.completions.create(
            model="gpt-4",
            messages=[{"role": "user", "content": prompt}],
            stream=True
        )
        
        tokens = 0
        async for chunk in stream:
            tokens += 1
            yield chunk.choices[0].delta.content
        
        span.set_attribute("llm.tokens.streamed", tokens)
```

---

## Grafana Queries

### Find Slow Tools
```promql
histogram_quantile(0.95, 
  sum by (tool, le) (
    rate(mcp_tool_duration_bucket[5m])
  )
) > 1000
```

### Memory Operation Patterns
```promql
sum by (operation) (
  rate(mcp_memory_operations_total[1h])
)
```

### Active Request Monitoring
```promql
max_over_time(mcp_active_requests[5m])
```

### Error Rate by Tool
```promql
sum by (tool) (
  rate(mcp_tool_invocations_total{status="error"}[5m])
) / sum by (tool) (
  rate(mcp_tool_invocations_total[5m])
)
```

---

## Debugging

### Enable Debug Logging
```python
import logging
logging.basicConfig(level=logging.DEBUG)
logging.getLogger("opentelemetry").setLevel(logging.DEBUG)
```

### Test Span Export
```python
from otel_wrapper import tracer

with tracer.start_as_current_span("test") as span:
    span.set_attribute("test", True)
    print(f"Trace ID: {span.get_span_context().trace_id:032x}")
```

### Verify in Grafana
1. Go to http://grafana.local
2. Navigate to Explore → Tempo
3. Search by service name or trace ID
4. Check span attributes and events

---

## Version Compatibility

- **Python**: 3.8+
- **OpenTelemetry**: 1.20.0+
- **Grafana Stack**: 10.0+
- **Alloy**: 1.0+

---

## Links

- [OpenTelemetry Python Docs](https://opentelemetry.io/docs/languages/python/)
- [Semantic Conventions](https://opentelemetry.io/docs/concepts/semantic-conventions/)
- [Grafana Tempo Docs](https://grafana.com/docs/tempo/latest/)
- [OTLP Specification](https://opentelemetry.io/docs/specs/otlp/)