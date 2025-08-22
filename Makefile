.PHONY: help up down restart logs status backup-all backup-config backup-snapshot backup-export backup-validate backup-restore backup-status backup-clean

# Default target
help: ## Show this help message
	@echo "Grafana Observability Stack - Available Commands"
	@echo "================================================"
	@echo ""
	@echo "Stack Management:"
	@grep -E '^[a-z-]+:.*?## .*$$' $(MAKEFILE_LIST) | grep -v backup | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Backup Operations:"
	@grep -E '^backup-[a-z-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Quick Start:"
	@echo "  make up              # Start the observability stack"
	@echo "  make backup-all      # Create a complete backup"
	@echo "  make backup-status   # Check backup health"

# Stack Management
up: ## Start the observability stack
	docker compose -f docker-compose.grafana.yml up -d
	@echo ""
	@echo "✅ Stack started successfully!"
	@echo "Access points:"
	@echo "  Grafana:    http://grafana.local or http://localhost:3001 (admin/admin)"
	@echo "  Prometheus: http://prometheus.local"
	@echo "  Tempo:      http://tempo.local"
	@echo "  Loki:       http://loki.local"
	@echo "  Alloy:      http://alloy.local"

down: ## Stop the observability stack
	docker compose -f docker-compose.grafana.yml down

restart: ## Restart the observability stack
	docker compose -f docker-compose.grafana.yml restart

logs: ## Show logs from all services
	docker compose -f docker-compose.grafana.yml logs -f

status: ## Show status of all services
	@echo "Service Status:"
	@docker compose -f docker-compose.grafana.yml ps
	@echo ""
	@echo "Health Checks:"
	@curl -s -o /dev/null -w "  Grafana:    %{http_code}\n" http://localhost:3001/api/health || echo "  Grafana:    Not responding"
	@curl -s -o /dev/null -w "  Prometheus: %{http_code}\n" http://prometheus.local:9090/-/healthy || echo "  Prometheus: Not responding"
	@curl -s -o /dev/null -w "  Tempo:      %{http_code}\n" http://tempo.local:3200/ready || echo "  Tempo:      Not responding"
	@curl -s -o /dev/null -w "  Loki:       %{http_code}\n" http://loki.local:3100/ready || echo "  Loki:       Not responding"
	@curl -s -o /dev/null -w "  Alloy:      %{http_code}\n" http://alloy.local:12345/-/ready || echo "  Alloy:      Not responding"

# Backup Operations
backup-all: ## Complete backup (SQLite + exports + git)
	@echo "🔄 Starting complete backup..."
	@./backup/scripts/grafana-backup.sh
	@echo ""
	@echo "📊 Exporting runtime configurations..."
	@./backup/scripts/export-runtime.sh
	@echo ""
	@echo "📝 Committing configuration changes..."
	@if git diff --quiet config/ dashboards/; then \
		echo "No configuration changes to commit"; \
	else \
		git add config/ dashboards/ && \
		git commit -m "chore(backup): configuration snapshot $$(date +%Y%m%d-%H%M%S)" || true; \
	fi
	@echo ""
	@echo "✅ Complete backup finished!"

backup-config: ## Commit configuration changes to git
	@if git diff --quiet config/ dashboards/; then \
		echo "No configuration changes to commit"; \
	else \
		git add config/ dashboards/ && \
		git commit -m "chore(backup): configuration snapshot $$(date +%Y%m%d-%H%M%S)"; \
		echo "✅ Configuration changes committed"; \
	fi

backup-snapshot: ## Create SQLite snapshot only
	@echo "📸 Creating SQLite snapshot..."
	@./backup/scripts/grafana-backup.sh --snapshot-only
	@echo "✅ Snapshot created"

backup-export: ## Export runtime configs via API
	@echo "📤 Exporting runtime configurations..."
	@./backup/scripts/export-runtime.sh
	@echo "✅ Export completed"

backup-validate: ## Validate all backups
	@echo "🔍 Validating backups..."
	@./backup/scripts/monitor-backups.sh --validate

backup-restore: ## Interactive restoration wizard
	@echo "🔄 Starting restoration wizard..."
	@echo ""
	@echo "Available restore options:"
	@echo "  1. Restore everything (SQLite + configs)"
	@echo "  2. Restore SQLite database only"
	@echo "  3. Restore dashboards only"
	@echo "  4. Restore alerts only"
	@echo "  5. Restore datasources only"
	@echo ""
	@read -p "Select option (1-5): " option; \
	case $$option in \
		1) ./backup/scripts/restore-grafana.sh --all ;; \
		2) ./backup/scripts/restore-grafana.sh --sqlite ;; \
		3) ./backup/scripts/restore-grafana.sh --dashboards ;; \
		4) ./backup/scripts/restore-grafana.sh --alerts ;; \
		5) ./backup/scripts/restore-grafana.sh --datasources ;; \
		*) echo "Invalid option"; exit 1 ;; \
	esac

backup-status: ## Show backup health report
	@./backup/scripts/monitor-backups.sh

backup-clean: ## Clean old backups and logs
	@echo "🧹 Cleaning old backups..."
	@find backup/snapshots/daily -name "snapshot-*" -type d -mtime +7 -exec rm -rf {} \; 2>/dev/null || true
	@find backup/snapshots/weekly -name "snapshot-*" -type d -mtime +28 -exec rm -rf {} \; 2>/dev/null || true
	@find backup/logs -name "*.log" -type f -mtime +30 -delete 2>/dev/null || true
	@find backup/exports -type d -name "20*" -mtime +30 -exec rm -rf {} \; 2>/dev/null || true
	@echo "✅ Cleanup completed"

# Advanced Operations
backup-restore-dry: ## Preview what would be restored
	@./backup/scripts/restore-grafana.sh --all --dry-run

backup-monitor-json: ## Get backup status as JSON
	@./backup/scripts/monitor-backups.sh --json

backup-schedule: ## Set up automated daily backups (macOS)
	@echo "Setting up daily backup schedule..."
	@echo "Creating LaunchAgent for daily backups at 2 AM..."
	@mkdir -p ~/Library/LaunchAgents
	@cat > ~/Library/LaunchAgents/com.grafana.backup.plist <<EOF
	<?xml version="1.0" encoding="UTF-8"?>
	<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
	<plist version="1.0">
	<dict>
	    <key>Label</key>
	    <string>com.grafana.backup</string>
	    <key>ProgramArguments</key>
	    <array>
	        <string>$(PWD)/backup/scripts/grafana-backup.sh</string>
	        <string>--snapshot-only</string>
	    </array>
	    <key>StartCalendarInterval</key>
	    <dict>
	        <key>Hour</key>
	        <integer>2</integer>
	        <key>Minute</key>
	        <integer>0</integer>
	    </dict>
	    <key>WorkingDirectory</key>
	    <string>$(PWD)</string>
	    <key>StandardOutPath</key>
	    <string>$(PWD)/backup/logs/schedule.log</string>
	    <key>StandardErrorPath</key>
	    <string>$(PWD)/backup/logs/schedule-error.log</string>
	</dict>
	</plist>
	EOF
	@launchctl load ~/Library/LaunchAgents/com.grafana.backup.plist
	@echo "✅ Daily backup scheduled for 2 AM"
	@echo "To unschedule: launchctl unload ~/Library/LaunchAgents/com.grafana.backup.plist"

# Development
logs-backup: ## Show backup operation logs
	@tail -f backup/logs/backup-*.log 2>/dev/null || echo "No backup logs found"

test-backup: ## Test backup and restore cycle
	@echo "🧪 Testing backup and restore cycle..."
	@echo "1. Creating test backup..."
	@./backup/scripts/grafana-backup.sh --snapshot-only
	@echo ""
	@echo "2. Validating backup..."
	@./backup/scripts/monitor-backups.sh --validate
	@echo ""
	@echo "3. Testing restore (dry run)..."
	@./backup/scripts/restore-grafana.sh --sqlite --dry-run
	@echo ""
	@echo "✅ Backup test cycle completed"

# Git hooks
setup-hooks: ## Configure git to use custom hooks
	git config core.hooksPath .githooks
	@echo "✅ Git hooks configured"
	@echo "Hooks enabled:"
	@echo "  - post-commit: Triggers backup after config changes"
	@echo "  - pre-push:    Validates backup completeness"
	@echo "  - post-merge:  Syncs runtime with provisioned configs"