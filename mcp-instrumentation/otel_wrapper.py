#!/usr/bin/env python3
"""
OpenTelemetry instrumentation wrapper for AI services
Provides decorators and context managers for tracing MCP tools, LLM calls, and memory operations
"""

import os
import time
import functools
import asyncio
from typing import Any, Dict, Optional, Callable, TypeVar, Union
from contextlib import contextmanager, asynccontextmanager
from datetime import datetime

from opentelemetry import trace, metrics
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.semconv.resource import ResourceAttributes
from opentelemetry.trace import Status, StatusCode
from opentelemetry.metrics import CallbackOptions, Observation

# Configure OTLP endpoint (Grafana Alloy or Tempo)
OTLP_ENDPOINT = os.getenv("OTLP_ENDPOINT", "http://alloy.local:4317")
SERVICE_NAME = os.getenv("MCP_SERVICE_NAME", "mcp-server")

# Type hints for decorators
F = TypeVar('F', bound=Callable[..., Any])

def setup_telemetry(service_name: str = SERVICE_NAME) -> tuple:
    """
    Set up OpenTelemetry tracing and metrics
    Returns (tracer, meter) tuple
    """
    # Create resource identifying this service
    resource = Resource.create({
        ResourceAttributes.SERVICE_NAME: service_name,
        ResourceAttributes.SERVICE_VERSION: "1.0.0",
        "deployment.environment": "orbstack",
        "mcp.server.type": service_name.replace("mcp-", ""),
    })
    
    # Set up tracing
    trace_provider = TracerProvider(resource=resource)
    trace_processor = BatchSpanProcessor(
        OTLPSpanExporter(endpoint=OTLP_ENDPOINT, insecure=True)
    )
    trace_provider.add_span_processor(trace_processor)
    trace.set_tracer_provider(trace_provider)
    
    # Set up metrics
    metric_reader = PeriodicExportingMetricReader(
        exporter=OTLPMetricExporter(endpoint=OTLP_ENDPOINT, insecure=True),
        export_interval_millis=30000,  # Export every 30 seconds
    )
    metric_provider = MeterProvider(resource=resource, metric_readers=[metric_reader])
    metrics.set_meter_provider(metric_provider)
    
    # Get tracer and meter
    tracer = trace.get_tracer(service_name)
    meter = metrics.get_meter(service_name)
    
    return tracer, meter


# Initialize telemetry
tracer, meter = setup_telemetry()

# Create metrics
tool_invocation_counter = meter.create_counter(
    "mcp.tool.invocations",
    description="Number of MCP tool invocations",
    unit="1",
)

tool_duration_histogram = meter.create_histogram(
    "mcp.tool.duration",
    description="Duration of MCP tool invocations",
    unit="ms",
)

memory_operation_counter = meter.create_counter(
    "mcp.memory.operations",
    description="Number of memory operations",
    unit="1",
)

# Active requests gauge (for tracking concurrent operations)
active_requests = 0

def _get_active_requests(options: CallbackOptions) -> list[Observation]:
    return [Observation(active_requests, {"service": SERVICE_NAME})]

meter.create_observable_gauge(
    "mcp.active_requests",
    callbacks=[_get_active_requests],
    description="Number of active MCP requests",
)


@contextmanager
def trace_tool_invocation(tool_name: str, **kwargs):
    """
    Context manager to trace MCP tool invocations
    
    Usage:
        with trace_tool_invocation("search_memory", query="docker error"):
            # Tool implementation here
            result = search_memory(query)
    """
    global active_requests
    active_requests += 1
    
    # Start span
    with tracer.start_as_current_span(
        f"mcp.tool.{tool_name}",
        kind=trace.SpanKind.SERVER,
    ) as span:
        # Add attributes
        span.set_attributes({
            "mcp.tool.name": tool_name,
            "mcp.service": SERVICE_NAME,
            **{f"mcp.param.{k}": str(v) for k, v in kwargs.items()},
        })
        
        # Record metric
        tool_invocation_counter.add(1, {"tool": tool_name})
        
        try:
            start_time = time.time()
            yield span
            
            # Record duration
            duration_ms = (time.time() - start_time) * 1000
            tool_duration_histogram.record(duration_ms, {"tool": tool_name})
            
            # Mark span as successful
            span.set_status(Status(StatusCode.OK))
            
        except Exception as e:
            # Record error
            span.record_exception(e)
            span.set_status(Status(StatusCode.ERROR, str(e)))
            raise
        finally:
            active_requests -= 1


def instrument_mcp_tool(func: F) -> F:
    """
    Decorator to automatically instrument MCP tool functions
    
    Usage:
        @instrument_mcp_tool
        async def capture_solution(error: str, solution: str):
            # Tool implementation
            return result
    """
    if asyncio.iscoroutinefunction(func):
        @functools.wraps(func)
        async def async_wrapper(*args, **kwargs):
            tool_name = func.__name__
            with trace_tool_invocation(tool_name, **kwargs):
                result = await func(*args, **kwargs)
                return result
        return async_wrapper
    else:
        @functools.wraps(func)
        def sync_wrapper(*args, **kwargs):
            tool_name = func.__name__
            with trace_tool_invocation(tool_name, **kwargs):
                result = func(*args, **kwargs)
                return result
        return sync_wrapper


def trace_memory_operation(operation: str, source: str, count: int = 1, **kwargs):
    """
    Trace GraphRAG/memory system operations
    
    Args:
        operation: Type of operation (search, capture, update, delete)
        source: Source system (gtd_coach, coding_assistant, etc.)
        count: Number of items affected
        **kwargs: Additional attributes to record
    
    Usage:
        trace_memory_operation("search", source="gtd_coach", count=5, query="docker")
        trace_memory_operation("capture", source="coding_assistant", count=1, concept="error handling")
    """
    with tracer.start_as_current_span(
        f"memory.{operation}",
        kind=trace.SpanKind.CLIENT,
    ) as span:
        # Add attributes
        span.set_attributes({
            "memory.operation": operation,
            "memory.source": source,
            "memory.count": count,
            **{f"memory.{k}": str(v) for k, v in kwargs.items()},
        })
        
        # Record metric
        memory_operation_counter.add(count, {
            "operation": operation,
            "source": source
        })
        
        # Add event for visibility
        span.add_event(
            f"Memory {operation} from {source}",
            attributes={"count": count, **kwargs}
        )


def trace_cross_domain_correlation(domain_from: str, domain_to: str, 
                                  correlation_score: float, context: str = ""):
    """
    Track correlations between different AI domains
    
    Args:
        domain_from: Source domain (e.g., "gtd", "memory")
        domain_to: Target domain (e.g., "coding", "planning")
        correlation_score: Strength of correlation (0.0 to 1.0)
        context: Optional context about the correlation
    
    Usage:
        trace_cross_domain_correlation("gtd", "coding", 0.85, 
                                      context="Applied GTD insight to code organization")
    """
    with tracer.start_as_current_span(
        f"correlation.{domain_from}_to_{domain_to}",
        kind=trace.SpanKind.INTERNAL,
    ) as span:
        span.set_attributes({
            "correlation.from": domain_from,
            "correlation.to": domain_to,
            "correlation.score": correlation_score,
            "correlation.context": context,
        })
        
        # Add event for timeline visibility
        span.add_event(
            f"Cross-domain insight: {domain_from} → {domain_to}",
            attributes={
                "score": correlation_score,
                "context": context
            }
        )


@asynccontextmanager
async def trace_llm_call(model: str, provider: str = "openai", **kwargs):
    """
    Async context manager for tracing LLM API calls with token tracking
    
    Args:
        model: Model name (e.g., "gpt-4", "claude-3")
        provider: LLM provider (openai, anthropic, etc.)
        **kwargs: Additional parameters (temperature, max_tokens, etc.)
    
    Usage:
        async with trace_llm_call("gpt-4", temperature=0.7) as span:
            response = await openai.chat.completions.create(...)
            span.set_attribute("llm.tokens.prompt", response.usage.prompt_tokens)
            span.set_attribute("llm.tokens.completion", response.usage.completion_tokens)
    """
    with tracer.start_as_current_span(
        f"llm.{provider}.{model}",
        kind=trace.SpanKind.CLIENT,
    ) as span:
        span.set_attributes({
            "llm.model": model,
            "llm.provider": provider,
            **{f"llm.param.{k}": str(v) for k, v in kwargs.items()},
        })
        
        start_time = time.time()
        try:
            yield span
            span.set_status(Status(StatusCode.OK))
        except Exception as e:
            span.record_exception(e)
            span.set_status(Status(StatusCode.ERROR, str(e)))
            raise
        finally:
            # Record latency
            latency_ms = (time.time() - start_time) * 1000
            span.set_attribute("llm.latency_ms", latency_ms)


# Export convenience functions for AI services
__all__ = [
    'setup_telemetry',
    'trace_tool_invocation',
    'instrument_mcp_tool',
    'trace_memory_operation',
    'trace_cross_domain_correlation',
    'trace_llm_call',
    'tracer',
    'meter',
]