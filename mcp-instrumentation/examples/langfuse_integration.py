#!/usr/bin/env python3
"""
Example: Integrating OpenTelemetry with Langfuse for comprehensive LLM observability
"""

import os
import asyncio
from typing import Dict, Any

# Langfuse for LLM-specific observability
from langfuse import Langfuse
from langfuse.decorators import observe, langfuse_context

# OpenTelemetry for distributed tracing
from otel_wrapper import (
    setup_telemetry,
    instrument_mcp_tool,
    trace_memory_operation,
    trace_llm_call,
    trace_cross_domain_correlation
)

# Initialize telemetry
tracer, meter = setup_telemetry("langfuse-example")

# Initialize Langfuse
langfuse = Langfuse(
    host=os.getenv("LANGFUSE_HOST", "http://langfuse.local"),
    public_key=os.getenv("LANGFUSE_PUBLIC_KEY"),
    secret_key=os.getenv("LANGFUSE_SECRET_KEY")
)

# Example 1: Dual instrumentation for MCP tools
@observe()  # Langfuse tracking
@instrument_mcp_tool  # OpenTelemetry tracing
async def enhanced_search(query: str, filters: Dict[str, Any] = None):
    """
    Search with both Langfuse and OpenTelemetry instrumentation.
    
    Langfuse tracks:
    - Input/output for debugging
    - Evaluation scores
    - User feedback
    
    OpenTelemetry tracks:
    - Distributed traces
    - Performance metrics
    - Infrastructure correlation
    """
    # Simulate search
    results = await perform_search(query, filters)
    
    # Track in OpenTelemetry
    trace_memory_operation("search", source="enhanced_search", count=len(results))
    
    # Add Langfuse score
    langfuse_context.score(
        name="relevance",
        value=0.95,
        comment="High quality results"
    )
    
    return results


# Example 2: RAG pipeline with comprehensive tracking
@observe(name="rag_pipeline")
async def rag_query_with_tracking(query: str):
    """
    Complete RAG pipeline with multi-layer observability.
    """
    # Step 1: Retrieve context
    with tracer.start_as_current_span("retrieve_context") as span:
        contexts = await retrieve_documents(query)
        span.set_attribute("context_count", len(contexts))
        
        # Track retrieval in Langfuse
        langfuse_context.update_current_observation(
            metadata={"retrieved_docs": len(contexts)}
        )
    
    # Step 2: Generate response with LLM
    async with trace_llm_call("gpt-4", temperature=0.7) as span:
        import openai
        
        # Prepare prompt
        prompt = f"Context: {contexts}\n\nQuery: {query}\n\nAnswer:"
        
        # Make LLM call (tracked by Langfuse automatically if configured)
        response = await openai.chat.completions.create(
            model="gpt-4",
            messages=[{"role": "user", "content": prompt}],
            temperature=0.7
        )
        
        # Add metrics to OpenTelemetry
        span.set_attribute("llm.tokens.prompt", response.usage.prompt_tokens)
        span.set_attribute("llm.tokens.completion", response.usage.completion_tokens)
        
        # Calculate cost
        cost = (response.usage.prompt_tokens * 0.03 + 
                response.usage.completion_tokens * 0.06) / 1000
        span.set_attribute("llm.cost.usd", cost)
        
        answer = response.choices[0].message.content
    
    # Step 3: Track quality
    langfuse_context.score(
        name="answer_quality",
        value=evaluate_answer_quality(answer, query),
        comment="Automated quality check"
    )
    
    return {
        "answer": answer,
        "contexts": contexts,
        "tokens_used": response.usage.total_tokens,
        "cost_usd": cost
    }


# Example 3: Memory system with cross-domain correlation
class InstrumentedMemorySystem:
    """
    Memory system with full observability.
    """
    
    def __init__(self):
        self.langfuse = langfuse
        
    @observe(as_type="generation")
    async def capture_insight(self, insight: str, domain: str, metadata: dict = None):
        """
        Capture an insight with full tracking.
        """
        # OpenTelemetry span for infrastructure
        with tracer.start_as_current_span("capture_insight") as span:
            span.set_attribute("domain", domain)
            span.set_attribute("insight_length", len(insight))
            
            # Store in memory system
            doc_id = await self.store(insight, domain, metadata)
            
            # Track memory operation
            trace_memory_operation(
                operation="capture",
                source=domain,
                count=1,
                doc_id=doc_id
            )
            
            # Check for cross-domain correlations
            correlations = await self.find_correlations(insight, domain)
            for corr in correlations:
                trace_cross_domain_correlation(
                    domain_from=domain,
                    domain_to=corr["domain"],
                    correlation_score=corr["score"],
                    context=corr["description"]
                )
            
            # Langfuse tracking
            langfuse_context.update_current_observation(
                output={"doc_id": doc_id, "correlations": len(correlations)},
                metadata={"domain": domain, **metadata} if metadata else {"domain": domain}
            )
            
            return doc_id
    
    async def store(self, content: str, domain: str, metadata: dict):
        # Simulate storage
        await asyncio.sleep(0.1)
        return f"doc_{hash(content)}"
    
    async def find_correlations(self, content: str, domain: str):
        # Simulate correlation finding
        await asyncio.sleep(0.05)
        return [
            {"domain": "coding", "score": 0.85, "description": "Pattern matches coding best practice"},
            {"domain": "planning", "score": 0.72, "description": "Relates to project planning"}
        ]


# Example 4: Error handling with both systems
@observe()
@instrument_mcp_tool
async def robust_tool(input_data: str):
    """
    Tool with comprehensive error tracking.
    """
    try:
        # Process input
        result = await process_with_validation(input_data)
        
        # Track success
        langfuse_context.score(name="success", value=1)
        
        return result
        
    except ValidationError as e:
        # Track validation errors
        langfuse_context.score(name="success", value=0)
        langfuse_context.update_current_observation(
            level="ERROR",
            status_message=str(e)
        )
        
        # OpenTelemetry will automatically record the exception
        raise
        
    except Exception as e:
        # Track unexpected errors
        langfuse_context.score(name="success", value=0)
        langfuse_context.update_current_observation(
            level="ERROR",
            status_message=f"Unexpected: {str(e)}"
        )
        raise


# Utility functions
async def perform_search(query: str, filters: dict = None):
    """Simulate search operation."""
    await asyncio.sleep(0.1)
    return [f"Result {i} for {query}" for i in range(5)]


async def retrieve_documents(query: str):
    """Simulate document retrieval."""
    await asyncio.sleep(0.2)
    return [f"Document {i} relevant to {query}" for i in range(3)]


def evaluate_answer_quality(answer: str, query: str) -> float:
    """Simulate answer quality evaluation."""
    # Simple heuristic
    if query.lower() in answer.lower():
        return 0.9
    return 0.6


class ValidationError(Exception):
    """Custom validation error."""
    pass


async def process_with_validation(data: str):
    """Simulate processing with validation."""
    if not data or len(data) < 5:
        raise ValidationError("Input too short")
    await asyncio.sleep(0.05)
    return f"Processed: {data}"


# Main example runner
async def main():
    """
    Run examples to demonstrate integration.
    """
    print("🚀 Starting Langfuse + OpenTelemetry integration examples")
    print(f"📡 Sending traces to: {os.getenv('OTLP_ENDPOINT', 'http://alloy.local:4317')}")
    print(f"📊 Langfuse host: {os.getenv('LANGFUSE_HOST', 'http://langfuse.local')}")
    
    # Example 1: Enhanced search
    print("\n1. Testing enhanced search...")
    results = await enhanced_search("kubernetes deployment strategies", {"category": "devops"})
    print(f"   Found {len(results)} results")
    
    # Example 2: RAG pipeline
    print("\n2. Testing RAG pipeline...")
    rag_result = await rag_query_with_tracking("How do I scale a Kubernetes deployment?")
    print(f"   Generated answer using {rag_result['tokens_used']} tokens")
    print(f"   Cost: ${rag_result['cost_usd']:.4f}")
    
    # Example 3: Memory system
    print("\n3. Testing memory system...")
    memory = InstrumentedMemorySystem()
    doc_id = await memory.capture_insight(
        insight="Use horizontal pod autoscaling for dynamic load",
        domain="kubernetes",
        metadata={"source": "documentation", "confidence": 0.95}
    )
    print(f"   Captured insight with ID: {doc_id}")
    
    # Example 4: Error handling
    print("\n4. Testing error handling...")
    try:
        await robust_tool("test")  # Too short, will fail
    except ValidationError:
        print("   Validation error tracked in both systems")
    
    # Success case
    result = await robust_tool("valid input data")
    print(f"   Success: {result}")
    
    print("\n✅ Examples complete!")
    print("\nView results:")
    print("  - Traces: http://grafana.local → Explore → Tempo")
    print("  - Langfuse: http://langfuse.local")
    print("  - Metrics: http://prometheus.local")


if __name__ == "__main__":
    asyncio.run(main())