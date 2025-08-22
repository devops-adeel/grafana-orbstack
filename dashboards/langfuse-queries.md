# Langfuse Container Monitoring Queries

## Memory Monitoring

### Current Memory Usage per Container
```promql
container_memory_usage_bytes{name=~"langfuse-prod.*"}
```

### Memory Usage Percentage (relative to limit)
```promql
100 * (container_memory_usage_bytes{name=~"langfuse-prod.*"} 
/ container_spec_memory_limit_bytes{name=~"langfuse-prod.*"})
```

### Memory Working Set (actual active memory)
```promql
container_memory_working_set_bytes{name=~"langfuse-prod.*"}
```

## CPU Monitoring

### CPU Usage Rate (per second)
```promql
rate(container_cpu_usage_seconds_total{name=~"langfuse-prod.*"}[5m]) * 100
```

### CPU Throttling
```promql
rate(container_cpu_cfs_throttled_seconds_total{name=~"langfuse-prod.*"}[5m])
```

## Network Monitoring

### Network Ingress Rate (bytes/sec)
```promql
rate(container_network_receive_bytes_total{name=~"langfuse-prod.*"}[5m])
```

### Network Egress Rate (bytes/sec)
```promql
rate(container_network_transmit_bytes_total{name=~"langfuse-prod.*"}[5m])
```

## Disk I/O Monitoring

### Disk Read Rate (bytes/sec)
```promql
rate(container_fs_reads_bytes_total{name=~"langfuse-prod.*"}[5m])
```

### Disk Write Rate (bytes/sec)
```promql
rate(container_fs_writes_bytes_total{name=~"langfuse-prod.*"}[5m])
```

## Container Health

### Container Restart Count
```promql
container_start_time_seconds{name=~"langfuse-prod.*"}
```

### Container Last Seen (liveness check)
```promql
time() - container_last_seen{name=~"langfuse-prod.*"}
```

## Alerting Rules Examples

### High Memory Usage Alert (>80%)
```promql
(container_memory_usage_bytes{name=~"langfuse-prod.*"} 
/ container_spec_memory_limit_bytes{name=~"langfuse-prod.*"}) > 0.8
```

### High CPU Usage Alert (>70%)
```promql
rate(container_cpu_usage_seconds_total{name=~"langfuse-prod.*"}[5m]) > 0.7
```

### Container Down Alert
```promql
up{job="cadvisor"} == 0
```

## Grafana Dashboard Variables

### Container Name Variable
```promql
label_values(container_memory_usage_bytes{name=~"langfuse-prod.*"}, name)
```

### Service Name Variable
```promql
label_values(container_memory_usage_bytes{name=~"langfuse-prod.*"}, container_label_com_docker_compose_service)
```

## Combined Queries

### Top 5 Memory Consumers
```promql
topk(5, container_memory_usage_bytes{name=~"langfuse-prod.*"})
```

### Total Cluster Memory Usage
```promql
sum(container_memory_usage_bytes{name=~"langfuse-prod.*"})
```

### Per-Service Memory Usage
```promql
sum by (container_label_com_docker_compose_service) 
(container_memory_usage_bytes{name=~"langfuse-prod.*"})
```

## Access URLs
- Grafana: http://grafana.local (admin/admin)
- Prometheus: http://prometheus.local
- cAdvisor: http://cadvisor.local:8080
- Langfuse: https://langfuse.local