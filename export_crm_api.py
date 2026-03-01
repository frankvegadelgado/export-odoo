#!/usr/bin/env python3.11
# =============================================================================
# Export Odoo 18 CRM leads/opportunities to CSV via XML-RPC API
# Fetches records in large batches (configurable) to minimise round-trips.
# Designed for millions of rows: streams rows to CSV as each batch arrives
# so memory usage stays flat regardless of dataset size.
# Usage: sudo python3.11 export_crm_api.py [output_file.csv]
# =============================================================================

import csv
import sys
import xmlrpc.client
from datetime import datetime

# -- Configuration -------------------------------------------------------------
ODOO_URL        = "http://localhost:8069"
ODOO_DB         = "odoo"
ODOO_USER       = "admin"
ODOO_PASSWORD   = "admin"

# Batch size: how many records to fetch per XML-RPC call.
# 500–1000 is optimal — large enough to amortise round-trip latency,
# small enough to avoid timeout or memory spikes.
BATCH_SIZE      = 500

OUTPUT_FILE     = sys.argv[1] if len(sys.argv) > 1 \
                  else f"crm_export_api_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv"

# Fields to fetch from crm.lead
FIELDS = [
    "id", "name", "type", "active", "probability",
    "expected_revenue", "recurring_revenue", "priority",
    "date_deadline", "date_open", "date_closed", "date_conversion",
    "create_date", "write_date",
    "stage_id",
    "partner_id",
    "email_from", "phone", "mobile",
    "street", "city", "zip", "country_id",
    "partner_name",
    "user_id",
    "team_id",
    "tag_ids",
    "lost_reason_id",
    "campaign_id", "medium_id", "source_id",
]

# CSV column headers (matches field order above + expanded many2one labels)
HEADERS = [
    "id", "opportunity_name", "type", "active", "probability",
    "expected_revenue", "recurring_revenue", "priority",
    "date_deadline", "date_open", "date_closed", "date_conversion",
    "create_date", "write_date",
    "stage_name",
    "partner_name", "partner_id",
    "email_from", "phone", "mobile",
    "street", "city", "zip", "country",
    "lead_contact_name",
    "assigned_user", "user_id",
    "sales_team", "team_id",
    "tags",
    "lost_reason",
    "campaign", "medium", "source",
]

# -- Connect -------------------------------------------------------------------
print("=== Connecting to Odoo XML-RPC ===")
common  = xmlrpc.client.ServerProxy(f"{ODOO_URL}/xmlrpc/2/common")
models  = xmlrpc.client.ServerProxy(f"{ODOO_URL}/xmlrpc/2/object")

try:
    uid = common.authenticate(ODOO_DB, ODOO_USER, ODOO_PASSWORD, {})
except Exception as e:
    print(f"ERROR: Authentication failed: {e}")
    sys.exit(1)

if not uid:
    print("ERROR: Authentication failed — check credentials.")
    sys.exit(1)

print(f"Authenticated as UID: {uid}")

def call(model, method, *args, **kwargs):
    return models.execute_kw(ODOO_DB, uid, ODOO_PASSWORD,
                             model, method, list(args), kwargs)

# -- Count ---------------------------------------------------------------------
total = call("crm.lead", "search_count", [])
print(f"Leads/opportunities to export: {total}")

if total == 0:
    print("Nothing to export.")
    sys.exit(0)

# -- Stream to CSV in batches --------------------------------------------------
print(f"=== Exporting to {OUTPUT_FILE} (batch size: {BATCH_SIZE}) ===")

exported = 0
batches  = (total + BATCH_SIZE - 1) // BATCH_SIZE

import unicodedata

def flat(value, index=1):
    """Return display name or id from a many2one tuple, or raw value.
    Normalises unicode to NFC (composed form) so Spanish accented characters
    like á, é, í, ó, ú, ñ, ü are stored as single code points, not
    decomposed sequences — ensures correct display in Excel and LibreOffice.
    """
    if isinstance(value, (list, tuple)) and len(value) == 2:
        v = value[index]
    elif value is False or value is None:
        return ""
    else:
        v = value
    if isinstance(v, str):
        return unicodedata.normalize("NFC", v).strip()
    return v

# utf-8-sig writes a UTF-8 BOM so Excel opens Spanish accented
# characters (á é í ó ú ñ ü ¿ ¡) correctly without manual import steps.
with open(OUTPUT_FILE, "w", newline="", encoding="utf-8-sig") as f:
    writer = csv.writer(f)
    writer.writerow(HEADERS)

    for batch_num in range(batches):
        offset = batch_num * BATCH_SIZE

        records = call(
            "crm.lead", "search_read",
            [],
            fields=FIELDS,
            limit=BATCH_SIZE,
            offset=offset,
            order="id asc",
        )

        # Resolve all tag IDs for this batch in ONE call — not per record
        all_tag_ids = list({tid for r in records for tid in (r.get("tag_ids") or [])})
        tag_name_map = {}
        if all_tag_ids:
            # call() wraps positional args, so pass ids directly (not nested)
            raw_tags = models.execute_kw(
                ODOO_DB, uid, ODOO_PASSWORD,
                "crm.tag", "read",
                [all_tag_ids],
                {"fields": ["name"]},
            )
            for t in raw_tags:
                # name is jsonb in Odoo 18: {"es_ES": "Urgente"} — extract first value
                n = t["name"]
                if isinstance(n, dict):
                    n = next(iter(n.values()), "")
                tag_name_map[t["id"]] = unicodedata.normalize("NFC", str(n)).strip()

        for r in records:
            tag_names = " | ".join(
                tag_name_map.get(tid, "") for tid in (r.get("tag_ids") or [])
            )

            row = [
                r["id"],
                flat(r["name"]),
                flat(r["type"]),
                r["active"],
                r["probability"] if r["probability"] is not False else "",
                r["expected_revenue"],
                r["recurring_revenue"],
                flat(r["priority"]),
                flat(r["date_deadline"]),
                flat(r["date_open"]),
                flat(r["date_closed"]),
                flat(r["date_conversion"]),
                flat(r["create_date"]),
                flat(r["write_date"]),
                # stage
                flat(r["stage_id"], index=1),
                # partner
                flat(r["partner_id"], index=1),
                flat(r["partner_id"], index=0),
                # contact fields on lead
                flat(r["email_from"]),
                flat(r["phone"]),
                flat(r["mobile"]),
                flat(r["street"]),
                flat(r["city"]),
                flat(r["zip"]),
                flat(r["country_id"], index=1),
                flat(r["partner_name"]),
                # user
                flat(r["user_id"], index=1),
                flat(r["user_id"], index=0),
                # team
                flat(r["team_id"], index=1),
                flat(r["team_id"], index=0),
                # tags
                tag_names,
                # lost reason
                flat(r["lost_reason_id"], index=1),
                # UTM
                flat(r["campaign_id"], index=1),
                flat(r["medium_id"],   index=1),
                flat(r["source_id"],   index=1),
            ]
            writer.writerow(row)

        exported += len(records)
        pct = int(exported / total * 100)
        print(f"  {exported}/{total} ({pct}%) — batch {batch_num + 1}/{batches}",
              end="\r", flush=True)

print()  # newline after progress

# -- Summary -------------------------------------------------------------------
import os
size = os.path.getsize(OUTPUT_FILE)
size_str = f"{size / 1024 / 1024:.2f} MB" if size > 1024*1024 else f"{size / 1024:.1f} KB"

print("")
print("=== Export complete ===")
print(f"File   : {OUTPUT_FILE}")
print(f"Rows   : {exported}")
print(f"Size   : {size_str}")