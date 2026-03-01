#!/usr/bin/env bash
# =============================================================================
# Export Odoo 18 CRM to CSV via XML-RPC API
# Starts Odoo automatically if not running, then runs export_crm_api.py.
# If Odoo was started by this script it will be stopped afterwards.
# Usage: sudo ./export_crm_api.sh [output_file.csv]
# =============================================================================

set -e

ODOO_USER="odoo"
ODOO_CONF="/etc/odoo.conf"
ODOO_URL="http://localhost:8069"
SCRIPT_DIR="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
OUTPUT="${1:-}"

# -- Detect Odoo entry point ---------------------------------------------------
ODOO_BIN=""
for candidate in /usr/local/bin/odoo /usr/bin/odoo; do
    if [ -f "$candidate" ]; then
        ODOO_BIN="$candidate"
        break
    fi
done

if [ -z "$ODOO_BIN" ]; then
    echo "ERROR: Odoo entry point not found. Run install_odoo.sh first."
    exit 1
fi

# -- Ensure log directory exists with correct ownership -----------------------
mkdir -p /var/log/odoo && chown $ODOO_USER:$ODOO_USER /var/log/odoo

# -- Start Odoo if not running -------------------------------------------------
ODOO_STARTED_BY_US=false
ODOO_PID=""

if curl -s --max-time 3 "$ODOO_URL" > /dev/null 2>&1; then
    echo "Odoo is already running at $ODOO_URL"
else
    echo "=== Starting Odoo ==="
    sudo -u $ODOO_USER $ODOO_BIN -c $ODOO_CONF \
        --without-demo=all \
        > /var/log/odoo/odoo-export.log 2>&1 &
    ODOO_PID=$!
    ODOO_STARTED_BY_US=true
    echo "Odoo started with PID $ODOO_PID"

    echo "Waiting for Odoo to be ready (max 3 min)..."
    WAITED=0
    MAX_WAIT=180
    until curl -s --max-time 5 \
        -H "Content-Type: text/xml" \
        --data '<?xml version="1.0"?><methodCall><methodName>version</methodName><params></params></methodCall>' \
        "$ODOO_URL/xmlrpc/2/common" 2>/dev/null | grep -q "server_version"; do

        if ! ps -p $ODOO_PID > /dev/null 2>&1; then
            echo ""
            echo "ERROR: Odoo process exited before becoming ready."
            echo "Last 30 lines of log:"
            tail -30 /var/log/odoo/odoo-export.log 2>/dev/null || true
            exit 1
        fi

        if [ $WAITED -ge $MAX_WAIT ]; then
            echo ""
            echo "ERROR: Odoo did not respond after ${MAX_WAIT}s."
            echo "Last 30 lines of log:"
            tail -30 /var/log/odoo/odoo-export.log 2>/dev/null || true
            exit 1
        fi

        printf "  Waiting... ${WAITED}s\r"
        sleep 5
        WAITED=$((WAITED + 5))
    done
    echo "Odoo ready after ${WAITED}s."
fi

echo ""

# -- Run Python export ---------------------------------------------------------
if [ -n "$OUTPUT" ]; then
    python3.11 "$SCRIPT_DIR/export_crm_api.py" "$OUTPUT"
else
    python3.11 "$SCRIPT_DIR/export_crm_api.py"
fi

# -- Stop Odoo if we started it ------------------------------------------------
if [ "$ODOO_STARTED_BY_US" = true ]; then
    echo "=== Stopping Odoo (started by this script) ==="
    pkill -f "odoo -c $ODOO_CONF" || true
    sleep 2
    echo "Odoo stopped."
fi