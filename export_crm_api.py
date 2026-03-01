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

HEADERS = [
    "id", "opportunity_name", "type", "active", "probability",
    "expected_revenue", "recurring_revenue", "priority",
    "date_deadline", "date_open", "date_closed", "date_conversion",
    "create_date", "write_date",
    "stage_name", "stage_sequence",
    "partner_name", "partner_email", "partner_phone", "partner_mobile",
    "partner_street", "partner_city", "partner_zip", "partner_country",
    "lead_contact_name",
    "email_from", "phone", "mobile",
    "street", "city", "zip", "lead_country",
    "assigned_user_login", "assigned_user_name",
    "sales_team",
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
total = call("crm.lead", "search_count", [], context={"active_test": False})
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
            context={"active_test": False},
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

        # Bulk-fetch partner details for this batch (email, phone, mobile, address)
        partner_ids = list({r["partner_id"][0] for r in records
                            if isinstance(r.get("partner_id"), (list, tuple))})
        partner_map = {}
        if partner_ids:
            raw_partners = models.execute_kw(
                ODOO_DB, uid, ODOO_PASSWORD,
                "res.partner", "read",
                [partner_ids],
                {"fields": ["id", "email", "phone", "mobile",
                            "street", "city", "zip", "country_id"]},
            )
            for p in raw_partners:
                partner_map[p["id"]] = p

        # Bulk-fetch stage sequence for this batch
        stage_ids = list({r["stage_id"][0] for r in records
                          if isinstance(r.get("stage_id"), (list, tuple))})
        stage_map = {}
        if stage_ids:
            raw_stages = models.execute_kw(
                ODOO_DB, uid, ODOO_PASSWORD,
                "crm.stage", "read",
                [stage_ids],
                {"fields": ["id", "sequence"]},
            )
            for s in raw_stages:
                stage_map[s["id"]] = s["sequence"]

        # Bulk-fetch user login for this batch
        user_ids = list({r["user_id"][0] for r in records
                         if isinstance(r.get("user_id"), (list, tuple))})
        user_login_map = {}
        if user_ids:
            raw_users = models.execute_kw(
                ODOO_DB, uid, ODOO_PASSWORD,
                "res.users", "read",
                [user_ids],
                {"fields": ["id", "login"]},
            )
            for u in raw_users:
                user_login_map[u["id"]] = u["login"]

        for r in records:
            tag_names = " | ".join(
                tag_name_map.get(tid, "") for tid in (r.get("tag_ids") or [])
            )

            pid = r["partner_id"][0] if isinstance(r.get("partner_id"), (list, tuple)) else None
            p = partner_map.get(pid, {})

            sid = r["stage_id"][0] if isinstance(r.get("stage_id"), (list, tuple)) else None
            stage_seq = stage_map.get(sid, "")

            uid_val = r["user_id"][0] if isinstance(r.get("user_id"), (list, tuple)) else None
            user_login = user_login_map.get(uid_val, "")
            user_name  = flat(r["user_id"], index=1)

            row = [
                r["id"],
                flat(r["name"]),
                flat(r["type"]),
                r["active"],
                (f"{r['probability']:.10g}" if r["probability"] is not False else ""),
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
                stage_seq,
                # partner (from partner record)
                flat(r["partner_id"], index=1),
                flat(p.get("email", "")),
                flat(p.get("phone", "")),
                flat(p.get("mobile", "")),
                flat(p.get("street", "")),
                flat(p.get("city", "")),
                flat(p.get("zip", "")),
                flat(p.get("country_id", ""), index=1),
                # lead contact fields
                flat(r["partner_name"]),
                flat(r["email_from"]),
                flat(r["phone"]),
                flat(r["mobile"]),
                flat(r["street"]),
                flat(r["city"]),
                flat(r["zip"]),
                flat(r["country_id"], index=1),
                # user
                user_login,
                user_name,
                # team
                flat(r["team_id"], index=1),
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