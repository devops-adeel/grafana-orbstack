# MCP Instrumentation Guide

OpenTelemetry instrumentation for Model Context Protocol (MCP) servers with performance baselines and state management patterns.

## Performance Baselines

### Tool Latency Thresholds
| Operation Type | P50 | P95 | P99 | Alert |
|---------------|-----|-----|-----|-------|
| Simple Query | <100ms | <500ms | <1s | >5s |
| Memory Search | <200ms | <1s | <2s | >10s |
| LLM Call | <1s | <5s | <10s | >30s |
| File I/O | <50ms | <200ms | <500ms | >2s |
| Network API | <300ms | <1s | <3s | >10s |

### Concurrent Operations
| Metric | Normal | Warning | Critical |
|--------|--------|---------|----------|
| Active Requests | 0-5 | 6-10 | >10 |
| Queue Depth | 0-10 | 11-50 | >50 |
| Memory Operations/min | 5-30 | 31-120 | >120 |

## Basic Instrumentation

```python
#!/usr/bin/env python3
"""MCP server with OpenTelemetry instrumentation"""

from mcp.server import Server
from mcp.server.stdio import stdio_server
from opentelemetry import trace, metrics, baggage
from opentelemetry.trace import Status, StatusCode
import asyncio
import json
from typing import Any, Dict

# Import the instrumentation wrapper
from otel_wrapper import (
    setup_telemetry,
    instrument_mcp_tool,
    trace_memory_operation,
    active_requests
)

# Initialize telemetry
tracer, meter = setup_telemetry("mcp-memory-server")

# Create custom metrics
memory_searches = meter.create_counter(
    "mcp.memory.searches",
    description="Number of memory searches",
    unit="1"
)

search_latency = meter.create_histogram(
    "mcp.memory.search_latency",
    description="Memory search latency",
    unit="ms"
)

class InstrumentedMCPServer:
    def __init__(self):
        self.server = Server("memory-server")
        self.setup_tools()
        self.state_store = {}  # For cross-call state
    
    def setup_tools(self):
        @self.server.tool()
        @instrument_mcp_tool
        async def search_memory(query: str, filters: Dict[str, Any] = None):
            """Search memory with automatic instrumentation"""
            
            # Extract trace context if provided
            trace_parent = filters.pop('_trace_parent', None) if filters else None
            
            # Performance baseline check
            start_time = asyncio.get_event_loop().time()
            
            try:
                # Record search
                memory_searches.add(1, {"query_type": "semantic"})
                
                # Simulate search
                results = await self.perform_search(query, filters)
                
                # Check latency against baseline
                latency = (asyncio.get_event_loop().time() - start_time) * 1000
                search_latency.record(latency, {"status": "success"})
                
                if latency > 1000:  # P95 threshold
                    span = trace.get_current_span()
                    span.add_event("High latency detected", {
                        "latency_ms": latency,
                        "threshold_ms": 1000
                    })
                
                return results
                
            except Exception as e:
                search_latency.record(latency, {"status": "error"})
                raise
```

## State Management Across Stateless Calls

MCP servers are stateless, but you can maintain context across calls:

```python
from contextvars import ContextVar
from typing import Optional
import hashlib

# Thread-safe context storage
session_context = ContextVar('session_context', default={})

class StatefulMCPPatterns:
    
    @staticmethod
    def generate_session_id(user_id: str, trace_id: str) -> str:
        """Generate consistent session ID"""
        return hashlib.sha256(f"{user_id}:{trace_id}".encode()).hexdigest()[:16]
    
    @instrument_mcp_tool
    async def stateful_tool(
        self,
        action: str,
        session_id: Optional[str] = None,
        **params
    ):
        """Tool that maintains state across calls"""
        
        # Restore or create session
        if session_id:
            ctx = await self.restore_session(session_id)
            session_context.set(ctx)
        else:
            session_id = self.generate_session_id(
                params.get('user_id', 'anonymous'),
                format(trace.get_current_span().get_span_context().trace_id, '032x')
            )
            session_context.set({'id': session_id, 'calls': 0})
        
        # Track call count
        ctx = session_context.get()
        ctx['calls'] += 1
        
        # Add to span
        span = trace.get_current_span()
        span.set_attributes({
            "session.id": session_id,
            "session.call_count": ctx['calls'],
            "session.restored": session_id in params
        })
        
        # Perform action with context
        result = await self.execute_action(action, ctx, params)
        
        # Persist session
        await self.persist_session(session_id, ctx)
        
        return {
            "result": result,
            "session_id": session_id,  # Return for next call
            "call_count": ctx['calls']
        }
```

## Memory Loop Detection

Detect and break infinite loops in GraphRAG operations:

```python
class MemoryLoopDetector:
    def __init__(self, threshold: int = 50):
        self.threshold = threshold
        self.operation_history = {}
    
    @instrument_mcp_tool
    async def memory_operation_with_loop_detection(
        self,
        operation: str,
        params: dict
    ):
        """Detect potential memory loops"""
        
        # Generate operation signature
        sig = hashlib.md5(
            f"{operation}:{json.dumps(params, sort_keys=True)}".encode()
        ).hexdigest()
        
        # Get current trace ID
        trace_id = format(
            trace.get_current_span().get_span_context().trace_id, 
            '032x'
        )
        
        # Track operations per trace
        if trace_id not in self.operation_history:
            self.operation_history[trace_id] = {}
        
        # Count similar operations
        op_count = self.operation_history[trace_id].get(sig, 0) + 1
        self.operation_history[trace_id][sig] = op_count
        
        # Check for loops
        span = trace.get_current_span()
        if op_count > self.threshold:
            span.set_status(Status(StatusCode.ERROR, "Memory loop detected"))
            span.set_attributes({
                "error.type": "memory_loop",
                "loop.operation": operation,
                "loop.count": op_count,
                "loop.signature": sig
            })
            
            # Break the loop
            raise Exception(f"Memory loop detected: {operation} called {op_count} times")
        
        # Add operation count to span
        span.set_attribute("operation.count", op_count)
        
        # Perform actual operation
        result = await self.execute_memory_operation(operation, params)
        
        # Clean up old traces (prevent memory leak)
        if len(self.operation_history) > 100:
            oldest = min(self.operation_history.keys())
            del self.operation_history[oldest]
        
        return result
```

## Advanced Patterns

### Pattern 1: Distributed Lock Tracking
```python
import redis.asyncio as redis
from opentelemetry.instrumentation.redis import RedisInstrumentor

# Auto-instrument Redis
RedisInstrumentor().instrument()

class DistributedLockManager:
    def __init__(self):
        self.redis = redis.from_url("redis://localhost")
    
    @asynccontextmanager
    async def acquire_lock(self, resource: str, timeout: int = 10):
        """Acquire distributed lock with tracing"""
        
        lock_key = f"lock:{resource}"
        lock_id = format(trace.get_current_span().get_span_context().trace_id, '032x')
        
        with tracer.start_as_current_span("acquire_lock") as span:
            span.set_attributes({
                "lock.resource": resource,
                "lock.timeout": timeout,
                "lock.id": lock_id
            })
            
            # Try to acquire lock
            acquired = await self.redis.set(
                lock_key, lock_id, nx=True, ex=timeout
            )
            
            if not acquired:
                span.set_status(Status(StatusCode.ERROR, "Lock unavailable"))
                raise Exception(f"Could not acquire lock for {resource}")
            
            span.add_event("Lock acquired")
            
            try:
                yield lock_id
            finally:
                # Release lock
                await self.redis.delete(lock_key)
                span.add_event("Lock released")
```

### Pattern 2: Batch Operation Tracking
```python
class BatchProcessor:
    @instrument_mcp_tool
    async def process_batch(self, items: list, batch_size: int = 10):
        """Process items in batches with per-batch tracing"""
        
        total_items = len(items)
        batches = [items[i:i+batch_size] for i in range(0, total_items, batch_size)]
        
        span = trace.get_current_span()
        span.set_attributes({
            "batch.total_items": total_items,
            "batch.size": batch_size,
            "batch.count": len(batches)
        })
        
        results = []
        for i, batch in enumerate(batches):
            with tracer.start_as_current_span(f"batch_{i}") as batch_span:
                batch_span.set_attributes({
                    "batch.index": i,
                    "batch.items": len(batch)
                })
                
                try:
                    result = await self.process_single_batch(batch)
                    results.extend(result)
                    batch_span.set_status(Status(StatusCode.OK))
                except Exception as e:
                    batch_span.record_exception(e)
                    batch_span.set_status(Status(StatusCode.ERROR))
                    # Continue processing other batches
        
        return results
```

## Monitoring Queries

### Prometheus Queries
```promql
# Tool latency by percentile
histogram_quantile(0.95,
  sum(rate(mcp_tool_duration_bucket[5m])) by (tool, le)
)

# Memory loop detection
sum(rate(mcp_memory_operations_total[1m])) by (operation) > 100

# Active request saturation
mcp_active_requests / 10  # 10 is the max healthy concurrent requests

# Error rate by tool
sum(rate(mcp_tool_invocations_total{status="error"}[5m])) by (tool)
/ sum(rate(mcp_tool_invocations_total[5m])) by (tool)
```

### Grafana Alerts
```yaml
# High latency alert
- alert: MCPHighLatency
  expr: histogram_quantile(0.95, mcp_tool_duration_bucket) > 5000
  for: 5m
  annotations:
    summary: "MCP tool {{ $labels.tool }} P95 latency > 5s"

# Memory loop alert  
- alert: MemoryLoop
  expr: rate(mcp_memory_operations_total[1m]) > 120
  for: 2m
  annotations:
    summary: "Potential memory loop detected"
```

## Best Practices

1. **Always propagate trace context** through async boundaries
2. **Set appropriate timeouts** for all operations
3. **Use semantic conventions** for span attributes
4. **Implement circuit breakers** for external calls
5. **Add performance baseline checks** in critical paths
6. **Clean up state** to prevent memory leaks
7. **Use batching** for high-volume operations
8. **Sample appropriately** (100% dev, 1-10% prod)

## Troubleshooting

### High Latency
- Check `mcp_tool_duration_bucket` metrics
- Review span waterfalls in Tempo
- Look for N+1 query patterns
- Verify connection pooling is working

### Memory Loops
- Monitor `mcp_memory_operations_total` rate
- Check operation signatures for duplicates  
- Review GraphRAG query patterns
- Implement circuit breakers

### Lost Traces
- Verify OTLP endpoint connectivity
- Check batch processor settings
- Review sampling configuration
- Ensure context propagation in async code

## References

- [MCP OpenTelemetry Proposal](https://github.com/modelcontextprotocol/modelcontextprotocol/discussions/269)
- [OpenTelemetry Semantic Conventions](https://opentelemetry.io/docs/concepts/semantic-conventions/)
- [MCP Architecture](https://modelcontextprotocol.io/docs/learn/architecture)