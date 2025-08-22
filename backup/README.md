# Grafana Observability Stack Backup System

A comprehensive backup solution for the Grafana observability stack, following enterprise-grade practices inspired by the Langfuse backup strategy.

**Quick Reference**: For essential commands and emergency procedures, see [QUICK-REFERENCE.md](QUICK-REFERENCE.md)

## Features

- **Event-Driven Backups**: Git hooks automatically trigger backups on configuration changes
- **Three-Tier Strategy**: Separates provisioned configs, SQLite database, and runtime configurations
- **Full Observability**: Integrated metrics export to existing Grafana/Prometheus stack
- **Restoration Capabilities**: Complete restore scripts with dry-run support
- **Automated Monitoring**: Health checks, integrity validation, and alerting

## Quick Start

```bash
# Start the observability stack
make up

# Create your first backup
make backup-all

# Check backup health
make backup-status

# Restore from backup (interactive)
make backup-restore
```

## Backup Components

### 1. Configuration Files (Git-tracked)
- `/config/*.yml` - Prometheus, Alloy, Tempo configurations
- `/dashboards/*.json` - Grafana dashboard definitions
- Automatically committed on changes via git hooks

### 2. SQLite Database Snapshots
- Grafana's internal database (`grafana.db`)
- Daily snapshots with 7-day retention
- Weekly archives with 4-week retention
- Compressed with gzip for space efficiency

### 3. Runtime Exports (API-based)
- Dashboards created/modified via UI
- Alert rules and notification policies
- Datasource configurations
- Contact points and mute timings

## Directory Structure

```
backup/
├── configs/
│   └── backup.conf          # Central configuration file
├── scripts/
│   ├── grafana-backup.sh    # Main backup orchestrator
│   ├── export-runtime.sh    # API export utility
│   ├── monitor-backups.sh   # Health monitoring
│   └── restore-grafana.sh   # Restoration script
├── logs/                    # Operation logs (30-day retention)
├── snapshots/
│   ├── daily/              # Daily SQLite snapshots (7 days)
│   ├── weekly/             # Weekly archives (4 weeks)
│   └── latest -> ...       # Symlink to most recent
└── exports/
    ├── dashboards/         # Dashboard JSON exports
    ├── alerts/            # Alert configuration exports
    └── datasources/       # Datasource exports
```

## Configuration

Edit `backup/configs/backup.conf` to customize:

- Backup destination paths
- Retention policies
- API credentials
- Monitoring integration
- Component selection

### Environment Variables

Create `~/.env` with:
```bash
GRAFANA_API_KEY="your-service-account-token"
# Or use basic auth:
GRAFANA_USER="admin"
GRAFANA_PASSWORD="your-password"
```

## Git Hooks

The system uses three git hooks for automation:

- **post-commit**: Triggers SQLite snapshot after config changes
- **pre-push**: Validates backup completeness before pushing
- **post-merge**: Syncs runtime state after merging changes

Enable hooks:
```bash
make setup-hooks
```

## Monitoring

### Metrics Exported

The backup system exports metrics to Prometheus via Alloy:

- `grafana_backup_last_success_timestamp` - Last successful backup time
- `grafana_backup_age_hours` - Age of latest backup in hours
- `grafana_backup_sqlite_size_bytes` - SQLite backup size
- `grafana_backup_total_size_bytes` - Total backup storage
- `grafana_backup_integrity_errors` - Validation error count
- `grafana_backup_health_score` - Overall health (0-1)
- `grafana_backup_git_hook_triggered` - Hook execution count

### Dashboard

Import the Backup Health Dashboard from `/dashboards/backup-health.json` to visualize:
- Overall backup health status
- Backup timeline and age tracking
- Storage usage trends
- Git hook activity
- Log event analysis

## Restoration

### Full Restore
```bash
# Restore everything from latest backup
make backup-restore
# Select option 1: Restore everything
```

### Selective Restore
```bash
# Restore specific components
./backup/scripts/restore-grafana.sh --sqlite        # Database only
./backup/scripts/restore-grafana.sh --dashboards    # Dashboards only
./backup/scripts/restore-grafana.sh --alerts        # Alert configs only
./backup/scripts/restore-grafana.sh --datasources   # Datasources only
```

### Dry Run
```bash
# Preview what would be restored
make backup-restore-dry

# Or with specific backup
./backup/scripts/restore-grafana.sh --all --from /path/to/backup --dry-run
```

## Automation

### Daily Backups (macOS)
```bash
# Set up automated daily backups at 2 AM
make backup-schedule

# To disable:
launchctl unload ~/Library/LaunchAgents/com.grafana.backup.plist
```

### Manual Scheduling (Linux/Cron)
```cron
# Add to crontab -e
0 2 * * * /path/to/grafana-orbstack/backup/scripts/grafana-backup.sh --snapshot-only
```

## Maintenance

### Check Backup Health
```bash
# Full health report
make backup-status

# JSON output for automation
make backup-monitor-json

# Validate integrity only
./backup/scripts/monitor-backups.sh --validate
```

### Clean Old Backups
```bash
# Manual cleanup
make backup-clean

# Automatic cleanup runs with each backup
```

## Recovery Scenarios

### Scenario 1: Accidental Dashboard Deletion
```bash
# Export current state (optional)
make backup-export

# Restore dashboards from last backup
./backup/scripts/restore-grafana.sh --dashboards
```

### Scenario 2: Database Corruption
```bash
# Stop Grafana
make down

# Restore SQLite database
./backup/scripts/restore-grafana.sh --sqlite --force

# Start Grafana
make up
```

### Scenario 3: Complete Disaster Recovery
```bash
# Clone repository
git clone <repo-url>
cd grafana-orbstack

# Restore from backup location
./backup/scripts/restore-grafana.sh --all --from /Volumes/Backup/grafana-backup-20250122

# Verify services
make status
```

## Troubleshooting

### No Backups Found
```bash
# Create initial backup
make backup-all
```

### API Export Failures
1. Check Grafana is running: `make status`
2. Verify API credentials in `~/.env`
3. Test API access: `curl -H "Authorization: Bearer $GRAFANA_API_KEY" http://localhost:3001/api/health`

### SQLite Backup Issues
1. Check volume access: `ls ~/OrbStack/docker/volumes/`
2. Verify container name: `docker ps | grep grafana`
3. Check disk space: `df -h`

### Git Hook Not Triggering
1. Verify hooks enabled: `git config core.hooksPath`
2. Check hook permissions: `ls -la .githooks/`
3. Test manually: `./.githooks/post-commit`

## Best Practices

1. **Regular Testing**: Run `make test-backup` monthly to verify backup/restore cycle
2. **Offsite Copies**: Configure `BACKUP_BASE_DIR` to external drive or NAS
3. **Monitor Alerts**: Set up alerts for backup age >26 hours
4. **Document Changes**: Use conventional commits for configuration changes
5. **Version Control**: Always commit dashboard exports after major changes

## Support

For issues or questions:
1. Check backup logs: `tail -f backup/logs/backup-*.log`
2. Run health check: `make backup-status`
3. Review this documentation
4. Check the main project README