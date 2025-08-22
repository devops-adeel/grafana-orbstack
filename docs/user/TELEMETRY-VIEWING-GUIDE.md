# Viewing AI Service Telemetry in Grafana

A step-by-step guide to finding, analyzing, and understanding your AI service metrics and traces in Grafana.

## Quick Access

### 🔗 Direct Links
- **Grafana Dashboard**: http://grafana.local (login: admin/admin)
- **Prometheus Queries**: http://prometheus.local
- **Tempo Traces**: http://grafana.local/explore?left=%5B%22now-1h%22,%22now%22,%22Tempo%22%5D
- **Container Metrics**: http://cadvisor.local:8080

## Getting Started

### Step 1: Access Grafana

1. Open http://grafana.local in your browser
2. Login with:
   - Username: `admin`
   - Password: `admin`
3. You'll see the main dashboard

### Step 2: Navigate to Your Data

**For Traces (Tempo):**
- Click **Explore** in the left sidebar
- Select **Tempo** from the data source dropdown
- You'll see the trace search interface

**For Metrics (Prometheus):**
- Click **Explore** in the left sidebar  
- Select **Prometheus** from the data source dropdown
- You'll see the metrics query builder

**For Logs (Loki):**
- Click **Explore** in the left sidebar
- Select **Loki** from the data source dropdown
- You'll see the log query interface

## Finding Your AI Service Traces

### Method 1: Search by Service Name

1. Go to **Explore** → **Tempo**
2. Click **Search** tab
3. Under **Service Name**, select your service (e.g., `mcp-memory`, `ai-assistant`)
4. Click **Run query**
5. You'll see a list of traces

![Search by Service](search-by-service-placeholder.png)

### Method 2: Search by Trace ID

If you have a specific trace ID from your logs:

1. Go to **Explore** → **Tempo**
2. Click **TraceQL** tab
3. Enter the trace ID in the search box
4. Click **Run query**

### Method 3: Search by Time Range

1. Use the time picker in the top right
2. Select a time range (e.g., "Last 15 minutes")
3. Search will show traces from that period

## Understanding Trace Views

### Trace Timeline View

When you click on a trace, you'll see:

```
[Service Name] mcp.tool.search_memory          ━━━━━━━━━━━━━━━ 145ms
  ├─ [alloy] memory.search                     ━━━━━━━━━ 89ms
  │  └─ [database] query.execute               ━━━━ 45ms
  └─ [alloy] llm.openai.gpt-4                 ━━━━━━━━━━━━ 234ms
```

**Key Information:**
- **Service Name**: Which service created the span
- **Operation Name**: What operation was performed
- **Duration**: How long it took (bar length = duration)
- **Hierarchy**: Parent-child relationships show call flow

### Span Details Panel

Click on any span to see:

**Tags/Attributes:**
- `mcp.tool.name`: Tool that was invoked
- `mcp.param.*`: Parameters passed to the tool
- `llm.tokens.total`: Tokens used (for LLM calls)
- `memory.operation`: Memory operation type
- `error`: Error message if the span failed

**Events:**
- Timestamps of key events within the span
- Custom events you added (preprocessing, search, etc.)

## Viewing Metrics

### AI Operation Metrics

1. Go to **Explore** → **Prometheus**
2. Try these queries:

**Tool Invocation Rate:**
```promql
rate(mcp_tool_invocations_total[5m])
```
Shows tools being called per second

**Tool Duration (95th percentile):**
```promql
histogram_quantile(0.95, 
  rate(mcp_tool_duration_bucket[5m])
)
```
Shows how long tools take to execute

**Active Requests:**
```promql
mcp_active_requests
```
Shows currently running operations

**Memory Operations:**
```promql
sum by (operation) (
  rate(mcp_memory_operations_total[5m])
)
```
Shows memory system activity

### Container Metrics (via cAdvisor)

**Memory Usage:**
```promql
container_memory_usage_bytes{name=~"langfuse-prod.*"}
```

**CPU Usage:**
```promql
rate(container_cpu_usage_seconds_total{name=~"langfuse-prod.*"}[5m]) * 100
```

**Network Traffic:**
```promql
rate(container_network_receive_bytes_total{name=~"langfuse-prod.*"}[5m])
```

## Creating Custom Dashboards

### Step 1: Create New Dashboard

1. Click **Dashboards** → **New** → **New Dashboard**
2. Click **Add visualization**
3. Select **Prometheus** as data source

### Step 2: Add AI Metrics Panel

**Example: Tool Performance Panel**

1. Enter query:
```promql
histogram_quantile(0.95,
  sum by (tool, le) (
    rate(mcp_tool_duration_bucket[5m])
  )
)
```

2. Set visualization to **Time series**
3. In Legend, use: `{{tool}}`
4. Set title: "Tool Response Time (95th percentile)"

### Step 3: Add Trace Panel

1. Add new panel
2. Select **Tempo** as data source
3. Use Search query:
   - Service: Your service name
   - Span Name: `mcp.tool.*`
4. Set visualization to **Table**

### Step 4: Save Dashboard

1. Click **Save dashboard** icon
2. Name it (e.g., "AI Service Monitoring")
3. Choose folder or create new one

## Common Troubleshooting Views

### Finding Errors

**In Traces:**
1. Go to Tempo
2. Search with filter:
   - Status: Error
   - Service: Your service
3. Red spans indicate errors

**In Metrics:**
```promql
rate(mcp_tool_invocations_total{status="error"}[5m])
```

### Finding Slow Operations

**Query for slow tools:**
```promql
histogram_quantile(0.99, 
  rate(mcp_tool_duration_bucket[5m])
) > 1000
```
Shows tools taking >1 second

**In Tempo:**
1. Search traces
2. Sort by duration (descending)
3. Investigate longest traces

### Correlating with Container Issues

**High Memory Usage:**
1. Check container memory:
```promql
container_memory_usage_bytes{name=~".*your-service.*"} 
  / container_spec_memory_limit_bytes > 0.8
```

2. Find traces during that time
3. Look for memory-intensive operations

## Understanding the Data Flow

```
Your AI Service
     ↓
[Instrumentation Library]
     ↓
OTLP (ports 4317/4318)
     ↓
[Grafana Alloy]
     ↓
┌─────────┬──────────┬─────────┐
│Prometheus│  Tempo   │  Loki   │
│(Metrics) │ (Traces) │ (Logs)  │
└─────────┴──────────┴─────────┘
     ↓
[Grafana UI]
```

## Tips for Effective Monitoring

### 1. Use Trace Context

When you find an interesting trace:
- Copy the trace ID
- Search logs with that trace ID
- Check metrics at that exact time

### 2. Create Alerts

For critical metrics:
1. Go to **Alerting** → **Alert rules**
2. Create rule (e.g., high error rate)
3. Set notification channel

### 3. Use Annotations

Mark important events:
1. In any graph, Ctrl+Click to add annotation
2. Add description (e.g., "Deployed v2.0")
3. Annotations appear across all panels

### 4. Correlate Domains

Look for cross-domain patterns:
- Filter traces by `correlation.*` attributes
- Find GTD→Coding insights
- Track memory operations across services

## Keyboard Shortcuts

- `?` - Show all shortcuts
- `g h` - Go home
- `g e` - Go to Explore
- `g a` - Go to Alerting
- `Shift + ←/→` - Change time range
- `Ctrl + Z` - Zoom out time range

## Advanced Queries

### Multi-Service Traces

See traces that span multiple services:
```
{span.service.name=~"mcp-.*"} && duration > 500ms
```

### Token Usage Analysis

Track LLM token consumption:
```promql
sum by (model) (
  increase(llm_tokens_total[1h])
)
```

### Memory Loop Detection

Identify potential memory loops:
```promql
rate(mcp_memory_operations_total[1m]) > 2
```

### Cost Tracking

Estimate LLM costs:
```promql
sum(
  rate(llm_tokens_prompt[1h]) * 0.03 / 1000 +
  rate(llm_tokens_completion[1h]) * 0.06 / 1000
)
```

## Export and Sharing

### Export Data

1. Click the panel menu (three dots)
2. Select **Inspect** → **Data**
3. Click **Download CSV**

### Share Dashboard

1. Click **Share** button
2. Options:
   - Link: Copy URL to share
   - Snapshot: Create public snapshot
   - Export: Download JSON

### Create Reports

1. Set up dashboard with key metrics
2. Use **Reporting** (if enabled)
3. Schedule PDF generation

## Getting Help

### No Data Showing?

1. Check service is running: `docker ps`
2. Verify OTLP endpoint in service
3. Check Alloy logs: `docker logs grafana-alloy`
4. Test query in Prometheus: http://prometheus.local

### Slow Queries?

1. Reduce time range
2. Add more specific filters
3. Use recording rules for complex queries

### Missing Traces?

1. Check trace export is working
2. Verify service name matches
3. Expand time range
4. Check Tempo storage

## Next Steps

1. **Create Your Dashboard**: Import `/dashboards/ai-operations-unified.json`
2. **Set Up Alerts**: Configure alerts for error rates and latency
3. **Explore Correlations**: Link traces to container metrics
4. **Share Knowledge**: Document patterns you discover

---

**Remember**: The more you instrument, the better visibility you have. Start with basic tracing, then add custom attributes and events as you learn what matters for your AI services.