# Odoo 18 CRM Export Toolkit

A collection of bash and Python scripts to install, manage, populate and export Odoo 18 Community CRM data to CSV — designed for production environments with millions of rows and full support for Spanish (and any UTF-8) character sets.

---

## Table of Contents

- [Overview](#overview)
- [Scripts at a Glance](#scripts-at-a-glance)
- [Requirements](#requirements)
- [Configuration — adapt to your environment](#configuration--adapt-to-your-environment)
- [Installation](#installation)
- [Service Management](#service-management)
- [Populating Test Data](#populating-test-data)
- [Exporting CRM Data](#exporting-crm-data)
  - [Option A — Direct PostgreSQL export](#option-a--direct-postgresql-export-export_crm_dbsh)
  - [Option B — Odoo XML-RPC API export](#option-b--odoo-xml-rpc-api-export-export_crm_apish--export_crm_apipy)
  - [Why two options?](#why-two-options)
  - [Export output format](#export-output-format)
- [Uninstallation](#uninstallation)
- [Troubleshooting](#troubleshooting)

---

## Overview

This toolkit solves a real-world need: **reliably exporting Odoo 18 CRM leads and opportunities to a clean, importable CSV file** from any environment — whether you have direct database access or only HTTP access to the Odoo API.

Key design goals:

- **Identical output from both export methods.** The PostgreSQL and API exports produce exactly the same 40 columns in the same order, with the same data types and encoding — so you can switch between them transparently.
- **Production-safe at scale.** Both exports use bulk operations (PostgreSQL `COPY TO STDOUT` and batched `search_read`) to keep memory flat and latency low regardless of row count.
- **Spanish and accented character support.** All CSV files are written in UTF-8 with BOM so Excel, LibreOffice and data pipeline tools open them correctly without a manual import wizard — no mojibake on `á`, `é`, `ñ`, `ü`, `¿`, `¡`.
- **Zero data loss.** Inactive records (`active=False`) are included. All many2one and many2many fields are fully resolved to human-readable names. Timestamps are normalised. Booleans are consistent (`True`/`False`).
- **Self-contained.** No virtualenv, no Docker, no Odoo Enterprise licence required. Everything runs as a system-wide pip install on Ubuntu 22.04 / Debian.

---

## Scripts at a Glance

| Script | Purpose | Run as |
|--------|---------|--------|
| `install_odoo.sh` | Install Odoo 18 Community + PostgreSQL from scratch | `sudo` |
| `start_odoo.sh` | Start the Odoo service (no-op if already running) | `sudo` |
| `stop_odoo.sh` | Stop the Odoo service gracefully (no-op if not running) | `sudo` |
| `populate_crm.sh` | Seed ~1 500 realistic CRM leads with Spanish data for testing | `sudo` |
| `export_crm_db.sh` | Export CRM to CSV via direct PostgreSQL `COPY TO STDOUT` | `sudo` |
| `export_crm_api.sh` | Export CRM to CSV via Odoo XML-RPC API (wrapper) | `sudo` |
| `export_crm_api.py` | Python script called by `export_crm_api.sh` | (called internally) |
| `deinstall_odoo.sh` | Completely remove Odoo, DB and system user | `sudo` |

All scripts must be placed in the **same directory** and made executable:

```bash
chmod +x *.sh
```

---

## Requirements

- **OS:** Ubuntu 22.04 LTS or Debian 11/12
- **Python:** 3.11 (installed automatically if missing)
- **PostgreSQL:** 14+ (installed automatically)
- **Disk:** ~2 GB for Odoo source + Python dependencies
- **Network:** internet access during install to download the Odoo tarball
- **Privileges:** `sudo` / root for install and service management; read-only DB access is enough to run the export

---

## Configuration — adapt to your environment

Every configurable parameter is declared at the **top of each script** so you never have to hunt through logic to change them.

### `install_odoo.sh`

```bash
ODOO_VERSION="18.0"        # Odoo major version to download
ODOO_USER="odoo"           # Linux system user that runs Odoo
ODOO_HOME="/opt/odoo"      # Installation directory
ODOO_CONF="/etc/odoo.conf" # Path to the Odoo config file
DB_NAME="odoo"             # PostgreSQL database name
DB_USER="odoo"             # PostgreSQL user
```

### `populate_crm.sh`

```bash
ODOO_URL="http://localhost:8069"  # Base URL of the Odoo HTTP service
ODOO_DB="odoo"                    # Database name
ODOO_ADMIN_USER="admin"           # Odoo application admin login
ODOO_ADMIN_PASS="admin"           # Odoo application admin password
ODOO_HOME="/opt/odoo"             # Must match install_odoo.sh
ODOO_CONF="/etc/odoo.conf"        # Must match install_odoo.sh
```

### `export_crm_db.sh`

```bash
DB_NAME="odoo"   # PostgreSQL database name — must match your instance
DB_USER="odoo"   # PostgreSQL user — must have SELECT on all CRM tables
```

> **Remote databases:** the script runs `psql` via `sudo -u $DB_USER`, so it relies on peer authentication. For a remote host add a `--host` flag or configure `~/.pgpass`.

### `export_crm_api.py`

```python
ODOO_URL      = "http://localhost:8069"  # Full base URL, change for remote instances
ODOO_DB       = "odoo"                   # Database name shown on the login screen
ODOO_USER     = "admin"                  # Odoo application login (not the Linux user)
ODOO_PASSWORD = "admin"                  # Odoo application password
BATCH_SIZE    = 500                      # Records per API call — increase for fast networks,
                                         # decrease if you hit timeouts (default 500 is safe)
```

> **HTTPS / remote Odoo:** just change `ODOO_URL` to `https://your-odoo.example.com`. No other change needed. The XML-RPC client works over any HTTP/HTTPS endpoint.

### `start_odoo.sh` / `stop_odoo.sh` / `deinstall_odoo.sh`

```bash
ODOO_USER="odoo"           # Linux system user
ODOO_CONF="/etc/odoo.conf" # Path to config — used to identify the running process
```

---

## Installation

```bash
sudo ./install_odoo.sh
```

What it does, in order:

1. Checks and fixes DNS if broken (sets `8.8.8.8` as fallback nameserver)
2. Installs system dependencies: PostgreSQL, Python 3.11, `libxml2`, `libxslt`, `libldap`, `libsasl2`, and others required by Odoo
3. Creates the `odoo` Linux system user with home at `/opt/odoo`
4. Creates the `odoo` PostgreSQL user and `odoo` database
5. Downloads the Odoo 18 source tarball from `nightly.odoo.com` — **the tarball is preserved** across reinstalls so you don't re-download it
6. Patches a known `cbor2` version conflict in `requirements.txt`
7. Installs all Python dependencies system-wide (`pip install` without virtualenv)
8. Force-installs `urllib3` via pip to shadow the apt version, fixing a known `cryptography` incompatibility in Ubuntu 22.04
9. Writes `/etc/odoo.conf` with correct paths, DB credentials and log location
10. Creates `/var/log/odoo/` with correct ownership
11. Initialises the database with the `base` and `crm` modules (`--init base,crm --stop-after-init`)

Expected duration: **5–15 minutes** depending on network speed.

After install, start Odoo and open your browser:

```bash
sudo ./start_odoo.sh
# → http://localhost:8069   login: admin / admin
```

---

## Service Management

### Start

```bash
sudo ./start_odoo.sh
```

- Checks if Odoo is already responding on port 8069
- If already running: prints a notice and exits — **does nothing**
- If not running: ensures `/var/log/odoo/` has correct ownership, starts Odoo as the `odoo` user, prints the PID and log path

### Stop

```bash
sudo ./stop_odoo.sh
```

- Checks if Odoo is running
- If not running: prints a notice and exits — **does nothing**
- If running: sends `SIGTERM` and waits up to 10 seconds for a clean shutdown
- If it doesn't stop cleanly: sends `SIGKILL` as a last resort

---

## Populating Test Data

```bash
sudo ./populate_crm.sh
```

Seeds the CRM with **~1 500 realistic Spanish-language leads and opportunities**, useful for testing the export before pointing it at a production database.

The data includes:

- Mexican, Colombian and Spanish company names, contacts and phone formats
- Accented characters throughout (`á`, `é`, `í`, `ó`, `ú`, `ñ`, `ü`)
- Multiple CRM stages, priorities, tags and sales teams
- Expected revenue, deadlines and activity dates
- UTM campaign, medium and source attribution

The script starts Odoo automatically if it is not running, waits for it to be fully ready (XML-RPC version check), inserts all records in bulk, then stops Odoo again if it was started by the script.

> **Note:** `ODOO_ADMIN_USER` and `ODOO_ADMIN_PASS` must match the actual Odoo application credentials, not the Linux system user. The default after a fresh install is `admin` / `admin`.

---

## Exporting CRM Data

Both export options produce **identical output**: 40 columns, UTF-8 with BOM, all fields fully resolved, including inactive records.

### Option A — Direct PostgreSQL export (`export_crm_db.sh`)

```bash
sudo ./export_crm_db.sh                        # auto-named file
sudo ./export_crm_db.sh /path/to/output.csv   # custom path
```

Uses PostgreSQL's `COPY TO STDOUT` — the fastest possible export mechanism. The server streams all rows directly to the file in a **single query**, with all JOINs resolved server-side. No Python overhead, no row-by-row fetching.

**When to use this:**
- You have direct access to the PostgreSQL server (local or SSH tunnel)
- Dataset is very large (hundreds of thousands to millions of rows)
- You want the fastest possible export with minimal server load

**What it does automatically:**
- Detects the CRM tag many2many relation table using FK constraints (not fragile name-matching) so it works across Odoo versions
- Detects the active database language key from the jsonb translated fields (`stage_name`, `sales_team`, `lost_reason`, country names) and extracts the correct locale string
- Prepends a UTF-8 BOM so Excel opens accented characters correctly
- Normalises `active` to `True`/`False`, timestamps to `YYYY-MM-DD HH24:MI:SS`, probability to a single decimal place

### Option B — Odoo XML-RPC API export (`export_crm_api.sh` + `export_crm_api.py`)

```bash
sudo ./export_crm_api.sh                        # auto-named file
sudo ./export_crm_api.sh /path/to/output.csv   # custom path
```

The shell wrapper handles the Odoo lifecycle:

1. Checks if Odoo is already running (via HTTP)
2. If not: starts it, waits for it to be ready (XML-RPC `version` call), then proceeds
3. Calls `export_crm_api.py`
4. If Odoo was started by the script: stops it cleanly afterwards

The Python script fetches records in **configurable batches** (`BATCH_SIZE = 500`), streaming each batch to the CSV file as it arrives — memory usage stays flat regardless of total row count.

For each batch, related records (partner details, stage sequence, user login, tags) are fetched in **one bulk call per related model per batch** — not per record — keeping API round-trips to a minimum.

**When to use this:**
- You only have HTTP access to Odoo (no direct DB access)
- Exporting from a remote or cloud-hosted Odoo instance
- You need to respect Odoo's access control and field-level permissions

**Key API behaviours handled:**
- `context={"active_test": False}` — includes archived/inactive leads that the API hides by default
- jsonb translated fields (`stage_name`, `sales_team`, tag names) are extracted by detecting the first available language key
- Unicode NFC normalisation on all string fields so composed characters (`á` as single code point) are consistent

### Why two options?

| | PostgreSQL (`export_crm_db.sh`) | API (`export_crm_api.sh`) |
|---|---|---|
| **Speed** | Fastest — single server-side query | Fast — batched, but multiple round-trips |
| **Memory** | Streamed, O(1) | Streamed per batch, O(batch size) |
| **Access needed** | PostgreSQL peer/password auth | Odoo HTTP + valid user credentials |
| **Respects Odoo ACL** | No — direct DB read | Yes — Odoo enforces field access |
| **Works remotely** | With SSH tunnel or pg_hba | Yes — just change `ODOO_URL` |
| **Output** | Identical | Identical |

### Export output format

Both methods produce the same **40-column CSV**:

| Column | Description |
|--------|-------------|
| `id` | Internal Odoo record ID |
| `opportunity_name` | Lead / opportunity title |
| `type` | `lead` or `opportunity` |
| `active` | `True` (active) or `False` (archived) |
| `probability` | Win probability (0.0–100.0) |
| `expected_revenue` | Expected revenue amount |
| `recurring_revenue` | Recurring revenue amount |
| `priority` | 0 = Normal, 1 = Low, 2 = High, 3 = Very High |
| `date_deadline` | Expected close date |
| `date_open` | Date converted to opportunity |
| `date_closed` | Date won/lost |
| `date_conversion` | Date of last stage change |
| `create_date` | Record creation timestamp |
| `write_date` | Last update timestamp |
| `stage_name` | Pipeline stage label |
| `stage_sequence` | Stage sort order (useful for re-importing in correct order) |
| `partner_name` | Linked contact / company name |
| `partner_email` | Contact email address |
| `partner_phone` | Contact phone |
| `partner_mobile` | Contact mobile |
| `partner_street` | Contact street address |
| `partner_city` | Contact city |
| `partner_zip` | Contact postal code |
| `partner_country` | Contact country name |
| `lead_contact_name` | Company name typed directly on the lead |
| `email_from` | Email typed directly on the lead |
| `phone` | Phone typed directly on the lead |
| `mobile` | Mobile typed directly on the lead |
| `street` | Street typed directly on the lead |
| `city` | City typed directly on the lead |
| `zip` | ZIP typed directly on the lead |
| `lead_country` | Country typed directly on the lead |
| `assigned_user_login` | Login of the responsible salesperson |
| `assigned_user_name` | Display name of the responsible salesperson |
| `sales_team` | Sales team name |
| `tags` | Pipe-separated list of tags (`VIP \| Referido \| Corporativo`) |
| `lost_reason` | Reason for marking as lost |
| `campaign` | UTM campaign |
| `medium` | UTM medium |
| `source` | UTM source |

**Encoding:** UTF-8 with BOM (`utf-8-sig`) — opens correctly in Excel, LibreOffice Calc, Power BI and standard ETL tools without configuration.

---

## Uninstallation

```bash
sudo ./deinstall_odoo.sh
```

Removes everything installed by `install_odoo.sh`:

- Drops the `odoo` PostgreSQL database and user
- Removes the `odoo` Linux system user and `/opt/odoo`
- Removes `/etc/odoo.conf` and `/var/log/odoo`
- Removes the `odoo` entry point from `/usr/local/bin`

> **The source tarball (`odoo_18.0.latest.tar.gz`) is preserved** so a reinstall does not re-download it.

---

## Troubleshooting

**`ERROR: couldn't create the logfile directory`**
The `/var/log/odoo` directory either doesn't exist or is owned by root. `start_odoo.sh` and `export_crm_api.sh` create and fix ownership automatically. If you see this from a manual start, run:
```bash
sudo mkdir -p /var/log/odoo && sudo chown odoo:odoo /var/log/odoo
```

**`Authentication failed: Connection refused`**
Odoo is not running. Use `start_odoo.sh` to start it, or use `export_crm_api.sh` which starts Odoo automatically.

**`ERROR: relation "crm_lead" does not exist`**
The database was not initialised with the CRM module. Run `install_odoo.sh` again — it is safe to re-run.

**API export is missing records**
Odoo's API hides archived (`active=False`) records by default. The export already passes `context={"active_test": False}` to include them. If counts still differ, check that the API user has access to all records.

**Tags column is empty in DB export**
The script auto-detects the many2many join table using FK constraints. If detection fails (unusual schema), it will warn and export with empty tags. Check the output for `WARNING: CRM tag relation table not found`.

**Accented characters look wrong after opening in Excel**
Make sure you open the file directly (double-click or File → Open) rather than importing it. Both exports write a UTF-8 BOM that Excel uses automatically. If you are pasting into another tool, ensure it is configured for UTF-8.

**Remote Odoo instance (API export)**
Change `ODOO_URL` in `export_crm_api.py` to the full base URL of your instance (e.g. `https://mycompany.odoo.com`). Change `ODOO_DB`, `ODOO_USER` and `ODOO_PASSWORD` to match your credentials. `BATCH_SIZE` can be increased on fast/local connections or decreased if you hit server timeouts.
