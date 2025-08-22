#!/usr/bin/env python3
"""
MCP Service Mesh Example

Demonstrates tracing through a service mesh of MCP servers and downstream services,
showing service dependencies and performance bottlenecks.
"""

import os
import asyncio
import json
from typing import Dict, List, Any
from dataclasses import dataclass
from enum import Enum

from opentelemetry import trace, metrics
from opentelemetry.trace import Status, StatusCode
from opentelemetry.propagate import inject

# Import local wrapper
import sys
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from otel_wrapper import setup_telemetry, instrument_mcp_tool

tracer, meter = setup_telemetry("mcp-service-mesh")

# Metrics for service mesh
service_calls = meter.create_counter(
    "service_mesh.calls",
    description="Service mesh call counter"
)

service_latency = meter.create_histogram(
    "service_mesh.latency",
    description="Service call latency",
    unit="ms"
)


class ServiceType(Enum):
    """Types of services in our mesh"""
    MCP_TOOL = "mcp_tool"
    EMBEDDING = "embedding"
    VECTOR_DB = "vector_db"
    GRAPH_DB = "graph_db"
    LLM = "llm"
    CACHE = "cache"


@dataclass
class ServiceCall:
    """Represents a call to a service"""
    service_type: ServiceType
    service_name: str
    endpoint: str
    latency_ms: float
    success: bool
    data_size_bytes: int = 0


class ServiceMeshSimulator:
    """Simulates a complex service mesh for MCP operations"""
    
    def __init__(self):
        self.service_registry = {
            ServiceType.EMBEDDING: "http://embedding-api:8080",
            ServiceType.VECTOR_DB: "http://qdrant:6333",
            ServiceType.GRAPH_DB: "http://falkordb:6379",
            ServiceType.LLM: "http://openai-proxy:8000",
            ServiceType.CACHE: "http://redis:6379"
        }
        self.call_history: List[ServiceCall] = []
    
    @instrument_mcp_tool
    async def complex_rag_operation(self, query: str) -> Dict[str, Any]:
        """
        Complex RAG operation showing full service mesh.
        
        Flow:
        1. Check cache
        2. Generate embeddings
        3. Search vector DB
        4. Query graph DB
        5. Call LLM
        6. Update cache
        """
        
        span = trace.get_current_span()
        span.set_attribute("operation.type", "complex_rag")
        span.set_attribute("query.text", query)
        
        # Track service dependencies
        dependencies = []
        
        # Step 1: Check cache
        cache_result = await self._call_service(
            ServiceType.CACHE,
            "cache_check",
            {"key": f"rag:{query}"}
        )
        dependencies.append("cache")
        
        if cache_result.get("hit"):
            span.add_event("Cache hit", {"key": query})
            return cache_result["data"]
        
        # Step 2: Generate embeddings
        embeddings = await self._call_service(
            ServiceType.EMBEDDING,
            "generate_embeddings",
            {"text": query}
        )
        dependencies.append("embedding")
        
        # Step 3 & 4: Parallel search in vector and graph DBs
        vector_task = asyncio.create_task(
            self._call_service(
                ServiceType.VECTOR_DB,
                "vector_search",
                {"embeddings": embeddings, "limit": 10}
            )
        )
        
        graph_task = asyncio.create_task(
            self._call_service(
                ServiceType.GRAPH_DB,
                "graph_query",
                {"query": query, "depth": 2}
            )
        )
        
        # Wait for both
        vector_results, graph_results = await asyncio.gather(vector_task, graph_task)
        dependencies.extend(["vector_db", "graph_db"])
        
        # Step 5: Call LLM with context
        llm_response = await self._call_service(
            ServiceType.LLM,
            "generate_response",
            {
                "query": query,
                "vector_context": vector_results,
                "graph_context": graph_results
            }
        )
        dependencies.append("llm")
        
        # Step 6: Update cache
        await self._call_service(
            ServiceType.CACHE,
            "cache_set",
            {"key": f"rag:{query}", "value": llm_response, "ttl": 3600}
        )
        
        # Add service mesh metadata
        span.set_attributes({
            "service_mesh.depth": 3,  # Max depth of service calls
            "service_mesh.breadth": 5,  # Number of unique services
            "service_mesh.total_calls": len(self.call_history),
            "service_mesh.dependencies": ",".join(dependencies)
        })
        
        # Generate service map
        service_map = self._generate_service_map()
        span.add_event("Service mesh traversal complete", service_map)
        
        return {
            "response": llm_response,
            "service_map": service_map,
            "total_latency_ms": sum(c.latency_ms for c in self.call_history)
        }
    
    async def _call_service(
        self,
        service_type: ServiceType,
        operation: str,
        data: Dict[str, Any]
    ) -> Dict[str, Any]:
        """Simulate a service call with tracing"""
        
        service_url = self.service_registry[service_type]
        
        with tracer.start_as_current_span(f"{service_type.value}_{operation}") as span:
            span.set_attributes({
                "service.type": service_type.value,
                "service.operation": operation,
                "service.url": service_url,
                "service.downstream": service_type.value
            })
            
            # Simulate network call with varying latency
            latency = await self._simulate_service_latency(service_type)
            
            # Record call
            call = ServiceCall(
                service_type=service_type,
                service_name=service_type.value,
                endpoint=f"{service_url}/{operation}",
                latency_ms=latency * 1000,
                success=True,
                data_size_bytes=len(json.dumps(data))
            )
            self.call_history.append(call)
            
            # Record metrics
            service_calls.add(1, {
                "service": service_type.value,
                "operation": operation
            })
            service_latency.record(latency * 1000, {
                "service": service_type.value
            })
            
            # Add trace headers for propagation
            headers = {}
            inject(headers)
            span.add_event("Service call completed", {
                "latency_ms": latency * 1000,
                "data_size": call.data_size_bytes,
                "trace_headers": json.dumps(headers)
            })
            
            # Mock response based on service type
            return self._mock_service_response(service_type, operation)
    
    async def _simulate_service_latency(self, service_type: ServiceType) -> float:
        """Simulate realistic latency for different services"""
        latencies = {
            ServiceType.CACHE: 0.01,     # 10ms
            ServiceType.EMBEDDING: 0.2,   # 200ms
            ServiceType.VECTOR_DB: 0.15,  # 150ms
            ServiceType.GRAPH_DB: 0.3,    # 300ms
            ServiceType.LLM: 2.0,          # 2s
        }
        latency = latencies.get(service_type, 0.1)
        await asyncio.sleep(latency)
        return latency
    
    def _mock_service_response(self, service_type: ServiceType, operation: str) -> Dict:
        """Generate mock responses"""
        if service_type == ServiceType.CACHE:
            return {"hit": False} if operation == "cache_check" else {"stored": True}
        elif service_type == ServiceType.EMBEDDING:
            return {"embeddings": [0.1, 0.2, 0.3] * 128}  # 384-dim embedding
        elif service_type == ServiceType.VECTOR_DB:
            return {"results": [{"id": f"doc_{i}", "score": 0.9 - i*0.1} for i in range(5)]}
        elif service_type == ServiceType.GRAPH_DB:
            return {"nodes": ["concept_1", "concept_2"], "edges": [("concept_1", "relates_to", "concept_2")]}
        elif service_type == ServiceType.LLM:
            return {"response": "Generated response based on context", "tokens": 150}
        return {}
    
    def _generate_service_map(self) -> Dict[str, Any]:
        """Generate a service dependency map"""
        dependencies = {}
        for call in self.call_history:
            service = call.service_name
            if service not in dependencies:
                dependencies[service] = {
                    "calls": 0,
                    "total_latency_ms": 0,
                    "avg_latency_ms": 0
                }
            dependencies[service]["calls"] += 1
            dependencies[service]["total_latency_ms"] += call.latency_ms
            dependencies[service]["avg_latency_ms"] = (
                dependencies[service]["total_latency_ms"] / dependencies[service]["calls"]
            )
        
        return {
            "total_services": len(dependencies),
            "total_calls": len(self.call_history),
            "dependencies": dependencies,
            "critical_path": self._identify_critical_path()
        }
    
    def _identify_critical_path(self) -> List[str]:
        """Identify the critical path (slowest services)"""
        if not self.call_history:
            return []
        
        # Sort by latency
        sorted_calls = sorted(self.call_history, key=lambda x: x.latency_ms, reverse=True)
        
        # Return top 3 slowest
        return [f"{c.service_name}:{c.latency_ms:.0f}ms" for c in sorted_calls[:3]]


async def visualize_service_mesh():
    """Generate ASCII visualization of service mesh"""
    
    print("\n📊 Service Mesh Topology:")
    print("=" * 60)
    print("""
    [MCP Client]
         |
         v
    [MCP Server] ──────> [Cache]
         |                  ↑
         ├──> [Embedding API]
         |         |
         |         v
         ├──> [Vector DB]
         |         |
         ├──> [Graph DB]
         |         |
         └──────> [LLM API]
    """)
    print("=" * 60)


async def main():
    """Run service mesh example"""
    
    mesh = ServiceMeshSimulator()
    
    print("🕸️  MCP Service Mesh Example")
    print("=" * 60)
    
    # Visualize topology
    await visualize_service_mesh()
    
    # Run complex operation
    print("\n🚀 Executing complex RAG operation...")
    print("-" * 40)
    
    result = await mesh.complex_rag_operation("What are the best practices for microservices?")
    
    # Display results
    print(f"\n✅ Operation complete!")
    print(f"   Total latency: {result['total_latency_ms']:.0f}ms")
    print(f"\n📈 Service Statistics:")
    
    for service, stats in result["service_map"]["dependencies"].items():
        print(f"   {service:15} - Calls: {stats['calls']}, Avg: {stats['avg_latency_ms']:.0f}ms")
    
    print(f"\n🔥 Critical Path (slowest services):")
    for item in result["service_map"]["critical_path"]:
        print(f"   {item}")
    
    # Get trace ID for viewing
    span = trace.get_current_span()
    trace_id = format(span.get_span_context().trace_id, '032x')
    
    print(f"\n🔍 View complete service mesh trace:")
    print(f"   http://grafana.local/explore?traceID={trace_id}")
    print("\n   The trace waterfall will show:")
    print("   • Service dependencies")
    print("   • Parallel execution (vector + graph)")
    print("   • Latency breakdown by service")
    print("   • Data flow through the mesh")
    
    # Allow time for export
    await asyncio.sleep(2)


if __name__ == "__main__":
    asyncio.run(main())