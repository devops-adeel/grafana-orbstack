# AI Service Instrumentation Guide

This guide helps developers add OpenTelemetry instrumentation to their AI services for monitoring with the Grafana observability stack.

## Table of Contents
1. [Quick Start](#quick-start)
2. [Installation](#installation)
3. [Basic Setup](#basic-setup)
4. [Instrumentation Patterns](#instrumentation-patterns)
5. [Framework Integration](#framework-integration)
6. [Troubleshooting](#troubleshooting)

## Quick Start

### 1-Minute Setup
```python
# 1. Install dependencies
pip install opentelemetry-distro opentelemetry-exporter-otlp

# 2. Copy otel_wrapper.py to your project
cp /path/to/grafana-orbstack/mcp-instrumentation/otel_wrapper.py ./

# 3. Initialize in your main.py
from otel_wrapper import setup_telemetry, instrument_mcp_tool

# Initialize telemetry
tracer, meter = setup_telemetry("my-ai-service")

# 4. Instrument your functions
@instrument_mcp_tool
async def search_memory(query: str):
    # Your tool logic here
    return results
```

## Installation

### Prerequisites
- Python 3.8+
- Grafana observability stack running (see main README)
- Network access to Alloy collector (`http://alloy.local:4317`)

### Required Packages
```bash
# Core OpenTelemetry packages
pip install \
    opentelemetry-api \
    opentelemetry-sdk \
    opentelemetry-instrumentation \
    opentelemetry-exporter-otlp-proto-grpc

# Optional: Framework-specific instrumentation
pip install \
    opentelemetry-instrumentation-requests \
    opentelemetry-instrumentation-httpx \
    opentelemetry-instrumentation-sqlalchemy
```

### Environment Variables
```bash
# Required
export OTLP_ENDPOINT="http://alloy.local:4317"  # Grafana Alloy endpoint
export MCP_SERVICE_NAME="my-ai-service"          # Your service name

# Optional
export OTEL_LOG_LEVEL="info"                     # Logging level
export OTEL_TRACES_EXPORTER="otlp"              # Trace exporter
export OTEL_METRICS_EXPORTER="otlp"             # Metrics exporter
```

## Basic Setup

### Step 1: Initialize Telemetry

Create `telemetry.py` in your project:

```python
import os
from otel_wrapper import setup_telemetry

# Initialize once at startup
SERVICE_NAME = os.getenv("MCP_SERVICE_NAME", "my-ai-service")
tracer, meter = setup_telemetry(SERVICE_NAME)

# Now available globally
print(f"✅ Telemetry initialized for {SERVICE_NAME}")
print(f"📡 Sending to: {os.getenv('OTLP_ENDPOINT')}")
```

### Step 2: Add to Your Main Application

```python
# main.py or app.py
import asyncio
from telemetry import tracer, meter  # Import initialized telemetry
from otel_wrapper import instrument_mcp_tool, trace_memory_operation

# Your existing code...

@instrument_mcp_tool
async def process_user_query(query: str, context: dict = None):
    """
    Your MCP tool function - automatically traced!
    """
    # Tool logic here
    results = await search_knowledge_base(query)
    
    # Track memory operations
    trace_memory_operation("search", source="user_query", count=len(results))
    
    return results

if __name__ == "__main__":
    # Your app startup
    asyncio.run(main())
```

### Step 3: Verify It's Working

```bash
# Check metrics are being collected
curl http://alloy.local:12345/metrics | grep mcp_

# Check in Prometheus
curl http://prometheus.local:9090/api/v1/query?query=mcp_tool_invocations_total

# View in Grafana
open http://grafana.local
# Login: admin/admin
# Go to Explore → Select Tempo → Search for your service
```

## Instrumentation Patterns

### Pattern 1: MCP Tool Instrumentation

Use the decorator for automatic tracing:

```python
from otel_wrapper import instrument_mcp_tool

@instrument_mcp_tool
async def capture_solution(error: str, solution: str, tags: list = None):
    """
    Automatically traces:
    - Function name as span name
    - Parameters as span attributes
    - Duration as histogram metric
    - Errors with stack traces
    """
    # Your implementation
    doc_id = await store_solution(error, solution, tags)
    return {"id": doc_id, "status": "captured"}
```

### Pattern 2: Context Manager for Fine Control

```python
from otel_wrapper import trace_tool_invocation

async def complex_tool(query: str):
    # Manual tracing with context manager
    with trace_tool_invocation("complex_search", query=query, mode="semantic") as span:
        # Step 1: Preprocessing
        span.add_event("preprocessing_started")
        processed = preprocess_query(query)
        
        # Step 2: Search
        span.add_event("search_started", {"processed_query": processed})
        results = await search_engine.query(processed)
        
        # Step 3: Add metadata
        span.set_attribute("result_count", len(results))
        span.set_attribute("cache_hit", results.from_cache)
        
        return results
```

### Pattern 3: Memory Operations Tracking

```python
from otel_wrapper import trace_memory_operation

# Track GraphRAG/memory operations
def search_knowledge_graph(query: str, limit: int = 10):
    # Your search logic
    results = graph_db.search(query, limit=limit)
    
    # Track the operation
    trace_memory_operation(
        operation="search",
        source="knowledge_graph", 
        count=len(results),
        query=query,
        cache_hit=results.from_cache
    )
    
    return results

def capture_insight(insight: str, domain: str):
    # Store insight
    doc_id = memory_store.add(insight, metadata={"domain": domain})
    
    # Track capture
    trace_memory_operation(
        operation="capture",
        source=domain,
        count=1,
        doc_id=doc_id
    )
```

### Pattern 4: LLM Call Instrumentation

```python
from otel_wrapper import trace_llm_call
import openai

async def generate_response(prompt: str, temperature: float = 0.7):
    async with trace_llm_call("gpt-4", temperature=temperature) as span:
        # Make LLM call
        response = await openai.chat.completions.create(
            model="gpt-4",
            messages=[{"role": "user", "content": prompt}],
            temperature=temperature
        )
        
        # Add token metrics
        span.set_attribute("llm.tokens.prompt", response.usage.prompt_tokens)
        span.set_attribute("llm.tokens.completion", response.usage.completion_tokens)
        span.set_attribute("llm.tokens.total", response.usage.total_tokens)
        
        # Calculate cost (example for GPT-4)
        cost = (response.usage.prompt_tokens * 0.03 + 
                response.usage.completion_tokens * 0.06) / 1000
        span.set_attribute("llm.cost.usd", cost)
        
        return response.choices[0].message.content
```

### Pattern 5: Cross-Domain Correlations

```python
from otel_wrapper import trace_cross_domain_correlation

def apply_gtd_to_code(gtd_insight: str, code_context: str):
    # Your correlation logic
    suggestion = analyze_correlation(gtd_insight, code_context)
    
    if suggestion.confidence > 0.7:
        # Track high-confidence correlations
        trace_cross_domain_correlation(
            domain_from="gtd",
            domain_to="coding",
            correlation_score=suggestion.confidence,
            context=f"Applied: {suggestion.summary}"
        )
        
    return suggestion
```

## Framework Integration

### Langfuse Integration

```python
from langfuse import Langfuse
from langfuse.decorators import observe
from otel_wrapper import tracer

# Initialize Langfuse
langfuse = Langfuse(
    host="https://langfuse.local",
    public_key="your-key",
    secret_key="your-secret"
)

# Combine Langfuse with OpenTelemetry
@observe()  # Langfuse decorator
@instrument_mcp_tool  # OpenTelemetry decorator
async def enhanced_tool(query: str):
    """
    Dual instrumentation:
    - Langfuse: Detailed LLM traces, prompts, evaluations
    - OpenTelemetry: Metrics, distributed tracing, infrastructure correlation
    """
    # Your implementation
    return results
```

### LangChain Integration

```python
from langchain.callbacks import OpenTelemetryCallbackHandler
from otel_wrapper import tracer

# Create callback handler
otel_handler = OpenTelemetryCallbackHandler(tracer)

# Use with LangChain
from langchain.chains import LLMChain

chain = LLMChain(
    llm=llm,
    prompt=prompt,
    callbacks=[otel_handler]  # Automatic tracing
)

result = await chain.arun(input="Your query")
```

### Direct OpenAI Integration

```python
from openai import AsyncOpenAI
from otel_wrapper import trace_llm_call

client = AsyncOpenAI()

async def openai_with_telemetry(prompt: str):
    async with trace_llm_call("gpt-4-turbo", provider="openai") as span:
        # Add prompt to span for debugging (be careful with PII)
        span.set_attribute("llm.prompt.preview", prompt[:100])
        
        response = await client.chat.completions.create(
            model="gpt-4-turbo",
            messages=[{"role": "user", "content": prompt}]
        )
        
        # Add response metadata
        span.set_attribute("llm.response.id", response.id)
        span.set_attribute("llm.response.model", response.model)
        span.set_attribute("llm.tokens.total", response.usage.total_tokens)
        
        return response
```

## Troubleshooting

### No Metrics Appearing

1. **Check Alloy is running:**
```bash
docker ps | grep alloy
curl http://alloy.local:12345/metrics
```

2. **Verify environment variables:**
```python
import os
print(f"OTLP_ENDPOINT: {os.getenv('OTLP_ENDPOINT')}")
print(f"SERVICE_NAME: {os.getenv('MCP_SERVICE_NAME')}")
```

3. **Enable debug logging:**
```python
import logging
logging.basicConfig(level=logging.DEBUG)
logging.getLogger("opentelemetry").setLevel(logging.DEBUG)
```

### High Cardinality Issues

Avoid dynamic values in metric labels:
```python
# ❌ Bad - Creates too many time series
tool_invocation_counter.add(1, {"user_id": user_id})  # Unbounded

# ✅ Good - Limited cardinality
tool_invocation_counter.add(1, {"tool": tool_name})  # Bounded set
```

### Memory Leaks

Ensure spans are properly closed:
```python
# ❌ Bad - Span never closes
span = tracer.start_span("operation")
# Missing span.end()

# ✅ Good - Automatic cleanup
with tracer.start_as_current_span("operation") as span:
    # Span auto-closes when context exits
    pass
```

### Network Issues

Test connectivity:
```bash
# Test OTLP endpoint
telnet alloy.local 4317

# Test with grpcurl
grpcurl -plaintext alloy.local:4317 list

# Send test span
opentelemetry-instrument \
    --traces_exporter otlp \
    --exporter_otlp_endpoint http://alloy.local:4317 \
    python -c "print('Test')"
```

## Best Practices

1. **Service Naming**: Use consistent, descriptive service names
   - ✅ `mcp-memory-search`, `ai-code-assistant`
   - ❌ `service1`, `test`, `my-app`

2. **Attribute Naming**: Follow semantic conventions
   - ✅ `mcp.tool.name`, `llm.model`, `memory.operation`
   - ❌ `toolName`, `MODEL`, `op`

3. **Error Handling**: Always record exceptions
   ```python
   try:
       result = risky_operation()
   except Exception as e:
       span.record_exception(e)
       span.set_status(Status(StatusCode.ERROR))
       raise
   ```

4. **Sampling**: Configure for production
   ```python
   from opentelemetry.sdk.trace.sampling import TraceIdRatioBased
   
   # Sample 10% of traces in production
   sampler = TraceIdRatioBased(0.1)
   ```

5. **Correlation**: Link related operations
   ```python
   # Get current trace context
   from opentelemetry import trace
   current_span = trace.get_current_span()
   trace_id = current_span.get_span_context().trace_id
   
   # Pass to async jobs, logs, etc.
   logger.info(f"Processing job", extra={"trace_id": trace_id})
   ```

## Next Steps

1. **View Your Traces**: Open http://grafana.local → Explore → Tempo
2. **Create Dashboards**: Import from `/dashboards/ai-operations-unified.json`
3. **Set Up Alerts**: See `docs/user/TROUBLESHOOTING.md` for alert queries
4. **Correlate with Containers**: Your traces now link to container metrics via cAdvisor

## Support

- **Issues**: Check container logs: `docker logs grafana-alloy`
- **Examples**: See `/mcp-instrumentation/examples/` directory
- **Metrics Reference**: `docs/dev/API-REFERENCE.md`