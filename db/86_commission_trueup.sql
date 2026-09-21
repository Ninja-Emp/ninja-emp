-- ============================================================================
-- Ninja EMP — 86_commission_trueup.sql  (TENANT-SCOPED)
--
-- PERCENTAGE-COMMISSION TRUE-UPS  (ADR-0037)
--
-- THE PROBLEM
-- ADR-0028 accrues the consignor split AT SALE, which is right: the store owes
-- the consignor the moment the goods leave. But a TIERED commission rule
-- cannot be evaluated correctly one sale at a time.
--
-- Take "40% commission, dropping to 30% on cumulative sales above $5,000 in a
-- period". At the time of a given sale the store does not yet know where that
-- sale sits in the consignor's cumulative total for the period. Charging the
-- flat 40% at sale time and never revisiting it means every high-volume
-- consignor is systematically OVERCHARGED. Charging 30% optimistically means
-- every low-volume consignor is undercharged. Either way the store is wrong,
-- and it is wrong in a direction that compounds with volume: the best
-- consignors are the most overcharged, and they are the ones who leave.
--
-- THE FIX
-- Accrue at the sale-time rate (unchanged — ADR-0028 stands, the payable must
-- be real from the moment of sale), then compute the CORRECT tiered commission
-- over the whole period and post the DIFFERENCE as an adjusting entry.
--
-- This is exactly how percentage rent is trued up in 83_lease_trueup.sql, and
-- deliberately so: same shape of problem, same shape of answer. Accrue on the
-- best information available, true up when the period is known, never edit
-- history.
--
-- WHY NOT JUST RECALCULATE THE ORIGINAL LINES
-- Because the sale is posted, the period may be closed, and the consignor may
-- already have been paid. Rewriting the accrual would silently change a
-- settlement the consignor has already received a cheque for. The true-up is
-- a NEW, visible, reversible entry. Reversal-not-edit, all the way down.
--
-- Run with: SET search_path = <tenant_schema>, kernel;
-- ============================================================================
\set ON_ERROR_STOP on

-- ----------------------------------------------------------------------------
-- commission_trueup — one period adjustment for one consignor.
--
-- Records BOTH sides of the arithmetic (what was accrued, what was correct)
-- rather than just the delta, so the adjustment can be explained to the
-- consignor without re-deriving it from the whole sales history.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS commission_trueup (
  id                  uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id           uuid NOT NULL DEFAULT kernel.current_tenant(),
  agreement_id        uuid NOT NULL REFERENCES consignor_agreement(id) ON DELETE RESTRICT,
  consignor_party_id  uuid NOT NULL REFERENCES party(id) ON DELETE RESTRICT,

  period_start        date NOT NULL,
  period_end          date NOT NULL,

  gross_sales         kernel.money_amount NOT NULL DEFAULT 0,
  -- What the sale lines actually charged, summed.
  accrued_commission  kernel.money_amount NOT NULL DEFAULT 0,
  -- What the tiered rule says it should have been.
  correct_commission  kernel.money_amount NOT NULL DEFAULT 0,
  -- correct - accrued. POSITIVE = store under-charged, consignor owes the
  -- store. NEGATIVE = store over-charged, store owes the consignor.
  adjustment_amount   kernel.money_amount NOT NULL DEFAULT 0,

  currency            kernel.currency_code NOT NULL DEFAULT 'USD',
  effective_rate      kernel.percent_rate,

  status              text NOT NULL DEFAULT 'draft'
                        CHECK (status IN ('draft','posted','voided')),
  journal_entry_id    uuid REFERENCES journal_entry(id) ON DELETE RESTRICT,
  note                text,

  created_at          timestamptz NOT NULL DEFAULT now(),
  created_by          uuid DEFAULT kernel.current_actor(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  updated_by          uuid DEFAULT kernel.current_actor(),
  version             integer NOT NULL DEFAULT 1,

  CHECK (period_end >= period_start),
  CHECK (adjustment_amount = correct_commission - accrued_commission)
);
COMMENT ON TABLE commission_trueup IS
  'Period adjustment reconciling sale-time commission accrual to the correct tiered rate (ADR-0037).';

-- One true-up per agreement per period. Running it twice must not double-bill.
CREATE UNIQUE INDEX IF NOT EXISTS ux_commission_trueup_period
  ON commission_trueup (tenant_id, agreement_id, period_start, period_end)
  WHERE status <> 'voided';
CREATE INDEX IF NOT EXISTS ix_commission_trueup_party
  ON commission_trueup (consignor_party_id);

CREATE TRIGGER trg_commission_trueup_audit
  BEFORE UPDATE ON commission_trueup FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- ----------------------------------------------------------------------------
-- tiered_commission — evaluate a tiered rule over a cumulative amount.
--
-- MARGINAL, not cliff. A breakpoint of 5000 with base 40% and tier 30% means
-- the first 5000 is charged at 40% and only the EXCESS at 30%. A cliff rate
-- (the whole amount re-rated once the breakpoint is crossed) is the other
-- plausible reading, and it produces the absurdity that selling one more
-- dollar of goods can increase the consignor's net by hundreds. Marginal is
-- the only structure that is monotonic, and monotonicity is what stops the
-- incentive being perverse.
--
-- Returns the total commission for p_gross under the agreement's rules in
-- force on p_as_of.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION tiered_commission(
  p_agreement_id uuid,
  p_gross        kernel.money_amount,
  p_as_of        date DEFAULT current_date
) RETURNS kernel.money_amount
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_base_rate  kernel.percent_rate;
  v_rule       record;
  v_commission kernel.money_amount := 0;
  v_prev_bp    kernel.money_amount := 0;
  v_band       kernel.money_amount;
BEGIN
  IF p_gross IS NULL OR p_gross <= 0 THEN RETURN 0; END IF;

  -- Base (flat) rate in force on the date. Falls back to the agreement default
  -- so an agreement with no explicit rule still produces a defensible number
  -- rather than zero commission.
  SELECT cr.rate INTO v_base_rate
    FROM commission_rule cr
   WHERE cr.agreement_id = p_agreement_id
     AND cr.rule_type = 'flat'
     AND p_as_of BETWEEN cr.effective_from AND COALESCE(cr.effective_thru, 'infinity'::date)
   ORDER BY cr.effective_from DESC
   LIMIT 1;

  IF v_base_rate IS NULL THEN
    SELECT default_commission_rate INTO v_base_rate
      FROM consignor_agreement WHERE id = p_agreement_id;
  END IF;
  IF v_base_rate IS NULL THEN
    RAISE EXCEPTION 'No commission rate resolvable for agreement %', p_agreement_id
      USING ERRCODE='23503';
  END IF;

  -- Walk the tiers in breakpoint order, charging each band at its own rate.
  FOR v_rule IN
    SELECT cr.rate, cr.breakpoint_amount
      FROM commission_rule cr
     WHERE cr.agreement_id = p_agreement_id
       AND cr.rule_type = 'tiered'
       AND cr.breakpoint_amount IS NOT NULL
       AND p_as_of BETWEEN cr.effective_from AND COALESCE(cr.effective_thru, 'infinity'::date)
     ORDER BY cr.breakpoint_amount
  LOOP
    EXIT WHEN p_gross <= v_rule.breakpoint_amount;
    -- Band from the previous breakpoint up to this one, at the rate that
    -- applies BELOW this breakpoint.
    v_band := v_rule.breakpoint_amount - v_prev_bp;
    v_commission := v_commission + round(v_band * v_base_rate, 4);
    v_base_rate  := v_rule.rate;   -- above this breakpoint, the tier rate rules
    v_prev_bp    := v_rule.breakpoint_amount;
  END LOOP;

  -- Whatever is left above the last crossed breakpoint.
  v_commission := v_commission + round((p_gross - v_prev_bp) * v_base_rate, 4);

  RETURN v_commission;
END; $$;
COMMENT ON FUNCTION tiered_commission IS
  'Marginal tiered commission on a cumulative gross. Each band charged at its own rate (ADR-0037).';

-- ----------------------------------------------------------------------------
-- commission_period_actuals — what the sale lines actually charged.
--
-- Covers BOTH sale paths: the POS sale_line table and the consignment_sale_line
-- table. A store that rings consigned goods through the register and also
-- records direct consignment sales would otherwise true up against half its
-- volume, which is worse than not truing up at all because it looks right.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION commission_period_actuals(
  p_agreement_id uuid,
  p_start        date,
  p_end          date
) RETURNS TABLE (gross_sales numeric, accrued_commission numeric)
LANGUAGE sql STABLE AS $$
  WITH ag AS (
    SELECT id, consignor_party_id FROM consignor_agreement WHERE id = p_agreement_id
  ),
  pos AS (
    -- POS lines, net of refunds. A refund document carries is_refund and its
    -- lines must SUBTRACT, or a returned item leaves phantom commission in the
    -- period and the true-up over-bills the consignor.
    SELECT COALESCE(sum(CASE WHEN s.is_refund THEN -sl.extended_price
                             ELSE sl.extended_price END), 0) AS gross,
           COALESCE(sum(CASE WHEN s.is_refund THEN -sl.commission_amount
                             ELSE sl.commission_amount END), 0) AS comm
      FROM sale_line sl
      JOIN sale s ON s.id = sl.sale_id
      JOIN ag    ON ag.consignor_party_id = sl.consignor_party_id
     WHERE sl.line_kind = 'consignment'
       AND s.status IN ('completed','partially_refunded','refunded')
       AND s.deleted_at IS NULL
       AND s.sale_date BETWEEN p_start AND p_end
  ),
  csale AS (
    SELECT COALESCE(sum(csl.sale_price), 0)       AS gross,
           COALESCE(sum(csl.commission_amount), 0) AS comm
      FROM consignment_sale_line csl
      JOIN consignment_sale cs ON cs.id = csl.sale_id
      JOIN ag ON ag.consignor_party_id = csl.consignor_party_id
     WHERE cs.status = 'completed'
       AND cs.sale_date BETWEEN p_start AND p_end
  )
  SELECT (pos.gross + csale.gross)::numeric,
         (pos.comm  + csale.comm)::numeric
    FROM pos, csale;
$$;
COMMENT ON FUNCTION commission_period_actuals IS
  'Gross sales and commission actually accrued for an agreement in a period, across POS and consignment sales, net of refunds.';

-- ----------------------------------------------------------------------------
-- compute_commission_trueup — what the adjustment WOULD be. Reads only.
--
-- Separated from the posting function on purpose: the store needs to be able
-- to show a consignor the number and discuss it before anything hits the
-- ledger.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION compute_commission_trueup(
  p_agreement_id uuid,
  p_start        date,
  p_end          date
) RETURNS TABLE (
  gross_sales        numeric,
  accrued_commission numeric,
  correct_commission numeric,
  adjustment_amount  numeric,
  effective_rate     numeric
)
LANGUAGE sql STABLE AS $$
  WITH act AS (
    SELECT * FROM commission_period_actuals(p_agreement_id, p_start, p_end)
  ),
  calc AS (
    SELECT act.gross_sales,
           act.accrued_commission,
           tiered_commission(p_agreement_id, act.gross_sales::kernel.money_amount, p_end)::numeric
             AS correct_commission
      FROM act
  )
  SELECT calc.gross_sales,
         calc.accrued_commission,
         calc.correct_commission,
         (calc.correct_commission - calc.accrued_commission),
         CASE WHEN calc.gross_sales = 0 THEN NULL
              ELSE round(calc.correct_commission / calc.gross_sales, 6) END
    FROM calc;
$$;
COMMENT ON FUNCTION compute_commission_trueup IS
  'Dry run: what the period commission adjustment would be. Posts nothing.';

-- ----------------------------------------------------------------------------
-- post_commission_trueup — post the adjustment.
--
-- Sign discipline, because this is where these things go wrong:
--
--   adjustment > 0  store UNDER-charged commission. It should have kept more.
--                   debit  consignor_payable_control  (owe the consignor less)
--                   credit commission_revenue         (store earned more)
--
--   adjustment < 0  store OVER-charged commission. It owes the consignor back.
--                   debit  commission_revenue         (give back the revenue)
--                   credit consignor_payable_control  (owe the consignor more)
--
-- Idempotent on the period. Returns NULL when there is nothing to adjust,
-- which is the common and correct case for flat-rate agreements.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION post_commission_trueup(
  p_agreement_id    uuid,
  p_start           date,
  p_end             date,
  p_entry_date      date,
  p_idempotency_key text
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_ag     record;
  v_calc   record;
  v_ccy    kernel.currency_code;
  v_entry  uuid;
  v_lines  jsonb;
  v_id     uuid;
  v_abs    kernel.money_amount;
BEGIN
  -- Idempotency FIRST, before any computation, so a replay cannot produce a
  -- second adjustment just because sales data moved underneath it.
  SELECT id, journal_entry_id INTO v_id, v_entry
    FROM commission_trueup
   WHERE agreement_id = p_agreement_id
     AND period_start = p_start AND period_end = p_end
     AND status <> 'voided';
  IF v_id IS NOT NULL THEN RETURN v_entry; END IF;

  SELECT * INTO v_ag FROM consignor_agreement WHERE id = p_agreement_id;
  IF v_ag IS NULL THEN
    RAISE EXCEPTION 'Consignor agreement % not found', p_agreement_id USING ERRCODE='23503';
  END IF;

  SELECT * INTO v_calc FROM compute_commission_trueup(p_agreement_id, p_start, p_end);

  -- Nothing sold, or the accrual was already right. Record nothing: an
  -- adjustment of zero is noise in the ledger and in the consignor's statement.
  IF v_calc.gross_sales = 0 OR v_calc.adjustment_amount = 0 THEN
    RETURN NULL;
  END IF;

  v_ccy := (SELECT functional_currency FROM tenant_config LIMIT 1);
  v_abs := abs(v_calc.adjustment_amount);

  IF v_calc.adjustment_amount > 0 THEN
    -- Under-charged: store keeps more, consignor gets less.
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', posting_account('consignor_payable_control'),
                         'debit', v_abs, 'currency', v_ccy,
                         'party_id', v_ag.consignor_party_id,
                         'subledger_type_code', 'consignor_payable',
                         'memo', 'Commission true-up ' || p_start || '..' || p_end),
      jsonb_build_object('account_id', posting_account('commission_revenue'),
                         'credit', v_abs, 'currency', v_ccy,
                         'memo', 'Commission true-up ' || p_start || '..' || p_end)
    );
  ELSE
    -- Over-charged: store gives revenue back, consignor is owed more.
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', posting_account('commission_revenue'),
                         'debit', v_abs, 'currency', v_ccy,
                         'memo', 'Commission true-up (refund) ' || p_start || '..' || p_end),
      jsonb_build_object('account_id', posting_account('consignor_payable_control'),
                         'credit', v_abs, 'currency', v_ccy,
                         'party_id', v_ag.consignor_party_id,
                         'subledger_type_code', 'consignor_payable',
                         'memo', 'Commission true-up (refund) ' || p_start || '..' || p_end)
    );
  END IF;

  v_entry := post_journal_entry(
    p_entry_date,
    'Commission true-up for agreement ' || v_ag.agreement_no,
    'commission_trueup', p_agreement_id::text, p_idempotency_key, v_lines);

  INSERT INTO commission_trueup (
    agreement_id, consignor_party_id, period_start, period_end,
    gross_sales, accrued_commission, correct_commission, adjustment_amount,
    currency, effective_rate, status, journal_entry_id
  ) VALUES (
    p_agreement_id, v_ag.consignor_party_id, p_start, p_end,
    v_calc.gross_sales, v_calc.accrued_commission, v_calc.correct_commission,
    v_calc.adjustment_amount, v_ccy, v_calc.effective_rate, 'posted', v_entry
  );

  -- Open-item detail so the adjustment shows on the consignor's statement
  -- rather than appearing only as a mystery movement in the control account.
  --
  -- BOTH directions must be recorded, not just the one that owes the consignor
  -- more. The first version only wrote an open item for a negative adjustment.
  -- A POSITIVE adjustment still debits consignor_payable_control -- reducing
  -- what the store owes -- so skipping the subledger row left the GL saying
  -- one thing and the consignor's statement saying another, and
  -- open_item_control_check() went permanently out of balance by the amount of
  -- every under-charge true-up ever posted.
  --
  -- A reduction is a CREDIT MEMO, not a negative invoice: open_item_create()
  -- converts the negative amount into one, and open_item_signed() nets it off
  -- the balance. This is exactly what item_kind was added for.
  PERFORM open_item_create(
    'consignor_payable', v_ag.consignor_party_id,
    'commission_trueup', p_agreement_id::text,
    'CTU-' || v_ag.agreement_no || '-' || to_char(p_end,'YYYYMM'),
    CASE WHEN v_calc.adjustment_amount < 0 THEN v_abs ELSE -v_abs END,
    v_ccy, p_entry_date, NULL, v_entry);

  RETURN v_entry;
END; $$;
COMMENT ON FUNCTION post_commission_trueup IS
  'Idempotent per-period commission adjustment. Positive = store under-charged; negative = store owes the consignor.';

-- ----------------------------------------------------------------------------
-- v_commission_trueup_pending — agreements with tiered rules whose period has
-- ended and which have no true-up yet. The worklist.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_commission_trueup_pending AS
  SELECT ca.id AS agreement_id,
         ca.agreement_no,
         p.display_name AS consignor_name,
         ca.settlement_frequency,
         count(cr.id) AS tier_count
    FROM consignor_agreement ca
    JOIN party p ON p.id = ca.consignor_party_id
    JOIN commission_rule cr ON cr.agreement_id = ca.id AND cr.rule_type = 'tiered'
   WHERE ca.status = 'active'
     AND ca.deleted_at IS NULL
   GROUP BY ca.id, ca.agreement_no, p.display_name, ca.settlement_frequency
   ORDER BY ca.agreement_no;
COMMENT ON VIEW v_commission_trueup_pending IS
  'Active agreements carrying tiered commission rules; these need periodic true-up.';
