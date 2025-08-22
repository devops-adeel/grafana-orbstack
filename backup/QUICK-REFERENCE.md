# Backup System Quick Reference

Essential commands and recovery procedures for the Grafana backup system.

## Daily Operations

```bash
# Quick backup (SQLite only)
make backup-snapshot

# Complete backup (SQLite + exports + git)
make backup-all

# Check backup health
make backup-status

# View backup logs
make logs-backup
```

## Recovery Procedures

### Restore Latest Backup
```bash
# Interactive restore wizard
make backup-restore
# Select: 1 (complete), 2 (SQLite), 3 (dashboards), etc.

# Dry run first
make backup-restore-dry
```

### Disaster Recovery
```bash
# Complete system failure recovery
docker compose down
make backup-restore  # Select option 1
docker compose up -d
```

### Specific Component Restore
```bash
# SQLite database only
./backup/scripts/restore-grafana.sh --sqlite

# Dashboards only
./backup/scripts/restore-grafana.sh --dashboards

# Alerts only
./backup/scripts/restore-grafana.sh --alerts
```

## Troubleshooting

### No Backups Found
```bash
# Create initial backup
make backup-all

# Check backup location
ls -la backup/snapshots/latest/
```

### API Export Failures
```bash
# Test Grafana connectivity
curl -H "Authorization: Bearer $GRAFANA_API_KEY" \
     http://localhost:3001/api/health

# Check credentials
cat ~/.env | grep GRAFANA
```

### SQLite Access Issues
```bash
# Direct container copy
docker cp grafana-main:/var/lib/grafana/grafana.db backup/manual-backup.db

# Check volume
docker volume inspect grafana-orbstack_grafana-storage
```

### Git Hook Not Triggering
```bash
# Re-enable hooks
git config core.hooksPath .githooks

# Test manually
./.githooks/post-commit
```

## Configuration

### Key Paths
- Config: `backup/configs/backup.conf`
- Snapshots: `backup/snapshots/latest/`
- Exports: `backup/exports/`
- Logs: `backup/logs/`

### Retention Settings
- Daily snapshots: 7 days
- Weekly archives: 4 weeks
- Logs: 30 days

### Environment Variables
```bash
# ~/.env file
GRAFANA_API_KEY="your-service-account-token"
GRAFANA_HOST="http://localhost:3001"
```

## Automation

### Schedule Daily Backups (macOS)
```bash
make backup-schedule  # 2 AM daily
# To disable:
launchctl unload ~/Library/LaunchAgents/com.grafana.backup.plist
```

### Manual Cron (Linux)
```cron
0 2 * * * /path/to/backup/scripts/grafana-backup.sh --snapshot-only
```

## Emergency Commands

### Force Backup Now
```bash
./backup/scripts/grafana-backup.sh --force

# With specific components
./backup/scripts/export-runtime.sh --dashboards --alerts
```

### Clean Old Backups
```bash
make backup-clean

# Manual cleanup
find backup/snapshots/daily -mtime +7 -delete
```

### Validate Integrity
```bash
./backup/scripts/monitor-backups.sh --validate

# Check specific backup
gunzip -t backup/snapshots/latest/grafana.db.gz
```

## Monitoring Integration

### View Metrics
```bash
# Backup age
curl -s http://prometheus.local:9090/api/v1/query?query=grafana_backup_age_hours

# Last success
curl -s http://prometheus.local:9090/api/v1/query?query=grafana_backup_last_success_timestamp
```

### Import Dashboard
1. Open http://grafana.local
2. Dashboards → Import
3. Upload `/dashboards/backup-health.json`

## Full Documentation

For detailed information, see [backup/README.md](README.md)