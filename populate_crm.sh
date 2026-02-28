#!/usr/bin/env bash
# =============================================================================
# Populate Odoo 18 CRM with ~1500 realistic leads/opportunities via XML-RPC
# Usage: sudo ./populate_crm.sh
# =============================================================================

set -e

# -- Connection settings -------------------------------------------------------
ODOO_URL="http://localhost:8069"
ODOO_DB="odoo"
ODOO_USER="admin"
ODOO_PASS="admin"
ODOO_HOME="/opt/odoo"
ODOO_CONF="/etc/odoo.conf"
ODOO_SYSTEM_USER="odoo"

# -- Detect how to launch Odoo -------------------------------------------------
# venv/bin/odoo exists but may fail if 'import odoo' doesn't work.
# Always verify the module is importable before choosing a launch method.
ODOO_LAUNCH_CMD=""

if [ -f "$ODOO_HOME/odoo-bin" ]; then
    # Classic standalone binary
    ODOO_LAUNCH_CMD="$ODOO_HOME/venv/bin/python $ODOO_HOME/odoo-bin"
    echo "Launch method: standalone odoo-bin"

elif [ -f "$ODOO_HOME/venv/bin/odoo" ] && \
     $ODOO_HOME/venv/bin/python -c "import odoo" 2>/dev/null; then
    # Entry point script + odoo module is importable
    ODOO_LAUNCH_CMD="$ODOO_HOME/venv/bin/odoo"
    echo "Launch method: venv/bin/odoo (package entry point)"

elif [ -d "$ODOO_HOME/odoo" ] && [ -f "$ODOO_HOME/setup.py" ]; then
    # setup.py based install — use python -m odoo directly
    echo "venv/bin/odoo entry point not usable, falling back to: python -m odoo"

    # Re-run pip install -e . as root to ensure the package is registered
    if ! $ODOO_HOME/venv/bin/python -c "import odoo" 2>/dev/null; then
        echo "Registering Odoo package (pip install -e .)..."
        cd "$ODOO_HOME" && sudo $ODOO_HOME/venv/bin/pip install -e . --no-deps -q
        sudo chown -R $ODOO_SYSTEM_USER:$ODOO_SYSTEM_USER $ODOO_HOME/venv
        cd - > /dev/null
    fi

    # Final check
    if ! $ODOO_HOME/venv/bin/python -c "import odoo" 2>/dev/null; then
        echo "ERROR: 'import odoo' still fails after pip install -e ."
        echo "Try manually: cd /opt/odoo && sudo /opt/odoo/venv/bin/pip install -e . --no-deps"
        exit 1
    fi

    ODOO_LAUNCH_CMD="$ODOO_HOME/venv/bin/python -m odoo"
    echo "Launch method: python -m odoo"

else
    echo "ERROR: Could not find a way to launch Odoo in $ODOO_HOME"
    echo "Contents of $ODOO_HOME:"
    ls -la "$ODOO_HOME"
    exit 1
fi

# -- Start Odoo if not already running ----------------------------------------
ODOO_PID=""
ODOO_STARTED_BY_US=false

echo ""
echo "=== Checking if Odoo is running ==="

if curl -s --max-time 3 "$ODOO_URL" > /dev/null 2>&1; then
    echo "Odoo is already running at $ODOO_URL"
else
    echo "Odoo is not running. Starting it..."

    sudo -u $ODOO_SYSTEM_USER $ODOO_LAUNCH_CMD -c $ODOO_CONF \
        --without-demo=all \
        > /var/log/odoo/odoo-populate.log 2>&1 &

    ODOO_PID=$!
    ODOO_STARTED_BY_US=true
    echo "Odoo started with PID $ODOO_PID"

    # Step 1: wait for HTTP port to open
    echo "Waiting for HTTP port to open (max 3 min)..."
    WAITED=0
    MAX_WAIT=180
    until curl -s --max-time 3 "$ODOO_URL" > /dev/null 2>&1; do
        if [ $WAITED -ge $MAX_WAIT ]; then
            echo "ERROR: Odoo HTTP did not respond after ${MAX_WAIT}s."
            echo "Check the log: /var/log/odoo/odoo-populate.log"
            kill $ODOO_PID 2>/dev/null || true
            exit 1
        fi
        printf "  Waiting for HTTP... ${WAITED}s\r"
        sleep 5
        WAITED=$((WAITED + 5))
    done
    echo "HTTP port open after ${WAITED}s.          "
fi

# Step 2: wait until XML-RPC is actually ready.
# Odoo can respond to HTTP requests before the database workers are fully
# initialized, causing a 500 error on XML-RPC. We poll /xmlrpc/2/common
# until it returns a valid version response.
echo "Waiting for XML-RPC to be ready (max 3 min)..."
WAITED=0
MAX_WAIT=180
until curl -s --max-time 5 \
    -H "Content-Type: text/xml" \
    --data '<?xml version="1.0"?><methodCall><methodName>version</methodName><params></params></methodCall>' \
    "$ODOO_URL/xmlrpc/2/common" 2>/dev/null | grep -q "server_version"; do
    if [ $WAITED -ge $MAX_WAIT ]; then
        echo "ERROR: XML-RPC did not become ready after ${MAX_WAIT}s."
        echo "Check the log: /var/log/odoo/odoo-populate.log"
        [ "$ODOO_STARTED_BY_US" = true ] && kill $ODOO_PID 2>/dev/null || true
        exit 1
    fi
    printf "  XML-RPC not ready yet... ${WAITED}s\r"
    sleep 5
    WAITED=$((WAITED + 5))
done
echo "XML-RPC ready after ${WAITED}s.          "
echo ""

# -- Find Python interpreter ---------------------------------------------------
PYTHON=""
for py in "$ODOO_HOME/venv/bin/python" python3.11 python3 python; do
    if [ -f "$py" ] || command -v "$py" &>/dev/null; then
        PYTHON="$py"
        break
    fi
done

if [ -z "$PYTHON" ]; then
    echo "ERROR: Python interpreter not found."
    exit 1
fi

echo "Using interpreter: $PYTHON"
echo "Connecting to: $ODOO_URL  DB: $ODOO_DB  User: $ODOO_USER"
echo ""

# -- Embedded Python data insertion script ------------------------------------
$PYTHON - <<'PYEOF'
import xmlrpc.client
import random
import sys
from datetime import datetime, timedelta

# -- Connection ----------------------------------------------------------------
URL      = "http://localhost:8069"
DB       = "odoo"
USERNAME = "admin"
PASSWORD = "admin"

# -- Authenticate --------------------------------------------------------------
print("=== Authenticating with Odoo ===")
try:
    common = xmlrpc.client.ServerProxy(f"{URL}/xmlrpc/2/common", allow_none=True)
    uid = common.authenticate(DB, USERNAME, PASSWORD, {})
    if not uid:
        print("ERROR: Authentication failed. Check username/password in the script.")
        sys.exit(1)
    print(f"Authenticated as UID: {uid}")
except Exception as e:
    print(f"ERROR: Could not connect to Odoo XML-RPC: {e}")
    sys.exit(1)

models = xmlrpc.client.ServerProxy(f"{URL}/xmlrpc/2/object", allow_none=True)

# -- Sample data ---------------------------------------------------------------
FIRST_NAMES = [
    "Carlos","María","Juan","Ana","Luis","Laura","Pedro","Sofía","Miguel","Elena",
    "Fernando","Isabel","Alejandro","Patricia","Roberto","Carmen","Diego","Lucía",
    "Andrés","Valentina","Javier","Natalia","Ricardo","Claudia","Sergio","Mónica",
    "Eduardo","Daniela","Pablo","Gabriela","Héctor","Adriana","Jorge","Paola",
    "Raúl","Verónica","Arturo","Susana","Marco","Lorena","Víctor","Rebeca",
    "Antonio","Mariana","Guillermo","Karla","Emmanuel","Ximena","Rodrigo","Camila"
]

LAST_NAMES = [
    "García","Rodríguez","Martínez","López","Sánchez","Pérez","González","Ramírez",
    "Torres","Flores","Rivera","Moreno","Jiménez","Herrera","Díaz","Vargas",
    "Castro","Romero","Guerrero","Ortiz","Delgado","Navarro","Mendoza","Reyes",
    "Cruz","Vega","Ríos","Cabrera","Ruiz","Núñez","Suárez","Medina",
    "Aguilar","Ramos","Blanco","Molina","Castillo","Morales","Soto","Lara",
    "Espinoza","Silva","Gutiérrez","Ponce","Fuentes","Ibarra","Campos","Peña"
]

COMPANIES = [
    "TechSolutions Inc","Innovatech Ltda.","Global Ventures","DataSync Corp",
    "CloudBase Inc","NexGen Systems","ProSoft México","AlphaDigital","BetaWorks",
    "Grupo Empresarial Norte","Constructora del Pacífico","Distribuidora Central",
    "Logística Express","Manufactura Avanzada","Servicios Integrales SA",
    "Consulting Partners","FinServ Group","MedTech Soluciones","EduPlataforma",
    "RetailMáx","Agro Exportadora","Importadora del Sur","Transporte Rápido",
    "Seguros Confianza","Inmobiliaria Horizonte","Farmacéutica Nacional",
    "AutoPartes Premium","Energía Renovable SA","Telecomunicaciones Unidas",
    "Alimentos del Valle","Textiles Modernos","Plásticos Industriales",
    "Química Industrial","Electrónica Avanzada","Software Factory",
    "Marketing Digital Pro","Publicidad Creativa","Diseño & Branding Co",
    "Consultora Estratégica","Inversiones del Golfo","Capital Partners MX",
    "Bienes Raíces Élite","Turismo y Hospitalidad","Eventos Corporativos SA",
    "Recursos Humanos Plus","Outsourcing Total","Seguridad Integral",
    "Limpieza Profesional","Catering Ejecutivo","Papelería y Suministros"
]

CITIES = [
    "Ciudad de México","Guadalajara","Monterrey","Puebla","Tijuana",
    "León","Juárez","Zapopan","Mérida","San Luis Potosí",
    "Aguascalientes","Hermosillo","Mexicali","Culiacán","Acapulco",
    "Querétaro","Morelia","Chihuahua","Veracruz","Saltillo",
    "Toluca","Cancún","Torreón","Oaxaca","Tampico",
    "Bogotá","Lima","Buenos Aires","Santiago","Caracas",
    "Madrid","Barcelona","Miami","Los Ángeles","Nueva York"
]

PIPELINE_STAGES = ["New", "Qualified", "Proposition", "Won"]

DESCRIPTIONS = [
    "Cliente interesado en implementar una solución ERP completa para su empresa.",
    "Requiere consultoría para optimizar procesos de ventas y distribución.",
    "Busca integración con sistemas existentes y capacitación al equipo.",
    "Interesado en módulo de inventario y facturación electrónica.",
    "Empresa en crecimiento que necesita automatizar su contabilidad.",
    "Solicita demostración del sistema para presentar a directivos.",
    "Requiere migración desde sistema legado a plataforma moderna.",
    "Interesado en solución en la nube con acceso móvil para su fuerza de ventas.",
    "Busca soporte técnico y mantenimiento para el sistema actual.",
    "Empresa multinacional que requiere consolidación de datos entre sucursales.",
    "Startup tecnológica buscando herramientas de gestión escalables.",
    "Sector minorista con necesidades específicas de punto de venta.",
    "Empresa manufacturera interesada en módulo de producción y MRP.",
    "Firma de servicios profesionales que necesita gestión de proyectos.",
    "Distribuidora que busca optimizar su cadena de suministro.",
]

TAGS = [
    "VIP","Alta Prioridad","En Negociación","Seguimiento","Demostración Solicitada",
    "Presupuesto Aprobado","Tomador de Decisiones","Referido","Reactivación","Corporativo"
]

STREET_SUFFIXES = ["Calle Principal","Av. Reforma","Blvd. del Valle","Calzada Independencia",
                   "Paseo de la Constitución","Av. Revolución","Calle Álvaro Obregón",
                   "Callejón Ángel García","Av. Lázaro Cárdenas","Calle Héroe de Nacozari"]

# -- Setup pipeline stages -----------------------------------------------------
print("\n=== Setting up CRM pipeline stages ===")
stage_ids = []
for stage_name in PIPELINE_STAGES:
    existing = models.execute_kw(DB, uid, PASSWORD, 'crm.stage', 'search',
        [[['name', '=', stage_name]]])
    if existing:
        stage_ids.append(existing[0])
        print(f"  Existing stage: {stage_name} (ID {existing[0]})")
    else:
        sid = models.execute_kw(DB, uid, PASSWORD, 'crm.stage', 'create',
            [{'name': stage_name, 'sequence': PIPELINE_STAGES.index(stage_name) * 10}])
        stage_ids.append(sid)
        print(f"  Created stage: {stage_name} (ID {sid})")

# -- Setup tags ----------------------------------------------------------------
print("\n=== Setting up tags ===")
tag_ids = []
for tag_name in TAGS:
    existing = models.execute_kw(DB, uid, PASSWORD, 'crm.tag', 'search',
        [[['name', '=', tag_name]]])
    if existing:
        tag_ids.append(existing[0])
    else:
        tid = models.execute_kw(DB, uid, PASSWORD, 'crm.tag', 'create',
            [{'name': tag_name}])
        tag_ids.append(tid)
print(f"  {len(tag_ids)} tags ready.")

# -- Get internal users as salespeople ----------------------------------------
print("\n=== Loading system users ===")
user_ids = models.execute_kw(DB, uid, PASSWORD, 'res.users', 'search',
    [[['share', '=', False], ['active', '=', True]]])
if not user_ids:
    user_ids = [uid]
print(f"  {len(user_ids)} user(s) available as salespeople.")

# -- Get sales teams -----------------------------------------------------------
team_ids = models.execute_kw(DB, uid, PASSWORD, 'crm.team', 'search', [[]])
if not team_ids:
    team_ids = [False]

# -- Bulk insert ---------------------------------------------------------------
TOTAL    = 1500
BATCH    = 50     # Batch size — keeps server load manageable
inserted = 0
errors   = 0

print(f"\n=== Inserting {TOTAL} records into CRM (batches of {BATCH}) ===\n")

def random_phone():
    prefix = random.choice(["+1 305","+1 212","+1 310","+52 55","+52 81","+34 91"])
    number = "".join([str(random.randint(0,9)) for _ in range(8)])
    return f"{prefix} {number[:4]}-{number[4:]}"

def random_email(first, last, company):
    domain = ''.join(c for c in company.lower() if c.isalnum())[:12]
    ext = random.choice(["com","net","org","io","co"])
    return f"{first.lower()}.{last.lower()[:6]}@{domain}.{ext}"

for batch_start in range(0, TOTAL, BATCH):
    batch_records = []
    batch_size = min(BATCH, TOTAL - batch_start)

    for _ in range(batch_size):
        first   = random.choice(FIRST_NAMES)
        last    = random.choice(LAST_NAMES)
        company = random.choice(COMPANIES)
        city    = random.choice(CITIES)
        stage   = random.choice(stage_ids)
        prob    = random.randint(5, 95)

        # Won: 30% chance if in Won stage | Lost: 10% chance, archived
        won  = (stage == stage_ids[-1] and random.random() < 0.3)
        lost = (not won and random.random() < 0.1)

        record = {
            'name'            : f"Opportunity - {company} / {last}, {first}",
            'contact_name'    : f"{first} {last}",
            'partner_name'    : company,
            'email_from'      : random_email(first, last, company),
            'phone'           : random_phone(),
            'mobile'          : random_phone(),
            'city'            : city,
            'street'          : f"{random.choice(STREET_SUFFIXES)} #{random.randint(1,999)}, Int. {random.randint(1,50)}",
            'zip'             : str(random.randint(10000, 99999)),
            'stage_id'        : stage,
            'probability'     : 100.0 if won else (0.0 if lost else float(prob)),
            'expected_revenue': round(random.uniform(5000, 500000), 2),
            'priority'        : random.choice(['0','1','2','3']),
            'user_id'         : random.choice(user_ids),
            'team_id'         : random.choice(team_ids) if team_ids[0] else False,
            'description'     : random.choice(DESCRIPTIONS),
            'tag_ids'         : [(6, 0, random.sample(tag_ids, random.randint(1, 3)))],
            'date_deadline'   : (datetime.now() + timedelta(days=random.randint(1,180))).strftime('%Y-%m-%d'),
        }

        if won:
            record['active'] = True
            record['probability'] = 100.0
        elif lost:
            record['active'] = False  # Archived — hidden from default list view

        batch_records.append(record)

    # Insert batch
    try:
        new_ids = models.execute_kw(DB, uid, PASSWORD, 'crm.lead', 'create', [batch_records])
        count = len(new_ids) if isinstance(new_ids, list) else 1
        inserted += count
        pct = (inserted / TOTAL) * 100
        bar = '¦' * int(pct / 5) + '¦' * (20 - int(pct / 5))
        print(f"  [{bar}] {pct:5.1f}%  —  {inserted}/{TOTAL} records inserted", end='\r')
    except Exception as e:
        errors += batch_size
        print(f"\n  WARNING batch {batch_start}-{batch_start+batch_size}: {e}")

# -- Final summary -------------------------------------------------------------
print(f"\n\n=== Results ===")
print(f"  Records inserted : {inserted}")
print(f"  Errors           : {errors}")

total_leads = models.execute_kw(DB, uid, PASSWORD, 'crm.lead', 'search_count', [[]])
print(f"  Total leads in DB: {total_leads}")
print(f"\n  Open http://localhost:8069/odoo/crm to view the data.")
PYEOF

echo ""
echo "=== Script complete ==="

# -- Stop Odoo if we started it ------------------------------------------------
if [ "$ODOO_STARTED_BY_US" = true ] && [ -n "$ODOO_PID" ]; then
    echo ""
    echo "=== Stopping Odoo (PID $ODOO_PID) ==="
    kill $ODOO_PID 2>/dev/null || true
    wait $ODOO_PID 2>/dev/null || true
    echo "Odoo stopped."
    echo "To start it again: sudo -u $ODOO_SYSTEM_USER $ODOO_LAUNCH_CMD -c $ODOO_CONF"
else
    echo "Odoo is still running at $ODOO_URL"
fi