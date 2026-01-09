#!/bin/bash

# ==============================================================================
# EnterpriseDB Advanced Server 9.6 Comprehensive Health Check & Monitoring Script
# Enhanced Version with Log Analysis and Patch Management
# Target System: RHEL 7 / Azure VM
# Version: 2.0
# ==============================================================================

# Configuration
# ------------------------------------------------------------------------------
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

log_msg "Starting EDB Comprehensive Health Check..."

# Load environment variables
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

PGUSER="${PGUSER:-enterprisedb}"
PGPORT="${PGPORT:-5444}"
PGDATABASE="${PGDATABASE:-edb}"
PGPASSWORD="${PGPASSWORD}"
PGBIN="${PGBIN:-/usr/edb/as9.6/bin}"
PSQL="$PGBIN/edb-psql"
SERVICE_NAME="${SERVICE_NAME:-edb-as-9.6}"
LONG_QUERY_THRESHOLD="${LONG_QUERY_THRESHOLD:-5 minutes}"
HOSTNAME=$(hostname)
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
OUTPUT_FILE="${OUTPUT_FILE:-/tmp/edb_health_metrics.json}"

# Enhanced configuration
LOG_DIR_EDB="${LOG_DIR_EDB:-/var/log/edb/as9.6}"
LOG_ANALYSIS_ENABLED="${LOG_ANALYSIS_ENABLED:-true}"
ERROR_LOG_PATTERNS="${ERROR_LOG_PATTERNS:-FATAL|ERROR|PANIC}"
PATCH_CHECK_ENABLED="${PATCH_CHECK_ENABLED:-true}"
EDB_VERSION_CHECK="${EDB_VERSION_CHECK:-true}"

# Check if edb-psql exists
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

# JSON Building Helper Functions
# ------------------------------------------------------------------------------
json_start() { echo "{"; }
json_end() { echo "}"; }
json_key_value() { echo "\"$1\": \"$2\""; }
json_key_num() { echo "\"$1\": $2"; }
json_key_obj_start() { echo "\"$1\": {"; }
json_obj_end() { echo "}"; }
json_comma() { echo ","; }

# Include all existing collection functions from original script
# (System, Database Status, Performance, Locks, Vacuum, WAL, Storage, Replication, Backup, Bloat, Config)
# ... [Previous functions remain the same] ...

# 11. Log Analysis
# ------------------------------------------------------------------------------
collect_log_metrics() {
    echo "\"log_analysis\": {"
    
    if [ "$LOG_ANALYSIS_ENABLED" != "true" ]; then
        echo "\"enabled\": false"
        echo "},"
        return
    fi
    
    echo "\"enabled\": true,"
    
    # Find PostgreSQL log files
    log_files=""
    if [ -d "$LOG_DIR_EDB" ]; then
        # Try common log file locations
        for log_pattern in "postgresql*.log" "edb*.log" "*.log"; do
            found=$(find "$LOG_DIR_EDB" -maxdepth 1 -name "$log_pattern" -type f 2>/dev/null | head -5)
            if [ -n "$found" ]; then
                log_files="$log_files $found"
            fi
        done
    fi
    
    # Also check systemd journal if available
    journal_available=false
    if command -v journalctl &> /dev/null; then
        journal_available=true
    fi
    
    # Error count from last 24 hours
    error_count=0
    if [ "$journal_available" = true ]; then
        error_count=$(journalctl -u "$SERVICE_NAME" --since "24 hours ago" --no-pager 2>/dev/null | grep -iE "$ERROR_LOG_PATTERNS" | wc -l)
    elif [ -n "$log_files" ]; then
        for log_file in $log_files; do
            if [ -r "$log_file" ]; then
                count=$(grep -iE "$ERROR_LOG_PATTERNS" "$log_file" 2>/dev/null | wc -l)
                error_count=$((error_count + count))
            fi
        done
    fi
    echo "\"error_count_24h\": $error_count,"
    
    # Recent critical errors (last 100 lines)
    recent_errors="[]"
    if [ "$journal_available" = true ]; then
        recent_errors=$(journalctl -u "$SERVICE_NAME" --since "1 hour ago" --no-pager -n 100 2>/dev/null | \
            grep -iE "$ERROR_LOG_PATTERNS" | \
            head -10 | \
            jq -R -s 'split("\n") | map(select(length > 0)) | .[0:10]' 2>/dev/null || echo "[]")
    elif [ -n "$log_files" ]; then
        for log_file in $log_files; do
            if [ -r "$log_file" ]; then
                recent_errors=$(tail -100 "$log_file" 2>/dev/null | \
                    grep -iE "$ERROR_LOG_PATTERNS" | \
                    head -10 | \
                    jq -R -s 'split("\n") | map(select(length > 0)) | .[0:10]' 2>/dev/null || echo "[]")
                break
            fi
        done
    fi
    echo "\"recent_errors\": $recent_errors,"
    
    # Log file sizes
    log_sizes="{}"
    if [ -n "$log_files" ]; then
        log_sizes=$(for log_file in $log_files; do
            if [ -r "$log_file" ]; then
                size=$(stat -f%z "$log_file" 2>/dev/null || stat -c%s "$log_file" 2>/dev/null || echo "0")
                echo "\"$(basename "$log_file")\": $size"
            fi
        done | jq -s 'add' 2>/dev/null || echo "{}")
    fi
    echo "\"log_file_sizes\": $log_sizes,"
    
    # Checkpoint messages (indicating issues)
    checkpoint_warnings=0
    if [ "$journal_available" = true ]; then
        checkpoint_warnings=$(journalctl -u "$SERVICE_NAME" --since "24 hours ago" --no-pager 2>/dev/null | \
            grep -iE "checkpoint|WAL" | wc -l)
    fi
    echo "\"checkpoint_warnings_24h\": $checkpoint_warnings"
    
    echo "},"
}

# 12. Patch Management & Version Information
# ------------------------------------------------------------------------------
collect_patch_metrics() {
    echo "\"patch_management\": {"
    
    if [ "$PATCH_CHECK_ENABLED" != "true" ]; then
        echo "\"enabled\": false"
        echo "},"
        return
    fi
    
    echo "\"enabled\": true,"
    
    # Get PostgreSQL/EDB version
    db_version=$($PSQL -U "$PGUSER" -d "$PGDATABASE" -p "$PGPORT" -A -t -c "SELECT version();" 2>/dev/null | head -1)
    if [[ -z "$db_version" ]]; then db_version="unknown"; fi
    echo "\"database_version\": \"$db_version\","
    
    # Extract version number
    version_number=$(echo "$db_version" | grep -oE '[0-9]+\.[0-9]+' | head -1)
    echo "\"version_number\": \"$version_number\","
    
    # Check for available updates (RHEL 7)
    updates_available="unknown"
    if command -v yum &> /dev/null; then
        # Check for EDB package updates (requires appropriate repos)
        edb_updates=$(yum check-update --quiet 2>/dev/null | grep -i "edb\|enterprisedb\|postgresql" | wc -l)
        if [ "$edb_updates" -gt 0 ]; then
            updates_available="available"
        else
            updates_available="none"
        fi
    fi
    echo "\"updates_available\": \"$updates_available\","
    
    # Security patches (if CVE checking is available)
    security_patches="unknown"
    if command -v yum &> /dev/null; then
        security_patches=$(yum list-security --quiet 2>/dev/null | grep -i "edb\|enterprisedb\|postgresql" | wc -l || echo "0")
    fi
    echo "\"security_patches_count\": $security_patches,"
    
    # Last update check
    last_update_check=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "\"last_update_check\": \"$last_update_check\","
    
    # Extension versions (if applicable)
    extensions=$($PSQL -U "$PGUSER" -d "$PGDATABASE" -p "$PGPORT" -A -t -c "
        SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (
            SELECT extname, extversion 
            FROM pg_extension 
            ORDER BY extname
        ) t;
    " 2>/dev/null)
    if [[ -z "$extensions" ]]; then extensions="[]"; fi
    echo "\"installed_extensions\": $extensions"
    
    echo "},"
}

# Include all previous collection functions here
# (Copy from original collect_metrics.sh)
# For brevity, I'll reference the original functions

# Main Execution
# ------------------------------------------------------------------------------
{
    json_start
    echo "\"timestamp\": \"$TIMESTAMP\","
    echo "\"hostname\": \"$HOSTNAME\","
    
    # Original collection functions
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
    
    # New collection functions
    collect_log_metrics
    collect_patch_metrics
    
    echo "\"meta\": { \"version\": \"2.0\", \"collection_time\": \"$TIMESTAMP\" }"
    json_end
} > "$OUTPUT_FILE"

log_msg "Metrics collected and saved to $OUTPUT_FILE"

# Output the file content to stdout
cat "$OUTPUT_FILE"

# Send to Webhook (same as original)
# ------------------------------------------------------------------------------
if [[ -n "$WEBHOOK_URL" && -n "$N8N_JWT_SECRET" ]]; then
    if command -v python3 &> /dev/null; then
        PYTHON_CMD="python3"
    elif command -v python &> /dev/null; then
        PYTHON_CMD="python"
    else
        log_error "Python not found. Cannot generate JWT for webhook."
        PYTHON_CMD=""
    fi

    if [[ -n "$PYTHON_CMD" ]]; then
        # Validate JSON
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
            exit 1
        fi

        # Generate JWT and send
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
             log_msg "Sending metrics to webhook..."
             response_file=$(mktemp)
             response=$(curl -s -o "$response_file" -w "%{http_code}" -X POST "$WEBHOOK_URL" \
                -H "Content-Type: application/json" \
                -H "User-Agent: EDB-Monitor/2.0" \
                -H "Authorization: Bearer $JWT_TOKEN" \
                -d @"$OUTPUT_FILE")
             
             if [[ "$response" == "200" ]]; then
                 log_msg "Successfully sent metrics to webhook."
             else
                 response_body=$(cat "$response_file" 2>/dev/null | head -c 2000)
                 log_error "Failed to send metrics. HTTP Status: $response. Response: $response_body"
             fi
             rm -f "$response_file" 2>/dev/null || true
        else
             log_error "Failed to generate JWT token. Error: $JWT_OUTPUT"
        fi
    fi
fi

log_msg "Health check completed successfully"
