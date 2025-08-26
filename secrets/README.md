# Secrets Management with 1Password

This directory contains the 1Password template for secure secrets management in the Grafana observability stack.

## Overview

The Grafana observability stack uses 1Password CLI (`op`) to securely manage sensitive credentials. This approach ensures:
- No hardcoded secrets in the repository
- Protection against accidental exposure in screen shares/demos
- Centralized secret rotation via 1Password
- Consistent security patterns across all repositories

## Prerequisites

1. **Install 1Password CLI**:
   ```bash
   brew install --cask 1password-cli
   ```

2. **Sign in to 1Password**:
   ```bash
   op signin
   ```

## Setup

### 1. Create 1Password Vault

Run the setup wizard to see the exact commands:
```bash
make setup-secrets
```

Or manually create the vault and items in 1Password:

1. **Create vault** named `Grafana-Observability`

2. **Add Grafana admin password**:
   - Item: `Grafana`
   - Field: `admin-password`
   - Value: Your secure password

3. **Add ClickHouse password**:
   - Item: `ClickHouse`
   - Field: `password`
   - Value: Your secure password

4. **Add OTLP bearer token** (for MCP/Langfuse authentication):
   - Item: `Security`
   - Field: `otlp-bearer-token`
   - Value: Your bearer token (e.g., generated with `openssl rand -hex 32`)

## Usage

### Quick Development (Default Passwords)

For local development without 1Password:
```bash
make up
```
This uses default passwords (`admin` for Grafana, `clickhouse` for ClickHouse).

### Secure Deployment (1Password)

For secure deployment with 1Password secrets:
```bash
make up-secure
```
This will:
1. Verify 1Password CLI is installed
2. Inject secrets from 1Password into a temporary `.env.secrets` file
3. Start the stack with the injected secrets
4. Clean up the temporary file

### Manual Secret Injection

To manually inject and inspect the secrets:
```bash
# Generate the secrets file
op inject -i secrets/.env.1password -o .env.secrets

# View the injected values (be careful not to expose!)
cat .env.secrets

# Use with docker compose
docker compose -f docker-compose.grafana.yml --env-file .env.secrets up -d

# Clean up
rm -f .env.secrets
```

## OTLP Authentication

The stack supports optional OTLP authentication for securing telemetry ingestion from MCP servers and Langfuse.

### Enabling OTLP Authentication

1. **Set the bearer token** in 1Password (as described above)

2. **Enable authentication** in `config/alloy-config.alloy`:
   ```alloy
   // Uncomment these lines:
   otelcol.auth.bearer "otlp" {
     token = env("OTLP_BEARER_TOKEN")
   }
   
   // And add auth to the receivers:
   grpc {
     endpoint = "0.0.0.0:4317"
     auth = otelcol.auth.bearer.otlp.handler  // Uncomment this
   }
   ```

3. **Configure your clients** (MCP servers, Langfuse) with the bearer token:
   ```bash
   # Example for OpenTelemetry environment variables
   export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer <your-token>"
   ```

### Testing OTLP Authentication

With authentication enabled, test the endpoints:
```bash
# Should fail without token
curl -X POST http://localhost:4318/v1/metrics

# Should succeed with token
curl -X POST http://localhost:4318/v1/metrics \
  -H "Authorization: Bearer <your-token>" \
  -H "Content-Type: application/json"
```

## Security Best Practices

1. **Never commit** `.env.secrets` or any file containing actual secrets
2. **Use strong passwords** - Consider using `op` to generate them:
   ```bash
   op item create --generate-password=32,letters,digits,symbols
   ```
3. **Rotate secrets regularly** - Update them in 1Password and redeploy
4. **Different vaults** for different environments (dev/staging/prod)
5. **Audit access** - Review 1Password access logs periodically

## Troubleshooting

### "1Password CLI not installed"
```bash
brew install --cask 1password-cli
```

### "Failed to inject secrets from 1Password"
- Ensure you're signed in: `op signin`
- Verify vault exists: `op vault list | grep Grafana-Observability`
- Check items exist: `op item list --vault Grafana-Observability`

### "op: command not found" after installation
- Restart your terminal
- Or source your shell config: `source ~/.zshrc` or `source ~/.bashrc`

### Testing without 1Password
Use the default `make up` command which uses hardcoded development passwords.

## Files in This Directory

- `.env.1password` - Template with 1Password secret references (safe to commit)
- `.env.local` - Local overrides (gitignored, create if needed)
- `.env.secrets` - Generated file with actual secrets (gitignored, auto-deleted)

## Related Documentation

- [1Password CLI Documentation](https://developer.1password.com/docs/cli/)
- [Docker Compose Environment Variables](https://docs.docker.com/compose/environment-variables/)
- [OpenTelemetry Authentication](https://opentelemetry.io/docs/collector/configuration/#authentication)