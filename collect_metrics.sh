#!/bin/bash

# ==============================================================================
# EnterpriseDB Advanced Server 9.6 Health Check & Monitoring Script
# Target System: RHEL 7 / Azure VM
# ==============================================================================

# Configuration
# ------------------------------------------------------------------------------
# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Logging Configuration
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/execution_$(date +%Y-%m-%d).log"

log_msg() {
    local msg="$1"
    echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] $msg" >> "$LOG_FILE"
}

log_error() {
    local msg="$1"
    echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] $msg" >> "$LOG_FILE"
}

log_msg "Starting EDB Health Check..."

usage() {
    cat <<'EOF'
Usage:
  ./collect_metrics.sh \
    --host-username <ssh_user> \
    --server-name <server_or_ip> \
    [--ssh-port <port>] \
    --db-username <db_user> \
    --db-password <db_password> \
    [--db-port <port>] \
    [--db-host <db_host>] \
    [--db-name <database_name>]

Defaults:
  --ssh-port: 22
  --db-port: 5444
  --db-host: same value as --server-name
  --db-name: edb
EOF
}

# Load environment variables
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

# Remote connection settings (CLI args override env defaults)
SSH_USER="${HOST_USERNAME:-${SSH_USER:-}}"
SSH_HOST="${SERVER_NAME:-${SSH_HOST:-}}"
SSH_PORT="${SSH_PORT:-22}"

DB_USERNAME="${DB_USERNAME:-${PGUSER:-enterprisedb}}"
DB_PASSWORD="${DB_PASSWORD:-${PGPASSWORD:-}}"
DB_PORT="${DB_PORT:-${PGPORT:-5444}}"
PGDATABASE="${PGDATABASE:-edb}"
DB_HOST="${DB_HOST:-${PGHOST:-}}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host-username|--host-user)
            SSH_USER="$2"
            shift 2
            ;;
        --server-name|--host)
            SSH_HOST="$2"
            shift 2
            ;;
        --ssh-port)
            SSH_PORT="$2"
            shift 2
            ;;
        --db-username)
            DB_USERNAME="$2"
            shift 2
            ;;
        --db-password)
            DB_PASSWORD="$2"
            shift 2
            ;;
        --db-port)
            DB_PORT="$2"
            shift 2
            ;;
        --db-host)
            DB_HOST="$2"
            shift 2
            ;;
        --db-name)
            PGDATABASE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: Unknown argument '$1'" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ -z "$SSH_HOST" ]]; then
    echo "Error: --server-name is required." >&2
    exit 1
fi

if [[ -z "$SSH_USER" ]]; then
    echo "Error: --host-username is required." >&2
    exit 1
fi

if [[ -z "$DB_HOST" ]]; then
    DB_HOST="$SSH_HOST"
fi

if [[ -z "$DB_USERNAME" || -z "$DB_PASSWORD" ]]; then
    echo "Error: --db-username and --db-password are required." >&2
    exit 1
fi

# Keep compatibility with downstream variable names
PGUSER="$DB_USERNAME"
PGPASSWORD="$DB_PASSWORD"
PGPORT="$DB_PORT"
PGHOST="$DB_HOST"

PGBIN="${PGBIN:-/usr/edb/as9.6/bin}" # Adjust path if necessary
PSQL="$PGBIN/edb-psql"
SERVICE_NAME="${SERVICE_NAME:-edb-as-9.6}"
LONG_QUERY_THRESHOLD="${LONG_QUERY_THRESHOLD:-5 minutes}"
HOSTNAME="$SSH_HOST"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
OUTPUT_FILE="${OUTPUT_FILE:-/tmp/edb_health_metrics.json}"

# Check if edb-psql exists, otherwise fall back to psql or try to find it
if [ ! -f "$PSQL" ]; then
    if command -v edb-psql &> /dev/null; then
        PSQL="edb-psql"
    elif command -v psql &> /dev/null; then
        PSQL="psql"
    else
        log_error "Neither edb-psql nor psql found."
        echo "Error: Neither edb-psql nor psql found." >&2
        exit 1
    fi
fi

run_ssh_cmd() {
    local cmd="$1"
    ssh -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=10 "$SSH_USER@$SSH_HOST" "$cmd"
}

psql_query() {
    local sql="$1"
    PGPASSWORD="$PGPASSWORD" "$PSQL" -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -p "$PGPORT" -A -t -c "$sql" 2>/dev/null
}

psql_query_t() {
    local sql="$1"
    PGPASSWORD="$PGPASSWORD" "$PSQL" -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -p "$PGPORT" -t -c "$sql" 2>/dev/null
}

psql_ping() {
    PGPASSWORD="$PGPASSWORD" "$PSQL" -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -p "$PGPORT" -c "SELECT 1" >/dev/null 2>&1
}

# JSON Building Helper Functions
# ------------------------------------------------------------------------------
json_start() { echo "{"; }
json_end() { echo "}"; }
json_key_value() { echo "\"$1\": \"$2\""; }
json_key_num() { echo "\"$1\": $2"; }
json_key_obj_start() { echo "\"$1\": {"; }
json_obj_end() { echo "}"; }
json_comma() { echo ","; }

# 1. System Level Metrics (RHEL 7)
# ------------------------------------------------------------------------------
collect_system_metrics() {
    echo "\"system\": {"

    # CPU Utilization Percent (remote)
    cpu_util=$(run_ssh_cmd "vmstat 1 2 | tail -1 | awk '{print 100-\$15}'" 2>/dev/null | xargs)
    cpu_util=${cpu_util:-0}
    echo "\"cpu_util_percent\": $cpu_util,"

    # Memory Utilization Percent (remote)
    mem_util=$(run_ssh_cmd "free -m | awk '/^Mem:/ {if (\$2>0) printf \"%.2f\", (\$3/\$2)*100; else print 0}'" 2>/dev/null | xargs)
    mem_util=${mem_util:-0}
    echo "\"memory_util_percent\": $mem_util,"

    # Disk Utilization Percent (/data filesystem, remote)
    disk_usage=$(run_ssh_cmd "df -P /data 2>/dev/null | awk 'NR==2 {gsub(/%/,\"\",\$5); print \$5}'" 2>/dev/null | xargs)
    disk_usage=${disk_usage:-0}
    echo "\"disk_usage_percent\": $disk_usage"
    
    echo "},"
}

# 2. Database Connectivity & Status
# ------------------------------------------------------------------------------
collect_db_status() {
    echo "\"database_status\": {"
    
    # Service Status (Systemd)
    if run_ssh_cmd "systemctl is-active --quiet $SERVICE_NAME" >/dev/null 2>&1; then
        service_status="active"
    else
        # Try generic name if specific one fails
        if run_ssh_cmd "systemctl is-active --quiet postgresql" >/dev/null 2>&1; then
             service_status="active"
        else
             service_status="inactive"
        fi
    fi
    echo "\"service_status\": \"$service_status\","

    # Connection Check
    if psql_ping; then
        conn_status="success"
    else
        conn_status="failed"
    fi
    echo "\"connection_status\": \"$conn_status\""
    
    echo "},"
}

# 3. Performance Metrics
# ------------------------------------------------------------------------------
collect_performance_metrics() {
    echo "\"performance\": {"

    total_conns=$(psql_query "SELECT count(*) FROM pg_stat_activity;" | xargs)
    total_conns=${total_conns:-0}
    echo "\"total_connections\": $total_conns,"

    # Active Connections
    active_conns=$(psql_query "SELECT count(*) FROM pg_stat_activity WHERE state = 'active';" | xargs)
    active_conns=${active_conns:-0}
    echo "\"active_connections\": $active_conns,"

    # Idle Connections
    idle_conns=$(psql_query "SELECT count(*) FROM pg_stat_activity WHERE state = 'idle';" | xargs)
    idle_conns=${idle_conns:-0}
    echo "\"idle_connections\": $idle_conns,"

    idle_in_tx_conns=$(psql_query "SELECT count(*) FROM pg_stat_activity WHERE state = 'idle in transaction';" | xargs)
    idle_in_tx_conns=${idle_in_tx_conns:-0}
    echo "\"idle_in_transaction_connections\": $idle_in_tx_conns,"

    # Long Running Queries
    long_queries=$(psql_query "SELECT count(*) FROM pg_stat_activity WHERE state = 'active' AND now() - query_start > interval '$LONG_QUERY_THRESHOLD';" | xargs)
    long_queries=${long_queries:-0}
    echo "\"long_running_queries_count\": $long_queries,"
    
    # Cache Hit Ratio
    # Fixed: Use standard formula (hits / (hits + reads)) and standard SQL functions
    hit_ratio=$(psql_query "SELECT ROUND(sum(heap_blks_hit)::numeric / NULLIF(sum(heap_blks_hit) + sum(heap_blks_read), 0) * 100, 2) FROM pg_statio_user_tables;" | xargs)
    # Fallback for try_cast or div by zero
    if [[ -z "$hit_ratio" ]]; then hit_ratio=0; fi
    echo "\"cache_hit_ratio\": $hit_ratio"

    echo "},"
}

collect_database_metrics() {
    echo "\"database\": {"

    db_stats_query="
        SELECT row_to_json(t) FROM (
            SELECT
                datname,
                numbackends,
                xact_commit,
                xact_rollback,
                blks_read,
                blks_hit,
                tup_returned,
                tup_fetched,
                tup_inserted,
                tup_updated,
                tup_deleted,
                conflicts,
                deadlocks,
                temp_files,
                temp_bytes
            FROM pg_stat_database
            WHERE datname = current_database()
        ) t;
    "

    db_stats=$(psql_query "$db_stats_query")
    if [[ -z "$db_stats" ]]; then db_stats="{}"; fi
    echo "\"stats\": $db_stats"

    echo "},"
}

collect_lock_metrics() {
    echo "\"locks\": {"

    waiting_count=$(psql_query "SELECT count(*) FROM pg_stat_activity WHERE wait_event IS NOT NULL;" | xargs)
    waiting_count=${waiting_count:-0}
    echo "\"waiting_sessions\": $waiting_count,"

    waiters_query="
        SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (
            SELECT
                pid,
                usename,
                datname,
                state,
                EXTRACT(EPOCH FROM (now() - query_start))::int AS runtime_seconds,
                wait_event_type,
                wait_event,
                query
            FROM pg_stat_activity
            WHERE wait_event IS NOT NULL
            ORDER BY runtime_seconds DESC
            LIMIT 10
        ) t;
    "
    waiters=$(psql_query "$waiters_query")
    if [[ -z "$waiters" ]]; then waiters="[]"; fi
    echo "\"top_waiters\": $waiters,"

    blockers_query="
        SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (
            SELECT
                bl.pid AS blocked_pid,
                ka.pid AS blocking_pid,
                EXTRACT(EPOCH FROM (now() - a.query_start))::int AS blocked_for_seconds,
                a.query AS blocked_query,
                ka.query AS blocking_query
            FROM pg_catalog.pg_locks bl
            JOIN pg_catalog.pg_stat_activity a ON a.pid = bl.pid
            JOIN pg_catalog.pg_locks kl
              ON kl.locktype = bl.locktype
             AND kl.database IS NOT DISTINCT FROM bl.database
             AND kl.relation IS NOT DISTINCT FROM bl.relation
             AND kl.page IS NOT DISTINCT FROM bl.page
             AND kl.tuple IS NOT DISTINCT FROM bl.tuple
             AND kl.virtualxid IS NOT DISTINCT FROM bl.virtualxid
             AND kl.transactionid IS NOT DISTINCT FROM bl.transactionid
             AND kl.classid IS NOT DISTINCT FROM bl.classid
             AND kl.objid IS NOT DISTINCT FROM bl.objid
             AND kl.objsubid IS NOT DISTINCT FROM bl.objsubid
             AND kl.pid <> bl.pid
            JOIN pg_catalog.pg_stat_activity ka ON ka.pid = kl.pid
            WHERE NOT bl.granted
        ) t;
    "
    blocking_chains=$(psql_query "$blockers_query")
    if [[ -z "$blocking_chains" ]]; then blocking_chains="[]"; fi
    echo "\"blocking_chains\": $blocking_chains"

    echo "},"
}

collect_vacuum_metrics() {
    echo "\"vacuum\": {"

    dead_tuples_query="
        SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (
            SELECT
                schemaname,
                relname,
                n_live_tup,
                n_dead_tup,
                last_vacuum,
                last_autovacuum,
                last_analyze,
                last_autoanalyze
            FROM pg_stat_user_tables
            ORDER BY n_dead_tup DESC
            LIMIT 10
        ) t;
    "
    dead_tuples=$(psql_query "$dead_tuples_query")
    if [[ -z "$dead_tuples" ]]; then dead_tuples="[]"; fi
    echo "\"top_dead_tuples\": $dead_tuples,"

    freeze_risk_query="
        SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (
            SELECT
                n.nspname AS schemaname,
                c.relname,
                age(c.relfrozenxid) AS freeze_age,
                pg_total_relation_size(c.oid) AS total_bytes
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind='r'
              AND n.nspname NOT IN ('pg_catalog','information_schema')
            ORDER BY freeze_age DESC
            LIMIT 10
        ) t;
    "
    freeze_risk=$(psql_query "$freeze_risk_query")
    if [[ -z "$freeze_risk" ]]; then freeze_risk="[]"; fi
    echo "\"freeze_risk\": $freeze_risk"

    echo "},"
}

collect_wal_metrics() {
    echo "\"wal\": {"

    bgwriter_query="
        SELECT row_to_json(t) FROM (
            SELECT
                checkpoints_timed,
                checkpoints_req,
                checkpoint_write_time,
                checkpoint_sync_time,
                buffers_checkpoint,
                buffers_clean,
                buffers_backend,
                maxwritten_clean,
                buffers_alloc
            FROM pg_stat_bgwriter
        ) t;
    "
    bgwriter=$(psql_query "$bgwriter_query")
    if [[ -z "$bgwriter" ]]; then bgwriter="{}"; fi
    echo "\"bgwriter\": $bgwriter"

    echo "},"
}

collect_storage_metrics() {
    echo "\"storage\": {"

    database_size_query="
        SELECT row_to_json(t) FROM (
            SELECT
                pg_database_size(current_database()) AS database_size_bytes,
                pg_size_pretty(pg_database_size(current_database())) AS database_size
        ) t;
    "
    database_size=$(psql_query "$database_size_query")
    if [[ -z "$database_size" ]]; then database_size="{}"; fi
    echo "\"database_size\": $database_size,"

    temp_objects_query="
        SELECT row_to_json(t) FROM (
            SELECT
                COALESCE(sum(pg_total_relation_size(c.oid)), 0) AS temp_objects_total_bytes,
                pg_size_pretty(COALESCE(sum(pg_total_relation_size(c.oid)), 0)) AS temp_objects_total_size,
                count(*) AS temp_objects_count
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname LIKE 'pg_temp_%'
               OR n.nspname LIKE 'pg_toast_temp_%'
        ) t;
    "
    temp_objects=$(psql_query "$temp_objects_query")
    if [[ -z "$temp_objects" ]]; then temp_objects="{}"; fi
    echo "\"temp_objects\": $temp_objects,"

    top_tables_query="
        select * from valdezha.mv_largest_tab;
    "
    top_tables=$(psql_query "$top_tables_query")
    if [[ -z "$top_tables" ]]; then top_tables="[]"; fi
    echo "\"largest_tables\": $top_tables,"

    top_indexes_query="
    select * from valdezha.mv_largest_idx;
    "
    top_indexes=$(psql_query "$top_indexes_query")
    if [[ -z "$top_indexes" ]]; then top_indexes="[]"; fi
    echo "\"largest_indexes\": $top_indexes"

    echo "},"
}

# 4. Replication Status (if applicable)
# ------------------------------------------------------------------------------
collect_replication_metrics() {
    echo "\"replication\": {"
    
    is_in_recovery=$(psql_query "SELECT pg_is_in_recovery();" | xargs)
    if [[ -z "$is_in_recovery" ]]; then is_in_recovery="unknown"; fi
    echo "\"is_in_recovery\": \"$is_in_recovery\","

    if [ "$is_in_recovery" == "f" ]; then
        replica_count=$(psql_query "SELECT count(*) FROM pg_stat_replication;" | xargs)
        replica_count=${replica_count:-0}
        echo "\"connected_replicas\": $replica_count,"

        replication_details_query="
            SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (
                SELECT
                    pid,
                    client_addr,
                    state,
                    sent_lsn,
                    write_lsn,
                    flush_lsn,
                    replay_lsn,
                    write_lag,
                    flush_lag,
                    replay_lag
                FROM pg_stat_replication
            ) t;
        "
        replication_details=$(psql_query "$replication_details_query")
        if [[ -z "$replication_details" ]]; then replication_details="[]"; fi
        echo "\"replication_status\": $replication_details,"

        slots_query="
            SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (
                SELECT
                    slot_name,
                    slot_type,
                    active,
                    pg_xlog_location_diff(pg_current_xlog_location(), restart_lsn) AS retained_wal_bytes
                FROM pg_replication_slots
            ) t;
        "
        slots=$(psql_query "$slots_query")
        if [[ -z "$slots" ]]; then slots="[]"; fi
        echo "\"replication_slots\": $slots"
    else
        last_xact_replay=$(psql_query "SELECT COALESCE(EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))::int, 0);" | xargs)
        last_xact_replay=${last_xact_replay:-0}
        echo "\"replication_lag_seconds\": $last_xact_replay"
    fi

    echo "},"
}

# 5. Backup Readiness (WAL Archiving)
# ------------------------------------------------------------------------------
collect_backup_metrics() {
    echo "\"backup\": {"
    
    # Check if archiving is enabled
    archive_mode=$(psql_query_t "SHOW archive_mode;" | xargs)
    echo "\"archive_mode\": \"$archive_mode\","

    # Check last failed archive time
    last_failed=$(psql_query_t "SELECT last_failed_time FROM pg_stat_archiver;" | xargs)
    # Handle empty result (NULL)
    if [[ "$last_failed" == "" ]]; then last_failed="null"; else last_failed="\"$last_failed\""; fi
    echo "\"last_failed_archive\": $last_failed"

    echo "},"
}

# 6. Bloat Metrics (Table & Index)
# ------------------------------------------------------------------------------
collect_bloat_metrics() {
    echo "\"bloat\": {"
    
    # Table Bloat Query
    # Uses a standard approximation query based on pg_stats
    # Fixed: Improved null header calculation and logic
    table_bloat_query="
   SELECT * FROM valdezha.mv_tab_bloat;
    "
    
    table_bloat=$(psql_query "$table_bloat_query")
    if [[ -z "$table_bloat" ]]; then table_bloat="[]"; fi
    echo "\"top_bloated_tables\": $table_bloat,"

    # Index Bloat Query
    # Simplified heuristic: Indexes > 100MB AND larger than their table
    index_bloat_query="
    select * from valdezha.mv_idx_bloat;
    "
    
    index_bloat=$(psql_query "$index_bloat_query")
    if [[ -z "$index_bloat" ]]; then index_bloat="[]"; fi
    echo "\"large_indexes\": $index_bloat"

    echo "},"
}

# 7. Configuration Metrics (Security & Performance)
# ------------------------------------------------------------------------------
collect_config_metrics() {
    echo "\"configuration\": {"
    
    # Query key configuration parameters
    # We select a specific list of interesting parameters for health checks
    config_query="
        SELECT json_object_agg(name, setting) 
        FROM pg_settings 
        WHERE name IN (
            -- Security
            'ssl', 'log_connections', 'log_disconnections', 'log_statement', 'password_encryption', 'port',
            -- Performance / Memory
            'max_connections', 'shared_buffers', 'work_mem', 'maintenance_work_mem', 'effective_cache_size',
            -- Temp Objects
            'temp_buffers', 'temp_file_limit', 'temp_tablespaces',
            -- Autovacuum
            'autovacuum', 'autovacuum_max_workers', 'autovacuum_naptime',
            -- WAL / Checkpoints
            'wal_level', 'checkpoint_completion_target', 'max_wal_size'
        );
    "
    
    config_json=$(psql_query "$config_query")
    
    # Fallback if query fails (or json_object_agg not available, though it should be in 9.6)
    if [[ -z "$config_json" ]]; then config_json="{}"; fi
    
    echo "\"settings\": $config_json"

    echo "},"
}

# Main Execution
# ------------------------------------------------------------------------------
{
    json_start
    echo "\"timestamp\": \"$TIMESTAMP\","
    echo "\"hostname\": \"$HOSTNAME\","
    collect_system_metrics
    collect_db_status
    collect_performance_metrics
    collect_database_metrics
    collect_lock_metrics
    collect_vacuum_metrics
    collect_wal_metrics
    collect_storage_metrics
    collect_replication_metrics
    collect_backup_metrics
    collect_bloat_metrics
    collect_config_metrics
    # Remove trailing comma from last object if needed, but here we just ensure last item doesn't have comma inside the block
    # Actually, the last block 'backup' output has a trailing comma inside the function? No.
    # Wait, my functions output trailing commas. I need to handle that carefully or use a list approach.
    # Simplified approach: All blocks end with comma, I'll add a dummy final block.
    echo "\"meta\": { \"version\": \"1.1\" }"
    json_end
} > "$OUTPUT_FILE"

log_msg "Metrics collected and saved to $OUTPUT_FILE"

# Output the file content to stdout
cat "$OUTPUT_FILE"

# 8. Send to Webhook (Optional)
# ------------------------------------------------------------------------------
if [[ -n "$WEBHOOK_URL" && -n "$N8N_JWT_SECRET" ]]; then
    # Generate JWT Token using Python and jwt_helper.py
    # We assume jwt_helper.py is in the same directory as this script
    
    # Check for python3
    if command -v python3 &> /dev/null; then
        PYTHON_CMD="python3"
    elif command -v python &> /dev/null; then
        PYTHON_CMD="python"
    else
        log_error "Python not found. Cannot generate JWT for webhook."
        echo "Warning: Python not found. Cannot generate JWT for webhook." >&2
        PYTHON_CMD=""
    fi

    if [[ -n "$PYTHON_CMD" ]]; then
        JSON_VALIDATE_OUTPUT=$($PYTHON_CMD -c "
import json, sys, io
try:
    with io.open('$OUTPUT_FILE', 'r', encoding='utf-8') as f:
        json.load(f)
except Exception as e:
    sys.stderr.write(str(e))
    sys.exit(1)
" 2>&1)
        JSON_VALIDATE_EXIT_CODE=$?
        if [[ $JSON_VALIDATE_EXIT_CODE -ne 0 ]]; then
            log_error "Metrics JSON is invalid. Not sending to webhook. Error: $JSON_VALIDATE_OUTPUT"
            echo "Metrics JSON is invalid. Not sending to webhook. Error: $JSON_VALIDATE_OUTPUT" >&2
            exit 1
        fi

        # Capture both stdout and stderr to debug failures
        # Pass secret via env var to avoid quoting issues
        export N8N_JWT_SECRET
        JWT_OUTPUT=$($PYTHON_CMD -c "
import sys
import os
sys.path.append('$SCRIPT_DIR')
try:
    import jwt_helper
    payload = {
        'sub': 'edb-monitor',
        'name': 'Health Check Service for EDB',
        'role': 'service',
        'service_id': 'monitor-$SERVICE_NAME',
        'server_name': '$HOSTNAME',
        'timestamp': '$TIMESTAMP'
    }
    secret = os.environ.get('N8N_JWT_SECRET', '')
    if not secret:
        raise ValueError('N8N_JWT_SECRET is not set or empty')
    print(jwt_helper.generate_jwt(payload, secret))
except Exception as e:
    sys.stderr.write(str(e))
    sys.exit(1)
" 2>&1)
        
        PYTHON_EXIT_CODE=$?

        if [[ $PYTHON_EXIT_CODE -eq 0 && -n "$JWT_OUTPUT" ]]; then
             JWT_TOKEN="$JWT_OUTPUT"
             # Send data to webhook
             log_msg "Sending metrics to webhook..."
             echo "Sending metrics to webhook..." >&2
             response_file=$(mktemp)
             response=$(curl -s -o "$response_file" -w "%{http_code}" -X POST "$WEBHOOK_URL" \
                -H "Content-Type: application/json" \
                -H "User-Agent: EDB-Monitor/1.0" \
                -H "Authorization: Bearer $JWT_TOKEN" \
                -d @"$OUTPUT_FILE")
             
             if [[ "$response" == "200" ]]; then
                 log_msg "Successfully sent metrics to webhook."
                 echo "Successfully sent metrics to webhook." >&2
             else
                 response_body=$(cat "$response_file" 2>/dev/null | head -c 2000)
                 log_error "Failed to send metrics. HTTP Status: $response. Response: $response_body"
                 echo "Failed to send metrics. HTTP Status: $response" >&2
                 if [[ -n "$response_body" ]]; then
                     echo "Response body (truncated): $response_body" >&2
                 fi
             fi
             rm -f "$response_file" 2>/dev/null || true
        else
             log_error "Failed to generate JWT token. Error: $JWT_OUTPUT"
             echo "Failed to generate JWT token. Error: $JWT_OUTPUT" >&2
        fi
    fi
fi
