
#!/bin/bash

# ==============================================================================
# EnterpriseDB Advanced Server 9.6 Health Check & Monitoring Script
# Target System: RHEL 7 / Azure VM
# ==============================================================================

# Configuration
# ------------------------------------------------------------------------------
# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

resolve_local_hostname() {
    local resolved
    resolved="$(hostname 2>/dev/null || uname -n 2>/dev/null || echo unknown-host)"
    echo "$resolved"
}

# Logging Configuration
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOG_DIR"
LOG_HOSTNAME="${SERVER_NAME:-$(resolve_local_hostname)}"
LOG_HOSTNAME="$(echo "$LOG_HOSTNAME" | tr -cs '[:alnum:]_.-' '_')"
LOG_FILE="${LOG_DIR}/${LOG_HOSTNAME}_execution_$(date +%Y-%m-%d).log"

log_msg() {
    local msg="$1"
    echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] $msg" >> "$LOG_FILE"
}

log_error() {
    local msg="$1"
    echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] $msg" >> "$LOG_FILE"
}

usage() {
    cat <<'EOF'
Usage:
  ./collect_metrics.sh \
    --host-username <ssh_user> \
    --server-name <server_or_ip> \
    [--ssh-port <port>] \
        [--ssh-key <private_key_path>] \
        [--ssh-password <ssh_password>] \
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

load_env_file() {
    local env_file="$1"
    local line
    local key
    local value

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"

        if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi

        if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"

            if [[ "$value" =~ ^\".*\"$ ]]; then
                value="${value:1:${#value}-2}"
            elif [[ "$value" =~ ^\'.*\'$ ]]; then
                value="${value:1:${#value}-2}"
            fi

            export "$key=$value"
        fi
    done < "$env_file"
}

normalize_ssh_key_path() {
    local input_path="$1"
    if [[ "$input_path" =~ ^([A-Za-z]):\\(.*)$ ]]; then
        local drive="${BASH_REMATCH[1],,}"
        local rest="${BASH_REMATCH[2]}"
        rest="${rest//\\//}"
        echo "/${drive}/${rest}"
    else
        echo "$input_path"
    fi
}

normalize_windows_path() {
    local input_path="$1"
    if [[ "$input_path" =~ ^([A-Za-z]):\\(.*)$ ]]; then
        local drive="${BASH_REMATCH[1],,}"
        local rest="${BASH_REMATCH[2]}"
        rest="${rest//\\//}"

        if [[ -d "/mnt/$drive" ]]; then
            echo "/mnt/${drive}/${rest}"
        else
            echo "/${drive}/${rest}"
        fi
    else
        echo "$input_path"
    fi
}

resolve_existing_ssh_key_path() {
    local candidate
    candidate="$(normalize_ssh_key_path "$1")"

    if [[ -f "$candidate" ]]; then
        echo "$candidate"
        return 0
    fi

    if [[ "$candidate" =~ ^/([a-z])/(.*)$ ]]; then
        local drive="${BASH_REMATCH[1]}"
        local rest="${BASH_REMATCH[2]}"
        local wsl_candidate="/mnt/${drive}/${rest}"
        if [[ -f "$wsl_candidate" ]]; then
            echo "$wsl_candidate"
            return 0
        fi
    fi

    echo "$candidate"
}

resolve_plink_binary() {
    local plink_path=""

    if [[ -n "$PLINK_PATH" && -f "$PLINK_PATH" ]]; then
        echo "$PLINK_PATH"
        return 0
    fi

    if command -v plink >/dev/null 2>&1; then
        command -v plink
        return 0
    fi

    if [[ -f "/c/Program Files/PuTTY/plink.exe" ]]; then
        echo "/c/Program Files/PuTTY/plink.exe"
        return 0
    fi

    if [[ -f "/mnt/c/Program Files/PuTTY/plink.exe" ]]; then
        echo "/mnt/c/Program Files/PuTTY/plink.exe"
        return 0
    fi

    return 1
}

to_windows_path() {
    local input_path="$1"

    if [[ "$input_path" =~ ^/mnt/([a-zA-Z])/(.*)$ ]]; then
        local drive="${BASH_REMATCH[1]^}"
        local rest="${BASH_REMATCH[2]}"
        rest="${rest//\//\\}"
        echo "${drive}:\\${rest}"
        return 0
    fi

    if [[ "$input_path" =~ ^/([a-zA-Z])/(.*)$ ]]; then
        local drive="${BASH_REMATCH[1]^}"
        local rest="${BASH_REMATCH[2]}"
        rest="${rest//\//\\}"
        echo "${drive}:\\${rest}"
        return 0
    fi

    echo "$input_path"
}

run_plink_via_powershell() {
    local plink_path="$1"
    local plink_key="$2"
    local cmd="$3"
    local plink_path_s
    local plink_key_s
    local ps_host
    local ps_port
    local ps_user
    local ps_target
    local cmd_s
    local ps_script

    escape_for_powershell() {
        local input="$1"
        printf '%s' "$input" | base64 | tr -d '\r\n'
    }

    ps_host="$(escape_for_powershell "$SSH_HOST")"
    ps_port="$(escape_for_powershell "$SSH_PORT")"
    ps_user="$(escape_for_powershell "$SSH_USER")"
    plink_path_s="$(escape_for_powershell "$plink_path")"
    plink_key_s="$(escape_for_powershell "$plink_key")"
    cmd_s="$(escape_for_powershell "$cmd")"
    ps_target="${ps_user}@${ps_host}"

    ps_script="\$ErrorActionPreference='Stop'; \$enc=[System.Text.Encoding]::UTF8; \$plink=\$enc.GetString([System.Convert]::FromBase64String('${plink_path_s}')); \$key=\$enc.GetString([System.Convert]::FromBase64String('${plink_key_s}')); \$host=\$enc.GetString([System.Convert]::FromBase64String('${ps_host}')); \$port=\$enc.GetString([System.Convert]::FromBase64String('${ps_port}')); \$user=\$enc.GetString([System.Convert]::FromBase64String('${ps_user}')); \$remote=\$enc.GetString([System.Convert]::FromBase64String('${cmd_s}')); \$target=\$user + '@' + \$host; & \$plink -batch -P \$port -i \$key \$target \$remote; exit \$LASTEXITCODE"

    if command -v powershell.exe >/dev/null 2>&1; then
        powershell.exe -NoProfile -NonInteractive -Command "$ps_script"
        return $?
    fi

    if command -v pwsh.exe >/dev/null 2>&1; then
        pwsh.exe -NoProfile -NonInteractive -Command "$ps_script"
        return $?
    fi

    if command -v powershell >/dev/null 2>&1; then
        powershell -NoProfile -NonInteractive -Command "$ps_script"
        return $?
    fi

    if command -v pwsh >/dev/null 2>&1; then
        pwsh -NoProfile -NonInteractive -Command "$ps_script"
        return $?
    fi

    return 127
}

# Load environment variables
if [ -f .env ]; then
    load_env_file .env
fi

# Remote connection settings (CLI args override env defaults)
SSH_USER="${HOST_USERNAME:-${SSH_USER:-}}"
SSH_HOST="${SERVER_NAME:-${SSH_HOST:-}}"
SSH_PORT="${SSH_PORT:-22}"
SSH_KEY_FILE="${SSH_KEY_FILE:-}"
SSH_PASSWORD="${SSH_PASSWORD:-}"

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
        --ssh-key|--ssh-key-file)
            SSH_KEY_FILE="$2"
            shift 2
            ;;
        --ssh-password)
            SSH_PASSWORD="$2"
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

if [[ -n "$SSH_KEY_FILE" ]]; then
    SSH_KEY_FILE="$(resolve_existing_ssh_key_path "$SSH_KEY_FILE")"
fi

if [[ -n "$SSH_KEY_FILE" && ! -f "$SSH_KEY_FILE" ]]; then
    echo "Error: SSH key file not found: $SSH_KEY_FILE" >&2
    exit 1
fi

if [[ -z "$DB_HOST" ]]; then
    DB_HOST="$SSH_HOST"
fi

if [[ -z "$DB_USERNAME" || -z "$DB_PASSWORD" ]]; then
    echo "Error: --db-username and --db-password are required." >&2
    exit 1
fi

LOG_HOSTNAME="$SSH_HOST"
LOG_HOSTNAME="$(echo "$LOG_HOSTNAME" | tr -cs '[:alnum:]_.-' '_')"
LOG_FILE="${LOG_DIR}/${LOG_HOSTNAME}_execution_$(date +%Y-%m-%d).log"
log_msg "Starting EDB Health Check..."

# Keep compatibility with downstream variable names
PGUSER="$DB_USERNAME"
PGPASSWORD="$DB_PASSWORD"
PGPORT="$DB_PORT"
PGHOST="$DB_HOST"

PGBIN="${PGBIN:-/usr/edb/as9.6/bin}" # Adjust path if necessary
PSQL="$PGBIN/edb-psql"
REMOTE_PGBIN="${REMOTE_PGBIN:-$PGBIN}"
if [[ "$REMOTE_PGBIN" =~ ^[A-Za-z]: || "$REMOTE_PGBIN" == *\\* ]]; then
    REMOTE_PGBIN="/usr/edb/as9.6/bin"
fi
USE_REMOTE_PSQL="false"
REMOTE_PSQL=""
PSQL_CLIENT_READY="false"
PSQL_CLIENT_ERROR_EMITTED="false"
SSH_READY="unknown"
SERVICE_NAME="${SERVICE_NAME:-edb-as-9.6}"
LONG_QUERY_THRESHOLD="${LONG_QUERY_THRESHOLD:-5 minutes}"
HOSTNAME="$SSH_HOST"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
OUTPUT_FILE="${OUTPUT_FILE:-/tmp/edb_health_metrics.json}"
OUTPUT_FILE="$(normalize_windows_path "$OUTPUT_FILE")"

run_ssh_cmd() {
    local cmd="$1"
    local ssh_opts
    local plink_bin
    local plink_key
    local rc
    local askpass_script
    local ssh_exit

    ssh_opts=(-p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=10)

    if [[ -n "$SSH_KEY_FILE" ]]; then
        if [[ "$SSH_KEY_FILE" =~ \.ppk$ ]] && plink_bin="$(resolve_plink_binary)"; then
            plink_key="$(to_windows_path "$SSH_KEY_FILE")"

            if "$plink_bin" -V >/dev/null 2>&1; then
                "$plink_bin" -batch -P "$SSH_PORT" -i "$plink_key" "$SSH_USER@$SSH_HOST" "$cmd"
                return $?
            fi

            run_plink_via_powershell "$plink_bin" "$plink_key" "$cmd"
            rc=$?

            if [[ $rc -eq 0 ]]; then
                return 0
            fi

            if [[ $rc -ne 127 ]]; then
                return $rc
            fi

            echo "Error: Found plink at '$plink_bin' but this shell cannot execute it, and PowerShell bridge is unavailable." >&2
            echo "Hint: this is usually WSL with Windows interop disabled. Convert .ppk to OpenSSH key or run from a shell that can execute plink." >&2
            return 1
        fi
        ssh -i "$SSH_KEY_FILE" "${ssh_opts[@]}" "$SSH_USER@$SSH_HOST" "$cmd"
    elif [[ -n "$SSH_PASSWORD" ]]; then
        if ! command -v sshpass >/dev/null 2>&1; then
            if ! command -v setsid >/dev/null 2>&1; then
                echo "Error: Password authentication requires sshpass or setsid (for SSH_ASKPASS fallback)." >&2
                return 1
            fi

            askpass_script="$(mktemp)"
            cat > "$askpass_script" <<'EOF'
#!/bin/sh
printf '%s\n' "${SSH_ASKPASS_PASSWORD:-}"
EOF
            chmod 700 "$askpass_script"

            DISPLAY="${DISPLAY:-:0}" SSH_ASKPASS="$askpass_script" SSH_ASKPASS_REQUIRE=force SSH_ASKPASS_PASSWORD="$SSH_PASSWORD" \
                setsid ssh -o BatchMode=no -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive \
                -p "$SSH_PORT" -o ConnectTimeout=10 "$SSH_USER@$SSH_HOST" "$cmd" < /dev/null
            ssh_exit=$?
            rm -f "$askpass_script"
            return $ssh_exit
        fi
        SSHPASS="$SSH_PASSWORD" sshpass -e ssh -o BatchMode=no -p "$SSH_PORT" -o ConnectTimeout=10 "$SSH_USER@$SSH_HOST" "$cmd"
    else
        ssh "${ssh_opts[@]}" "$SSH_USER@$SSH_HOST" "$cmd"
    fi
}

ensure_ssh_connectivity() {
    if [[ "$SSH_READY" == "true" ]]; then
        return 0
    fi

    if run_ssh_cmd "echo SSH_OK" >/dev/null; then
        SSH_READY="true"
        return 0
    fi

    SSH_READY="false"
    return 1
}

ensure_psql_client() {
    if [[ "$PSQL_CLIENT_READY" == "true" ]]; then
        return 0
    fi

    if [ -f "$PSQL" ]; then
        PSQL_CLIENT_READY="true"
        return 0
    fi

    if command -v edb-psql &> /dev/null; then
        PSQL="edb-psql"
        PSQL_CLIENT_READY="true"
        return 0
    fi

    if command -v psql &> /dev/null; then
        PSQL="psql"
        PSQL_CLIENT_READY="true"
        return 0
    fi

    if ensure_ssh_connectivity; then
        REMOTE_PSQL=$(run_ssh_cmd "bash -lc 'if [ -x \"$REMOTE_PGBIN/edb-psql\" ]; then echo \"$REMOTE_PGBIN/edb-psql\"; elif command -v edb-psql >/dev/null 2>&1; then command -v edb-psql; elif command -v psql >/dev/null 2>&1; then command -v psql; elif [ -x /usr/edb/as9.6/bin/edb-psql ]; then echo /usr/edb/as9.6/bin/edb-psql; elif [ -x /usr/bin/psql ]; then echo /usr/bin/psql; fi'" 2>/dev/null | head -n 1 | xargs)
    else
        REMOTE_PSQL=""
    fi

    if [[ -n "$REMOTE_PSQL" ]]; then
        USE_REMOTE_PSQL="true"
        PSQL_CLIENT_READY="true"
        log_msg "Using remote psql client over SSH: $REMOTE_PSQL"
        return 0
    fi

    if [[ "$PSQL_CLIENT_ERROR_EMITTED" != "true" ]]; then
        if [[ "$SSH_READY" == "false" ]]; then
            log_error "SSH connectivity failed to $SSH_USER@$SSH_HOST:$SSH_PORT. Cannot check remote psql."
            echo "Error: SSH connectivity/auth failed to $SSH_USER@$SSH_HOST:$SSH_PORT (cannot check remote psql)." >&2
            echo "Hint: verify VPN/network route, NSG/firewall for port $SSH_PORT, remote username, and SSH auth method (key path/permissions or password with sshpass)." >&2
        else
            log_error "Neither local nor remote edb-psql/psql found."
            echo "Error: Neither local nor remote edb-psql/psql found." >&2
        fi
        PSQL_CLIENT_ERROR_EMITTED="true"
    fi
    return 1
}

remote_psql_query() {
    local mode="$1"
    local sql="$2"
    local psql_opts
    local esc_pass esc_host esc_user esc_db esc_port esc_psql

    if [[ "$mode" == "t" ]]; then
        psql_opts="-t"
    else
        psql_opts="-A -t"
    fi

    esc_pass=$(printf '%q' "$PGPASSWORD")
    esc_host=$(printf '%q' "$PGHOST")
    esc_user=$(printf '%q' "$PGUSER")
    esc_db=$(printf '%q' "$PGDATABASE")
    esc_port=$(printf '%q' "$PGPORT")
    esc_psql=$(printf '%q' "$REMOTE_PSQL")

    run_ssh_cmd "PGPASSWORD=$esc_pass $esc_psql -h $esc_host -U $esc_user -d $esc_db -p $esc_port $psql_opts -f -" <<< "$sql" 2>/dev/null
}

psql_query() {
    local sql="$1"
    ensure_psql_client || return 1
    if [[ "$USE_REMOTE_PSQL" == "true" ]]; then
        remote_psql_query "at" "$sql"
    else
        PGPASSWORD="$PGPASSWORD" "$PSQL" -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -p "$PGPORT" -A -t -c "$sql" 2>/dev/null
    fi
}

psql_query_t() {
    local sql="$1"
    ensure_psql_client || return 1
    if [[ "$USE_REMOTE_PSQL" == "true" ]]; then
        remote_psql_query "t" "$sql"
    else
        PGPASSWORD="$PGPASSWORD" "$PSQL" -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -p "$PGPORT" -t -c "$sql" 2>/dev/null
    fi
}

psql_ping() {
    ensure_psql_client || return 1
    if [[ "$USE_REMOTE_PSQL" == "true" ]]; then
        remote_psql_query "at" "SELECT 1" >/dev/null 2>&1
    else
        PGPASSWORD="$PGPASSWORD" "$PSQL" -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -p "$PGPORT" -c "SELECT 1" >/dev/null 2>&1
    fi
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
    echo "\"cache_hit_ratio\": $hit_ratio,"

    # Checkpoint & WAL Stress Rates
    wal_stress_query="
        SELECT row_to_json(t) FROM (
            SELECT
                checkpoints_timed,
                checkpoints_req,
                ROUND((checkpoints_req::numeric / NULLIF(checkpoints_timed + checkpoints_req, 0)) * 100, 2) AS requested_checkpoint_ratio_pct,
                ROUND((buffers_backend::numeric / NULLIF(buffers_checkpoint + buffers_clean + buffers_backend, 0)) * 100, 2) AS backend_write_pressure_pct,
                ROUND((checkpoint_write_time::numeric / NULLIF(checkpoints_timed + checkpoints_req, 0)), 2) AS checkpoint_write_time_ms_per_checkpoint,
                ROUND((checkpoint_sync_time::numeric / NULLIF(checkpoints_timed + checkpoints_req, 0)), 2) AS checkpoint_sync_time_ms_per_checkpoint
            FROM pg_stat_bgwriter
        ) t;
    "
    wal_stress=$(psql_query "$wal_stress_query")
    if [[ -z "$wal_stress" ]]; then wal_stress="{}"; fi
    echo "\"wal_stress\": $wal_stress,"

    # Autovacuum Effectiveness
    autovac_effectiveness_query="
        SELECT row_to_json(t) FROM (
            SELECT
                COUNT(*) FILTER (WHERE n_dead_tup > 0) AS tables_with_dead_tuples,
                COUNT(*) FILTER (WHERE n_dead_tup > GREATEST(n_live_tup, 1) * 0.2) AS tables_dead_tuple_ratio_over_20pct,
                COUNT(*) FILTER (WHERE last_autovacuum IS NULL) AS tables_never_autovacuumed,
                COALESCE(SUM(n_dead_tup), 0) AS total_dead_tuples,
                COALESCE(SUM(n_live_tup), 0) AS total_live_tuples,
                ROUND((COALESCE(SUM(n_dead_tup), 0)::numeric / NULLIF(COALESCE(SUM(n_live_tup), 0) + COALESCE(SUM(n_dead_tup), 0), 0)) * 100, 2) AS global_dead_tuple_ratio_pct,
                ROUND((AVG(EXTRACT(EPOCH FROM (now() - last_autovacuum))) FILTER (WHERE last_autovacuum IS NOT NULL))::numeric, 2) AS avg_seconds_since_last_autovacuum
            FROM pg_stat_user_tables
        ) t;
    "
    autovac_effectiveness=$(psql_query "$autovac_effectiveness_query")
    if [[ -z "$autovac_effectiveness" ]]; then autovac_effectiveness="{}"; fi
    echo "\"autovacuum_effectiveness\": $autovac_effectiveness,"

    # Lock Contention Severity + Longest Lock Wait
    waiting_sessions_perf=$(psql_query "SELECT count(*) FROM pg_stat_activity WHERE wait_event IS NOT NULL;" | xargs)
    waiting_sessions_perf=${waiting_sessions_perf:-0}

    longest_lock_wait_seconds=$(psql_query "SELECT COALESCE(MAX(EXTRACT(EPOCH FROM (now() - query_start))::int), 0) FROM pg_stat_activity WHERE wait_event IS NOT NULL;" | xargs)
    longest_lock_wait_seconds=${longest_lock_wait_seconds:-0}

    if [[ "$longest_lock_wait_seconds" -ge 300 || "$waiting_sessions_perf" -ge 20 ]]; then
        lock_severity="critical"
    elif [[ "$longest_lock_wait_seconds" -ge 120 || "$waiting_sessions_perf" -ge 10 ]]; then
        lock_severity="high"
    elif [[ "$longest_lock_wait_seconds" -ge 30 || "$waiting_sessions_perf" -ge 3 ]]; then
        lock_severity="medium"
    else
        lock_severity="low"
    fi

    echo "\"waiting_sessions_for_severity\": $waiting_sessions_perf,"
    echo "\"longest_lock_wait_seconds\": $longest_lock_wait_seconds,"
    echo "\"lock_contention_severity\": \"$lock_severity\","

    # Per-Database Health Split
    per_database_health_query="
        SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (
            SELECT
                datname,
                numbackends,
                xact_commit,
                xact_rollback,
                ROUND((xact_rollback::numeric / NULLIF(xact_commit + xact_rollback, 0)) * 100, 2) AS rollback_ratio_pct,
                blks_read,
                blks_hit,
                ROUND((blks_hit::numeric / NULLIF(blks_hit + blks_read, 0)) * 100, 2) AS cache_hit_ratio_pct,
                deadlocks,
                temp_files,
                temp_bytes,
                stats_reset
            FROM pg_stat_database
            WHERE datname NOT IN ('template0', 'template1')
            ORDER BY temp_bytes DESC NULLS LAST, deadlocks DESC NULLS LAST
        ) t;
    "
    per_database_health=$(psql_query "$per_database_health_query")
    if [[ -z "$per_database_health" ]]; then per_database_health="[]"; fi
    echo "\"per_database_health\": $per_database_health,"

    # Query Performance (pg_stat_statements if installed)
    has_pg_stat_statements=$(psql_query "SELECT EXISTS(SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements');" | xargs)
    has_pg_stat_statements=${has_pg_stat_statements:-f}

    if [[ "$has_pg_stat_statements" == "t" ]]; then
        query_perf_query="
            SELECT row_to_json(t) FROM (
                SELECT
                    s.total_calls,
                    s.total_exec_time_ms,
                    ROUND((s.total_exec_time_ms / NULLIF(s.total_calls, 0)), 2) AS avg_exec_time_ms,
                    q.top_queries
                FROM (
                    SELECT
                        COALESCE(SUM(calls), 0) AS total_calls,
                        COALESCE(SUM(total_time), 0)::numeric AS total_exec_time_ms
                    FROM pg_stat_statements
                ) s,
                (
                    SELECT COALESCE(json_agg(row_to_json(x)), '[]'::json) AS top_queries
                    FROM (
                        SELECT
                            userid,
                            dbid,
                            calls,
                            ROUND(total_time::numeric, 2) AS total_time_ms,
                            ROUND((total_time / NULLIF(calls, 0))::numeric, 2) AS mean_time_ms,
                            rows,
                            shared_blks_hit,
                            shared_blks_read,
                            temp_blks_read,
                            temp_blks_written,
                            query
                        FROM pg_stat_statements
                        ORDER BY total_time DESC
                        LIMIT 10
                    ) x
                ) q
            ) t;
        "
        query_performance=$(psql_query "$query_perf_query")
        if [[ -z "$query_performance" ]]; then query_performance="{}"; fi
    else
        query_performance='{"available": false, "reason": "pg_stat_statements extension not installed"}'
    fi

    echo "\"query_performance\": $query_performance"

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
if ! ensure_psql_client; then
    exit 1
fi

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
             WEBHOOK_MAX_RETRIES=${WEBHOOK_MAX_RETRIES:-3}
             WEBHOOK_INITIAL_BACKOFF_SEC=${WEBHOOK_INITIAL_BACKOFF_SEC:-5}
             WEBHOOK_MAX_BACKOFF_SEC=${WEBHOOK_MAX_BACKOFF_SEC:-30}
             WEBHOOK_CONNECT_TIMEOUT_SEC=${WEBHOOK_CONNECT_TIMEOUT_SEC:-10}
             WEBHOOK_REQUEST_TIMEOUT_SEC=${WEBHOOK_REQUEST_TIMEOUT_SEC:-120}
             WEBHOOK_ENABLE_COMPACT_FALLBACK=${WEBHOOK_ENABLE_COMPACT_FALLBACK:-true}

             response_file=$(mktemp)
             response="000"
             response_body=""
             backoff_sec=$WEBHOOK_INITIAL_BACKOFF_SEC
             delivery_ok="false"

             send_webhook_payload() {
                 local payload_file="$1"
                 curl -s -o "$response_file" -w "%{http_code}" -X POST "$WEBHOOK_URL" \
                    --connect-timeout "$WEBHOOK_CONNECT_TIMEOUT_SEC" \
                    --max-time "$WEBHOOK_REQUEST_TIMEOUT_SEC" \
                    -H "Content-Type: application/json" \
                    -H "User-Agent: EDB-Monitor/1.0" \
                    -H "Authorization: Bearer $JWT_TOKEN" \
                    -d @"$payload_file"
             }

             for ((attempt=1; attempt<=WEBHOOK_MAX_RETRIES; attempt++)); do
                 response=$(send_webhook_payload "$OUTPUT_FILE")
                 response_body=$(cat "$response_file" 2>/dev/null | head -c 2000)

                 if [[ "$response" =~ ^2[0-9][0-9]$ ]]; then
                     delivery_ok="true"
                     break
                 fi

                if (( attempt < WEBHOOK_MAX_RETRIES )) && [[ "$response" =~ ^(000|408|429|500|502|503|504|524)$ ]]; then
                     log_error "Webhook attempt $attempt/$WEBHOOK_MAX_RETRIES failed with HTTP $response. Retrying in ${backoff_sec}s."
                     sleep "$backoff_sec"
                     backoff_sec=$(( backoff_sec * 2 ))
                     if (( backoff_sec > WEBHOOK_MAX_BACKOFF_SEC )); then
                         backoff_sec=$WEBHOOK_MAX_BACKOFF_SEC
                     fi
                 else
                     break
                 fi
             done

             if [[ "$delivery_ok" != "true" ]] && [[ "$WEBHOOK_ENABLE_COMPACT_FALLBACK" == "true" ]] && [[ "$response" =~ ^(000|408|429|500|502|503|504|524)$ ]]; then
                 compact_payload_file=$(mktemp)
                 compact_output=$($PYTHON_CMD -c "
import io, json, sys
src = '$OUTPUT_FILE'
dst = '$compact_payload_file'
with io.open(src, 'r', encoding='utf-8') as f:
    data = json.load(f)

compact = {
    'timestamp': data.get('timestamp'),
    'hostname': data.get('hostname'),
    'database_status': data.get('database_status', {}),
    'performance': {
        'total_connections': data.get('performance', {}).get('total_connections'),
        'active_connections': data.get('performance', {}).get('active_connections'),
        'long_running_queries_count': data.get('performance', {}).get('long_running_queries_count'),
        'cache_hit_ratio': data.get('performance', {}).get('cache_hit_ratio'),
        'lock_contention_severity': data.get('performance', {}).get('lock_contention_severity')
    },
    'summary_only': True
}

with io.open(dst, 'w', encoding='utf-8') as f:
    json.dump(compact, f, separators=(',', ':'))
print('ok')
" 2>&1)

                 if [[ "$compact_output" == "ok" ]]; then
                     response=$(send_webhook_payload "$compact_payload_file")
                     response_body=$(cat "$response_file" 2>/dev/null | head -c 2000)
                     if [[ "$response" =~ ^2[0-9][0-9]$ ]]; then
                         delivery_ok="true"
                         log_msg "Successfully sent compact fallback metrics to webhook after timeout-class failures."
                     fi
                 fi
                 rm -f "$compact_payload_file" 2>/dev/null || true
             fi

             if [[ "$delivery_ok" == "true" ]]; then
                 log_msg "Successfully sent metrics to webhook."
                 echo "Successfully sent metrics to webhook." >&2
             else
                 log_error "Failed to send metrics after retries. HTTP Status: $response. Response: $response_body"
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
