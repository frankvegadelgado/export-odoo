#!/usr/bin/env bash
# =============================================================================
# Start Odoo 18 Community
# If already running, notifies and exits without doing anything.
# Usage: sudo ./start_odoo.sh
# =============================================================================

set -e

ODOO_USER="odoo"
ODOO_CONF="/etc/odoo.conf"
ODOO_URL="http://localhost:8069"

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
if curl -s --max-time 3 "$ODOO_URL" > /dev/null 2>&1; then
    echo "Odoo is already running at $ODOO_URL"
    exit 0
fi

# -- Ensure log directory exists with correct ownership -----------------------
mkdir -p /var/log/odoo && chown $ODOO_USER:$ODOO_USER /var/log/odoo

# -- Start Odoo ----------------------------------------------------------------
echo "=== Starting Odoo ==="
sudo -u $ODOO_USER $ODOO_BIN -c $ODOO_CONF \
    --without-demo=all \
    > /var/log/odoo/odoo.log 2>&1 &
PID=$!
echo "Odoo started with PID $PID"
echo "Logs: /var/log/odoo/odoo.log"
echo "URL:  $ODOO_URL"