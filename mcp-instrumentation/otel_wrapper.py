#!/usr/bin/env python3
"""
OpenTelemetry instrumentation wrapper for MCP servers
Minimal, non-invasive wrapper that adds observability without modifying MCP logic
"""

import os
import functools
from typing import Any, Dict, Optional
from contextlib import contextmanager

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
            import time
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


def instrument_mcp_tool(func):
    """
    Decorator to automatically instrument MCP tool functions
    
    Usage:
        @instrument_mcp_tool
        async def capture_solution(error: str, solution: str):
            # Tool implementation
            return result
    """
    @functools.wraps(func)
    async def wrapper(*args, **kwargs):
        tool_name = func.__name__
        
        with trace_tool_invocation(tool_name, **kwargs):
            result = await func(*args, **kwargs)
            return result
    
    return wrapper


def trace_memory_operation(operation: str, source: str = None, count: int = 1):
    """
    Trace memory-specific operations (search, capture, supersede, etc.)
    
    Usage:
        trace_memory_operation("search", source="gtd_coach", count=5)
    """
    span = trace.get_current_span()
    if span:
        span.set_attributes({
            "mcp.memory.operation": operation,
            "mcp.memory.source": source or "unknown",
            "mcp.memory.count": count,
        })
    
    # Record metric
    memory_operation_counter.add(
        count,
        {"operation": operation, "source": source or "unknown"}
    )


def trace_cross_domain_correlation(from_domain: str, to_domain: str, correlation_score: float):
    """
    Trace cross-domain correlations (e.g., GTD task to coding solution)
    
    Usage:
        trace_cross_domain_correlation("gtd", "coding", 0.85)
    """
    span = trace.get_current_span()
    if span:
        span.add_event(
            "cross_domain_correlation",
            attributes={
                "from_domain": from_domain,
                "to_domain": to_domain,
                "correlation_score": correlation_score,
            }
        )


# Export convenience functions for MCP servers
__all__ = [
    'setup_telemetry',
    'trace_tool_invocation',
    'instrument_mcp_tool',
    'trace_memory_operation',
    'trace_cross_domain_correlation',
    'tracer',
    'meter',
]