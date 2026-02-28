# EnterpriseDB Advanced Server 9.6 Comprehensive Monitoring System
## Complete Deployment Guide

### Table of Contents
1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Prerequisites](#prerequisites)
4. [Installation](#installation)
5. [Configuration](#configuration)
6. [Workflow Setup](#workflow-setup)
7. [Testing & Validation](#testing--validation)
8. [Maintenance](#maintenance)
9. [Troubleshooting](#troubleshooting)

---

## Overview

This comprehensive monitoring system provides automated, AI-driven analysis of EnterpriseDB Advanced Server 9.6 instances running on RHEL 7 VMs in Azure. The system collects metrics across 12 monitoring domains, uses specialized AI agents for analysis, and automatically creates prioritized Jira tasks for identified issues.

### Key Features

- **Comprehensive Metric Collection**: 12 monitoring domains covering system health, database performance, security, backup readiness, and more
- **AI-Powered Analysis**: 6 specialized AI agents working in parallel to analyze different aspects
- **Automated Issue Reporting**: Automatic Jira task creation for Critical and High priority issues
- **Multi-Agent Processing**: Task breakdown tools for complex analysis scenarios
- **Secure Communication**: JWT-based authentication for webhook communication
- **Continuous Operation**: Designed for 24/7 monitoring with minimal overhead

---

## Architecture

### System Components

```
┌─────────────────────────────────────────────────────────────┐
│                    RHEL 7 VM (Azure)                        │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  EnterpriseDB Advanced Server 9.6                    │  │
│  └──────────────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  collect_metrics.sh (Bash Script)                    │  │
│  │  - System Metrics                                     │  │
│  │  - Database Metrics                                   │  │
│  │  - Performance Metrics                                │  │
│  │  - Security & Compliance                              │  │
│  │  - Backup & Recovery                                  │  │
│  │  - Log Analysis                                       │  │
│  │  - Patch Management                                   │  │
│  └──────────────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  jwt_helper.py (JWT Generator)                       │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                            │
                            │ HTTPS + JWT
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                    n8n Instance                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Webhook (JWT Auth)                                   │  │
│  └──────────────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Parse Metric Data                                    │  │
│  └──────────────────────────────────────────────────────┘  │
│  ┌──────────┬──────────┬──────────┬──────────┬──────────┐  │
│  │ System   │ DB       │ Backup   │ Security │ Storage  │  │
│  │ Health   │ Perf     │ Recovery │ Comply   │ Capacity │  │
│  │ Agent    │ Agent    │ Agent    │ Agent    │ Agent    │  │
│  └──────────┴──────────┴──────────┴──────────┴──────────┘  │
│                            │                                │
│                            ▼                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Consolidation Aggregator                            │  │
│  └──────────────────────────────────────────────────────┘  │
│                            │                                │
│                            ▼                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Consolidation AI Agent                               │  │
│  └──────────────────────────────────────────────────────┘  │
│                            │                                │
│                            ▼                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Jira Task Creation                                   │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### Data Flow

1. **Collection**: Bash script runs via cron, collects metrics from system and database
2. **Transmission**: Script generates JWT token and sends metrics to n8n webhook
3. **Parsing**: n8n workflow parses and normalizes incoming data
4. **Splitting**: Data is split into specialized domains
5. **Analysis**: 5 specialized AI agents analyze their respective domains in parallel
6. **Consolidation**: Results are aggregated and deduplicated
7. **Final Analysis**: Consolidation agent synthesizes findings
8. **Action**: Jira tasks created for Critical/High priority issues

---

## Prerequisites

### Server Requirements (RHEL 7 VM)

- **OS**: RHEL 7.x
- **Database**: EnterpriseDB Advanced Server 9.6
- **Python**: Python 3.6+ (for JWT generation)
- **Tools**: 
  - `curl` (for webhook communication)
  - `jq` (optional, for JSON validation)
  - `systemctl` (for service status checks)
  - `edb-psql` or `psql` (for database queries)

### Network Requirements

- Outbound HTTPS access to n8n instance
- Database connectivity (local or network)
- Firewall rules allowing outbound connections

### n8n Requirements

- n8n instance (self-hosted or cloud)
- OpenAI API credentials
- Jira API credentials (for task creation)
- PostgreSQL database (for vector store and memory)
- Task Breakdown MCP server (optional, for advanced analysis)

### API Keys & Credentials

- **OpenAI API Key**: For AI agent analysis
- **Jira API Token**: For automated task creation
- **n8n JWT Secret**: Shared secret for webhook authentication
- **PostgreSQL Credentials**: For vector store and memory

---

## Installation

### Step 1: Prepare Server Environment

```bash
# Create monitoring directory
sudo mkdir -p /usr/local/bin/edb-monitor
sudo mkdir -p /usr/local/bin/edb-monitor/logs
cd /usr/local/bin/edb-monitor

# Set ownership (adjust user as needed)
sudo chown $USER:$USER /usr/local/bin/edb-monitor
```

### Step 2: Deploy Scripts

```bash
# Copy files to server
scp collect_metrics.sh user@server:/usr/local/bin/edb-monitor/
scp jwt_helper.py user@server:/usr/local/bin/edb-monitor/
scp .env.example user@server:/usr/local/bin/edb-monitor/

# Make scripts executable
ssh user@server "chmod +x /usr/local/bin/edb-monitor/collect_metrics.sh"
```

### Step 3: Install Python Dependencies

```bash
# On the server
cd /usr/local/bin/edb-monitor
pip3 install pyjwt cryptography --user
# Or system-wide:
sudo pip3 install pyjwt cryptography
```

### Step 4: Configure Environment

```bash
# Create .env file from template
cp .env.example .env
chmod 600 .env

# Edit .env with your settings
vi .env
```

### Step 5: Test Script Locally

```bash
# Test metric collection
cd /usr/local/bin/edb-monitor
./collect_metrics.sh \
   --host-username monitor_user \
   --server-name db-server.example.com \
   --ssh-port 22 \
   --ssh-key /home/monitor_user/.ssh/id_rsa \
   --db-username edb_monitor_svc \
   --db-password 'your_secure_password_here' \
   --db-port 5444 \
   --db-name edb

# Verify JSON output
cat /tmp/edb_health_metrics.json | jq .

# Test webhook transmission (if configured)
./collect_metrics.sh \
   --host-username monitor_user \
   --server-name db-server.example.com \
   --ssh-key /home/monitor_user/.ssh/id_rsa \
   --db-username edb_monitor_svc \
   --db-password 'your_secure_password_here'
```

---

## Configuration

### Environment Variables (.env)

```ini
# Remote Server (System Metrics via SSH)
HOST_USERNAME=monitor_user
SERVER_NAME=db-server.example.com
SSH_PORT=22
SSH_KEY_FILE=/home/monitor_user/.ssh/id_rsa

# Remote Database (DB Metrics via psql)
DB_USERNAME=edb_monitor_svc
DB_PASSWORD=your_secure_password_here
DB_HOST=db-server.example.com
DB_PORT=5444
PGDATABASE=edb

# Local client binary path (where script runs)
PGBIN=/usr/edb/as9.6/bin
SERVICE_NAME=edb-as-9.6

# Monitoring Configuration
OUTPUT_FILE=/tmp/edb_health_metrics.json
LONG_QUERY_THRESHOLD="5 minutes"

# Webhook Configuration
WEBHOOK_URL=https://your-n8n-instance.com/webhook/edb-health-check
N8N_JWT_SECRET=your_jwt_secret_here_minimum_32_characters

# Log Analysis Configuration
LOG_DIR=/var/log/edb/as9.6
LOG_ANALYSIS_ENABLED=true
ERROR_LOG_PATTERNS="FATAL|ERROR|PANIC"

# Patch Management Configuration
PATCH_CHECK_ENABLED=true
EDB_VERSION_CHECK=true
```

Run with explicit CLI parameters (optional when values are in `.env`):

```bash
./collect_metrics.sh \
   --host-username monitor_user \
   --server-name db-server.example.com \
   --ssh-port 22 \
   --ssh-key /home/monitor_user/.ssh/id_rsa \
   --db-username edb_monitor_svc \
   --db-password 'your_secure_password_here' \
   --db-port 5444 \
   --db-name edb
```

### Cron Job Setup

```bash
# Edit crontab
crontab -e

# Add entry (runs every 15 minutes)
*/15 * * * * cd /usr/local/bin/edb-monitor && ./collect_metrics.sh >> /var/log/edb_monitor.log 2>&1

# Or for more frequent monitoring (every 5 minutes)
*/5 * * * * cd /usr/local/bin/edb-monitor && ./collect_metrics.sh >> /var/log/edb_monitor.log 2>&1
```

### Database Permissions

Use a dedicated read-only monitoring account instead of a superuser. This repo includes a ready-to-run least-privilege SQL script.

```sql
-- Run as admin/superuser
\i /usr/local/bin/edb-monitor/scripts/create_monitoring_readonly_role.sql
```

After running the script:

1. Update `.env` to use the service login created by the SQL script:

```ini
DB_USERNAME=edb_monitor_svc
DB_PASSWORD=CHANGE_ME_STRONG_PASSWORD
DB_HOST=db-server.example.com
DB_PORT=5444
PGDATABASE=edb
HOST_USERNAME=monitor_user
SERVER_NAME=db-server.example.com
SSH_PORT=22
SSH_KEY_FILE=/home/monitor_user/.ssh/id_rsa
```

2. Rotate the placeholder password immediately.
3. Validate access with:

```bash
PGUSER=edb_monitor_svc PGPASSWORD='your_password' /usr/edb/as9.6/bin/edb-psql -d edb -p 5444 -c "SELECT 1;"
PGUSER=edb_monitor_svc PGPASSWORD='your_password' /usr/edb/as9.6/bin/edb-psql -d edb -p 5444 -c "SELECT count(*) FROM pg_stat_activity;"
```

Note: if cross-session query text is masked in `pg_stat_activity`, that is expected on some deployments unless additional monitoring visibility is granted.

---

## Workflow Setup

### Step 1: Import Workflow

1. Log in to your n8n instance
2. Click **Workflows** → **Import from File**
3. Select `edb_health_workflow.json`
4. The workflow will be imported with all nodes

### Step 2: Configure Credentials

#### Webhook Node
- **Authentication**: JWT Auth
- **Secret**: Must match `N8N_JWT_SECRET` from server `.env`
- **Path**: `edb-health-check` (or customize)

#### OpenAI Chat Model
- **Credentials**: Create/select OpenAI API credentials
- **Model**: `gpt-5-nano` (or your preferred model)

#### Postgres Chat Memory
- **Credentials**: Create/select PostgreSQL credentials for vector store
- **Session Key**: Uses timestamp from webhook payload

#### Output Parser
- **Schema**: Pre-configured for issue output format
- **Required Fields**: Issue, Priority, Description, Immediate remediation steps, Preventative actions

#### Task Breakdown Tool (Optional)
- **Endpoint URL**: Your Task Breakdown MCP server URL
- **API Key**: Your MCP server API key
- **Description**: Update tool description for better agent understanding

### Step 3: Connect AI Agents

**IMPORTANT**: The workflow requires proper connections between nodes:

1. **OpenAI Chat Model** → All AI Agents (via `ai_languageModel` connection)
   - System Health Agent
   - DB Performance Agent
   - Backup Recovery Agent
   - Security Compliance Agent
   - Storage Capacity Agent
   - Consolidation AI Agent

2. **format_final_json_response** → All AI Agents (via `ai_outputParser` connection)
   - System Health Agent
   - DB Performance Agent
   - Backup Recovery Agent
   - Security Compliance Agent
   - Storage Capacity Agent
   - Consolidation AI Agent

3. **Postgres Chat Memory** → All AI Agents (via `ai_memory` connection)

4. **Postgres PGVector Store Retrieve** → Consolidation AI Agent (via `ai_tool` connection)

### Step 4: Configure Jira Integration

The workflow calls a separate "Create Jira Ticket" workflow. Ensure:

1. The "Create Jira Ticket" workflow exists and is active
2. It accepts inputs: `summary`, `description`, `priority`
3. Jira credentials are configured in that workflow

### Step 5: Activate Workflow

1. Click **Active** toggle in n8n
2. Copy the webhook URL
3. Update `WEBHOOK_URL` in server `.env` file
4. Test with a manual execution

---

## Testing & Validation

### Test Script: `test_monitoring_system.sh`

```bash
#!/bin/bash
# Comprehensive test script for monitoring system

echo "=== Testing EDB Monitoring System ==="

# Test 1: Script Execution
echo "Test 1: Script execution..."
cd /usr/local/bin/edb-monitor
./collect_metrics.sh > /tmp/test_output.json 2>&1
if [ $? -eq 0 ]; then
    echo "✓ Script executed successfully"
else
    echo "✗ Script execution failed"
    exit 1
fi

# Test 2: JSON Validity
echo "Test 2: JSON validity..."
python3 -m json.tool /tmp/edb_health_metrics.json > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo "✓ JSON is valid"
else
    echo "✗ JSON is invalid"
    exit 1
fi

# Test 3: Required Fields
echo "Test 3: Required fields..."
python3 << EOF
import json
with open('/tmp/edb_health_metrics.json') as f:
    data = json.load(f)
required = ['timestamp', 'hostname', 'system', 'database_status', 'performance']
missing = [r for r in required if r not in data]
if missing:
    print(f"✗ Missing fields: {missing}")
    exit(1)
else:
    print("✓ All required fields present")
EOF

# Test 4: Webhook Transmission
echo "Test 4: Webhook transmission..."
if [ -n "$WEBHOOK_URL" ]; then
    response=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $(python3 -c "import sys; sys.path.append('.'); import jwt_helper; import os; print(jwt_helper.generate_jwt({'sub': 'test'}, os.environ.get('N8N_JWT_SECRET', '')))")" \
        -d @/tmp/edb_health_metrics.json)
    if [ "$response" == "200" ]; then
        echo "✓ Webhook transmission successful"
    else
        echo "✗ Webhook transmission failed (HTTP $response)"
    fi
else
    echo "⚠ Webhook URL not configured, skipping"
fi

echo "=== All tests completed ==="
```

### Manual Testing

1. **Test Metric Collection**:
   ```bash
   cd /usr/local/bin/edb-monitor
   ./collect_metrics.sh
   cat /tmp/edb_health_metrics.json | jq .
   ```

2. **Test Webhook**:
   ```bash
   # Use n8n's "Test Workflow" feature or send manual POST request
   curl -X POST https://your-n8n-instance.com/webhook/edb-health-check \
     -H "Content-Type: application/json" \
     -H "Authorization: Bearer YOUR_JWT_TOKEN" \
     -d @/tmp/edb_health_metrics.json
   ```

3. **Test AI Analysis**:
   - Trigger workflow manually in n8n
   - Check execution logs
   - Verify AI agents produce output
   - Confirm Jira tasks are created

### Validation Checklist

- [ ] Script executes without errors
- [ ] JSON output is valid
- [ ] All required metric categories are present
- [ ] Webhook transmission succeeds
- [ ] n8n workflow receives data
- [ ] AI agents execute successfully
- [ ] Output parser formats correctly
- [ ] Jira tasks are created for issues
- [ ] Cron job runs on schedule
- [ ] Logs are generated correctly

---

## Maintenance

### Regular Tasks

1. **Review Logs** (Weekly):
   ```bash
   tail -f /usr/local/bin/edb-monitor/logs/<server_name>_execution_$(date +%Y-%m-%d).log
   ```

2. **Check Metric Quality** (Monthly):
   - Review sample metrics JSON
   - Verify all monitoring domains are covered
   - Check for missing or null values

3. **Update Thresholds** (As needed):
   - Adjust `LONG_QUERY_THRESHOLD` in `.env`
   - Update AI agent prompts for new requirements
   - Modify Jira task creation criteria

4. **Monitor n8n Workflow** (Daily):
   - Check execution history
   - Review failed executions
   - Monitor AI agent performance

### Backup & Recovery

1. **Backup Configuration**:
   ```bash
   tar -czf edb-monitor-backup-$(date +%Y%m%d).tar.gz \
     /usr/local/bin/edb-monitor/.env \
     /usr/local/bin/edb-monitor/collect_metrics.sh \
     /usr/local/bin/edb-monitor/jwt_helper.py
   ```

2. **Restore Configuration**:
   ```bash
   tar -xzf edb-monitor-backup-YYYYMMDD.tar.gz -C /
   ```

### Updates

1. **Script Updates**:
   - Backup current version
   - Deploy new version
   - Test thoroughly
   - Monitor for issues

2. **Workflow Updates**:
   - Export current workflow as backup
   - Import new workflow version
   - Test in non-production first
   - Activate after validation

---

## Troubleshooting

### Common Issues

#### 1. Script Fails to Execute

**Symptoms**: Script exits with error, no output file created

**Solutions**:
- Check file permissions: `chmod +x collect_metrics.sh`
- Verify database connectivity: `edb-psql -U enterprisedb -d edb -c "SELECT 1"`
- Check Python installation: `python3 --version`
- Review logs: `cat /usr/local/bin/edb-monitor/logs/*_execution_*.log`

#### 2. JSON Validation Fails

**Symptoms**: "Metrics JSON is invalid" error

**Solutions**:
- Check for syntax errors in script output
- Verify all functions return valid JSON
- Test individual collection functions
- Use `jq` to validate: `cat output.json | jq .`

#### 3. Webhook Transmission Fails

**Symptoms**: HTTP errors, connection timeouts

**Solutions**:
- Verify `WEBHOOK_URL` is correct and accessible
- Check firewall rules allow outbound HTTPS
- Validate JWT secret matches n8n configuration
- Test connectivity: `curl -I https://your-n8n-instance.com`
- Review n8n webhook logs

#### 4. AI Agents Not Executing

**Symptoms**: Workflow runs but agents produce no output

**Solutions**:
- Verify OpenAI credentials are valid
- Check API quota and limits
- Ensure language model connections are correct
- Verify output parser connections
- Review n8n execution logs for errors

#### 5. Jira Tasks Not Created

**Symptoms**: Analysis completes but no Jira tasks

**Solutions**:
- Verify "Create Jira Ticket" workflow is active
- Check Jira credentials in that workflow
- Ensure task creation criteria are met (priority <= 3)
- Review workflow execution logs
- Test Jira workflow independently

### Debug Mode

Enable verbose logging:

```bash
# Add to collect_metrics.sh
set -x  # Enable debug mode
```

### Support Resources

- **n8n Documentation**: https://docs.n8n.io
- **EnterpriseDB Documentation**: https://www.enterprisedb.com/docs
- **PostgreSQL Monitoring**: https://www.postgresql.org/docs/current/monitoring.html
- **JWT Debugging**: Use https://jwt.io to decode tokens

---

## Security Considerations

1. **Credentials**: Store all secrets in `.env` file with `chmod 600`
2. **JWT Secret**: Use strong, random secret (minimum 32 characters)
3. **Network**: Use HTTPS for all webhook communications
4. **Permissions**: Run scripts with minimal required privileges
5. **Logs**: Ensure logs don't contain sensitive information
6. **Access Control**: Limit access to monitoring directory

---

## Performance Optimization

1. **Collection Frequency**: Adjust cron schedule based on needs
2. **Query Optimization**: Limit result sets in database queries
3. **Parallel Processing**: AI agents run in parallel automatically
4. **Caching**: Consider caching static configuration data
5. **Resource Limits**: Monitor script resource usage

---

## Appendix

### Monitoring Domains

1. **System Health**: CPU, memory, disk usage, load averages
2. **Database Status**: Service status, connection health
3. **Performance**: Connections, queries, cache hit ratio
4. **Database Stats**: Transactions, deadlocks, temp files
5. **Locks**: Waiting sessions, blocking chains
6. **Vacuum**: Dead tuples, freeze risk
7. **WAL**: Checkpoint activity, buffer statistics
8. **Storage**: Database size, temp objects, largest tables/indexes
9. **Replication**: Lag, status, slots
10. **Backup**: Archive mode, failed archives
11. **Bloat**: Table and index bloat
12. **Configuration**: Security and performance settings

### AI Agent Specializations

- **System Health Agent**: Infrastructure and resource management
- **DB Performance Agent**: Query optimization and lock analysis
- **Backup Recovery Agent**: Disaster recovery readiness
- **Security Compliance Agent**: Security hardening and compliance
- **Storage Capacity Agent**: Capacity planning and optimization
- **Consolidation Agent**: Holistic analysis and prioritization

---

**Version**: 1.0  
**Last Updated**: 2026-01-09  
**Author**: System Integration Team
