#!/usr/bin/env python3
"""
Dual Observability Example: Langfuse + OpenTelemetry

Shows how to instrument MCP tools with both Langfuse (for LLM observability)
and OpenTelemetry (for infrastructure observability).
"""

import os
import asyncio
from typing import Dict, Any, List
from datetime import datetime

# Langfuse for LLM observability
from langfuse import Langfuse
from langfuse.decorators import observe, langfuse_context

# OpenTelemetry for infrastructure
from opentelemetry import trace, metrics, baggage
from opentelemetry.trace import Status, StatusCode

# Import the local instrumentation wrapper
import sys
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from otel_wrapper import (
    setup_telemetry,
    instrument_mcp_tool,
    trace_memory_operation,
    trace_cross_domain_correlation
)

# Initialize both systems
langfuse = Langfuse(
    host=os.getenv("LANGFUSE_HOST", "http://langfuse.local"),
    public_key=os.getenv("LANGFUSE_PUBLIC_KEY"),
    secret_key=os.getenv("LANGFUSE_SECRET_KEY")
)

tracer, meter = setup_telemetry("dual-observability-example")


class DualObservabilityExample:
    """Example MCP server with complete observability"""
    
    @observe(name="memory_search")  # Langfuse decorator
    @instrument_mcp_tool  # OpenTelemetry decorator
    async def search_memory(self, query: str, filters: Dict[str, Any] = None) -> List[Dict]:
        """
        Memory search with dual observability.
        
        Langfuse tracks:
        - Input/output for debugging
        - Token usage if LLM is called
        - User feedback scores
        
        OpenTelemetry tracks:
        - Service dependencies
        - Infrastructure metrics
        - Distributed traces
        """
        
        # Link the two trace systems
        self._link_traces()
        
        # Track operation in both systems
        trace_memory_operation("search", source="dual_example", count=1, query=query)
        
        # Simulate search with latency
        await asyncio.sleep(0.5)
        
        # Mock results
        results = [
            {"id": "1", "content": "Example result", "score": 0.95},
            {"id": "2", "content": "Another result", "score": 0.87}
        ]
        
        # Add quality score to Langfuse
        langfuse_context.score(
            name="search_relevance",
            value=0.95,
            comment=f"Found {len(results)} results for: {query}"
        )
        
        # Add metrics to OpenTelemetry
        span = trace.get_current_span()
        span.set_attributes({
            "search.query": query,
            "search.result_count": len(results),
            "search.top_score": results[0]["score"] if results else 0
        })
        
        return results
    
    @observe(name="complex_operation")
    @instrument_mcp_tool
    async def complex_ai_operation(self, prompt: str) -> str:
        """
        Complex operation showing service mesh tracing.
        """
        
        # Link traces
        self._link_traces()
        
        # Step 1: Search memory
        with tracer.start_as_current_span("search_phase") as search_span:
            search_span.set_attribute("phase", "memory_search")
            context = await self.search_memory(prompt, {"type": "context"})
        
        # Step 2: Process with LLM (tracked by Langfuse)
        with tracer.start_as_current_span("llm_phase") as llm_span:
            llm_span.set_attribute("phase", "llm_processing")
            
            # Simulate LLM call
            await asyncio.sleep(1.0)
            
            # This would be tracked by Langfuse in real scenario
            langfuse_context.update_current_observation(
                metadata={"model": "gpt-4", "tokens": 1500}
            )
            
            response = f"Processed {len(context)} context items for: {prompt}"
        
        # Step 3: Store result (infrastructure operation)
        with tracer.start_as_current_span("storage_phase") as storage_span:
            storage_span.set_attribute("phase", "result_storage")
            await self._store_result(response)
        
        # Track cross-domain correlation
        trace_cross_domain_correlation(
            "memory", "llm", 0.85,
            context=f"Used memory search to enhance LLM response"
        )
        
        return response
    
    def _link_traces(self):
        """Link Langfuse and OpenTelemetry traces"""
        
        # Get OTel trace context
        otel_span = trace.get_current_span()
        otel_context = otel_span.get_span_context()
        otel_trace_id = format(otel_context.trace_id, '032x')
        otel_span_id = format(otel_context.span_id, '016x')
        
        # Add to Langfuse metadata
        if langfuse_trace := langfuse_context.get_current_trace():
            langfuse_context.update_current_trace(
                metadata={
                    "tempo_trace_id": otel_trace_id,
                    "tempo_span_id": otel_span_id,
                    "tempo_url": f"http://grafana.local/explore?traceID={otel_trace_id}"
                }
            )
            
            # Add Langfuse ID to OTel
            otel_span.set_attribute("langfuse.trace_id", langfuse_trace.id)
            otel_span.set_attribute("langfuse.url", 
                f"http://langfuse.local/trace/{langfuse_trace.id}")
            
            # Set baggage for downstream propagation
            baggage.set_baggage("langfuse_trace_id", langfuse_trace.id)
    
    async def _store_result(self, result: str):
        """Simulate storing result with tracing"""
        await asyncio.sleep(0.2)
        span = trace.get_current_span()
        span.set_attribute("storage.size_bytes", len(result))


async def main():
    """Run example demonstrating dual observability"""
    
    example = DualObservabilityExample()
    
    print("🔍 Running Dual Observability Example...")
    print("-" * 50)
    
    # Example 1: Simple search
    print("\n1. Simple memory search:")
    results = await example.search_memory("Docker best practices")
    print(f"   Found {len(results)} results")
    
    # Example 2: Complex operation
    print("\n2. Complex AI operation:")
    response = await example.complex_ai_operation("Explain container orchestration")
    print(f"   Response: {response[:100]}...")
    
    # Show where to view traces
    print("\n" + "=" * 50)
    print("📊 View traces in:")
    print("   Langfuse: http://langfuse.local")
    print("   Tempo: http://grafana.local/explore?datasource=tempo")
    print("\n💡 Traces are linked - find one in either system to see both!")
    
    # Give time for spans to export
    await asyncio.sleep(2)


if __name__ == "__main__":
    asyncio.run(main())