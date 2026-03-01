#!/usr/bin/env bash
# =============================================================================
# Export Odoo 18 CRM leads/opportunities to CSV via direct PostgreSQL COPY
# Uses server-side COPY TO which streams the entire result in one query —
# optimal for millions of rows (no row-by-row fetch, no Python overhead).
# Usage: sudo ./export_crm_db.sh [output_file.csv]
# =============================================================================

set -e

DB_NAME="odoo"
DB_USER="odoo"
OUTPUT="${1:-crm_export_$(date +%Y%m%d_%H%M%S).csv}"

# -- Verify PostgreSQL is reachable --------------------------------------------
echo "=== Verifying database connection ==="
if ! cd /tmp && sudo -u $DB_USER psql -d $DB_NAME -c "SELECT 1" > /dev/null 2>&1; then
    echo "ERROR: Cannot connect to database '$DB_NAME' as user '$DB_USER'."
    exit 1
fi
echo "Database connection OK."

# -- Count rows ----------------------------------------------------------------
ROW_COUNT=$(cd /tmp && sudo -u $DB_USER psql -d $DB_NAME -tAc \
    "SELECT COUNT(*) FROM crm_lead;" 2>/dev/null | tr -d '[:space:]')
echo "Leads/opportunities to export: $ROW_COUNT"

# -- Detect many2many tag relation table (name changed between Odoo versions) --
echo "=== Detecting CRM tag relation table ==="
# Find the many2many table that links crm_lead to crm_tag specifically
# by checking both the table name AND that it has a FK into crm_lead
TAG_REL=$(cd /tmp && sudo -u $DB_USER psql -d $DB_NAME -tAc     "SELECT kcu.table_name
     FROM information_schema.key_column_usage kcu
     JOIN information_schema.referential_constraints rc
       ON rc.constraint_name = kcu.constraint_name
     JOIN information_schema.key_column_usage kcu2
       ON kcu2.constraint_name = rc.unique_constraint_name
     WHERE kcu2.table_name = 'crm_lead'
       AND kcu.table_name NOT LIKE '%iap%'
       AND kcu.table_name NOT LIKE '%mining%'
       AND (kcu.table_name LIKE '%tag%' OR kcu.table_name LIKE '%crm_lead%')
     ORDER BY length(kcu.table_name) LIMIT 1;" 2>/dev/null | tr -d '[:space:]')

if [ -z "$TAG_REL" ]; then
    echo "WARNING: CRM tag relation table not found — tags will be empty."
    TAG_JOIN="LEFT JOIN (SELECT NULL::int AS lead_id, NULL::text AS tag_name WHERE false) ltr ON false"
    TAG_AGG="NULL::text"
else
    # Detect which column references crm_lead
    LEAD_COL=$(cd /tmp && sudo -u $DB_USER psql -d $DB_NAME -tAc         "SELECT column_name FROM information_schema.columns
         WHERE table_name = '$TAG_REL'
         AND column_name LIKE '%lead%'
         LIMIT 1;" 2>/dev/null | tr -d '[:space:]')
    TAG_COL=$(cd /tmp && sudo -u $DB_USER psql -d $DB_NAME -tAc         "SELECT column_name FROM information_schema.columns
         WHERE table_name = '$TAG_REL'
         AND column_name NOT LIKE '%lead%'
         LIMIT 1;" 2>/dev/null | tr -d '[:space:]')
    echo "Tag table: $TAG_REL  (lead_col=$LEAD_COL, tag_col=$TAG_COL)"
    TAG_JOIN="LEFT JOIN $TAG_REL ltr ON ltr.$LEAD_COL = l.id LEFT JOIN crm_tag tg ON tg.id = ltr.$TAG_COL"
    # tg.name is jsonb in Odoo 18 (translated field, e.g. {"es_ES":"Urgente"})
    # Detect the actual language key stored in the db
    LANG_KEY=$(cd /tmp && sudo -u $DB_USER psql -d $DB_NAME -tAc \
        "SELECT jsonb_object_keys(name) FROM crm_tag WHERE name IS NOT NULL LIMIT 1;" \
        2>/dev/null | tr -d '[:space:]' | head -1)
    LANG_KEY=${LANG_KEY:-en_US}
    TAG_AGG="STRING_AGG(tg.name->>'$LANG_KEY', ' | ' ORDER BY tg.name->>'$LANG_KEY')"
fi

# -- Export via server-side COPY TO --------------------------------------------
# COPY TO is the fastest PostgreSQL bulk export — the server writes directly
# to stdout without row-by-row Python/client overhead. All joins are done
# server-side in a single pass.
echo "=== Exporting to $OUTPUT ==="

ABS_OUTPUT="$(cd "$(dirname "$OUTPUT")" 2>/dev/null && pwd || pwd)/$(basename "$OUTPUT")"

cd /tmp && sudo -u $DB_USER psql -d $DB_NAME -c \
"COPY (
    SELECT
        l.id,
        l.name                              AS opportunity_name,
        l.type,
        CASE WHEN l.active THEN 'True' ELSE 'False' END AS active,
        CASE WHEN l.probability IS NOT NULL
             THEN TRIM(TRAILING '0' FROM ROUND(l.probability::numeric, 2)::text)
                  || CASE WHEN ROUND(l.probability::numeric,2)::text NOT LIKE '%.%' THEN '.0' ELSE '' END
             ELSE NULL END                  AS probability,
        l.expected_revenue,
        l.recurring_revenue,
        l.priority,
        l.date_deadline,
        to_char(l.date_open, 'YYYY-MM-DD HH24:MI:SS') AS date_open,
        to_char(l.date_closed, 'YYYY-MM-DD HH24:MI:SS') AS date_closed,
        to_char(l.date_conversion, 'YYYY-MM-DD HH24:MI:SS') AS date_conversion,
        to_char(l.create_date, 'YYYY-MM-DD HH24:MI:SS') AS create_date,
        to_char(l.write_date, 'YYYY-MM-DD HH24:MI:SS') AS write_date,

        -- Stage
        s.name->>'$LANG_KEY'               AS stage_name,
        s.sequence                          AS stage_sequence,

        -- Partner / customer
        p.name                              AS partner_name,
        p.email                             AS partner_email,
        p.phone                             AS partner_phone,
        p.mobile                            AS partner_mobile,
        p.street                            AS partner_street,
        p.city                              AS partner_city,
        p.zip                               AS partner_zip,
        co.name->>'$LANG_KEY'              AS partner_country,

        -- Company on the lead itself
        l.partner_name                      AS lead_contact_name,
        l.email_from,
        l.phone,
        l.mobile,
        l.street,
        l.city,
        l.zip,
        lco.name->>'$LANG_KEY'             AS lead_country,

        -- Assigned user
        u.login                             AS assigned_user_login,
        ru.name                             AS assigned_user_name,

        -- Sales team
        t.name->>'$LANG_KEY'               AS sales_team,

        -- Tags (aggregated)
        $TAG_AGG                          AS tags,

        -- Lost reason
        lr.name->>'$LANG_KEY'              AS lost_reason,

        -- Campaign / UTM
        uc.name                             AS campaign,
        um.name                             AS medium,
        us.name                             AS source

    FROM      crm_lead                 l
    LEFT JOIN crm_stage                s   ON s.id  = l.stage_id
    LEFT JOIN res_partner              p   ON p.id  = l.partner_id
    LEFT JOIN res_country              co  ON co.id = p.country_id
    LEFT JOIN res_country              lco ON lco.id = l.country_id
    LEFT JOIN res_users                u   ON u.id  = l.user_id
    LEFT JOIN res_partner              ru  ON ru.id = u.partner_id
    LEFT JOIN crm_team                 t   ON t.id  = l.team_id
    $TAG_JOIN
    LEFT JOIN crm_lost_reason          lr  ON lr.id = l.lost_reason_id
    LEFT JOIN utm_campaign             uc  ON uc.id = l.campaign_id
    LEFT JOIN utm_medium               um  ON um.id = l.medium_id
    LEFT JOIN utm_source               us  ON us.id = l.source_id
    GROUP BY
        l.id, s.name, s.sequence,
        p.name, p.email, p.phone, p.mobile,
        p.street, p.city, p.zip, co.name,
        u.login, ru.name, t.name,
        lr.name, uc.name, um.name, us.name,
        lco.name
    ORDER BY l.id
) TO STDOUT WITH (FORMAT CSV, HEADER TRUE, DELIMITER ',', ENCODING 'UTF8');" \
| (printf '\xEF\xBB\xBF'; cat) \
> "$ABS_OUTPUT"

# -- Summary -------------------------------------------------------------------
EXPORTED=$(wc -l < "$ABS_OUTPUT")
EXPORTED=$((EXPORTED - 1))   # subtract header row
echo ""
echo "=== Export complete ==="
echo "File   : $ABS_OUTPUT"
echo "Rows   : $EXPORTED"
echo "Size   : $(du -h "$ABS_OUTPUT" | cut -f1)"