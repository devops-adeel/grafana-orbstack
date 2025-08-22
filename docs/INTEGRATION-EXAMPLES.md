# Integration Examples

Real-world scenarios showing how to integrate Langfuse + Grafana Stack for complete AI observability.

## Scenario 1: Debugging Slow Memory Search

### Problem
User reports: "My AI assistant takes 10+ seconds to respond when searching memory."

### Solution
```python
# mcp-instrumentation/examples/trace_correlation.py
from langfuse import Langfuse
from opentelemetry import trace, baggage
from otel_wrapper import instrument_mcp_tool, tracer
import time

langfuse = Langfuse()

@langfuse.observe()
@instrument_mcp_tool
async def search_memory_with_correlation(query: str):
    """Memory search with full observability"""
    
    # Start timing
    start = time.time()
    
    # Get trace IDs from both systems
    otel_span = trace.get_current_span()
    otel_trace_id = format(otel_span.get_span_context().trace_id, '032x')
    
    # Link traces
    langfuse.trace(
        name="memory_search",
        metadata={
            "tempo_trace_id": otel_trace_id,
            "query_length": len(query)
        }
    )
    
    # Perform search with instrumentation
    results = await search_graphrag(query)
    
    # Check performance
    duration = time.time() - start
    if duration > 5:  # Threshold breach
        otel_span.add_event("Slow search detected", {
            "duration_seconds": duration,
            "result_count": len(results)
        })
    
    return results

# Query both systems
def debug_slow_search(langfuse_trace_id: str):
    """Find root cause across both systems"""
    
    # Get Langfuse data
    trace = langfuse.get_trace(langfuse_trace_id)
    tempo_id = trace.metadata.get("tempo_trace_id")
    
    # Query Tempo for infrastructure details
    print(f"Langfuse: {trace.latency}ms for {trace.input}")
    print(f"Check Tempo: http://grafana.local/explore?traceID={tempo_id}")
    
    # Query Prometheus for resource usage during trace
    query = f'container_memory_usage_bytes{{trace_id="{tempo_id}"}}'
    print(f"Memory during search: {query}")
```

### Dashboard View
- Langfuse: Shows 10s latency, 500 tokens used
- Tempo: Reveals 9.5s spent in FalkorDB query
- Prometheus: Shows memory spike to 3.5GB during search
- **Root Cause**: GraphRAG index needs optimization

## Scenario 2: Memory Loop Detection

### Problem
AI agent gets stuck in infinite loop when searching for non-existent information.

### Solution
```python
# mcp-instrumentation/examples/memory_loop_detection.py
from collections import defaultdict
import hashlib

class MemoryLoopDetector:
    def __init__(self):
        self.operation_counts = defaultdict(lambda: defaultdict(int))
    
    @instrument_mcp_tool
    async def search_with_loop_detection(self, query: str, session_id: str):
        """Detect and break memory loops"""
        
        # Generate query signature
        sig = hashlib.md5(query.encode()).hexdigest()[:8]
        
        # Track operation count
        self.operation_counts[session_id][sig] += 1
        count = self.operation_counts[session_id][sig]
        
        # Get current span
        span = trace.get_current_span()
        span.set_attribute("loop.count", count)
        span.set_attribute("query.signature", sig)
        
        # Detect loop
        if count > 10:
            span.set_status(Status(StatusCode.ERROR, "Memory loop detected"))
            
            # Alert via Langfuse
            langfuse.score(
                name="memory_loop",
                value=0,  # Failure score
                comment=f"Loop detected: {query} called {count} times"
            )
            
            # Break the loop
            raise Exception(f"Memory loop: Query '{query}' repeated {count} times")
        
        # Add warning annotation
        if count > 5:
            span.add_event("Potential loop forming", {
                "query": query,
                "count": count
            })
        
        # Perform actual search
        return await self.graphrag_search(query)

# Monitoring query
memory_loop_query = """
rate(mcp_memory_operations_total[1m]) > 100
"""
```

## Scenario 3: Service Mesh Dependencies

### Problem
Need to understand which services are called for a specific AI operation.

### Solution
```python
# mcp-instrumentation/examples/mcp_service_mesh.py
from opentelemetry.instrumentation.aiohttp import AioHttpInstrumentor
import aiohttp

# Auto-instrument HTTP calls
AioHttpInstrumentor().instrument()

class ServiceMeshTracer:
    @instrument_mcp_tool
    async def complex_ai_operation(self, prompt: str):
        """Trace through multiple services"""
        
        span = trace.get_current_span()
        
        # Step 1: Get embeddings
        with tracer.start_as_current_span("get_embeddings") as embed_span:
            embed_span.set_attribute("service.downstream", "embedding-api")
            embeddings = await self.call_embedding_service(prompt)
        
        # Step 2: Search vector DB
        with tracer.start_as_current_span("vector_search") as search_span:
            search_span.set_attribute("service.downstream", "qdrant")
            contexts = await self.search_vectors(embeddings)
        
        # Step 3: Query GraphRAG
        with tracer.start_as_current_span("graphrag_query") as graph_span:
            graph_span.set_attribute("service.downstream", "falkordb")
            knowledge = await self.query_graphrag(contexts)
        
        # Step 4: Call LLM
        with tracer.start_as_current_span("llm_completion") as llm_span:
            llm_span.set_attribute("service.downstream", "openai")
            response = await self.call_llm(prompt, knowledge)
        
        # Add service map to trace
        span.set_attributes({
            "service.map": "client→embedding→vector→graph→llm",
            "service.hops": 4,
            "service.total_latency": span.end_time - span.start_time
        })
        
        return response

# Tempo query to see service dependencies
service_query = """
{ .service.downstream != "" } | 
  by(.service.downstream) | 
  count() > 0
"""
```

## Scenario 4: Cost Attribution

### Problem
Need to understand infrastructure costs for specific LLM operations.

### Solution
```python
# mcp-instrumentation/examples/cost_tracking.py
class CostTracker:
    def __init__(self):
        self.cost_meter = meter.create_observable_gauge(
            "ai.operation.cost",
            callbacks=[self.calculate_cost]
        )
    
    @langfuse.observe()
    @instrument_mcp_tool
    async def operation_with_cost_tracking(self, prompt: str):
        """Track both token and infrastructure costs"""
        
        start_time = time.time()
        start_cpu = self.get_cpu_seconds()
        
        # Perform operation
        response = await self.process(prompt)
        
        # Calculate costs
        duration = time.time() - start_time
        cpu_used = self.get_cpu_seconds() - start_cpu
        
        # Get Langfuse costs
        langfuse_trace = langfuse.get_current_trace()
        token_cost = langfuse_trace.cost  # From Langfuse
        
        # Calculate infrastructure cost
        infra_cost = (
            cpu_used * 0.0001 +  # CPU seconds
            duration * 0.00001   # Time-based
        )
        
        # Add to trace
        span = trace.get_current_span()
        span.set_attributes({
            "cost.tokens_usd": token_cost,
            "cost.infrastructure_usd": infra_cost,
            "cost.total_usd": token_cost + infra_cost,
            "cost.cpu_seconds": cpu_used,
            "cost.duration_seconds": duration
        })
        
        return response

# Dashboard query for cost analysis
cost_analysis = """
sum(rate(cost_total_usd[1h])) by (operation)
"""
```

## Scenario 5: Async Context Propagation

### Problem
Losing trace context when spawning async tasks for parallel processing.

### Solution
```python
# mcp-instrumentation/examples/async_context.py
import asyncio
from contextvars import copy_context

class AsyncContextManager:
    @instrument_mcp_tool
    async def parallel_processing(self, items: list):
        """Maintain trace context across async boundaries"""
        
        # Get current context
        ctx = copy_context()
        parent_span = trace.get_current_span()
        langfuse_trace = langfuse.get_current_trace()
        
        # Store in context
        ctx.run(lambda: baggage.set_baggage("langfuse_id", langfuse_trace.id))
        
        async def process_item(item, index):
            """Process with preserved context"""
            # Create child span with parent context
            with tracer.start_as_current_span(
                f"process_item_{index}",
                context=ctx
            ) as span:
                span.set_attributes({
                    "item.index": index,
                    "parent.trace": format(parent_span.get_span_context().trace_id, '032x'),
                    "langfuse.parent": baggage.get_baggage("langfuse_id")
                })
                
                # Process item
                return await self.process(item)
        
        # Run in parallel with context
        tasks = [
            asyncio.create_task(
                ctx.run(process_item, item, i)
            )
            for i, item in enumerate(items)
        ]
        
        results = await asyncio.gather(*tasks)
        return results
```

## Quick Integration Checklist

1. ✅ Both Langfuse and Tempo receiving traces
2. ✅ Trace IDs shared between systems
3. ✅ Context propagation working across async
4. ✅ Service dependencies visible
5. ✅ Cost metrics being collected
6. ✅ Loop detection in place
7. ✅ Performance baselines defined
8. ✅ Dashboards showing correlated data

## References

- [Full Examples Directory](../mcp-instrumentation/examples/)
- [Trace Correlation Guide](dev/TRACE-CORRELATION-GUIDE.md)
- [MCP Instrumentation](dev/MCP-INSTRUMENTATION.md)