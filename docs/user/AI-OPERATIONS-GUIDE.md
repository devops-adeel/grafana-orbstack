# AI Operations Guide

## Quick Start (3 Commands)

```bash
# 1. Start the observability stack
cd /Users/adeel/Documents/1_projects/grafana-orbstack
docker compose -f docker-compose.grafana.yml up -d

# 2. Wait for services to be healthy (about 30 seconds)
docker ps | grep grafana-orbstack

# 3. Open Grafana
open http://grafana.local
# Login: admin / admin
```

## Unified AI Operations Dashboard

### Creating Your Single Pane of Glass

The unified dashboard combines critical metrics from GraphRAG, System Resources, and APM into one view optimized for reactive monitoring.

**Key Panels to Include:**

1. **AI Agent Health** (Top Row - Always Visible)
   - MCP Tool Invocations Rate (line graph)
   - Memory Operations Pattern (stacked bars)
   - Active Requests Gauge
   - Cache Hit Rate Gauge

2. **Performance Indicators** (Middle Row)
   - Tool Latency Percentiles (P50/P95/P99)
   - FalkorDB Query Performance
   - GraphRAG Memory Usage
   - Error Rate Timeline

3. **System Resources** (Bottom Row - Context)
   - Container CPU/Memory (key services only)
   - Host CPU Gauge (from Netdata)
   - Network I/O (if experiencing slowness)

### Dashboard URL
Once created, access at: `http://grafana.local/d/ai-ops-unified/ai-operations`

## Debug Scenarios

### 🔴 Scenario 1: Memory Loops
**Symptom:** AI agent seems stuck, repeated operations, high CPU

**Pattern Recognition:**
- Visual: Rapid alternating red/yellow bars in "Memory Operations by Type" panel
- Metric spike: >200 operations/minute
- Alternating capture/supersede operations

**Investigation Query:**
```promql
# Check memory operation rate
rate(mcp_memory_operations_total[1m])

# Identify operation types
sum by(operation) (rate(mcp_memory_operations_total[1m]))
```

**Fix:**
1. Check GTD Coach logs: `docker logs gtd-coach-1 --tail 100 | grep -i conflict`
2. Restart if needed: `docker restart gtd-coach-1`
3. Clear memory state if persistent: `docker exec falkordb redis-cli FLUSHDB`

---

### 🔴 Scenario 2: Slow Responses
**Symptom:** AI responses taking longer than usual

**Pattern Recognition:**
- MCP tool duration P95 > 2 seconds
- Gradual increase in latency over time
- No corresponding error increase

**Investigation Query:**
```promql
# Check tool latency percentiles
histogram_quantile(0.95, 
  rate(mcp_tool_duration_bucket[5m])
)

# Identify slow tools
topk(5, 
  histogram_quantile(0.95, 
    sum by(tool) (rate(mcp_tool_duration_bucket[5m]))
  )
)
```

**Fix:**
1. Check LMStudio model: May need to switch to smaller model
2. Verify FalkorDB performance: `docker stats falkordb`
3. Check cache hit rate: Should be >70%
4. Consider memory pressure: Check host memory usage

---

### 🔴 Scenario 3: Context Loss
**Symptom:** AI agent not remembering recent interactions

**Pattern Recognition:**
- Cache hit rate drops below 70%
- Memory operation failures (check logs)
- Graph traversal timeouts

**Investigation Query:**
```promql
# Check cache effectiveness
(redis_keyspace_hits_total / 
 (redis_keyspace_hits_total + redis_keyspace_misses_total)) * 100

# Check FalkorDB memory
redis_memory_used_bytes{job="falkordb"} / 1024 / 1024
```

**Fix:**
1. Check FalkorDB memory: `docker exec falkordb redis-cli INFO memory`
2. Warm cache if cold: Trigger a few common queries
3. Verify Graphiti is connected: `docker logs grafana-alloy | grep graphiti`
4. Check for network issues between services

## Critical Thresholds

### 🚦 Traffic Light System

| Metric | 🟢 Normal | 🟡 Warning | 🔴 Critical | Action |
|--------|-----------|------------|-------------|--------|
| **MCP Tool Invocations** | 10-50/min | >100/min | >200/min | Check for loops |
| **Tool Latency P95** | <1s | 1-2s | >5s | Check model/resources |
| **Memory Operations** | 5-30/min | >60/min | >120/min | Investigate conflicts |
| **Cache Hit Rate** | >85% | 70-85% | <70% | Warm cache/restart |
| **FalkorDB Memory** | <2GB | 2-3GB | >3GB | Consider cleanup |
| **Container Memory Total** | <4GB | 4-6GB | >8GB | Resource pressure |
| **Host CPU** | <60% | 60-80% | >80% | Reduce load |

## Common Patterns Visual Guide

### Normal Operation
```
Memory Ops:  █ █ █ █ █ (steady, green bars)
Tool Calls:  ───────── (smooth line, gradual changes)
Cache Rate:  ████████░ (consistently >85%)
```

### Memory Loop Pattern
```
Memory Ops:  ██████████ (rapid alternating colors)
Tool Calls:  ╱╲╱╲╱╲╱╲╱ (spiky pattern)
Cache Rate:  ████░░░░░ (dropping)
```

### Resource Exhaustion
```
Memory Ops:  █████...  (operations stop)
Tool Calls:  ─────╱... (timeout spike then flat)
Cache Rate:  ██░░░░░░░ (very low)
```

## Quick Health Check

Run this when something feels off:

```bash
# One command health check
curl -s http://prometheus.local:9090/api/v1/query?query=up | \
  jq '.data.result[] | select(.value[1]=="0") | .metric.job' || \
  echo "✅ All exporters up"

# Check current load
echo "=== Current AI Operations Load ==="
curl -s http://prometheus.local:9090/api/v1/query?query='rate(mcp_tool_invocations_total[1m])' | \
  jq '.data.result[0].value[1]' | \
  xargs printf "Tool calls/min: %.0f\n"

curl -s http://prometheus.local:9090/api/v1/query?query='redis_memory_used_bytes{job="falkordb"}/1024/1024' | \
  jq '.data.result[0].value[1]' | \
  xargs printf "FalkorDB Memory: %.0f MB\n"
```

## Tips for Reactive Monitoring

1. **Keep Grafana tab pinned** - Quick CMD+number access
2. **Set browser bookmark** - `http://grafana.local/d/ai-ops-unified`
3. **Watch for pattern changes** - Gradual degradation often precedes failures
4. **Trust the traffic lights** - Yellow = investigate, Red = act now
5. **Check newest memories first** - Recent operations most likely to cause issues

## Related Resources
- [Troubleshooting Guide](TROUBLESHOOTING.md) - Problem/solution reference
- [Technical Documentation](../dev/README.md) - Architecture and configuration
- Dashboard JSONs: `/dashboards/*.json`