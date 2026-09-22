-- ============================================================================
-- Ninja EMP — 00_kernel.sql
-- Shared kernel: domains, helper functions, global reference data.
-- Applied ONCE per database (not per tenant). Read-only to tenant roles.
-- Target: PostgreSQL 18 (uuidv7() is native; no extension required for it).
-- Conforms to docs/DATA_STANDARDS.md (ADR-0015).
-- ============================================================================
\set ON_ERROR_STOP on

CREATE SCHEMA IF NOT EXISTS kernel;
COMMENT ON SCHEMA kernel IS
  'Ninja EMP shared kernel: domains, helper functions, global reference data. Read-only to tenant roles.';

-- btree_gist: needed for EXCLUDE constraints mixing uuid equality + range overlap.
-- pgcrypto: gen_random_uuid() fallback + PII encryption at rest (ADR-0018).
-- Installed INTO the kernel schema so tenant search_path (tenant, kernel) resolves
-- pgp_sym_encrypt/decrypt and digest() without needing `public` on the path.
CREATE EXTENSION IF NOT EXISTS btree_gist SCHEMA kernel;
CREATE EXTENSION IF NOT EXISTS pgcrypto  SCHEMA kernel;

-- ----------------------------------------------------------------------------
-- Domains — the single place money/quantity/rate precision is defined.
-- "The scale you choose IS your rounding boundary." NUMERIC(19,4) rounds at the
-- 4th decimal: beyond real-world need, and never silently loses value at cent level.
-- ----------------------------------------------------------------------------
CREATE DOMAIN kernel.money_amount AS numeric(19,4);
COMMENT ON DOMAIN kernel.money_amount IS 'Monetary amount. Scale 4 is the rounding boundary. Never PG money type.';

CREATE DOMAIN kernel.currency_code AS char(3)
  CHECK (VALUE = upper(VALUE) AND VALUE ~ '^[A-Z]{3}$');
COMMENT ON DOMAIN kernel.currency_code IS 'ISO-4217 alpha-3, uppercase.';

CREATE DOMAIN kernel.quantity AS numeric(19,4);
COMMENT ON DOMAIN kernel.quantity IS 'Countable/measurable quantity (units, weight).';

CREATE DOMAIN kernel.fx_rate AS numeric(19,10) CHECK (VALUE > 0);
COMMENT ON DOMAIN kernel.fx_rate IS 'Exchange rate. 10 dp to avoid compounding rounding error.';

CREATE DOMAIN kernel.percent_rate AS numeric(9,6);
COMMENT ON DOMAIN kernel.percent_rate IS 'A rate expressed as a fraction (0.075000 = 7.5%).';

-- ----------------------------------------------------------------------------
-- Session-context helpers. The DBAL sets these per transaction via SET LOCAL.
-- current_tenant() drives RLS defense-in-depth; NULL means "no tenant" -> no rows.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION kernel.current_tenant() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('app.tenant_id', true), '')::uuid
$$;
COMMENT ON FUNCTION kernel.current_tenant() IS 'Tenant id from app.tenant_id session GUC. NULL when unset (RLS then hides all rows).';

CREATE OR REPLACE FUNCTION kernel.current_actor() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('app.actor_id', true), '')::uuid
$$;
COMMENT ON FUNCTION kernel.current_actor() IS 'Acting user/service id from app.actor_id session GUC.';

CREATE OR REPLACE FUNCTION kernel.now_utc() RETURNS timestamptz
LANGUAGE sql STABLE AS $$ SELECT now() $$;
COMMENT ON FUNCTION kernel.now_utc() IS 'Current instant (timestamptz is stored UTC).';

-- ----------------------------------------------------------------------------
-- AUDIT & CONCURRENCY HELPERS (ADR-0017, DATA_STANDARDS §2)
-- ----------------------------------------------------------------------------

-- touch_audit(): BEFORE UPDATE trigger. Stamps updated_at/updated_by and bumps
-- the optimistic-locking version. Attach to every mutable table.
CREATE OR REPLACE FUNCTION kernel.touch_audit() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  NEW.updated_by := kernel.current_actor();
  NEW.version    := COALESCE(OLD.version, 1) + 1;
  RETURN NEW;
END; $$;
COMMENT ON FUNCTION kernel.touch_audit() IS 'BEFORE UPDATE trigger: stamps updated_at/updated_by, increments version (optimistic locking).';

-- forbid_mutation(): generic append-only guard for journal + audit tables.
CREATE OR REPLACE FUNCTION kernel.forbid_mutation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'Table % is append-only; % is not permitted. Post a reversal entry instead.',
    TG_TABLE_NAME, TG_OP USING ERRCODE = '55000';
END; $$;
COMMENT ON FUNCTION kernel.forbid_mutation() IS 'Append-only guard: blocks UPDATE/DELETE.';

-- audit_row(): AFTER INSERT/UPDATE/DELETE trigger writing a before/after row to
-- the tenant-local audit_log (resolved via search_path). Scoped to high-value
-- tables (ADR-0017) to avoid noise/cost on every table.
CREATE OR REPLACE FUNCTION kernel.audit_row() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_row_id text;
BEGIN
  v_row_id := COALESCE((to_jsonb(NEW)->>'id'), (to_jsonb(OLD)->>'id'));
  INSERT INTO audit_log (
    tenant_id, table_schema, table_name, row_id, op,
    actor_id, before_data, after_data
  ) VALUES (
    kernel.current_tenant(), TG_TABLE_SCHEMA, TG_TABLE_NAME, v_row_id, TG_OP,
    kernel.current_actor(),
    CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) END,
    CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) END
  );
  RETURN NULL;
END; $$;
COMMENT ON FUNCTION kernel.audit_row() IS 'AFTER I/U/D trigger: writes before/after JSON to the tenant audit_log.';

-- mask_tail(): keep the last n chars, mask the rest. For PII display (ADR-0018).
CREATE OR REPLACE FUNCTION kernel.mask_tail(p_value text, p_keep int DEFAULT 4)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_value IS NULL THEN NULL
    WHEN length(p_value) <= p_keep THEN repeat('*', length(p_value))
    ELSE repeat('*', length(p_value) - p_keep) || right(p_value, p_keep)
  END
$$;
COMMENT ON FUNCTION kernel.mask_tail(text,int) IS 'Mask all but the last n characters (PII display).';

-- ----------------------------------------------------------------------------
-- Global reference data (shared across all tenants).
-- ----------------------------------------------------------------------------
CREATE TABLE kernel.currency (
  code         kernel.currency_code PRIMARY KEY,
  numeric_code smallint NOT NULL,
  name         text NOT NULL,
  minor_unit   smallint NOT NULL DEFAULT 2 CHECK (minor_unit BETWEEN 0 AND 4),
  symbol       text,
  is_active    boolean NOT NULL DEFAULT true
);
COMMENT ON TABLE kernel.currency IS 'ISO-4217 currency reference. minor_unit = display scale.';

-- money_scale_ok(): true when an amount has no digits beyond the currency's
-- scale. A CHECK constraint cannot contain a subquery, so the scale is reached
-- through this function (MO-1). STABLE, not IMMUTABLE: it reads kernel.currency,
-- and claiming immutability for a table read is a lie that bites at dump/restore.
CREATE OR REPLACE FUNCTION kernel.money_scale_ok(p_amount numeric, p_currency char(3))
RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT p_amount = round(p_amount, COALESCE((SELECT minor_unit FROM kernel.currency WHERE code = p_currency), 2))
$$;
COMMENT ON FUNCTION kernel.money_scale_ok IS
  'True when p_amount has no digits beyond the currency scale. Used by scale CHECKs (MO-1).';

CREATE TABLE kernel.account_type (
  code          text PRIMARY KEY,          -- asset | liability | equity | revenue | expense
  name          text NOT NULL,
  normal_balance char(1) NOT NULL CHECK (normal_balance IN ('D','C')),
  statement     text NOT NULL CHECK (statement IN ('balance_sheet','income_statement')),
  sort_order    smallint NOT NULL
);
COMMENT ON TABLE kernel.account_type IS 'The five account types + normal balance + which statement they roll into.';

CREATE TABLE kernel.party_role_type (
  code        text PRIMARY KEY,
  name        text NOT NULL,
  description text
);
COMMENT ON TABLE kernel.party_role_type IS 'Roles a Party can play. is_house lives on the role instance, not here.';

CREATE TABLE kernel.party_relationship_type (
  code        text PRIMARY KEY,
  name        text NOT NULL,
  description text
);

CREATE TABLE kernel.contact_mechanism_type (
  code text PRIMARY KEY,          -- email | phone | mobile | web | fax | social
  name text NOT NULL
);

CREATE TABLE kernel.subledger_type (
  code        text PRIMARY KEY,   -- ar | ap | vendor_payable | customer_credit | gift_certificate | security_deposit
  name        text NOT NULL,
  description text,
  -- Whether money may sit in this control account with NO party attached.
  --
  -- Normally false, and that is the point: a control account balance is a
  -- promise to or from a NAMED party, and an untagged line is money nobody
  -- can be billed for or paid. Only a genuine BEARER instrument is exempt --
  -- a gift certificate sold to a walk-in is anonymous by design, not by
  -- oversight, and there is no party to record.
  --
  -- This is a whitelist rather than a blanket allowance so the exemption is
  -- a visible, reviewable data decision instead of an accident.
  allows_untagged boolean NOT NULL DEFAULT false,

  -- Whether this subledger's detail lives in open_item.
  --
  -- Not all of them do. Security deposits live in lease_deposit, layaway
  -- deposits in layaway/layaway_payment, stored value in stored_value, and
  -- vendor payables can be accrued straight to the control account. Those
  -- carry a real GL balance with no open item behind it, which is correct,
  -- not a defect.
  --
  -- This flag is what lets open_item_control_check() tell a genuine imbalance
  -- from a subledger that simply keeps its detail elsewhere. The alternative
  -- -- every caller hard-coding IN ('ar','ap','consignor_payable') -- means
  -- the day a new open-item-backed subledger is added, every existing check
  -- silently stops covering it.
  uses_open_items boolean NOT NULL DEFAULT false
);
COMMENT ON TABLE kernel.subledger_type IS 'Subledger kinds that must tie to a GL control account.';

-- Identifier types (party_identifier). is_pii drives classification (ADR-0018).
CREATE TABLE kernel.identifier_type (
  code        text PRIMARY KEY,   -- tax_id | vendor_no | customer_no | duns | ssn | ein | license_no
  name        text NOT NULL,
  is_pii      boolean NOT NULL DEFAULT false,
  is_sensitive boolean NOT NULL DEFAULT false
);
COMMENT ON TABLE kernel.identifier_type IS 'External identifier kinds. is_sensitive => encrypted at rest + masked.';

-- Space types for the Vendor Mall (extensible set -> lookup table, DATA_STANDARDS §11).
CREATE TABLE kernel.space_type (
  code        text PRIMARY KEY,   -- kiosk | booth | inline | endcap | cart | office | storage | popup
  name        text NOT NULL,
  description text
);

-- Rent component types (what makes up a lease's periodic charge).
CREATE TABLE kernel.rent_component_type (
  code        text PRIMARY KEY,   -- base_rent | cam | percentage_rent | utilities | marketing | insurance | fixed_fee
  name        text NOT NULL,
  is_variable boolean NOT NULL DEFAULT false,   -- percentage rent is variable
  description text
);

-- Posting roles: the account-determination keys domain code resolves via posting_map (ADR-0020).
CREATE TABLE kernel.posting_role (
  code        text PRIMARY KEY,   -- cash | ar_control | rent_revenue | security_deposit_liability | ...
  name        text NOT NULL,
  description text
);
COMMENT ON TABLE kernel.posting_role IS 'Account-determination keys. Domain posting resolves account_id via tenant posting_map (ADR-0020).';

-- Data classification registry (ADR-0018, DATA_STANDARDS §6).
CREATE TABLE kernel.data_classification (
  schema_name text NOT NULL,
  table_name  text NOT NULL,
  column_name text NOT NULL,
  class       text NOT NULL CHECK (class IN ('public','internal','confidential','pii','pii_sensitive')),
  note        text,
  PRIMARY KEY (schema_name, table_name, column_name)
);
COMMENT ON TABLE kernel.data_classification IS 'Column-level data classification registry. pii_sensitive => encrypted + masked.';

-- ----------------------------------------------------------------------------
-- Migration ledger — supports the resumable, batched, per-schema migration runner.
-- Keyed by (schema_name, version) so each tenant schema tracks its own progress.
-- ----------------------------------------------------------------------------
CREATE TABLE kernel.migration (
  schema_name  text NOT NULL,
  version      text NOT NULL,
  checksum     text,
  applied_at   timestamptz NOT NULL DEFAULT now(),
  applied_by   text,
  execution_ms integer,
  PRIMARY KEY (schema_name, version)
);
COMMENT ON TABLE kernel.migration IS 'Per-schema applied-migration ledger for the resumable migration runner.';

-- ----------------------------------------------------------------------------
-- Seed reference data.
-- ----------------------------------------------------------------------------
INSERT INTO kernel.currency (code, numeric_code, name, minor_unit, symbol) VALUES
  ('USD', 840, 'US Dollar',        2, '$'),
  ('EUR', 978, 'Euro',             2, '€'),
  ('GBP', 826, 'Pound Sterling',   2, '£'),
  ('CAD', 124, 'Canadian Dollar',  2, 'C$'),
  ('MXN', 484, 'Mexican Peso',     2, 'MX$'),
  ('JPY', 392, 'Japanese Yen',     0, '¥'),
  ('AUD',  36, 'Australian Dollar',2, 'A$')
ON CONFLICT (code) DO NOTHING;

INSERT INTO kernel.account_type (code, name, normal_balance, statement, sort_order) VALUES
  ('asset',     'Asset',     'D', 'balance_sheet',    10),
  ('liability', 'Liability', 'C', 'balance_sheet',    20),
  ('equity',    'Equity',    'C', 'balance_sheet',    30),
  ('revenue',   'Revenue',   'C', 'income_statement', 40),
  ('expense',   'Expense',   'D', 'income_statement', 50)
ON CONFLICT (code) DO NOTHING;

INSERT INTO kernel.party_role_type (code, name, description) VALUES
  ('customer',   'Customer',   'Buys goods/services.'),
  ('vendor',     'Vendor',     'Sells goods to the store or rents a booth.'),
  ('consignor',  'Consignor',  'Places goods on consignment.'),
  ('supplier',   'Supplier',   'Supplies goods/services to the store.'),
  ('employee',   'Employee',   'Works for the store.'),
  ('landlord',   'Landlord',   'Lessor of space (the mall itself, in vendor-run model).'),
  ('buyer',      'Buyer',      'Store acting as purchaser of vendor/consignor goods.'),
  ('contact',    'Contact',    'Generic contact person.'),
  ('lessee',     'Lessee',     'Holds a lease for mall space.')
ON CONFLICT (code) DO NOTHING;

INSERT INTO kernel.party_relationship_type (code, name, description) VALUES
  ('vendor_of',    'Vendor of',    'from_party supplies to_party.'),
  ('employee_of',  'Employee of',  'from_party is employed by to_party.'),
  ('contact_for',  'Contact for',  'from_party is a contact for to_party.'),
  ('guarantor_of', 'Guarantor of', 'from_party guarantees to_party obligations.'),
  ('parent_of',    'Parent of',    'Corporate hierarchy.')
ON CONFLICT (code) DO NOTHING;

INSERT INTO kernel.contact_mechanism_type (code, name) VALUES
  ('email','Email'), ('phone','Phone'), ('mobile','Mobile'),
  ('web','Website'), ('fax','Fax'), ('social','Social')
ON CONFLICT (code) DO NOTHING;

--                                                        untagged? open items?
INSERT INTO kernel.subledger_type (code, name, description, allows_untagged, uses_open_items) VALUES
  ('ar',               'Accounts Receivable', 'Money owed TO the store by customers.', false, true),
  ('ap',               'Accounts Payable',    'Money the store owes suppliers.', false, true),
  -- Vendor payables can be accrued straight to the control account by the
  -- settlement engine, so they are not open-item backed.
  ('vendor_payable',   'Vendor Payable',      'Net settlement owed to vendors/consignors.', false, false),
  -- Detail lives in stored_value, reconciled by stored_value_control_check().
  ('customer_credit',  'Customer Store Credit','Refund liability owed to a customer.', false, false),
  -- The one legitimate untagged exception. A bearer gift certificate sold over
  -- the counter has no holder to record; whoever presents it may redeem it.
  ('gift_certificate', 'Gift Certificate',    'Outstanding gift certificate liability. Bearer instruments have no party.', true, false),
  -- Detail lives in lease_deposit.
  ('security_deposit', 'Security Deposit',    'Refundable deposit held for a lessee.', false, false),
  ('consignor_payable','Consignor Payable',   'Net proceeds owed to a consignor after commission.', false, true),
  -- Layaway deposits are per-CUSTOMER money held on trust, exactly the same
  -- shape as a security deposit: a liability the store owes to one identified
  -- person, with the detail living in its own table (layaway/layaway_payment)
  -- rather than in open_item. Without its own subledger type the deposits
  -- would pile up in a control account with no way to answer "whose money is
  -- this", which is the first question asked in a layaway dispute.
  -- Detail lives in layaway/layaway_payment, reconciled by
  -- layaway_liability_check().
  ('layaway_deposit',  'Layaway Deposit',     'Customer money held on trust against an open layaway.', false, false)
ON CONFLICT (code) DO NOTHING;

INSERT INTO kernel.identifier_type (code, name, is_pii, is_sensitive) VALUES
  ('tax_id',      'Tax Identifier',      true,  true),
  ('ein',         'Employer ID Number',  true,  true),
  ('ssn',         'Social Security No.', true,  true),
  ('duns',        'DUNS Number',         false, false),
  ('vendor_no',   'Vendor Number',       false, false),
  ('customer_no', 'Customer Number',     false, false),
  ('license_no',  'Business License No.',false, false)
ON CONFLICT (code) DO NOTHING;

INSERT INTO kernel.space_type (code, name, description) VALUES
  ('kiosk',   'Kiosk',    'Small freestanding unit.'),
  ('booth',   'Booth',    'Open booth in a hall.'),
  ('inline',  'Inline',   'Standard inline storefront.'),
  ('endcap',  'End Cap',  'End-of-aisle display.'),
  ('cart',    'Cart',     'Mobile cart.'),
  ('office',  'Office',   'Back-office / service space.'),
  ('storage', 'Storage',  'Storage unit.'),
  ('popup',   'Pop-up',   'Short-term pop-up space.')
ON CONFLICT (code) DO NOTHING;

INSERT INTO kernel.rent_component_type (code, name, is_variable, description) VALUES
  ('base_rent',     'Base Rent',       false, 'Fixed periodic rent.'),
  ('cam',           'CAM',             false, 'Common area maintenance.'),
  ('percentage_rent','Percentage Rent',true,  'Rent as a % of sales over a breakpoint.'),
  ('utilities',     'Utilities',       false, 'Utility pass-through.'),
  ('marketing',     'Marketing Fee',   false, 'Marketing/promotion fee.'),
  ('insurance',     'Insurance',       false, 'Insurance pass-through.'),
  ('fixed_fee',     'Fixed Fee',       false, 'Any other fixed periodic fee.')
ON CONFLICT (code) DO NOTHING;

INSERT INTO kernel.posting_role (code, name, description) VALUES
  ('cash',                       'Cash',                        'Cash / bank account.'),
  ('ar_control',                 'AR Control',                  'Accounts receivable control account.'),
  ('ap_control',                 'AP Control',                  'Accounts payable control account.'),
  ('vendor_payable_control',     'Vendor Payable Control',      'Vendor/consignor payable control account.'),
  ('customer_credit_control',    'Customer Credit Control',     'Customer store-credit liability control.'),
  ('gift_certificate_control',   'Gift Certificate Control',    'Gift certificate liability control.'),
  ('security_deposit_control',   'Security Deposit Control',    'Refundable deposit liability control.'),
  ('rent_revenue',               'Rent Revenue',                'Rental income.'),
  ('cam_revenue',                'CAM Revenue',                 'Common-area-maintenance income.'),
  ('percentage_rent_revenue',    'Percentage Rent Revenue',     'Percentage rent income.'),
  ('other_income',               'Other Income',                'Miscellaneous income.'),
  ('bad_debt_expense',           'Bad Debt Expense',            'Write-off of uncollectible receivables.'),
  ('sales_revenue',              'Sales Revenue',               'Merchandise sales revenue.'),
  ('cogs',                       'Cost of Goods Sold',          'Cost of goods sold.'),
  ('inventory',                  'Inventory',                   'Inventory asset.'),
  ('owner_equity',               'Owner Equity',                'Owner equity / draw.'),
  ('consignor_payable_control',  'Consignor Payable Control',   'Net proceeds owed to consignors (control).'),
  ('commission_revenue',         'Commission Revenue',          'Commission earned on consignment sales.'),
  ('consignment_cogs',           'Consignment COGS',            'Cost of consigned goods sold (amount due to consignor).'),
  -- POS & Payments (Part 5, ADR-0029)
  ('undeposited_funds',          'Undeposited Funds',           'Cash/checks received but not yet deposited.'),
  ('card_clearing',              'Card Clearing',               'Card receipts awaiting processor settlement (not cash).'),
  ('bank',                       'Bank',                        'Operating bank account.'),
  ('tips_payable',               'Tips Payable',                'Tips collected on behalf of staff.'),
  ('sales_tax_payable',          'Sales Tax Payable',           'Sales tax collected and owed to jurisdictions.'),
  ('cash_over_short',            'Cash Over/Short',             'Drawer count differences (never netted into revenue).'),
  ('merchant_fees',              'Merchant Fees',               'Card processor fees expensed at settlement.'),
  ('sales_discounts',            'Sales Discounts',             'Contra-revenue discounts granted at POS.'),
  -- Period / year-end close (Part 6, ADR-0030)
  ('retained_earnings',          'Retained Earnings',           'Accumulated prior-year net income; target of year-end close.'),
  ('income_summary',             'Income Summary',              'Clearing account used during year-end close; always nets to zero.'),
  -- Inventory & owned goods (Part 6, ADR-0031)
  ('inventory_adjustment',       'Inventory Adjustment',        'Shrink/spoilage/count adjustments to inventory value.'),
  ('purchase_clearing',          'Purchase Clearing',           'Goods received not yet invoiced (GRNI).'),
  -- Stored value (Part 6, ADR-0032)
  ('gift_certificate_breakage',  'Gift Certificate Breakage',   'Unredeemed stored value recognized as income.')
ON CONFLICT (code) DO NOTHING;

-- Seed the classification registry for the columns we know are sensitive.
INSERT INTO kernel.data_classification (schema_name, table_name, column_name, class, note) VALUES
  ('*','party_identifier','identifier_value','pii_sensitive','Encrypted at rest; masked in views (ADR-0018).'),
  ('*','person','date_of_birth','pii_sensitive','Encrypted/masked; never exposed raw.'),
  ('*','person','given_name','pii',NULL),
  ('*','person','family_name','pii',NULL),
  ('*','party_contact_mechanism','value','pii','Email/phone are personal data.'),
  ('*','postal_address','line1','pii',NULL),
  ('*','postal_address','line2','pii',NULL),
  ('*','postal_address','postal_code','pii',NULL),
  ('*','journal_entry','memo','confidential',NULL),
  ('*','journal_line','memo','confidential',NULL),
  ('*','lease','*','confidential','Contract terms.')
ON CONFLICT (schema_name, table_name, column_name) DO NOTHING;

-- ----------------------------------------------------------------------------
-- schema_migration — applied-migration ledger (one row per tenant schema).
--
-- provision.sh builds from scratch; this table is how the schema evolves AFTER
-- a tenant is live. The runner (scripts/migrate.sh) is resumable and refuses to
-- proceed if an already-applied file changed on disk.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS kernel.schema_migration (
  tenant_schema text        NOT NULL,
  version       text        NOT NULL,
  filename      text        NOT NULL,
  checksum      text        NOT NULL,
  applied_at    timestamptz NOT NULL DEFAULT now(),
  applied_by    text        NOT NULL DEFAULT current_user,
  duration_ms   integer,
  PRIMARY KEY (tenant_schema, version)
);
COMMENT ON TABLE kernel.schema_migration IS 'Applied migrations per tenant schema. Checksums detect edited migrations.';
