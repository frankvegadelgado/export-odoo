#!/usr/bin/env bash
# =============================================================================
# Stop Odoo 18 Community
# If not running, notifies and exits without doing anything.
# Usage: sudo ./stop_odoo.sh
# =============================================================================

set -e

ODOO_CONF="/etc/odoo.conf"

# -- Check if running ----------------------------------------------------------
if ! pgrep -f "odoo -c $ODOO_CONF" > /dev/null 2>&1; then
    echo "Odoo is not running."
    exit 0
fi

# -- Stop Odoo -----------------------------------------------------------------
echo "=== Stopping Odoo ==="
pkill -f "odoo -c $ODOO_CONF" || true

# Wait up to 10 seconds for clean shutdown
for i in $(seq 1 10); do
    if ! pgrep -f "odoo -c $ODOO_CONF" > /dev/null 2>&1; then
        echo "Odoo stopped."
        exit 0
    fi
    sleep 1
done

# Force kill if still running
echo "Odoo did not stop cleanly, forcing..."
pkill -9 -f "odoo -c $ODOO_CONF" || true
echo "Odoo force-stopped."