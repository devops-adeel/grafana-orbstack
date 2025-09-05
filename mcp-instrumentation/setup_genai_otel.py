#!/usr/bin/env python3
"""
Setup script for OpenTelemetry Gen AI instrumentation
Configures auto-instrumentation for Ollama, OpenAI, and other LLM providers
Following OpenTelemetry Gen AI semantic conventions
"""

import os
import logging
from typing import Optional, Dict, Any

# OpenTelemetry core
from opentelemetry import trace, metrics
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.semconv.resource import ResourceAttributes

# OTLP exporters for dual export
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter as HTTPSpanExporter

# Gen AI semantic conventions (will be available in future releases)
# For now, we define the attributes manually based on the spec
class GenAIAttributes:
    """Gen AI semantic convention attributes"""
    # Provider and Model
    GEN_AI_SYSTEM = "gen_ai.system"
    GEN_AI_REQUEST_MODEL = "gen_ai.request.model"
    GEN_AI_RESPONSE_MODEL = "gen_ai.response.model"
    
    # Operation
    GEN_AI_OPERATION_NAME = "gen_ai.operation.name"
    GEN_AI_CONVERSATION_ID = "gen_ai.conversation.id"
    
    # Token Usage
    GEN_AI_USAGE_INPUT_TOKENS = "gen_ai.usage.input_tokens"
    GEN_AI_USAGE_OUTPUT_TOKENS = "gen_ai.usage.output_tokens"
    GEN_AI_TOKEN_TYPE = "gen_ai.token.type"
    
    # Request Configuration
    GEN_AI_REQUEST_TEMPERATURE = "gen_ai.request.temperature"
    GEN_AI_REQUEST_MAX_TOKENS = "gen_ai.request.max_tokens"
    GEN_AI_REQUEST_TOP_P = "gen_ai.request.top_p"
    GEN_AI_REQUEST_FREQUENCY_PENALTY = "gen_ai.request.frequency_penalty"
    
    # Response
    GEN_AI_RESPONSE_FINISH_REASONS = "gen_ai.response.finish_reasons"
    GEN_AI_OUTPUT_TYPE = "gen_ai.output.type"
    
    # Local Model Extensions (custom for resource tracking)
    GEN_AI_RESOURCE_GPU_MEMORY_MB = "gen_ai.resource.gpu_memory_mb"
    GEN_AI_RESOURCE_INFERENCE_MS = "gen_ai.resource.inference_ms"
    GEN_AI_RESOURCE_MODEL_LOAD_MS = "gen_ai.resource.model_load_ms"
    GEN_AI_RESOURCE_LOCAL_COST = "gen_ai.resource.local_cost"


logger = logging.getLogger(__name__)


def setup_genai_telemetry(
    service_name: str = "genai-service",
    alloy_endpoint: str = None,
    langfuse_endpoint: str = None,
    langfuse_auth: str = None,
    capture_content: bool = False,
) -> tuple:
    """
    Set up OpenTelemetry with Gen AI semantic conventions and dual export
    
    Args:
        service_name: Name of the service
        alloy_endpoint: Grafana Alloy OTLP endpoint (e.g., http://alloy.local:4317)
        langfuse_endpoint: Langfuse OTLP endpoint (e.g., http://langfuse.local:3000/api/public/otel)
        langfuse_auth: Base64 encoded Langfuse auth (pk:sk)
        capture_content: Whether to capture message content (privacy setting)
    
    Returns:
        (tracer, meter) tuple for instrumentation
    """
    # Set environment variable for content capture
    os.environ["OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT"] = str(capture_content).lower()
    
    # Create resource with Gen AI attributes
    resource = Resource.create({
        ResourceAttributes.SERVICE_NAME: service_name,
        ResourceAttributes.SERVICE_VERSION: "1.0.0",
        "deployment.environment": "orbstack",
        "telemetry.sdk.name": "opentelemetry-python",
        "gen_ai.enabled": True,
    })
    
    # Set up tracing with dual export
    trace_provider = TracerProvider(resource=resource)
    
    # Export to Grafana Alloy (gRPC)
    if alloy_endpoint or os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT"):
        alloy_exporter = OTLPSpanExporter(
            endpoint=alloy_endpoint or os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://alloy.local:4317"),
            insecure=True,
        )
        trace_provider.add_span_processor(BatchSpanProcessor(alloy_exporter))
        logger.info(f"Configured Alloy export to {alloy_endpoint}")
    
    # Export to Langfuse (HTTP with auth)
    if langfuse_endpoint or os.getenv("LANGFUSE_OTLP_ENDPOINT"):
        headers = {}
        if langfuse_auth or os.getenv("LANGFUSE_AUTH_BASE64"):
            headers["Authorization"] = f"Basic {langfuse_auth or os.getenv('LANGFUSE_AUTH_BASE64')}"
        
        langfuse_exporter = HTTPSpanExporter(
            endpoint=langfuse_endpoint or os.getenv("LANGFUSE_OTLP_ENDPOINT", "http://langfuse.local:3000/api/public/otel"),
            headers=headers,
        )
        trace_provider.add_span_processor(BatchSpanProcessor(langfuse_exporter))
        logger.info(f"Configured Langfuse export to {langfuse_endpoint}")
    
    trace.set_tracer_provider(trace_provider)
    
    # Set up metrics
    metric_readers = []
    
    if alloy_endpoint or os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT"):
        metric_reader = PeriodicExportingMetricReader(
            exporter=OTLPMetricExporter(
                endpoint=alloy_endpoint or os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://alloy.local:4317"),
                insecure=True,
            ),
            export_interval_millis=30000,
        )
        metric_readers.append(metric_reader)
    
    metric_provider = MeterProvider(resource=resource, metric_readers=metric_readers)
    metrics.set_meter_provider(metric_provider)
    
    # Get tracer and meter
    tracer = trace.get_tracer(service_name)
    meter = metrics.get_meter(service_name)
    
    return tracer, meter


def auto_instrument_genai():
    """
    Auto-instrument Gen AI libraries (Ollama, OpenAI, etc.)
    """
    instrumented = []
    
    # Try to instrument Ollama
    try:
        from opentelemetry.instrumentation.ollama import OllamaInstrumentor
        OllamaInstrumentor().instrument()
        instrumented.append("Ollama")
        logger.info("Instrumented Ollama")
    except ImportError:
        logger.debug("Ollama instrumentation not available")
    
    # Try to instrument OpenAI
    try:
        from opentelemetry.instrumentation.openai_v2 import OpenAIInstrumentor
        OpenAIInstrumentor().instrument()
        instrumented.append("OpenAI")
        logger.info("Instrumented OpenAI")
    except ImportError:
        logger.debug("OpenAI instrumentation not available")
    
    # Try to instrument Google GenAI
    try:
        from opentelemetry.instrumentation.google_genai import GoogleGenAiInstrumentor
        GoogleGenAiInstrumentor().instrument()
        instrumented.append("Google GenAI")
        logger.info("Instrumented Google GenAI")
    except ImportError:
        logger.debug("Google GenAI instrumentation not available")
    
    # Try OpenLLMetry for broader coverage
    try:
        from opentelemetry.instrumentation.openllmetry import OpenLLMetryInstrumentor
        OpenLLMetryInstrumentor().instrument()
        instrumented.append("OpenLLMetry (multi-provider)")
        logger.info("Instrumented OpenLLMetry")
    except ImportError:
        logger.debug("OpenLLMetry instrumentation not available")
    
    return instrumented


def map_ollama_to_genai(span: trace.Span, ollama_response: Dict[str, Any]):
    """
    Map Ollama response fields to Gen AI semantic conventions
    
    Args:
        span: Current span to add attributes to
        ollama_response: Ollama API response dict
    """
    # Map Ollama fields to Gen AI conventions
    if "model" in ollama_response:
        span.set_attribute(GenAIAttributes.GEN_AI_RESPONSE_MODEL, ollama_response["model"])
    
    if "done_reason" in ollama_response:
        # Map Ollama's done_reason to Gen AI finish_reasons
        done_reason = ollama_response["done_reason"]
        if done_reason == "stop":
            finish_reason = "stop"
        elif done_reason == "length":
            finish_reason = "length"
        else:
            finish_reason = done_reason
        span.set_attribute(GenAIAttributes.GEN_AI_RESPONSE_FINISH_REASONS, [finish_reason])
    
    # Token usage
    if "prompt_eval_count" in ollama_response:
        span.set_attribute(GenAIAttributes.GEN_AI_USAGE_INPUT_TOKENS, ollama_response["prompt_eval_count"])
    
    if "eval_count" in ollama_response:
        span.set_attribute(GenAIAttributes.GEN_AI_USAGE_OUTPUT_TOKENS, ollama_response["eval_count"])
    
    # Performance metrics for local models
    if "total_duration" in ollama_response:
        span.set_attribute(GenAIAttributes.GEN_AI_RESOURCE_INFERENCE_MS, 
                          ollama_response["total_duration"] / 1_000_000)  # Convert ns to ms
    
    if "load_duration" in ollama_response:
        span.set_attribute(GenAIAttributes.GEN_AI_RESOURCE_MODEL_LOAD_MS,
                          ollama_response["load_duration"] / 1_000_000)  # Convert ns to ms


if __name__ == "__main__":
    # Example usage
    logging.basicConfig(level=logging.INFO)
    
    # Set up telemetry with dual export
    tracer, meter = setup_genai_telemetry(
        service_name="genai-example",
        alloy_endpoint="http://alloy.local:4317",
        langfuse_endpoint="http://langfuse.local:3000/api/public/otel",
        capture_content=False,  # Privacy-first
    )
    
    # Auto-instrument available libraries
    instrumented = auto_instrument_genai()
    print(f"Successfully instrumented: {', '.join(instrumented) if instrumented else 'None (install packages first)'}")
    
    # Example: Manual instrumentation for custom logic
    with tracer.start_as_current_span("genai.custom_operation") as span:
        span.set_attribute(GenAIAttributes.GEN_AI_OPERATION_NAME, "custom_inference")
        span.set_attribute(GenAIAttributes.GEN_AI_SYSTEM, "ollama")
        span.set_attribute(GenAIAttributes.GEN_AI_REQUEST_MODEL, "llama3")
        
        # Simulate Ollama response
        mock_response = {
            "model": "llama3",
            "done_reason": "stop",
            "prompt_eval_count": 150,
            "eval_count": 75,
            "total_duration": 500_000_000,  # 500ms in nanoseconds
        }
        
        map_ollama_to_genai(span, mock_response)
        
    print("Telemetry configured and example span sent!")