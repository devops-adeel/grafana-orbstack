#!/usr/bin/env python3
"""
Trace Correlation Example

Demonstrates how to correlate traces between Langfuse and Tempo for debugging
slow operations and understanding service dependencies.
"""

import os
import time
import asyncio
import json
from typing import Optional
from dataclasses import dataclass

from opentelemetry import trace, baggage, context
from opentelemetry.trace import Status, StatusCode
from opentelemetry.propagate import inject, extract

# Import local wrapper
import sys
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from otel_wrapper import setup_telemetry, instrument_mcp_tool

tracer, meter = setup_telemetry("trace-correlation-example")


@dataclass
class TraceContext:
    """Holds correlation information between systems"""
    otel_trace_id: str
    otel_span_id: str
    langfuse_trace_id: Optional[str] = None
    parent_context: Optional[dict] = None
    
    def to_headers(self) -> dict:
        """Convert to HTTP headers for propagation"""
        headers = {}
        inject(headers)  # Inject W3C trace context
        
        if self.langfuse_trace_id:
            headers['X-Langfuse-Trace-Id'] = self.langfuse_trace_id
        
        return headers
    
    @classmethod
    def from_headers(cls, headers: dict) -> 'TraceContext':
        """Extract trace context from headers"""
        ctx = extract(headers)
        context.attach(ctx)
        
        span = trace.get_current_span()
        span_context = span.get_span_context()
        
        return cls(
            otel_trace_id=format(span_context.trace_id, '032x'),
            otel_span_id=format(span_context.span_id, '016x'),
            langfuse_trace_id=headers.get('X-Langfuse-Trace-Id'),
            parent_context=headers
        )


class TraceCorrelationExample:
    """Examples of trace correlation patterns"""
    
    @instrument_mcp_tool
    async def slow_operation_debug(self, input_data: str) -> dict:
        """
        Simulates a slow operation to demonstrate debugging with correlated traces.
        """
        
        start_time = time.time()
        trace_ctx = self._get_current_trace_context()
        
        # Log trace correlation info
        print(f"🔍 Starting slow operation")
        print(f"   OTel Trace: http://grafana.local/explore?traceID={trace_ctx.otel_trace_id}")
        if trace_ctx.langfuse_trace_id:
            print(f"   Langfuse: http://langfuse.local/trace/{trace_ctx.langfuse_trace_id}")
        
        # Simulate phases of operation
        results = {}
        
        # Phase 1: Data preparation (fast)
        with tracer.start_as_current_span("prepare_data") as span:
            span.set_attribute("phase", "preparation")
            await asyncio.sleep(0.1)
            results["prepared"] = True
        
        # Phase 2: External API call (slow)
        with tracer.start_as_current_span("external_api_call") as span:
            span.set_attribute("phase", "external_call")
            span.set_attribute("api.endpoint", "https://api.example.com/process")
            
            # Simulate slow API
            await asyncio.sleep(3.0)  # This is the bottleneck!
            
            span.add_event("API response received", {
                "response_time_ms": 3000,
                "status_code": 200
            })
            results["api_response"] = "processed"
        
        # Phase 3: Post-processing (fast)
        with tracer.start_as_current_span("post_process") as span:
            span.set_attribute("phase", "post_processing")
            await asyncio.sleep(0.2)
            results["processed"] = True
        
        # Add performance summary
        total_time = time.time() - start_time
        root_span = trace.get_current_span()
        root_span.set_attributes({
            "operation.duration_seconds": total_time,
            "operation.bottleneck": "external_api_call",
            "operation.bottleneck_duration": 3.0
        })
        
        if total_time > 2:  # Threshold
            root_span.add_event("Slow operation detected", {
                "duration": total_time,
                "threshold": 2
            })
        
        return {
            "results": results,
            "duration": total_time,
            "trace_id": trace_ctx.otel_trace_id
        }
    
    async def distributed_operation(self, request_id: str):
        """
        Simulates operation across multiple services with context propagation.
        """
        
        # Create root span
        with tracer.start_as_current_span("distributed_operation") as root_span:
            root_span.set_attribute("request.id", request_id)
            
            # Set baggage for cross-service correlation
            baggage.set_baggage("request_id", request_id)
            baggage.set_baggage("user_id", "user_123")
            
            # Simulate service calls
            results = []
            
            # Service A
            result_a = await self._call_service_a(request_id)
            results.append(result_a)
            
            # Service B (parallel with C)
            result_b_task = asyncio.create_task(self._call_service_b(request_id))
            
            # Service C (parallel with B)
            result_c_task = asyncio.create_task(self._call_service_c(request_id))
            
            # Wait for parallel operations
            result_b = await result_b_task
            result_c = await result_c_task
            results.extend([result_b, result_c])
            
            # Aggregate results
            root_span.set_attribute("services.called", 3)
            root_span.set_attribute("services.successful", len([r for r in results if r["success"]]))
            
            return {
                "request_id": request_id,
                "trace_id": format(root_span.get_span_context().trace_id, '032x'),
                "services": results
            }
    
    async def _call_service_a(self, request_id: str) -> dict:
        """Simulate Service A call"""
        with tracer.start_as_current_span("service_a_call") as span:
            span.set_attribute("service.name", "service-a")
            span.set_attribute("service.version", "1.2.3")
            
            # Propagate context
            headers = {}
            inject(headers)
            
            # Simulate network call
            await asyncio.sleep(0.5)
            
            # Get baggage
            req_id = baggage.get_baggage("request_id")
            span.set_attribute("propagated.request_id", req_id)
            
            return {"service": "A", "success": True, "duration": 0.5}
    
    async def _call_service_b(self, request_id: str) -> dict:
        """Simulate Service B call"""
        with tracer.start_as_current_span("service_b_call") as span:
            span.set_attribute("service.name", "service-b")
            await asyncio.sleep(0.7)
            return {"service": "B", "success": True, "duration": 0.7}
    
    async def _call_service_c(self, request_id: str) -> dict:
        """Simulate Service C call"""
        with tracer.start_as_current_span("service_c_call") as span:
            span.set_attribute("service.name", "service-c")
            await asyncio.sleep(0.3)
            return {"service": "C", "success": True, "duration": 0.3}
    
    def _get_current_trace_context(self) -> TraceContext:
        """Get current trace context for correlation"""
        span = trace.get_current_span()
        span_context = span.get_span_context()
        
        return TraceContext(
            otel_trace_id=format(span_context.trace_id, '032x'),
            otel_span_id=format(span_context.span_id, '016x'),
            langfuse_trace_id=baggage.get_baggage("langfuse_trace_id")
        )


class TraceAnalyzer:
    """Utilities for analyzing correlated traces"""
    
    @staticmethod
    def generate_tempo_query(langfuse_trace_id: str) -> str:
        """Generate Tempo query from Langfuse trace ID"""
        return f'{{.langfuse.trace_id="{langfuse_trace_id}"}}'
    
    @staticmethod
    def generate_prometheus_query(trace_id: str, metric: str) -> str:
        """Generate Prometheus query for metrics during trace"""
        return f'{metric}{{trace_id="{trace_id}"}}'
    
    @staticmethod
    def analyze_trace_timing(trace_data: dict) -> dict:
        """Analyze timing from trace data"""
        # This would parse actual trace data in production
        return {
            "total_duration": trace_data.get("duration"),
            "bottleneck": "external_api_call",
            "optimization_potential": "Cache external API responses"
        }


async def main():
    """Run trace correlation examples"""
    
    example = TraceCorrelationExample()
    analyzer = TraceAnalyzer()
    
    print("🔗 Trace Correlation Examples")
    print("=" * 60)
    
    # Example 1: Debug slow operation
    print("\n1. Debugging Slow Operation:")
    print("-" * 40)
    result = await example.slow_operation_debug("test input")
    print(f"   Duration: {result['duration']:.2f}s")
    print(f"   Bottleneck identified via trace waterfall")
    print(f"   View trace: http://grafana.local/explore?traceID={result['trace_id']}")
    
    # Example 2: Distributed operation
    print("\n2. Distributed Service Calls:")
    print("-" * 40)
    dist_result = await example.distributed_operation("req_12345")
    print(f"   Called {len(dist_result['services'])} services")
    print(f"   Trace shows parallel execution of B and C")
    print(f"   View trace: http://grafana.local/explore?traceID={dist_result['trace_id']}")
    
    # Example 3: Query generation
    print("\n3. Query Examples:")
    print("-" * 40)
    langfuse_id = "lf_abc123"
    print(f"   Tempo query: {analyzer.generate_tempo_query(langfuse_id)}")
    print(f"   Prometheus: {analyzer.generate_prometheus_query(dist_result['trace_id'], 'container_cpu_usage')}")
    
    print("\n" + "=" * 60)
    print("✅ Examples complete - check Grafana for trace waterfalls")
    
    # Allow time for export
    await asyncio.sleep(2)


if __name__ == "__main__":
    asyncio.run(main())