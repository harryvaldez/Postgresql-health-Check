#!/bin/bash

# ==============================================================================
# Comprehensive Test Suite for EDB Monitoring System
# ==============================================================================

set -e  # Exit on error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PASSED=0
FAILED=0

test_pass() {
    echo -e "${GREEN}✓${NC} $1"
    ((PASSED++))
}

test_fail() {
    echo -e "${RED}✗${NC} $1"
    ((FAILED++))
}

test_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

echo "=========================================="
echo "EDB Monitoring System Test Suite"
echo "=========================================="
echo ""

# Test 1: Script Execution
echo "Test 1: Script execution..."
if ./collect_metrics.sh > /tmp/test_output.json 2>&1; then
    test_pass "Script executed successfully"
else
    test_fail "Script execution failed"
    cat /tmp/test_output.json
    exit 1
fi

# Test 2: Output File Creation
echo "Test 2: Output file creation..."
if [ -f /tmp/edb_health_metrics.json ]; then
    test_pass "Output file created"
else
    test_fail "Output file not created"
    exit 1
fi

# Test 3: JSON Validity
echo "Test 3: JSON validity..."
if python3 -m json.tool /tmp/edb_health_metrics.json > /dev/null 2>&1; then
    test_pass "JSON is valid"
else
    test_fail "JSON is invalid"
    python3 -m json.tool /tmp/edb_health_metrics.json 2>&1 | head -20
    exit 1
fi

# Test 4: Required Fields
echo "Test 4: Required fields..."
python3 << 'PYEOF'
import json
import sys

with open('/tmp/edb_health_metrics.json') as f:
    data = json.load(f)

required = [
    'timestamp', 'hostname', 'system', 'database_status', 
    'performance', 'database', 'locks', 'vacuum', 'wal',
    'storage', 'replication', 'backup', 'bloat', 'configuration'
]

missing = [r for r in required if r not in data]
if missing:
    print(f"Missing fields: {missing}")
    sys.exit(1)
else:
    print("All required fields present")
PYEOF

if [ $? -eq 0 ]; then
    test_pass "All required fields present"
else
    test_fail "Missing required fields"
fi

# Test 5: Data Quality Checks
echo "Test 5: Data quality checks..."
python3 << 'PYEOF'
import json
import sys

with open('/tmp/edb_health_metrics.json') as f:
    data = json.load(f)

issues = []

# Check timestamp format
if 'timestamp' in data:
    if not isinstance(data['timestamp'], str) or 'T' not in data['timestamp']:
        issues.append("Timestamp format invalid")

# Check system metrics
if 'system' in data:
    sys_data = data['system']
    if 'load_avg' not in sys_data:
        issues.append("Missing load_avg in system metrics")
    if 'memory_mb' not in sys_data:
        issues.append("Missing memory_mb in system metrics")

# Check database status
if 'database_status' in data:
    db_status = data['database_status']
    if 'service_status' not in db_status:
        issues.append("Missing service_status")
    if 'connection_status' not in db_status:
        issues.append("Missing connection_status")

if issues:
    print("Data quality issues found:")
    for issue in issues:
        print(f"  - {issue}")
    sys.exit(1)
else:
    print("Data quality checks passed")
PYEOF

if [ $? -eq 0 ]; then
    test_pass "Data quality checks passed"
else
    test_fail "Data quality issues found"
fi

# Test 6: Webhook Transmission (if configured)
echo "Test 6: Webhook transmission..."
if [ -f .env ]; then
    source .env
    if [ -n "$WEBHOOK_URL" ] && [ -n "$N8N_JWT_SECRET" ]; then
        # Generate JWT
        JWT_TOKEN=$(python3 << PYEOF
import sys
import os
sys.path.append('$SCRIPT_DIR')
try:
    import jwt_helper
    payload = {
        'sub': 'test',
        'name': 'Health Check Service for EDB',
        'role': 'service',
        'server_name': 'test-server',
        'timestamp': '$(date -u +"%Y-%m-%dT%H:%M:%SZ")'
    }
    secret = os.environ.get('N8N_JWT_SECRET', '')
    print(jwt_helper.generate_jwt(payload, secret))
except Exception as e:
    sys.stderr.write(str(e))
    sys.exit(1)
PYEOF
)
        
        if [ $? -eq 0 ] && [ -n "$JWT_TOKEN" ]; then
            response=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$WEBHOOK_URL" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer $JWT_TOKEN" \
                -d @/tmp/edb_health_metrics.json 2>&1)
            
            if [ "$response" == "200" ]; then
                test_pass "Webhook transmission successful"
            else
                test_warn "Webhook transmission returned HTTP $response (may be expected if workflow not active)"
            fi
        else
            test_warn "Could not generate JWT token for webhook test"
        fi
    else
        test_warn "Webhook not configured, skipping transmission test"
    fi
else
    test_warn ".env file not found, skipping webhook test"
fi

# Test 7: Python Dependencies
echo "Test 7: Python dependencies..."
if python3 -c "import jwt; import cryptography" 2>/dev/null; then
    test_pass "Python dependencies available"
else
    test_fail "Python dependencies missing (pyjwt, cryptography)"
fi

# Test 8: Database Connectivity
echo "Test 8: Database connectivity..."
if [ -f .env ]; then
    source .env
    PGBIN="${PGBIN:-/usr/edb/as9.6/bin}"
    PSQL="$PGBIN/edb-psql"
    
    if [ ! -f "$PSQL" ]; then
        if command -v edb-psql &> /dev/null; then
            PSQL="edb-psql"
        elif command -v psql &> /dev/null; then
            PSQL="psql"
        fi
    fi
    
    if $PSQL -U "$PGUSER" -d "$PGDATABASE" -p "$PGPORT" -c "SELECT 1" >/dev/null 2>&1; then
        test_pass "Database connectivity successful"
    else
        test_warn "Database connectivity test failed (may be expected if DB is down)"
    fi
else
    test_warn ".env file not found, skipping database connectivity test"
fi

# Summary
echo ""
echo "=========================================="
echo "Test Summary"
echo "=========================================="
echo -e "${GREEN}Passed: $PASSED${NC}"
if [ $FAILED -gt 0 ]; then
    echo -e "${RED}Failed: $FAILED${NC}"
    exit 1
else
    echo -e "${GREEN}Failed: $FAILED${NC}"
    echo ""
    echo "All tests passed! ✓"
    exit 0
fi
