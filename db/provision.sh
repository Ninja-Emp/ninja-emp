#!/usr/bin/env bash
# ============================================================================
# Ninja EMP — provision.sh
# ADR-0008: TWO databases.
#   ninja_control — control plane (tenant registry). Its own DB.
#   ninja_emp     — tenant plane (kernel + tenant schemas).
# Roles are cluster-level (created once).
# Usage: ./provision.sh [tenant_schema]   (default: tenant_demo)
# ============================================================================
set -euo pipefail
PSQL="sudo -u postgres psql -v ON_ERROR_STOP=1 -q"
CONTROL_DB="ninja_control"
TENANT_DB="ninja_emp"
TENANT="${1:-tenant_demo}"
# Fixed demo tenant id so seeds and tests align (tests use the same id).
DEMO_TENANT_ID="11111111-1111-7111-8111-111111111111"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo ">> roles (cluster-level)"
$PSQL -d postgres -f "$HERE/99_roles.sql"

echo ">> control plane database: $CONTROL_DB"
$PSQL -c "DROP DATABASE IF EXISTS $CONTROL_DB;" >/dev/null
$PSQL -c "CREATE DATABASE $CONTROL_DB;" >/dev/null
$PSQL -d "$CONTROL_DB" -f "$HERE/00_bootstrap.sql"

echo ">> tenant plane database: $TENANT_DB"
$PSQL -c "DROP DATABASE IF EXISTS $TENANT_DB;" >/dev/null
$PSQL -c "CREATE DATABASE $TENANT_DB;" >/dev/null
$PSQL -d "$TENANT_DB" -f "$HERE/00_kernel.sql"

echo ">> kernel grants (per-database)"
$PSQL -d "$TENANT_DB" -c "GRANT USAGE ON SCHEMA kernel TO ninja_app, ninja_migrator; \
  GRANT SELECT ON ALL TABLES IN SCHEMA kernel TO ninja_app, ninja_migrator; \
  ALTER DEFAULT PRIVILEGES IN SCHEMA kernel GRANT SELECT ON TABLES TO ninja_app, ninja_migrator;"

echo ">> tenant schema: $TENANT"
$PSQL -d "$TENANT_DB" -c "CREATE SCHEMA $TENANT;"

# Core tenant DDL (audit log must exist before tables that write to it).
for f in 05_audit.sql 10_party.sql 20_money.sql 30_ledger.sql; do
  echo "   - $f"
  $PSQL -d "$TENANT_DB" -c "SET search_path = $TENANT, kernel;" -f "$HERE/$f"
done

echo ">> tenant config + fiscal calendar (ADR-0014)"
$PSQL -d "$TENANT_DB" -c "SET search_path = $TENANT, kernel; \
  SET app.tenant_id = '$DEMO_TENANT_ID'; \
  INSERT INTO tenant_config (legal_name, functional_currency) \
    VALUES ('Demo Mall LLC','USD') ON CONFLICT (tenant_id) DO NOTHING;"

# Seeds (CoA + posting_map, consignment CoA, fiscal calendar generator).
for f in 35_coa_seed.sql 37_coa_consignment.sql 38_coa_pos.sql 39_coa_close.sql 36_tenant_seed.sql; do
  echo "   - $f"
  $PSQL -d "$TENANT_DB" -c "SET search_path = $TENANT, kernel; SET app.tenant_id = '$DEMO_TENANT_ID';" -f "$HERE/$f"
done
$PSQL -d "$TENANT_DB" -c "SET search_path = $TENANT, kernel; SET app.tenant_id = '$DEMO_TENANT_ID'; SELECT ensure_fiscal_calendar();" >/dev/null

# Domain + posting + RLS last.
for f in 40_subledger.sql 45_openitem.sql 50_vendormall.sql 55_vendormall_posting.sql \
         60_consignment.sql 65_consignment_posting.sql \
         70_pos.sql 75_pos_posting.sql 80_vendor_portal.sql 85_close.sql 90_rls.sql; do
  echo "   - $f"
  # tenant_id is needed because some domain files seed tenant reference data
  # (e.g. 70_pos.sql seeds tender_type).
  $PSQL -d "$TENANT_DB" -c "SET search_path = $TENANT, kernel; SET app.tenant_id = '$DEMO_TENANT_ID';" -f "$HERE/$f"
done

echo ">> grants for ninja_app / ninja_migrator on $TENANT"
$PSQL -d "$TENANT_DB" -c "GRANT USAGE ON SCHEMA $TENANT TO ninja_app, ninja_migrator; \
  GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA $TENANT TO ninja_app; \
  GRANT ALL ON ALL TABLES IN SCHEMA $TENANT TO ninja_migrator; \
  GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA $TENANT TO ninja_app, ninja_migrator;"

echo ">> done. control=$CONTROL_DB tenant_db=$TENANT_DB schema=$TENANT tenant_id=$DEMO_TENANT_ID"
