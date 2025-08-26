#!/bin/bash
# Example configuration for MCP servers and Langfuse to use OTLP authentication
# This file shows how to configure your AI services to send telemetry to the secured Grafana stack

# Method 1: Environment variables for OpenTelemetry SDK
# Use this method for services that use the OpenTelemetry SDK directly

# Get the token from 1Password
export OTLP_TOKEN=$(op read "op://Grafana-Observability/Security/otlp-bearer-token")

# Configure OTLP exporters with authentication
export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4318"  # HTTP endpoint
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer ${OTLP_TOKEN}"
export OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf"

# For gRPC endpoint (port 4317)
# export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4317"
# export OTEL_EXPORTER_OTLP_PROTOCOL="grpc"

# Method 2: Direct configuration in Python (for MCP servers)
cat << 'EOF'
# Example Python configuration for MCP servers:
import os
from opentelemetry import trace, metrics
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.metrics import MeterProvider

# Get token from environment or 1Password
otlp_token = os.environ.get('OTLP_TOKEN', '')

# Configure trace exporter with authentication
trace_exporter = OTLPSpanExporter(
    endpoint="http://localhost:4318/v1/traces",
    headers={"Authorization": f"Bearer {otlp_token}"}
)

# Configure metrics exporter with authentication
metric_exporter = OTLPMetricExporter(
    endpoint="http://localhost:4318/v1/metrics",
    headers={"Authorization": f"Bearer {otlp_token}"}
)

# Set up providers
trace.set_tracer_provider(TracerProvider())
trace.get_tracer_provider().add_span_processor(
    BatchSpanProcessor(trace_exporter)
)

metrics.set_meter_provider(
    MeterProvider(
        metric_readers=[PeriodicExportingMetricReader(metric_exporter)]
    )
)
EOF

# Method 3: Langfuse configuration
cat << 'EOF'
# For Langfuse, add these environment variables to your docker-compose:
# 
# langfuse-server:
#   environment:
#     - TELEMETRY_ENABLED=true
#     - OTEL_EXPORTER_OTLP_ENDPOINT=http://alloy:4318
#     - OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer ${OTLP_TOKEN}
#     - OTEL_SERVICE_NAME=langfuse
#
# langfuse-worker:
#   environment:
#     - TELEMETRY_ENABLED=true
#     - OTEL_EXPORTER_OTLP_ENDPOINT=http://alloy:4318
#     - OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer ${OTLP_TOKEN}
#     - OTEL_SERVICE_NAME=langfuse-worker
EOF

# Testing the OTLP endpoint with authentication
echo ""
echo "Testing OTLP endpoint authentication:"
echo "======================================"
echo ""
echo "Without token (should fail if auth is enabled):"
curl -X POST http://localhost:4318/v1/metrics 2>/dev/null | head -c 100

echo ""
echo ""
echo "With token (should succeed):"
curl -X POST http://localhost:4318/v1/metrics \
  -H "Authorization: Bearer ${OTLP_TOKEN}" \
  -H "Content-Type: application/json" 2>/dev/null | head -c 100

echo ""
echo ""
echo "✅ Configuration complete! Your MCP servers and Langfuse can now send telemetry securely."