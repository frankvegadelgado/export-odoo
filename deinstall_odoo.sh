#!/usr/bin/env bash
# =============================================================================
# Odoo 18 Community — complete uninstall script
# Removes everything installed by install_odoo.sh EXCEPT the tarball
# (odoo_18.0.latest.tar.gz or any versioned .tar.gz in the script directory)
# Usage: sudo ./deinstall_odoo.sh
# =============================================================================

set -e

ODOO_VERSION="18.0"
ODOO_USER="odoo"
ODOO_HOME="/opt/odoo"
ODOO_CONF="/etc/odoo.conf"
DB_NAME="odoo"
DB_USER="odoo"
LOG_DIR="/var/log/odoo"

echo ""
echo "=== Odoo 18 Uninstaller ==="
echo "This will remove Odoo, its configuration, database, and system user."
echo "The tarball (odoo_${ODOO_VERSION}.latest.tar.gz) will NOT be removed."
echo ""

# -- Stop any running Odoo process ---------------------------------------------
echo "=== Stopping Odoo if running ==="
if pgrep -f "odoo -c $ODOO_CONF" > /dev/null 2>&1; then
    sudo pkill -f "odoo -c $ODOO_CONF" || true
    sleep 3
    echo "Odoo stopped."
else
    echo "Odoo was not running."
fi

# -- Remove pip-installed Odoo entry point and package -------------------------
echo "=== Removing Odoo Python package ==="
sudo python3.11 -m pip uninstall odoo -y --root-user-action=ignore 2>/dev/null || echo "Odoo pip package not found, skipping."

# -- Remove Odoo home directory (source + addons) ------------------------------
echo "=== Removing $ODOO_HOME ==="
if [ -d "$ODOO_HOME" ]; then
    sudo rm -rf "$ODOO_HOME"
    echo "$ODOO_HOME removed."
else
    echo "$ODOO_HOME not found, skipping."
fi

# -- Remove configuration file -------------------------------------------------
echo "=== Removing $ODOO_CONF ==="
if [ -f "$ODOO_CONF" ]; then
    sudo rm -f "$ODOO_CONF"
    echo "$ODOO_CONF removed."
else
    echo "$ODOO_CONF not found, skipping."
fi

# -- Remove log directory ------------------------------------------------------
echo "=== Removing $LOG_DIR ==="
if [ -d "$LOG_DIR" ]; then
    sudo rm -rf "$LOG_DIR"
    echo "$LOG_DIR removed."
else
    echo "$LOG_DIR not found, skipping."
fi

# -- Drop PostgreSQL database and user -----------------------------------------
echo "=== Dropping PostgreSQL database '$DB_NAME' ==="
if cd /tmp && sudo -u $DB_USER psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" 2>/dev/null | grep -q 1; then
    cd /tmp && sudo -u $DB_USER dropdb $DB_NAME
    echo "Database '$DB_NAME' dropped."
else
    echo "Database '$DB_NAME' not found, skipping."
fi

echo "=== Dropping PostgreSQL user '$DB_USER' ==="
if cd /tmp && sudo -u $DB_USER psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" 2>/dev/null | grep -q 1; then
    cd /tmp && sudo -u postgres dropuser $DB_USER
    echo "PostgreSQL user '$DB_USER' dropped."
else
    echo "PostgreSQL user '$DB_USER' not found, skipping."
fi

# -- Remove Odoo system user ----------------------------------------------------
echo "=== Removing system user '$ODOO_USER' ==="
if id "$ODOO_USER" &>/dev/null; then
    sudo deluser --remove-home $ODOO_USER 2>/dev/null || sudo userdel -r $ODOO_USER 2>/dev/null || true
    echo "System user '$ODOO_USER' removed."
else
    echo "System user '$ODOO_USER' not found, skipping."
fi

# -- Remove Odoo entry point binary --------------------------------------------
echo "=== Removing Odoo entry point binary ==="
for candidate in /usr/local/bin/odoo /usr/bin/odoo; do
    if [ -f "$candidate" ]; then
        sudo rm -f "$candidate"
        echo "$candidate removed."
    fi
done

# -- Done ----------------------------------------------------------------------
echo ""
echo "=== Uninstall complete ==="
echo "The tarball odoo_${ODOO_VERSION}.latest.tar.gz has been preserved."
echo "PostgreSQL and system packages (libpq-dev, etc.) were NOT removed."
echo "Run install_odoo.sh to reinstall."