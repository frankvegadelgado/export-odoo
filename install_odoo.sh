#!/usr/bin/env bash
# Script de instalación automática de Odoo Community + PostgreSQL
# Probado en Debian/Ubuntu

set -e

# Directorio donde se encuentra este script
SCRIPT_DIR="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
echo "Directorio del script: $SCRIPT_DIR"

# Variables
ODOO_VERSION="18.0"
ODOO_USER="odoo"
ODOO_HOME="/opt/odoo"
ODOO_CONF="/etc/odoo.conf"
DB_NAME="odoo"
DB_USER="odoo"

echo "=== Verificando conectividad DNS ==="
if ! nslookup archive.ubuntu.com > /dev/null 2>&1; then
    echo "DNS no responde, aplicando fix (8.8.8.8)..."
    echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf > /dev/null
    echo "DNS corregido."
else
    echo "DNS OK."
fi

echo "=== Esperando que apt quede libre ==="
while sudo fuser /var/lib/dpkg/lock-frontend > /dev/null 2>&1; do
    echo "apt ocupado por otro proceso, esperando 5 segundos..."
    sleep 5
done

echo "=== Instalando dependencias básicas ==="
sudo apt install -y wget curl python3 python3-pip python3-venv build-essential \
                    libpq-dev postgresql nano \
                    libldap2-dev libsasl2-dev libssl-dev

echo "=== Configurando PostgreSQL ==="
if cd /tmp && sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1; then
    echo "Usuario PostgreSQL '$DB_USER' ya existe, omitiendo."
else
    cd /tmp && sudo -u postgres createuser -s $DB_USER
    echo "Usuario PostgreSQL '$DB_USER' creado."
fi

if cd /tmp && sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1; then
    echo "Base de datos '$DB_NAME' ya existe, omitiendo."
else
    cd /tmp && sudo -u postgres createdb $DB_NAME
    echo "Base de datos '$DB_NAME' creada."
fi

echo "=== Creando usuario y directorio para Odoo ==="
if id "$ODOO_USER" &>/dev/null; then
    echo "Usuario '$ODOO_USER' ya existe, omitiendo."
else
    sudo adduser --system --home=$ODOO_HOME --group $ODOO_USER
    echo "Usuario '$ODOO_USER' creado."
fi

echo "=== Descargando Odoo Community $ODOO_VERSION ==="
TARBALL="odoo_${ODOO_VERSION}.latest.tar.gz"
DOWNLOAD_URL="https://nightly.odoo.com/${ODOO_VERSION}/nightly/src/${TARBALL}"

if [ -f "$SCRIPT_DIR/$TARBALL" ]; then
    echo "Archivo $TARBALL ya existe en $SCRIPT_DIR, omitiendo descarga."
else
    echo "Archivo no encontrado en: $SCRIPT_DIR/$TARBALL"
    echo "Descargando desde: $DOWNLOAD_URL"
    wget --progress=bar:force:noscroll -O "$SCRIPT_DIR/$TARBALL" "$DOWNLOAD_URL"
fi

# Extraer en un directorio temporal, luego mover al destino final
TMP_DIR=$(mktemp -d)
tar -xzf "$SCRIPT_DIR/$TARBALL" -C "$TMP_DIR"

# El tarball extrae a una subcarpeta (ej: odoo-18.0.YYYYMMDD); movemos su contenido a ODOO_HOME
EXTRACTED_DIR="$TMP_DIR/$(ls "$TMP_DIR")"
sudo rm -rf "$ODOO_HOME"
sudo mkdir -p "$ODOO_HOME"
sudo mv "$EXTRACTED_DIR"/* "$ODOO_HOME"/
sudo chown -R $ODOO_USER:$ODOO_USER "$ODOO_HOME"

# Verificar que odoo-bin quedó en el lugar correcto
if [ ! -f "$ODOO_HOME/odoo-bin" ]; then
    echo "ADVERTENCIA: odoo-bin no está en $ODOO_HOME, buscando..."
    FOUND=$(find "$ODOO_HOME" -name "odoo-bin" 2>/dev/null | head -1)
    echo "odoo-bin encontrado en: $FOUND"
else
    echo "odoo-bin correctamente ubicado en: $ODOO_HOME/odoo-bin"
fi

echo "=== Instalando Python 3.11 ==="
sudo apt install -y python3.11 python3.11-venv python3.11-dev

echo "=== Creando entorno virtual Python e instalando dependencias ==="
sudo python3.11 -m venv $ODOO_HOME/venv
sudo $ODOO_HOME/venv/bin/pip install --upgrade pip setuptools wheel

# cbor2==5.4.2 usa pkg_resources que fue eliminado en setuptools moderno
# Se reemplaza por una version compatible con el build system actual
sudo sed -i 's/cbor2==5\.4\.2/cbor2>=5.4.6/' $ODOO_HOME/requirements.txt
echo "Parche aplicado: cbor2==5.4.2 -> cbor2>=5.4.6"

sudo $ODOO_HOME/venv/bin/pip install -r $ODOO_HOME/requirements.txt
# Registrar Odoo como paquete editable para poder usar: python -m odoo
# Debe correr como root ya que el venv fue creado con sudo
cd $ODOO_HOME && sudo $ODOO_HOME/venv/bin/pip install -e . --no-deps -q
sudo chown -R $ODOO_USER:$ODOO_USER $ODOO_HOME/venv

echo "=== Configurando archivo de Odoo ==="
sudo tee $ODOO_CONF > /dev/null <<EOF
[options]
addons_path = $ODOO_HOME/addons
db_host = False
db_port = False
db_user = $DB_USER
db_password = False
logfile = /var/log/odoo/odoo.log
EOF

echo "=== Creando directorio de logs ==="
sudo mkdir -p /var/log/odoo
sudo chown $ODOO_USER:$ODOO_USER /var/log/odoo

echo "=== Instalación completada ==="
echo "Para iniciar Odoo:"
if [ -f "$ODOO_HOME/odoo-bin" ]; then
    echo "  sudo -u $ODOO_USER $ODOO_HOME/venv/bin/python $ODOO_HOME/odoo-bin -c $ODOO_CONF"
elif [ -f "$ODOO_HOME/venv/bin/odoo" ]; then
    echo "  sudo -u $ODOO_USER $ODOO_HOME/venv/bin/odoo -c $ODOO_CONF"
else
    echo "  cd $ODOO_HOME && sudo -u $ODOO_USER $ODOO_HOME/venv/bin/python -m odoo -c $ODOO_CONF"
fi
echo "Luego abre en navegador: http://localhost:8069"