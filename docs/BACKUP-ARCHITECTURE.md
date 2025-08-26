# Grafana Observability Stack - Backup Architecture

## Overview

This document describes the sophisticated backup system implemented for the Grafana Observability Stack using `offen/docker-volume-backup`. The system provides industrial-grade backup capabilities with failsafe mechanisms, tiered storage, and automated verification.

## Architecture Components

### 1. Segregated Backup Services

The backup system uses **two primary backup containers** plus a metrics exporter:

```
┌─────────────────────────────────────────────────────────────┐
│                    Backup Infrastructure                      │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌──────────────────┐  ┌──────────────────┐  ┌───────────┐ │
│  │ backup-critical  │  │  backup-bulk     │  │  backup-  │ │
│  │                  │  │                  │  │  metrics  │ │
│  │ • Grafana       │  │ • Tempo          │  │           │ │
│  │ • Prometheus    │  │ • Loki           │  │ • Exports │ │
│  │ • Metrics       │  │                  │  │   JSON    │ │
│  │                  │  │                  │  │           │ │
│  │ Daily @ 2AM     │  │ Weekly @ 3AM     │  │  Hourly   │ │
│  │ 30-day retain   │  │ 14-day retain    │  │           │ │
│  └──────────────────┘  └──────────────────┘  └───────────┘ │
│                                                               │
└─────────────────────────────────────────────────────────────┘
```

#### backup-critical
- **Purpose**: Daily backups of critical operational data
- **Volumes**: Grafana SQLite, Prometheus snapshots, failsafe metrics
- **Schedule**: 2 AM daily
- **Retention**: 30 days
- **Compression**: gzip (fast)
- **Size**: ~100-500MB per backup

#### backup-bulk
- **Purpose**: Weekly backups of high-volume trace/log data
- **Volumes**: Tempo traces, Loki logs
- **Schedule**: 3 AM Sundays
- **Retention**: 14 days
- **Compression**: zstd (high compression)
- **Size**: ~1-3GB per backup

#### backup-metrics
- **Purpose**: Circular validation - exports metrics to JSON
- **Frequency**: Hourly
- **Storage**: Embedded in Grafana volume
- **Use Case**: Bootstrap recovery if Prometheus fails

### 2. Storage Tiers

```
┌──────────────┐     rsync      ┌──────────────┐     optional    ┌──────────────┐
│  Hot Tier    │ ───────────────▶│  Warm Tier   │ ──────────────▶│  Cold Tier   │
│              │                 │              │                 │              │
│ Local SSD    │                 │ External     │                 │ S3/MinIO     │
│ 7-day cache  │                 │ Drive        │                 │ Long-term    │
└──────────────┘                 └──────────────┘                 └──────────────┘
```

#### Hot Tier (Local SSD)
- **Location**: `${HOME}/GrafanaBackups/`
- **Purpose**: Fast recovery, recent backups
- **Retention**: 7-30 days depending on type
- **Access**: Always available

#### Warm Tier (External Drive)
- **Location**: `/Volumes/SanDisk/GrafanaBackups/`
- **Purpose**: Extended retention, disaster recovery
- **Sync**: Automatic via rsync when drive mounted
- **Detection**: Automatic with fallback to hot tier only

#### Cold Tier (Optional)
- **Location**: S3, MinIO, Azure Blob
- **Purpose**: Compliance, long-term archive
- **Configuration**: Via environment variables

### 3. Prometheus Snapshot Strategy

Traditional backup approaches fail with Prometheus TSDB due to its use of memory-mapped files and write-ahead logs. Our solution uses the **snapshot API**:

```mermaid
sequenceDiagram
    participant Backup as backup-critical
    participant Prometheus
    participant Volume as /tmp/prometheus-snapshot
    
    Backup->>Prometheus: POST /api/v1/admin/tsdb/snapshot
    Prometheus->>Prometheus: Create hard links in /prometheus/snapshots/
    Prometheus-->>Backup: snapshot name
    Backup->>Prometheus: Copy snapshot to /tmp/prometheus-snapshot/
    Backup->>Prometheus: Delete original snapshot (cleanup)
    Backup->>Volume: Archive /tmp/prometheus-snapshot/
```

**Key Points**:
- No downtime required (unlike container stop method)
- Consistent point-in-time backup
- Hard links save space initially
- Cleanup prevents storage bloat

### 4. Failsafe Circular Validation

The "who watches the watchers" problem is solved with a lightweight metrics exporter:

```
┌─────────────┐
│ Prometheus  │──────── Stores metrics
└─────────────┘              │
       ▲                     │
       │                     ▼
   Monitors           ┌─────────────┐
       │              │   backup-   │
       │              │   metrics   │
       │              └─────────────┘
       │                     │
       │                     │ Exports to JSON
       │                     ▼
       │              ┌─────────────┐
       └──────────────│  Grafana    │
                      │   Volume    │
                      └─────────────┘
```

This ensures that even if Prometheus fails completely, we have:
1. Recent backup status in JSON format
2. Service health snapshots
3. Key metrics for bootstrap recovery

### 5. Backup Lifecycle Hooks

The system uses Docker labels for sophisticated pre/post backup operations:

#### Grafana
```yaml
docker-volume-backup.stop-during-backup: grafana-critical
docker-volume-backup.archive-pre: Export dashboards to JSON
```
- Stops briefly for SQLite consistency
- Exports dashboards via CLI before backup

#### Prometheus  
```yaml
docker-volume-backup.exec-label: prometheus-snapshot
docker-volume-backup.archive-pre: Create and copy TSDB snapshot
docker-volume-backup.archive-post: Cleanup snapshot directory
```
- Never stops (uses snapshot API)
- Creates consistent snapshot before backup
- Cleans up to prevent storage bloat

#### Tempo/Loki
```yaml
docker-volume-backup.stop-during-backup: tempo-loki
```
- Brief stop for consistency
- Grouped together for efficiency

## Operational Procedures

### Starting the Backup System

```bash
# Start all backup services
docker compose -f docker-compose.backup.yml up -d

# Start only critical backups
docker compose -f docker-compose.backup.yml up -d backup-critical

# View logs
docker logs -f backup-critical
```

### Manual Backup Execution

```bash
# Trigger immediate critical backup
docker exec backup-critical backup

# Full manual backup (all volumes)
docker compose -f docker-compose.backup.yml run --rm backup-manual-full

# Prometheus-only backup
docker compose -f docker-compose.backup.yml run --rm backup-manual-prometheus
```

### Verification

```bash
# Run comprehensive verification
./backup/scripts/verify-backups.sh

# Verbose mode with details
./backup/scripts/verify-backups.sh --verbose

# Test restore procedure (dry run)
./backup/scripts/verify-backups.sh --test-restore
```

### Restore Procedures

#### Grafana Restore
```bash
# Stop Grafana
docker stop grafana-main

# Extract backup
tar -xzf ~/GrafanaBackups/critical/critical-latest.tar.gz \
    -C /tmp backup/grafana/

# Copy to volume
docker run --rm \
    -v grafana-orbstack_grafana-storage:/grafana \
    -v /tmp/backup/grafana:/restore:ro \
    alpine cp -a /restore/* /grafana/

# Start Grafana
docker start grafana-main
```

#### Prometheus Restore
```bash
# Use the dedicated restore script
./backup/scripts/restore-prometheus.sh \
    ~/GrafanaBackups/critical/critical-latest.tar.gz

# Force mode (skip confirmations)
./backup/scripts/restore-prometheus.sh \
    ~/GrafanaBackups/critical/critical-latest.tar.gz --force
```

## Configuration

### Environment Variables

Key configuration in `backup/configs/backup.env`:

| Variable | Default | Description |
|----------|---------|-------------|
| `BACKUP_DIR` | `${HOME}/GrafanaBackups` | Primary backup location |
| `EXTERNAL_DRIVE` | `SanDisk` | External drive name |
| `RETENTION_CRITICAL` | `30` | Days to keep critical backups |
| `RETENTION_BULK` | `14` | Days to keep bulk backups |
| `NOTIFICATION_URLS` | (empty) | Notification endpoints |
| `GZIP_PARALLELISM` | `4` | Compression threads |

### Notification Setup

Configure notifications for backup failures:

```bash
# Email notifications
NOTIFICATION_URLS=smtp://user:pass@smtp.gmail.com:587/?from=backup@example.com&to=admin@example.com

# Slack notifications
NOTIFICATION_URLS=slack://xoxb-token@workspace#alerts

# Multiple destinations
NOTIFICATION_URLS=smtp://...,slack://...,discord://...
```

### External Drive Detection

The system automatically detects external drives:

1. Checks `/Volumes/${EXTERNAL_DRIVE}/`
2. If mounted: Syncs via rsync after each backup
3. If not mounted: Continues with local backups only
4. Logs status but doesn't fail

## Monitoring

### Backup Metrics

The system exports metrics to Prometheus via OTLP:

- `grafana_backup_last_success_timestamp` - Last successful backup
- `grafana_backup_validation_status` - Validation pass/fail
- `grafana_backup_size_bytes` - Backup sizes
- `grafana_backup_duration_seconds` - Backup duration

### Health Checks

Monitor backup health via:

1. **Grafana Dashboard**: Import `dashboards/backup-health.json`
2. **Prometheus Queries**:
   ```promql
   # Backup age
   time() - grafana_backup_last_success_timestamp
   
   # Success rate
   rate(grafana_backup_success_total[24h])
   ```
3. **Container Status**:
   ```bash
   docker ps | grep backup-
   ```

## Troubleshooting

### Common Issues

#### 1. Prometheus Snapshot Fails
**Symptom**: "Admin APIs disabled" error
**Solution**: Ensure `--web.enable-admin-api` flag is set in Prometheus

#### 2. External Drive Not Syncing
**Symptom**: No files in `/Volumes/SanDisk/GrafanaBackups/`
**Solution**: 
- Check drive is mounted: `ls /Volumes/`
- Check rsync in logs: `docker logs backup-critical | grep rsync`

#### 3. Backup Archive Corrupted
**Symptom**: "tar: Unexpected end of file" error
**Solution**:
- Check disk space: `df -h`
- Verify container didn't crash: `docker logs backup-critical`
- Test with manual backup: `docker exec backup-critical backup`

#### 4. Restore Fails with Permission Errors
**Symptom**: "Permission denied" during restore
**Solution**:
```bash
# Fix permissions on restored data
docker run --rm \
    -v grafana-orbstack_prometheus-data:/prometheus \
    alpine chown -R nobody:nobody /prometheus
```

### Debug Mode

Enable debug output in `backup/configs/backup.env`:

```bash
DEBUG_MODE=true
VERBOSE_OUTPUT=true
EXEC_FORWARD_OUTPUT=true
```

Then check logs:
```bash
docker logs -f backup-critical 2>&1 | grep -E "DEBUG|ERROR"
```

## Best Practices

### 1. Regular Verification
- Run `verify-backups.sh` weekly
- Test restore procedure monthly
- Monitor backup metrics in Grafana

### 2. Storage Management
- Keep 30 days locally for critical data
- Sync to external drive when available
- Consider cloud storage for compliance

### 3. Security
- Never store credentials in backup configs
- Use Docker secrets or environment files
- Consider GPG encryption for sensitive data

### 4. Performance
- Stagger backup schedules (2 AM, 3 AM)
- Use appropriate compression (gz vs zst)
- Monitor I/O impact during backups

## Recovery Time Objectives (RTO)

| Component | Backup Frequency | Recovery Time | Data Loss (RPO) |
|-----------|-----------------|---------------|-----------------|
| Grafana | Daily | 10 minutes | 24 hours |
| Prometheus | Daily | 15 minutes | 24 hours |
| Tempo | Weekly | 20 minutes | 7 days |
| Loki | Weekly | 20 minutes | 7 days |
| Full Stack | Daily/Weekly | 30 minutes | 24 hours |

## Maintenance

### Monthly Tasks
- Verify external drive sync
- Test restore procedure
- Review retention policies
- Check storage usage

### Quarterly Tasks
- Update `offen/docker-volume-backup` image
- Review and tune backup schedules
- Audit backup metrics and alerts
- Document any configuration changes

## References

- [offen/docker-volume-backup Documentation](https://offen.github.io/docker-volume-backup/)
- [Prometheus TSDB Snapshot API](https://prometheus.io/docs/prometheus/latest/querying/api/#tsdb-admin-apis)
- [Grafana Backup Best Practices](https://grafana.com/docs/grafana/latest/administration/back-up-grafana/)
- [Docker Volume Management](https://docs.docker.com/storage/volumes/)