#!/usr/bin/env bash
# =============================================================================
# Automatic Odoo 18 Community + PostgreSQL installer
# Tested on Ubuntu 22.04 / Debian
# Usage: sudo ./install_odoo.sh
# =============================================================================

set -e

# -- Resolve the directory where this script lives ----------------------------
SCRIPT_DIR="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
echo "Script directory: $SCRIPT_DIR"

# -- Configuration variables ---------------------------------------------------
ODOO_VERSION="18.0"
ODOO_USER="odoo"
ODOO_HOME="/opt/odoo"
ODOO_CONF="/etc/odoo.conf"
DB_NAME="odoo"
DB_USER="odoo"

# -- Fix DNS if broken ---------------------------------------------------------
echo "=== Checking DNS connectivity ==="
if ! nslookup archive.ubuntu.com > /dev/null 2>&1; then
    echo "DNS not responding. Applying fix (nameserver 8.8.8.8)..."
    echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf > /dev/null
    echo "DNS fixed."
else
    echo "DNS OK."
fi

# -- Wait for apt lock to be released (unattended-upgrades may be running) -----
echo "=== Waiting for apt to be free ==="
while sudo fuser /var/lib/dpkg/lock-frontend > /dev/null 2>&1; do
    echo "apt is locked by another process, waiting 5 seconds..."
    sleep 5
done

# -- Install system dependencies -----------------------------------------------
echo "=== Installing system dependencies ==="
sudo apt install -y wget curl python3 python3-pip python3-venv build-essential \
                    libpq-dev postgresql nano \
                    libldap2-dev libsasl2-dev libssl-dev

# -- Configure PostgreSQL ------------------------------------------------------
echo "=== Configuring PostgreSQL ==="
if cd /tmp && sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1; then
    echo "PostgreSQL user '$DB_USER' already exists, skipping."
else
    cd /tmp && sudo -u postgres createuser -s $DB_USER
    echo "PostgreSQL user '$DB_USER' created."
fi

if cd /tmp && sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1; then
    echo "Database '$DB_NAME' already exists, skipping."
else
    cd /tmp && sudo -u postgres createdb $DB_NAME
    echo "Database '$DB_NAME' created."
fi

# -- Create Odoo system user ---------------------------------------------------
echo "=== Creating Odoo system user ==="
if id "$ODOO_USER" &>/dev/null; then
    echo "User '$ODOO_USER' already exists, skipping."
else
    sudo adduser --system --home=$ODOO_HOME --group $ODOO_USER
    echo "User '$ODOO_USER' created."
fi

# -- Download Odoo Community tarball ------------------------------------------
echo "=== Downloading Odoo Community $ODOO_VERSION ==="
TARBALL="odoo_${ODOO_VERSION}.latest.tar.gz"
DOWNLOAD_URL="https://nightly.odoo.com/${ODOO_VERSION}/nightly/src/${TARBALL}"

if [ -f "$SCRIPT_DIR/$TARBALL" ]; then
    echo "File $TARBALL already exists in $SCRIPT_DIR, skipping download."
else
    echo "File not found at: $SCRIPT_DIR/$TARBALL"
    echo "Downloading from: $DOWNLOAD_URL"
    wget --progress=bar:force:noscroll -O "$SCRIPT_DIR/$TARBALL" "$DOWNLOAD_URL"
fi

# -- Extract tarball into ODOO_HOME --------------------------------------------
# The tarball extracts into a versioned subfolder (e.g. odoo-18.0.20250227)
# We move its contents directly into ODOO_HOME so odoo-bin / setup.py sit at root
echo "=== Extracting Odoo ==="
TMP_DIR=$(mktemp -d)
tar -xzf "$SCRIPT_DIR/$TARBALL" -C "$TMP_DIR"

EXTRACTED_DIR="$TMP_DIR/$(ls "$TMP_DIR")"
sudo rm -rf "$ODOO_HOME"
sudo mkdir -p "$ODOO_HOME"
sudo mv "$EXTRACTED_DIR"/* "$ODOO_HOME"/
sudo chown -R $ODOO_USER:$ODOO_USER "$ODOO_HOME"

# Verify the layout
if [ -f "$ODOO_HOME/odoo-bin" ]; then
    echo "odoo-bin found at: $ODOO_HOME/odoo-bin"
elif [ -f "$ODOO_HOME/setup.py" ]; then
    echo "setup.py found — Odoo will be launched via: python -m odoo"
else
    echo "WARNING: Neither odoo-bin nor setup.py found in $ODOO_HOME"
    echo "Contents: $(ls $ODOO_HOME)"
fi

# -- Install Python 3.11 -------------------------------------------------------
# Odoo 18 requires Python 3.11+. Ubuntu 22.04 ships with 3.10 by default.
echo "=== Installing Python 3.11 ==="
sudo apt install -y python3.11 python3.11-venv python3.11-dev

# -- Create virtualenv and install Python dependencies ------------------------
echo "=== Creating Python virtual environment ==="
sudo python3.11 -m venv $ODOO_HOME/venv
sudo $ODOO_HOME/venv/bin/pip install --upgrade pip setuptools wheel

# cbor2==5.4.2 uses pkg_resources which was removed from modern setuptools.
# Patch it to a newer version that uses pyproject.toml instead.
sudo sed -i 's/cbor2==5\.4\.2/cbor2>=5.4.6/' $ODOO_HOME/requirements.txt
echo "Patched: cbor2==5.4.2 -> cbor2>=5.4.6"

echo "=== Installing Python requirements ==="
sudo $ODOO_HOME/venv/bin/pip install -r $ODOO_HOME/requirements.txt

# Register Odoo as an editable package so it can be launched via: python -m odoo
# Must run as root because the venv was created with sudo
echo "=== Registering Odoo as editable package ==="
cd $ODOO_HOME && sudo $ODOO_HOME/venv/bin/pip install -e . --no-deps -q

# Hand ownership of the venv back to the odoo user
sudo chown -R $ODOO_USER:$ODOO_USER $ODOO_HOME/venv

# -- Write Odoo configuration file ---------------------------------------------
echo "=== Writing Odoo configuration file ==="
sudo tee $ODOO_CONF > /dev/null <<EOF
[options]
addons_path = $ODOO_HOME/addons
db_host = False
db_port = False
db_user = $DB_USER
db_password = False
logfile = /var/log/odoo/odoo.log
EOF

# -- Create log directory ------------------------------------------------------
echo "=== Creating log directory ==="
sudo mkdir -p /var/log/odoo
sudo chown $ODOO_USER:$ODOO_USER /var/log/odoo

# -- Done ----------------------------------------------------------------------
echo ""
echo "=== Installation complete ==="
echo "To start Odoo:"
if [ -f "$ODOO_HOME/odoo-bin" ]; then
    echo "  sudo -u $ODOO_USER $ODOO_HOME/venv/bin/python $ODOO_HOME/odoo-bin -c $ODOO_CONF"
elif [ -f "$ODOO_HOME/venv/bin/odoo" ]; then
    echo "  sudo -u $ODOO_USER $ODOO_HOME/venv/bin/odoo -c $ODOO_CONF"
else
    echo "  cd $ODOO_HOME && sudo -u $ODOO_USER $ODOO_HOME/venv/bin/python -m odoo -c $ODOO_CONF"
fi
echo "Then open in browser: http://localhost:8069"