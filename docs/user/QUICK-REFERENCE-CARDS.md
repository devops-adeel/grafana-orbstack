# 🚀 Quick Reference Cards - Grafana AI Observability Stack

> **Purpose**: Immediate solutions for critical issues. Keep this file open during operations.  
> **Format**: Copy-paste ready commands. Test in dev first when possible.  
> **Updated**: 2024-08-22

---

## 🚨 CRITICAL ISSUES

### 💾 DISK FULL EMERGENCY
**Symptoms**: `no space left on device`, containers failing to start, restart loops

**QUICK CHECKS:**
```bash
df -h /var | grep disk                                           # Check available space
docker system df                                                 # Check Docker usage
docker ps --format "table {{.Names}}\t{{.Size}}" | sort -k2 -hr # Find large containers
```

**IMMEDIATE FIXES:**
```bash
docker system prune -f --volumes                                 # ⚠️ Removes stopped containers/unused volumes
docker system prune -a -f --volumes                             # ⚠️ AGGRESSIVE: Removes all unused images too
docker logs --since 24h grafana-main 2>&1 | tail -1000         # Check before clearing logs
```

**GTD COACH SPECIFIC** (Common 100GB+ culprit):
```bash
docker ps | grep gtd-coach                                      # Find GTD coach containers
docker stop $(docker ps -q --filter name=gtd-coach)           # Stop all GTD coaches
docker rm $(docker ps -aq --filter name=gtd-coach)            # Remove GTD coach containers
```

---

### 🔐 GRAFANA LOGIN FAILURES
**Symptoms**: 500 Internal Server Error, "Failed to find organization", login page refreshes

**QUICK CHECKS:**
```bash
docker logs grafana-main --tail 50 | grep -i "error\|auth"    # Check auth errors
curl -X POST http://localhost:3001/login -H "Content-Type: application/json" -d '{"user":"admin","password":"admin"}'
curl http://localhost:3001/api/org                             # Check org exists
```

**ANONYMOUS AUTH CONFLICT FIX:**
```bash
grep "GF_AUTH_ANONYMOUS" docker-compose.grafana.yml            # Check if anonymous enabled
# If enabled, comment out these lines in docker-compose.grafana.yml:
# - GF_AUTH_ANONYMOUS_ENABLED=true
# - GF_AUTH_ANONYMOUS_ORG_ROLE=Admin
docker compose -f docker-compose.grafana.yml restart grafana   # Restart after change
```

**RESET GRAFANA DATABASE** (Last Resort):
```bash
docker compose -f docker-compose.grafana.yml stop grafana      # Stop Grafana
docker volume rm grafana-orbstack_grafana-storage              # ⚠️ DELETES all dashboards/settings
docker compose -f docker-compose.grafana.yml up -d grafana     # Recreate with fresh DB
```

---

### 🌐 502 BAD GATEWAY / ORBSTACK NETWORKING
**Symptoms**: `502 Bad Gateway`, `no route to host`, works on localhost but not .local domain

**QUICK CHECKS:**
```bash
curl http://localhost:3001/api/health                          # Test direct port
curl http://grafana.local/api/health                          # Test OrbStack domain
curl http://grafana-main.orb.local/api/health                 # Test default OrbStack domain
docker inspect grafana-main | jq '.[0].NetworkSettings.Networks.observability.IPAddress'
```

**ORBSTACK ROUTING FIX:**
```bash
docker compose -f docker-compose.grafana.yml stop grafana      # Stop container
docker compose -f docker-compose.grafana.yml rm -f grafana     # Remove container
docker compose -f docker-compose.grafana.yml up -d grafana     # Recreate to refresh routing
```

**NETWORK ENDPOINT CONFLICTS:**
```bash
docker network inspect observability | jq '.[] | .Containers'  # Check network endpoints
docker network disconnect observability grafana-main           # Disconnect problematic endpoint
docker network connect observability grafana-main              # Reconnect
```

---

## 🔧 COMMON OPERATIONS

### ✅ HEALTH CHECKS
**Full Stack Status:**
```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "grafana|prometheus|tempo|loki|alloy"
curl -s http://prometheus.local:9090/api/v1/query?query=up | jq '.data.result[] | select(.value[1]=="0") | .metric.job'
```

**Service Endpoints Test:**
```bash
for url in grafana:3001 prometheus:9090 tempo:3200 alloy:4317; do echo -n "$url: "; curl -s -o /dev/null -w "%{http_code}\n" http://localhost:${url##*:}; done
```

**AI Agent Metrics Check:**
```bash
curl -s http://prometheus.local:9090/api/v1/query?query='rate(mcp_tool_invocations_total[1m])' | jq '.data.result[0].value[1]'
curl -s http://prometheus.local:9090/api/v1/query?query='rate(mcp_memory_operations_total[1m])' | jq '.data.result[0].value[1]'
```

---

### 🔄 SERVICE MANAGEMENT
**Start Everything:**
```bash
docker compose -f docker-compose.grafana.yml up -d             # Start all services
docker compose -f docker-compose.grafana.yml ps               # Verify running
```

**Restart Specific Service:**
```bash
docker compose -f docker-compose.grafana.yml restart grafana   # Restart Grafana only
docker restart prometheus-local tempo-local loki-local         # Restart storage backends
```

**Stop Everything Cleanly:**
```bash
docker compose -f docker-compose.grafana.yml stop             # Stop all containers
docker compose -f docker-compose.grafana.yml down             # Stop and remove containers
docker compose -f docker-compose.grafana.yml down -v          # ⚠️ Also removes volumes (data)
```

---

### 📊 PERFORMANCE MONITORING
**Container Resource Usage:**
```bash
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" | grep -E "grafana|prometheus|tempo|loki|alloy|gtd|falkor|langfuse"
```

**Top Memory Consumers:**
```bash
docker ps -q | xargs docker stats --no-stream --format "table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}" | sort -k3 -hr | head -10
```

**Check Memory Loops (AI Agents):**
```bash
curl -s http://prometheus.local:9090/api/v1/query?query='rate(mcp_memory_operations_total[1m])' | jq '.data.result[] | select(.value[1] | tonumber > 2)'
```

---

## 🩺 TROUBLESHOOTING FLOWS

### 🔍 GRAFANA NOT ACCESSIBLE
```bash
# Step 1: Check container
docker ps | grep grafana                                       # Is it running?
↓ NO → docker compose -f docker-compose.grafana.yml up -d grafana

# Step 2: Check logs
docker logs grafana-main --tail 100 | grep -i error           # Any errors?
↓ YES → Check specific error below

# Step 3: Test endpoints
curl http://localhost:3001/api/health                         # Direct port work?
↓ NO → docker restart grafana-main
↓ YES → Continue

curl http://grafana.local/api/health                         # Domain work?
↓ NO → See "502 BAD GATEWAY" section above
```

### 🔍 NO METRICS IN DASHBOARDS
```bash
# Step 1: Check Prometheus
curl http://prometheus.local:9090/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, health: .health}'

# Step 2: Check Alloy (OTLP Collector)
docker logs grafana-alloy --tail 50 | grep -E "error|refused"

# Step 3: Check specific exporter
docker ps | grep exporter                                     # Are exporters running?
docker logs redis-exporter --tail 20                         # Check exporter logs
```

### 🔍 HIGH CPU/MEMORY USAGE
```bash
# Step 1: Identify culprit
docker stats --no-stream --format "json" | jq -s 'sort_by(.CPUPerc | rtrimstr("%") | tonumber) | reverse | .[0:5] | .[] | {name: .Name, cpu: .CPUPerc, mem: .MemUsage}'

# Step 2: Check for memory loops (AI specific)
docker logs gtd-coach-1 --tail 100 | grep -c "conflict\|retry\|loop"

# Step 3: Emergency restart
docker restart $(docker ps --format "{{.Names}}" | grep -E "gtd|mcp|falkor")
```

---

## 🛠️ CONFIGURATION CHANGES

### 📝 MODIFY GRAFANA SETTINGS
```bash
# Edit configuration
vi docker-compose.grafana.yml                                 # Make changes

# Apply changes
docker compose -f docker-compose.grafana.yml up -d grafana    # Recreate with new config

# Verify changes
docker exec grafana-main env | grep GF_                       # Check environment variables
```

### 📝 UPDATE PROMETHEUS SCRAPING
```bash
# Edit Prometheus config
vi config/prometheus.yml                                      # Add new targets

# Reload configuration (without restart)
docker exec prometheus-local kill -HUP 1                      # Reload config
curl -X POST http://prometheus.local:9090/-/reload           # Alternative reload method
```

---

## 🆘 EMERGENCY RECOVERY

### 💥 COMPLETE STACK RESET
```bash
# ⚠️ WARNING: This removes all data and starts fresh
docker compose -f docker-compose.grafana.yml down -v          # Stop and remove everything
docker system prune -a -f --volumes                          # Clean all Docker resources
docker compose -f docker-compose.grafana.yml up -d           # Start fresh
```

### 📦 BACKUP CRITICAL DATA
```bash
# Backup Grafana dashboards
docker exec grafana-main grafana-cli admin export-dashboard-json /var/lib/grafana/dashboards-backup.json

# Backup FalkorDB
docker exec falkordb redis-cli BGSAVE                        # Create RDB snapshot
docker cp falkordb:/data/dump.rdb ./falkordb-backup.rdb    # Copy backup locally

# Backup Prometheus data
docker run --rm -v grafana-orbstack_prometheus-data:/data -v $(pwd):/backup alpine tar czf /backup/prometheus-backup.tar.gz /data
```

---

## 📋 USEFUL ALIASES

Add to your shell profile for faster access:

```bash
# Grafana stack aliases
alias gs-up='docker compose -f docker-compose.grafana.yml up -d'
alias gs-down='docker compose -f docker-compose.grafana.yml down'
alias gs-restart='docker compose -f docker-compose.grafana.yml restart'
alias gs-logs='docker compose -f docker-compose.grafana.yml logs -f --tail=100'
alias gs-status='docker ps --format "table {{.Names}}\t{{.Status}}" | grep -E "grafana|prometheus|tempo|loki|alloy"'

# Quick checks
alias check-disk='df -h /var | grep disk && docker system df'
alias check-grafana='curl -s -o /dev/null -w "Grafana HTTP: %{http_code}\n" http://localhost:3001/api/health'
alias check-metrics='curl -s http://prometheus.local:9090/api/v1/query?query=up | jq ".data.result[] | select(.value[1]==\"0\")"'

# Cleanup
alias docker-clean='docker system prune -f --volumes'
alias docker-clean-all='docker system prune -a -f --volumes'
```

---

## 📞 SUPPORT RESOURCES

- **GitHub Issues**: https://github.com/grafana/grafana/issues
- **OrbStack Docs**: https://docs.orbstack.dev/docker/domains
- **Grafana Community**: https://community.grafana.com
- **This Project**: `/Users/adeel/Documents/1_projects/grafana-orbstack`

---

> **Last Updated**: 2024-08-22  
> **Maintained By**: DevOps Team  
> **Version**: 1.0.0