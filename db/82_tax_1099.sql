-- ============================================================================
-- Ninja EMP — 82_tax_1099.sql  (TENANT-SCOPED)
--
-- 1099-NEC / 1099-MISC threshold tracking and annual extract.
--
-- WHY THIS IS A LEDGER QUESTION, NOT A REPORT
-- A consignment store pays individuals. The IRS requires an information return
-- for each payee paid at or above the threshold in a calendar year, and it is
-- reportable on a CASH basis -- what was actually PAID in the year, not what
-- was accrued. ADR-0022 makes accrual the book of record and cash basis a
-- derivation, so the 1099 figure must be derived from PAYMENTS, never from the
-- consignor_payable accrual.
--
-- Getting this wrong is not a cosmetic bug. Filing late or wrong carries
-- per-form penalties, and the store carries backup-withholding exposure for
-- payees with no TIN on file.
--
-- WHAT THIS FILE PROVIDES
--   tax_form_threshold       the reportable minimum per form/box/year (data,
--                            not a hard-coded constant -- Congress moves it)
--   payee_tax_profile        per-party filing status: TIN on file, W-9
--                            received, exempt (corporations), backup
--                            withholding
--   tax_year_payment         the cash-basis payment ledger that feeds the form
--   record_reportable_payment()  idempotent capture of one payment
--   party_1099_total()       what a payee was actually paid in a year
--   form_1099_extract()      the filing worklist for a year
--   form_1099_exceptions()   what will BLOCK filing -- missing TIN, missing W-9
--   tax_1099_reconciliation_check()  1099 totals vs the GL
--
-- ADR-0034.
-- Run with: SET search_path = <tenant_schema>, kernel;
-- ============================================================================
\set ON_ERROR_STOP on

-- ----------------------------------------------------------------------------
-- Thresholds as DATA.
--
-- The 1099-NEC threshold was USD 600 for decades and is legislated, not
-- eternal. Recent law raises it and indexes it to inflation. Hard-coding 600
-- would mean a code change and a redeploy every time Congress acts, applied
-- retroactively to years that should keep their old threshold. Storing it
-- per (form, box, tax_year) means prior years keep filing correctly forever.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tax_form_threshold (
  tenant_id        uuid NOT NULL DEFAULT kernel.current_tenant(),
  form_code        text NOT NULL,
  box_code         text NOT NULL,
  tax_year         smallint NOT NULL,
  threshold_amount kernel.money_amount NOT NULL,
  currency         kernel.currency_code NOT NULL DEFAULT 'USD',
  note             text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, form_code, box_code, tax_year),
  CHECK (form_code IN ('1099-NEC','1099-MISC')),
  CHECK (threshold_amount >= 0),
  CHECK (tax_year BETWEEN 2000 AND 2100)
);
COMMENT ON TABLE tax_form_threshold IS
  'Reportable minimum per form/box/tax year. Data, not a constant: thresholds are legislated and change.';

-- Seeded here, immediately beside the table, rather than in the CoA seed file.
-- The CoA seeds run before the domain DDL, so a seed in 39_coa_tax.sql would
-- reference a table that does not exist yet. Keeping the legislated values next
-- to the table they populate also means one place to look when Congress moves.
--
--   through 2025 : USD 600   (unchanged for decades)
--   2026         : USD 2,000 (One Big Beautiful Bill Act, s.70433, 2025-07-04)
--   2027+        : USD 2,000 indexed for inflation -- the indexed figure is not
--                  yet published, so 2027 is seeded at the 2026 value and MUST
--                  be updated when the IRS publishes it. form_1099_threshold_for()
--                  falls back to the latest prior year on file, so an un-seeded
--                  future year uses the last known rule rather than zero
--                  (everyone reportable) or infinity (nobody reportable).
INSERT INTO tax_form_threshold (form_code, box_code, tax_year, threshold_amount, note) VALUES
  ('1099-NEC','nec', 2024, 600.00,   'Pre-OBBBA threshold.'),
  ('1099-NEC','nec', 2025, 600.00,   'Final year at 600; OBBBA raises it from 2026.'),
  ('1099-NEC','nec', 2026, 2000.00,  'OBBBA s.70433, effective tax year 2026.'),
  ('1099-NEC','nec', 2027, 2000.00,  'PLACEHOLDER: inflation-indexed from 2027. Update when IRS publishes.'),
  ('1099-MISC','rent',2024, 600.00,  'Pre-OBBBA threshold.'),
  ('1099-MISC','rent',2025, 600.00,  'Final year at 600.'),
  ('1099-MISC','rent',2026, 2000.00, 'OBBBA s.70433, effective tax year 2026.'),
  ('1099-MISC','rent',2027, 2000.00, 'PLACEHOLDER: inflation-indexed from 2027. Update when IRS publishes.')
ON CONFLICT (tenant_id, form_code, box_code, tax_year) DO NOTHING;

-- ----------------------------------------------------------------------------
-- Payee tax profile.
--
-- Separate from party because most parties are not payees and because these
-- facts have their own lifecycle: a W-9 is received on a date, a TIN is
-- certified or not, backup withholding switches on when the IRS says so.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS payee_tax_profile (
  party_id            uuid PRIMARY KEY REFERENCES party(id) ON DELETE RESTRICT,
  tenant_id           uuid NOT NULL DEFAULT kernel.current_tenant(),

  -- Corporations are generally exempt from 1099-NEC. Recording WHY keeps the
  -- decision auditable instead of someone silently ticking a box.
  is_exempt           boolean NOT NULL DEFAULT false,
  exempt_reason       text,

  w9_received_date    date,
  tin_type            text CHECK (tin_type IN ('ssn','ein','itin')),

  -- Backup withholding: the payer must withhold when the payee has not
  -- furnished a certified TIN, or the IRS has issued a B-notice. The RATE is
  -- stored because it is legislated and has changed (31% -> 28% -> 24%).
  backup_withholding          boolean NOT NULL DEFAULT false,
  backup_withholding_rate     kernel.percent_rate,

  -- Where the form gets mailed. Denormalised deliberately: the form must
  -- reflect the address as used at filing time, and the party's current
  -- address may change afterwards.
  recipient_name      text,
  recipient_address   text,

  notes               text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  created_by          uuid DEFAULT kernel.current_actor(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  updated_by          uuid DEFAULT kernel.current_actor(),
  version             integer NOT NULL DEFAULT 1,
  CHECK (NOT is_exempt OR exempt_reason IS NOT NULL),
  CHECK (NOT backup_withholding OR backup_withholding_rate IS NOT NULL)
);
COMMENT ON TABLE payee_tax_profile IS
  '1099 filing status per payee: TIN on file, W-9, exemption, backup withholding.';

CREATE TRIGGER trg_payee_tax_profile_audit
  BEFORE UPDATE ON payee_tax_profile
  FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- ----------------------------------------------------------------------------
-- tax_year_payment — the cash-basis payment ledger behind the form.
--
-- APPEND-ONLY, and linked to the journal entry that moved the cash. Two
-- reasons:
--   1. A 1099 is a legal assertion about money actually paid. It must be
--      reconstructable from the ledger, line by line, years later.
--   2. Deriving the figure by re-querying payouts at filing time gives a
--      different answer every time history is corrected. Capturing it at
--      payment time, and reversing rather than editing, keeps the filing
--      defensible.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tax_year_payment (
  id               uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id        uuid NOT NULL DEFAULT kernel.current_tenant(),
  party_id         uuid NOT NULL REFERENCES party(id) ON DELETE RESTRICT,
  tax_year         smallint NOT NULL,
  form_code        text NOT NULL DEFAULT '1099-NEC',
  box_code         text NOT NULL DEFAULT 'nec',
  payment_date     date NOT NULL,
  amount           kernel.money_amount NOT NULL,
  currency         kernel.currency_code NOT NULL DEFAULT 'USD',
  withheld_amount  kernel.money_amount NOT NULL DEFAULT 0,
  source           text NOT NULL,
  source_ref       text,
  journal_entry_id uuid REFERENCES journal_entry(id) ON DELETE RESTRICT,
  idempotency_key  text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  created_by       uuid DEFAULT kernel.current_actor(),
  CHECK (form_code IN ('1099-NEC','1099-MISC')),
  CHECK (withheld_amount >= 0),
  -- tax_year must match payment_date: a 1099 is a calendar-year statement and
  -- a mismatch here is a misfiled form.
  CHECK (tax_year = EXTRACT(YEAR FROM payment_date)::smallint)
);
COMMENT ON TABLE tax_year_payment IS
  'Append-only cash-basis payment ledger feeding 1099 extracts. Negative amounts are corrections.';

CREATE UNIQUE INDEX IF NOT EXISTS ux_tax_year_payment_idem
  ON tax_year_payment (tenant_id, idempotency_key) WHERE idempotency_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_tax_year_payment_party_year
  ON tax_year_payment (tenant_id, party_id, tax_year);
CREATE INDEX IF NOT EXISTS ix_tax_year_payment_year
  ON tax_year_payment (tenant_id, tax_year, form_code);

-- Append-only. Corrections are negative rows, exactly like the ledger's
-- reversal-not-edit rule, so the filed figure and its correction are both
-- visible.
DROP TRIGGER IF EXISTS trg_tax_year_payment_append_only ON tax_year_payment;
CREATE TRIGGER trg_tax_year_payment_append_only
  BEFORE UPDATE OR DELETE ON tax_year_payment
  FOR EACH ROW EXECUTE FUNCTION kernel.forbid_mutation();

-- ----------------------------------------------------------------------------
-- record_reportable_payment — capture one payment against a payee's tax year.
--
-- Idempotent. Skips exempt payees, because recording payments to a corporation
-- as reportable and filtering later invites the filter being forgotten.
-- Returns NULL when nothing was recorded.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION record_reportable_payment(
  p_party_id        uuid,
  p_payment_date    date,
  p_amount          kernel.money_amount,
  p_source          text,
  p_source_ref      text DEFAULT NULL,
  p_journal_entry   uuid DEFAULT NULL,
  p_idempotency_key text DEFAULT NULL,
  p_form_code       text DEFAULT '1099-NEC',
  p_box_code        text DEFAULT 'nec'
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_id      uuid;
  v_profile record;
  v_year    smallint := EXTRACT(YEAR FROM p_payment_date)::smallint;
  v_withheld kernel.money_amount := 0;
BEGIN
  IF p_amount = 0 THEN
    RETURN NULL;
  END IF;

  IF p_idempotency_key IS NOT NULL THEN
    SELECT id INTO v_id FROM tax_year_payment
      WHERE tenant_id = kernel.current_tenant()
        AND idempotency_key = p_idempotency_key;
    IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  END IF;

  SELECT * INTO v_profile FROM payee_tax_profile WHERE party_id = p_party_id;

  -- Exempt payees (corporations) are not tracked at all.
  IF v_profile.is_exempt THEN
    RETURN NULL;
  END IF;

  IF COALESCE(v_profile.backup_withholding, false) THEN
    v_withheld := round(p_amount * v_profile.backup_withholding_rate, 4);
  END IF;

  INSERT INTO tax_year_payment (
    party_id, tax_year, form_code, box_code, payment_date, amount,
    currency, withheld_amount, source, source_ref, journal_entry_id,
    idempotency_key
  ) VALUES (
    p_party_id, v_year, p_form_code, p_box_code, p_payment_date, p_amount,
    (SELECT functional_currency FROM tenant_config LIMIT 1),
    v_withheld, p_source, p_source_ref, p_journal_entry, p_idempotency_key
  ) RETURNING id INTO v_id;

  RETURN v_id;
END; $$;
COMMENT ON FUNCTION record_reportable_payment IS
  'Idempotently records a cash-basis reportable payment. Returns NULL for exempt payees or zero amounts.';

-- ----------------------------------------------------------------------------
-- party_1099_total — what a payee was actually paid in a calendar year.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION party_1099_total(
  p_party_id  uuid,
  p_tax_year  smallint,
  p_form_code text DEFAULT '1099-NEC'
) RETURNS kernel.money_amount
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(sum(amount), 0)::kernel.money_amount
    FROM tax_year_payment
   WHERE tenant_id = kernel.current_tenant()
     AND party_id  = p_party_id
     AND tax_year  = p_tax_year
     AND form_code = p_form_code;
$$;
COMMENT ON FUNCTION party_1099_total IS 'Cash-basis total paid to a payee in a tax year.';

-- ----------------------------------------------------------------------------
-- form_1099_threshold_for — the threshold in force for a form/box/year.
-- Falls back to the most recent PRIOR year on file rather than to a literal,
-- so an un-seeded future year uses the last known rule instead of zero (which
-- would make every payee reportable) or infinity (which would make none).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION form_1099_threshold_for(
  p_form_code text,
  p_box_code  text,
  p_tax_year  smallint
) RETURNS kernel.money_amount
LANGUAGE sql STABLE AS $$
  SELECT threshold_amount
    FROM tax_form_threshold
   WHERE tenant_id = kernel.current_tenant()
     AND form_code = p_form_code
     AND box_code  = p_box_code
     AND tax_year <= p_tax_year
   ORDER BY tax_year DESC
   LIMIT 1;
$$;
COMMENT ON FUNCTION form_1099_threshold_for IS
  'Threshold in force for a form/box/year; falls back to the most recent prior year on file.';

-- ----------------------------------------------------------------------------
-- form_1099_extract — the filing worklist for a tax year.
--
-- Returns every non-exempt payee with activity, whether or not they cross the
-- threshold, with is_reportable computed. Showing near-threshold payees is
-- deliberate: a payee at 595.00 is who you check for a missed payment before
-- filing.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION form_1099_extract(
  p_tax_year  smallint,
  p_form_code text DEFAULT '1099-NEC'
) RETURNS TABLE (
  party_id         uuid,
  recipient_name   text,
  tin_type         text,
  has_tin          boolean,
  w9_received      boolean,
  total_paid       kernel.money_amount,
  total_withheld   kernel.money_amount,
  threshold_amount kernel.money_amount,
  is_reportable    boolean,
  blocker          text
)
LANGUAGE sql STABLE AS $$
  WITH totals AS (
    SELECT t.party_id,
           t.box_code,
           sum(t.amount)          AS total_paid,
           sum(t.withheld_amount) AS total_withheld
      FROM tax_year_payment t
     WHERE t.tenant_id = kernel.current_tenant()
       AND t.tax_year  = p_tax_year
       AND t.form_code = p_form_code
     GROUP BY t.party_id, t.box_code
  )
  SELECT
    tot.party_id,
    COALESCE(ptp.recipient_name, p.display_name) AS recipient_name,
    ptp.tin_type,
    EXISTS (SELECT 1 FROM party_identifier pi
             WHERE pi.party_id = tot.party_id
               AND pi.identifier_type IN ('ssn','ein','tax_id')
               AND pi.deleted_at IS NULL)     AS has_tin,
    (ptp.w9_received_date IS NOT NULL)        AS w9_received,
    tot.total_paid::kernel.money_amount,
    tot.total_withheld::kernel.money_amount,
    COALESCE(form_1099_threshold_for(p_form_code, tot.box_code, p_tax_year), 0)
                                              AS threshold_amount,
    (tot.total_paid >= COALESCE(form_1099_threshold_for(p_form_code, tot.box_code, p_tax_year), 0))
                                              AS is_reportable,
    CASE
      WHEN tot.total_paid < COALESCE(form_1099_threshold_for(p_form_code, tot.box_code, p_tax_year), 0)
        THEN NULL
      WHEN NOT EXISTS (SELECT 1 FROM party_identifier pi
                        WHERE pi.party_id = tot.party_id
                          AND pi.identifier_type IN ('ssn','ein','tax_id')
                          AND pi.deleted_at IS NULL)
        THEN 'NO TIN ON FILE'
      WHEN ptp.w9_received_date IS NULL
        THEN 'NO W-9 ON FILE'
      WHEN COALESCE(ptp.recipient_address, '') = ''
        THEN 'NO RECIPIENT ADDRESS'
      ELSE NULL
    END                                       AS blocker
  FROM totals tot
  JOIN party p ON p.id = tot.party_id
  LEFT JOIN payee_tax_profile ptp ON ptp.party_id = tot.party_id
 WHERE COALESCE(ptp.is_exempt, false) = false
 ORDER BY tot.total_paid DESC;
$$;
COMMENT ON FUNCTION form_1099_extract IS
  'Filing worklist for a tax year: totals, threshold, reportability and blockers per payee.';

-- ----------------------------------------------------------------------------
-- form_1099_exceptions — only the rows that will stop you filing.
--
-- Run this in NOVEMBER, not in January. A missing W-9 is easy to chase while
-- the consignor is still trading and nearly impossible once they have gone.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION form_1099_exceptions(
  p_tax_year  smallint,
  p_form_code text DEFAULT '1099-NEC'
) RETURNS TABLE (
  party_id       uuid,
  recipient_name text,
  total_paid     kernel.money_amount,
  blocker        text
)
LANGUAGE sql STABLE AS $$
  SELECT e.party_id, e.recipient_name, e.total_paid, e.blocker
    FROM form_1099_extract(p_tax_year, p_form_code) e
   WHERE e.is_reportable AND e.blocker IS NOT NULL
   ORDER BY e.total_paid DESC;
$$;
COMMENT ON FUNCTION form_1099_exceptions IS
  'Reportable payees that cannot be filed yet (missing TIN, W-9 or address). Run before year end.';

-- ----------------------------------------------------------------------------
-- tax_1099_reconciliation_check — 1099 totals vs the GL.
--
-- The 1099 ledger is populated by application calls, so it can drift from the
-- cash actually paid. This compares what was captured as reportable against
-- the payments recorded in the ledger for the same payees and year. A nonzero
-- difference means a payment path exists that does not record 1099 data --
-- which is exactly the bug you want to find in November.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION tax_1099_reconciliation_check(p_tax_year smallint)
RETURNS TABLE (
  party_id      uuid,
  form_total    kernel.money_amount,
  ledger_total  kernel.money_amount,
  difference    kernel.money_amount
)
LANGUAGE sql STABLE AS $$
  WITH form AS (
    SELECT t.party_id, sum(t.amount) AS form_total
      FROM tax_year_payment t
     WHERE t.tenant_id = kernel.current_tenant()
       AND t.tax_year = p_tax_year
     GROUP BY t.party_id
  ),
  -- Cash actually paid out to these payees, from the consignor payout ledger.
  ledger AS (
    SELECT cs.consignor_party_id AS party_id,
           sum(cp.payout_amount) AS ledger_total
      FROM consignor_payout cp
      JOIN consignor_settlement cs ON cs.id = cp.settlement_id
     WHERE cp.tenant_id = kernel.current_tenant()
       AND EXTRACT(YEAR FROM cp.payout_date)::smallint = p_tax_year
       AND cp.method <> 'store_credit'   -- store credit is not a cash payment
     GROUP BY cs.consignor_party_id
  )
  SELECT COALESCE(f.party_id, l.party_id),
         COALESCE(f.form_total, 0)::kernel.money_amount,
         COALESCE(l.ledger_total, 0)::kernel.money_amount,
         (COALESCE(f.form_total, 0) - COALESCE(l.ledger_total, 0))::kernel.money_amount
    FROM form f
    FULL OUTER JOIN ledger l ON l.party_id = f.party_id
   WHERE COALESCE(f.form_total, 0) <> COALESCE(l.ledger_total, 0);
$$;
COMMENT ON FUNCTION tax_1099_reconciliation_check IS
  'Payees whose captured 1099 total differs from cash paid per the ledger. Empty result = reconciled.';

-- ----------------------------------------------------------------------------
-- v_1099_summary — quick per-year view for the dashboard.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_1099_summary AS
  SELECT tax_year,
         form_code,
         count(DISTINCT party_id) AS payee_count,
         sum(amount)              AS total_paid,
         sum(withheld_amount)     AS total_withheld
    FROM tax_year_payment
   WHERE tenant_id = kernel.current_tenant()
   GROUP BY tax_year, form_code
   ORDER BY tax_year DESC, form_code;
COMMENT ON VIEW v_1099_summary IS 'Per-year 1099 totals across all payees.';
