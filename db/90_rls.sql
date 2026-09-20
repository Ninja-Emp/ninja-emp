-- ============================================================================
-- Ninja EMP — 90_rls.sql  (TENANT-SCOPED)
-- Row-Level Security as DEFENSE-IN-DEPTH on top of schema-per-tenant.
-- FORCE ROW LEVEL SECURITY so even the table owner is subject to policies.
-- The app sets app.tenant_id per transaction (SET LOCAL); NULL hides all rows.
--
-- ADR-0007 (MEASURED): RLS costs ~3x on the hot journal path
--   (200k-row scan: 231ms with RLS vs 73ms without; index-driven 207ms vs 72ms).
-- Because schema-per-tenant already physically isolates tables, RLS is
-- redundant for isolation on the highest-volume tables. We therefore apply RLS
-- to all tenant tables EXCEPT journal_entry and journal_line, which rely on
-- schema isolation + the app-level tenant guard. If we ever move to
-- shared-schema multi-tenancy, RLS MUST be re-enabled on those two tables.
-- Run with: SET search_path = <tenant_schema>, kernel;
-- ============================================================================
\set ON_ERROR_STOP on

-- Helper to apply the standard tenant policy to a table that has tenant_id.
CREATE OR REPLACE FUNCTION _apply_tenant_rls(p_table text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', p_table);
  EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', p_table);
  EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON %I', p_table);
  EXECUTE format(
    'CREATE POLICY tenant_isolation ON %I USING (tenant_id = kernel.current_tenant()) '
    'WITH CHECK (tenant_id = kernel.current_tenant())', p_table);
END; $$;

-- Tables carrying tenant_id directly (journal tables intentionally excluded — ADR-0007).
SELECT _apply_tenant_rls(t) FROM unnest(ARRAY[
  'tenant_config','exchange_rate','party','party_role','party_relationship',
  'party_contact_mechanism','postal_address','party_identifier',
  'account','posting_map','fiscal_period','audit_log',
  'open_item','payment_application',
  -- Vendor Mall (Part 3)
  'location','floor','space','space_attribute','waitlist',
  'lease','lease_space','rent_component','lease_deposit','delinquency',
  -- Consignment (Part 4)
  'consignor_agreement','commission_rule','consignment_item','item_price_change',
  'consignment_sale','consignment_sale_line','consignor_settlement',
  'settlement_line','consignor_payout',
  -- POS & Payments (Part 5)
  'tender_type','tax_jurisdiction','tax_rate','register','shift',
  'sale','sale_line','sale_line_tax','payment','payment_tender',
  'merchant_settlement'
]) AS t;

-- Subtype tables (person/organization) have no tenant_id; isolate via their party.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['person','organization'] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON %I', t);
    EXECUTE format(
      'CREATE POLICY tenant_isolation ON %I USING ('
      'EXISTS (SELECT 1 FROM party p WHERE p.id = %I.party_id '
      'AND p.tenant_id = kernel.current_tenant())) '
      'WITH CHECK (EXISTS (SELECT 1 FROM party p WHERE p.id = %I.party_id '
      'AND p.tenant_id = kernel.current_tenant()))', t, t, t);
  END LOOP;
END $$;

-- Journal tables: RLS explicitly DISABLED (ADR-0007, measured). Documented here
-- so the omission is intentional and auditable, not an oversight.
ALTER TABLE journal_entry DISABLE ROW LEVEL SECURITY;
ALTER TABLE journal_line  DISABLE ROW LEVEL SECURITY;
COMMENT ON TABLE journal_entry IS 'Append-only journal header. RLS intentionally OFF (ADR-0007, measured 3x cost); relies on schema isolation.';
COMMENT ON TABLE journal_line  IS 'Append-only journal lines. RLS intentionally OFF (ADR-0007, measured 3x cost); relies on schema isolation.';

DROP FUNCTION _apply_tenant_rls(text);
