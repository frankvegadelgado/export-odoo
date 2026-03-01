#!/usr/bin/env bash
# =============================================================================
# Start Odoo 18 Community
# If already running, notifies and exits without doing anything.
# Usage: sudo ./start_odoo.sh
# =============================================================================

set -e

ODOO_USER="odoo"
ODOO_CONF="/etc/odoo.conf"

# -- Detect entry point --------------------------------------------------------
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

# -- Check if already running --------------------------------------------------
if pgrep -f "odoo -c $ODOO_CONF" > /dev/null 2>&1; then
    echo "Odoo is already running."
    exit 0
fi

# -- Start Odoo ----------------------------------------------------------------
echo "=== Starting Odoo ==="
sudo -u $ODOO_USER $ODOO_BIN -c $ODOO_CONF &
PID=$!
echo "Odoo started with PID $PID"
echo "Logs: /var/log/odoo/odoo.log"
echo "URL:  http://localhost:8069"