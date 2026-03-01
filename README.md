# EnterpriseDB Advanced Server 9.6 Health Monitoring System

This project provides a comprehensive, automated monitoring solution for EnterpriseDB Advanced Server 9.6 running on RHEL 7. It consists of a bash script for data collection, a Python helper for secure JWT authentication, and an n8n workflow for AI-driven analysis and Jira incident management.

## Components

1.  **`collect_metrics.sh`**: A bash script that gathers system and database metrics, generates a secure JWT, and pushes data to n8n.
2.  **`jwt_helper.py`**: A Python script used by the bash script to generate signed JWT tokens for webhook authentication.
3.  **`edb_health_workflow.json`**: An n8n workflow that processes metrics, uses AI to detect issues, and creates Jira tasks.
4.  **`build_deploy_package.py`**: A utility script to package and deploy the solution to your server.
5.  **`sample_metrics.json`**: Sample output for testing.

## Prerequisites

-   **Server**: RHEL 7 VM in Azure.
-   **Database**: EnterpriseDB Advanced Server 9.6.
-   **Runtime**: Python 3 (required for JWT generation).
-   **SSH Auth (if using password)**: `sshpass` must be installed on the machine running `collect_metrics.sh`.
-   **n8n**: An n8n instance (self-hosted or cloud) accessible via HTTP/HTTPS.
-   **API Keys**: OpenAI API Key (for analysis), Jira Cloud API Token.

## Quick Deployment (Recommended)

You can use the included `build_deploy_package.py` script to package and deploy the necessary files to your RHEL 7 server.

```bash
# Build the deployment ZIP
python build_deploy_package.py

# Build and Deploy via SCP (requires SSH access)
python build_deploy_package.py --deploy user@your-rhel7-server --remote-path /usr/local/bin
```

## Manual Deployment Instructions

### 1. Configure the Scripts

1.  Upload `collect_metrics.sh`, `jwt_helper.py`, and `.env.example` to your database server (e.g., `/usr/local/bin/`).
2.  Make the script executable:
    ```bash
    chmod +x /usr/local/bin/collect_metrics.sh
    ```
3.  Create a `.env` file from the example and secure it:
    ```bash
    cp /usr/local/bin/.env.example /usr/local/bin/.env
    chmod 600 /usr/local/bin/.env
    ```
4.  Run a remote collection test (copy/paste example):
    ```bash
    /usr/local/bin/collect_metrics.sh \
      --host-username monitor_user \
      --server-name db-server.example.com \
      --ssh-port 22 \
        --ssh-key /home/monitor_user/.ssh/id_rsa \
        # OR use password auth (requires sshpass):
        # --ssh-password 'your_ssh_password' \
      --db-username edb_monitor_svc \
      --db-password 'your_secure_password' \
      --db-port 5444 \
      --db-name edb
    ```
5.  Edit the `.env` file with your actual database credentials, paths, and webhook details:
    ```ini
    # Remote Server (System Metrics via SSH)
    HOST_USERNAME=monitor_user
    SERVER_NAME=db-server.example.com
    SSH_PORT=22
    SSH_KEY_FILE=/home/monitor_user/.ssh/id_rsa
    # Optional alternative to SSH key auth (requires sshpass)
    # SSH_PASSWORD=your_ssh_password

    # Remote Database (DB Metrics via psql)
    DB_USERNAME=edb_monitor_svc
    DB_PASSWORD=your_secure_password
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
    N8N_JWT_SECRET=your_jwt_secret_here
    ```

### 2. Set Up the n8n Workflow

1.  Log in to your n8n instance.
2.  Create a new workflow.
3.  Click the **...** menu in the top right -> **Import from File**.
4.  Select `edb_health_workflow.json`.
5.  **Configure Credentials**:
    *   **Webhook Node**: Ensure it is configured to validate the JWT token using the secret defined in `N8N_JWT_SECRET`.
    *   **AI Agent Analysis**: Select/create your OpenAI credentials.
    *   **Create Jira Ticket**: Select/create your Jira Software credentials (this workflow calls a separate “Create Jira Ticket” workflow via an Execute Workflow node).
    *   **Task Breakdown Tool**: Update the MCP endpoint URL API key (the imported workflow uses `api_key=REPLACE_ME`).
6.  **Activate** the workflow.

### 3. Automate Data Collection (Cron Job)

Since `collect_metrics.sh` now handles webhook transmission internally (when `WEBHOOK_URL` and `N8N_JWT_SECRET` are set), you can simply add it to crontab.

1.  Add to crontab (e.g., run every 15 minutes):
    ```bash
    crontab -e
    ```
    Add:
    ```cron
    */15 * * * * cd /usr/local/bin && ./collect_metrics.sh >> /var/log/edb_monitor.log 2>&1
    ```
    *Note: We `cd` into the directory first so the script can find `jwt_helper.py` and `.env` easily.*

## Monitoring Areas

The system monitors the following:

1.  **System Health**: CPU utilization (%), Memory utilization (%), Disk usage (%) for `/data`.
2.  **Database Status**: Systemd service status, connection check.
3.  **Performance**: Total/Active/Idle connections, idle-in-transaction sessions, long-running queries (configurable `LONG_QUERY_THRESHOLD`), cache hit ratio.
4.  **Database Stats**: `pg_stat_database` counters (including `temp_files` and `temp_bytes`).
5.  **Locks**: Waiting session count, top waiters, blocking chains.
6.  **Vacuum**: Top tables by dead tuples, tables at freeze risk.
7.  **WAL/Checkpoints**: `pg_stat_bgwriter` checkpoint/buffer activity.
8.  **Storage**:
    *   **Database Size**: Total size of the current database (`database_size_bytes` and human-readable `database_size`).
    *   **Temp Objects**: Total size and count of objects in `pg_temp_%` and `pg_toast_temp_%`.
    *   **Largest Tables**: Top 10 largest tables.
    *   **Largest Indexes**: Top 10 largest indexes.
9.  **Replication**: Recovery status, connected replicas (Primary), replication lag (Standby), replication slots (Primary).
10. **Backup**: Archive mode status, last failed archive timestamp.
11. **Bloat Metrics**:
    *   **Table Bloat**: Top bloated tables.
    *   **Index Bloat**: Top bloated indexes.
12. **Configuration**: Selected `pg_settings` values for security and performance.

Note: the bloat metrics (`top_bloated_tables` and `large_indexes`) are queried from `valdezha.*` objects in `collect_metrics.sh`. Ensure those views/materialized views exist in your database, or update the queries to match your environment.

## AI Analysis & Alerting

The n8n workflow uses an AI Agent to parse the JSON metrics. It applies the following logic:

-   **CRITICAL**: Service down, connection failed, disk usage > 90%, load > 10, replication lag > 300s.
-   **WARNING**:
    -   Disk usage > 80%
    -   Long-running queries above `LONG_QUERY_THRESHOLD`
    -   Cache hit ratio < 90%
    -   Table/index bloat signals
    -   Unusually large tables/indexes and rapid database growth
-   **OK**: Metrics within normal ranges.

If the AI Agent outputs issues, a Jira task is automatically created (via the “Create Jira Ticket” workflow) with a summary of issues and AI-generated recommendations.

## Customization

-   **Adding Metrics**: Add new functions to `collect_metrics.sh` and ensure they output valid JSON fields.
-   **Adjusting Thresholds**: Modify variables in `.env` or the prompt in the **AI Agent Analysis** node in n8n.
-   **Alerting Channels**: Add nodes for Slack, Email, or Teams in the n8n workflow.

## Logging

- Script logs are written under `logs/` with hostname-prefixed daily filenames:
    `<server_name>_execution_YYYY-MM-DD.log`
