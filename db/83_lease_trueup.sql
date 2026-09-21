-- ============================================================================
-- Ninja EMP — 83_lease_trueup.sql  (TENANT-SCOPED)
--
-- Percentage rent true-up, CAM reconciliation, and lease renewals/escalations.
--
-- THE GAP THIS CLOSES
-- post_rent_invoice() bills the FIXED components and explicitly skips
-- percentage_rent, because percentage rent cannot be known in advance: it is a
-- share of sales above a breakpoint, so it is only computable after the sales
-- have happened. Until now nothing ever came back to compute it, which means
-- percentage rent was never billed at all. Same story for CAM: the lease bills
-- an ESTIMATE monthly, and the landlord must reconcile to actual cost at year
-- end and bill or credit the difference. Neither existed.
--
-- WHAT THIS FILE PROVIDES
--   lease_sales_report          reported sales per lease per period
--   percentage_rent_due()       computes the amount over the breakpoint
--   post_percentage_rent_trueup()  bills it, idempotently
--   cam_pool / cam_pool_expense    the actual recoverable cost pool
--   cam_reconciliation()        pro-rata share vs estimates already billed
--   post_cam_reconciliation()   bills or credits the difference
--   renew_lease() / apply_rent_escalation()  term and rate changes
--
-- ADR-0035.
-- Run with: SET search_path = <tenant_schema>, kernel;
-- ============================================================================
\set ON_ERROR_STOP on

-- ----------------------------------------------------------------------------
-- lease_sales_report — sales for a lease in a period.
--
-- Why a table rather than always summing POS: percentage rent is usually
-- computed on sales AS REPORTED BY THE TENANT, which is a contractual figure
-- that may legitimately differ from what passed through the mall's POS (online
-- sales, returns handled elsewhere, excluded categories). Recording the
-- reported figure alongside the POS figure makes the variance visible, which
-- is exactly what an audit clause exists to check.
--
-- For a vendor mall where all sales DO run through the house POS,
-- lease_pos_sales() computes the figure and reported_amount simply agrees.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS lease_sales_report (
  id               uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id        uuid NOT NULL DEFAULT kernel.current_tenant(),
  lease_id         uuid NOT NULL REFERENCES lease(id) ON DELETE RESTRICT,
  period_start     date NOT NULL,
  period_end       date NOT NULL,
  reported_amount  kernel.money_amount NOT NULL,
  pos_amount       kernel.money_amount,
  currency         kernel.currency_code NOT NULL DEFAULT 'USD',
  source           text NOT NULL DEFAULT 'tenant_reported'
                     CHECK (source IN ('tenant_reported','pos','audited')),
  received_date    date NOT NULL DEFAULT current_date,
  notes            text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  created_by       uuid DEFAULT kernel.current_actor(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  updated_by       uuid DEFAULT kernel.current_actor(),
  version          integer NOT NULL DEFAULT 1,
  CHECK (period_end >= period_start),
  CHECK (reported_amount >= 0),
  UNIQUE (tenant_id, lease_id, period_start, period_end)
);
COMMENT ON TABLE lease_sales_report IS
  'Sales reported by a lessee for a period. Drives percentage rent. pos_amount records the variance.';

CREATE INDEX IF NOT EXISTS ix_lease_sales_report_lease
  ON lease_sales_report (lease_id, period_start);
CREATE TRIGGER trg_lease_sales_report_audit
  BEFORE UPDATE ON lease_sales_report
  FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- ----------------------------------------------------------------------------
-- lease_pos_sales — what the house POS recorded for this lease's vendor.
-- Net of refunds: a refund reduces reportable sales, and billing percentage
-- rent on gross would overcharge the tenant.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lease_pos_sales(
  p_lease_id     uuid,
  p_period_start date,
  p_period_end   date
) RETURNS kernel.money_amount
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(sum(
           CASE WHEN s.is_refund THEN -sl.extended_price ELSE sl.extended_price END
         ), 0)::kernel.money_amount
    FROM sale_line sl
    JOIN sale s ON s.id = sl.sale_id
   WHERE sl.tenant_id = kernel.current_tenant()
     AND s.deleted_at IS NULL
     AND s.status = 'completed'
     AND s.sale_date BETWEEN p_period_start AND p_period_end
     AND sl.vendor_party_id = (SELECT lessee_party_id FROM lease WHERE id = p_lease_id);
$$;
COMMENT ON FUNCTION lease_pos_sales IS
  'Net POS sales (sales less refunds) for a lease''s lessee in a period.';

-- ----------------------------------------------------------------------------
-- percentage_rent_due — the amount owed for a period, net of what was billed.
--
-- Natural (annual) breakpoint: rent is due on sales ABOVE the breakpoint only.
-- Returns 0 rather than a negative when sales fall short -- a tenant below the
-- breakpoint owes nothing, they do not earn a refund of base rent.
--
-- Subtracting percentage rent ALREADY billed for overlapping periods is what
-- makes this safe to run monthly, quarterly and again at year end without
-- double-billing.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION percentage_rent_due(
  p_lease_id     uuid,
  p_period_start date,
  p_period_end   date,
  p_sales_amount kernel.money_amount DEFAULT NULL
) RETURNS kernel.money_amount
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_comp        record;
  v_sales       kernel.money_amount;
  v_over        kernel.money_amount;
  v_gross       kernel.money_amount := 0;
  v_already     kernel.money_amount := 0;
BEGIN
  SELECT * INTO v_comp
    FROM rent_component
   WHERE lease_id = p_lease_id
     AND component_type_code = 'percentage_rent'
     AND effective_from <= p_period_end
     AND (effective_thru IS NULL OR effective_thru >= p_period_start)
   ORDER BY effective_from DESC
   LIMIT 1;

  IF v_comp IS NULL THEN
    RETURN 0;   -- no percentage rent clause on this lease
  END IF;

  -- Prefer an explicit figure, then the tenant's report, then the POS.
  v_sales := COALESCE(
    p_sales_amount,
    (SELECT reported_amount FROM lease_sales_report
      WHERE lease_id = p_lease_id
        AND period_start = p_period_start AND period_end = p_period_end),
    lease_pos_sales(p_lease_id, p_period_start, p_period_end)
  );

  v_over := GREATEST(v_sales - COALESCE(v_comp.breakpoint_amount, 0), 0);
  v_gross := round(v_over * v_comp.percent_rate, 4);

  -- Percentage rent already billed for any overlapping period.
  --
  -- Reads journal_entry_STATUS, not journal_entry. The journal is append-only,
  -- so reversal is DERIVED (30_ledger.sql) and reversed_by_id exists only on
  -- the view. Querying the base table here would both fail and, worse, count
  -- reversed billings as still outstanding -- under-billing the tenant.
  SELECT COALESCE(sum(jl.credit), 0) INTO v_already
    FROM journal_line jl
    JOIN journal_entry_status je ON je.id = jl.journal_entry_id
   WHERE je.source = 'percentage_rent'
     AND je.source_ref = p_lease_id::text
     AND je.reversed_by_id IS NULL
     AND jl.account_id = posting_account('percentage_rent_revenue')
     AND je.entry_date BETWEEN p_period_start AND p_period_end + 180;

  RETURN GREATEST(v_gross - v_already, 0);
END; $$;
COMMENT ON FUNCTION percentage_rent_due IS
  'Percentage rent owed for a period over the breakpoint, net of amounts already billed.';

-- ----------------------------------------------------------------------------
-- post_percentage_rent_trueup — bill the percentage rent.
-- Debits AR (lessee), credits percentage rent revenue, opens an AR item.
-- Returns NULL when nothing is due, so callers can run it on every lease.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION post_percentage_rent_trueup(
  p_lease_id        uuid,
  p_period_start    date,
  p_period_end      date,
  p_entry_date      date,
  p_idempotency_key text,
  p_sales_amount    kernel.money_amount DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_lease  record;
  v_amount kernel.money_amount;
  v_entry  uuid;
  v_ccy    kernel.currency_code := (SELECT functional_currency FROM tenant_config LIMIT 1);
BEGIN
  SELECT * INTO v_lease FROM lease WHERE id = p_lease_id AND deleted_at IS NULL;
  IF v_lease IS NULL THEN
    RAISE EXCEPTION 'Lease % not found', p_lease_id USING ERRCODE='23503';
  END IF;

  -- Idempotency first: a re-run must return the original entry, not recompute
  -- against a ledger that already contains the first posting.
  SELECT id INTO v_entry FROM journal_entry
   WHERE idempotency_key = p_idempotency_key AND tenant_id = kernel.current_tenant();
  IF v_entry IS NOT NULL THEN RETURN v_entry; END IF;

  v_amount := percentage_rent_due(p_lease_id, p_period_start, p_period_end, p_sales_amount);

  IF v_amount <= 0 THEN
    RETURN NULL;   -- below breakpoint, or already fully billed
  END IF;

  v_entry := post_journal_entry(
    p_entry_date,
    'Percentage rent lease ' || v_lease.lease_no || ' ' || p_period_start || '..' || p_period_end,
    'percentage_rent', p_lease_id::text, p_idempotency_key,
    jsonb_build_array(
      jsonb_build_object(
        'account_id', posting_account('ar_control'),
        'debit', v_amount, 'currency', v_ccy,
        'party_id', v_lease.lessee_party_id,
        'subledger_type_code', 'ar',
        'memo', 'Percentage rent lease ' || v_lease.lease_no),
      jsonb_build_object(
        'account_id', posting_account('percentage_rent_revenue'),
        'credit', v_amount, 'currency', v_ccy,
        'memo', 'Percentage rent ' || p_period_start || '..' || p_period_end)
    )
  );

  IF NOT EXISTS (SELECT 1 FROM open_item WHERE journal_entry_id = v_entry) THEN
    PERFORM open_item_create(
      'ar', v_lease.lessee_party_id, 'percentage_rent', p_lease_id::text,
      'PCTRENT-' || v_lease.lease_no || '-' || to_char(p_period_end, 'YYYYMM'),
      v_amount, v_ccy, p_entry_date,
      (date_trunc('month', p_entry_date) + interval '1 month'
        + (LEAST(v_lease.billing_day, 28) - 1) * interval '1 day')::date,
      v_entry
    );
  END IF;

  RETURN v_entry;
END; $$;
COMMENT ON FUNCTION post_percentage_rent_trueup IS
  'Idempotently bills percentage rent for a period. Returns NULL when nothing is due.';

-- ============================================================================
-- CAM RECONCILIATION
-- ============================================================================

-- ----------------------------------------------------------------------------
-- cam_pool — a recoverable cost pool for a location and year.
--
-- CAM is billed monthly as an ESTIMATE and reconciled annually to actual.
-- The pool holds the actual recoverable spend; each lessee pays a pro-rata
-- share, normally by leased area.
--
-- admin_fee_rate: most leases let the landlord add a management fee to the
-- pool. Storing the rate rather than folding it into the costs keeps the
-- reconciliation statement explainable to a tenant who asks.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS cam_pool (
  id              uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id       uuid NOT NULL DEFAULT kernel.current_tenant(),
  location_id     uuid NOT NULL REFERENCES location(id) ON DELETE RESTRICT,
  pool_year       smallint NOT NULL,
  period_start    date NOT NULL,
  period_end      date NOT NULL,
  admin_fee_rate  kernel.percent_rate NOT NULL DEFAULT 0,
  status          text NOT NULL DEFAULT 'open'
                    CHECK (status IN ('open','reconciled','closed')),
  currency        kernel.currency_code NOT NULL DEFAULT 'USD',
  notes           text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  created_by      uuid DEFAULT kernel.current_actor(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  updated_by      uuid DEFAULT kernel.current_actor(),
  version         integer NOT NULL DEFAULT 1,
  CHECK (period_end >= period_start),
  UNIQUE (tenant_id, location_id, pool_year)
);
COMMENT ON TABLE cam_pool IS
  'Annual recoverable CAM cost pool for a location. Reconciled against estimates billed.';

CREATE TRIGGER trg_cam_pool_audit
  BEFORE UPDATE ON cam_pool FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

CREATE TABLE IF NOT EXISTS cam_pool_expense (
  id             uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id      uuid NOT NULL DEFAULT kernel.current_tenant(),
  cam_pool_id    uuid NOT NULL REFERENCES cam_pool(id) ON DELETE RESTRICT,
  expense_date   date NOT NULL,
  category       text NOT NULL,
  amount         kernel.money_amount NOT NULL,
  currency       kernel.currency_code NOT NULL DEFAULT 'USD',
  -- Not every cost in the pool is recoverable. Capital improvements and the
  -- landlord's own legal fees usually are not. Recording the exclusion keeps
  -- the pool defensible when a tenant audits it.
  is_recoverable boolean NOT NULL DEFAULT true,
  exclusion_reason text,
  journal_entry_id uuid REFERENCES journal_entry(id) ON DELETE RESTRICT,
  description    text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  created_by     uuid DEFAULT kernel.current_actor(),
  CHECK (is_recoverable OR exclusion_reason IS NOT NULL)
);
COMMENT ON TABLE cam_pool_expense IS
  'Individual costs in a CAM pool. is_recoverable=false keeps non-recoverable spend visible but excluded.';

CREATE INDEX IF NOT EXISTS ix_cam_pool_expense_pool ON cam_pool_expense (cam_pool_id);

-- ----------------------------------------------------------------------------
-- lease_pro_rata_share — a lease's share of a location, by leased area.
--
-- Denominator is LEASED area, not total area: vacant space is the landlord's
-- cost to carry, not the sitting tenants'. Charging occupied tenants for empty
-- units is a classic CAM overcharge and a common source of disputes.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lease_pro_rata_share(
  p_lease_id   uuid,
  p_location_id uuid,
  p_as_of      date
) RETURNS numeric
LANGUAGE sql STABLE AS $$
  WITH occupied AS (
    SELECT ls.lease_id,
           sum(COALESCE(ls.allocated_area_sqft, sp.area_sqft, 0)) AS area
      FROM lease_space ls
      JOIN space sp ON sp.id = ls.space_id
      JOIN lease  l  ON l.id  = ls.lease_id
     WHERE l.location_id = p_location_id
       AND l.deleted_at IS NULL
       AND ls.from_date <= p_as_of
       AND (ls.thru_date IS NULL OR ls.thru_date >= p_as_of)
     GROUP BY ls.lease_id
  )
  SELECT CASE
           WHEN (SELECT sum(area) FROM occupied) IS NULL
             OR (SELECT sum(area) FROM occupied) = 0 THEN 0
           ELSE round(
             COALESCE((SELECT area FROM occupied WHERE lease_id = p_lease_id), 0)
             / (SELECT sum(area) FROM occupied), 10)
         END;
$$;
COMMENT ON FUNCTION lease_pro_rata_share IS
  'Lease share of a location by leased area. Denominator excludes vacant space.';

-- ----------------------------------------------------------------------------
-- cam_reconciliation — the statement: share of actual vs estimates billed.
-- Positive balance_due = the lessee owes more. Negative = they are owed a credit.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cam_reconciliation(p_cam_pool_id uuid)
RETURNS TABLE (
  lease_id          uuid,
  lessee_party_id   uuid,
  pro_rata_share    numeric,
  recoverable_pool  kernel.money_amount,
  admin_fee         kernel.money_amount,
  share_of_pool     kernel.money_amount,
  estimates_billed  kernel.money_amount,
  balance_due       kernel.money_amount
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_pool        record;
  v_recoverable kernel.money_amount;
  v_admin       kernel.money_amount;
  v_total       kernel.money_amount;
BEGIN
  SELECT * INTO v_pool FROM cam_pool WHERE id = p_cam_pool_id;
  IF v_pool IS NULL THEN
    RAISE EXCEPTION 'CAM pool % not found', p_cam_pool_id USING ERRCODE='23503';
  END IF;

  SELECT COALESCE(sum(amount), 0) INTO v_recoverable
    FROM cam_pool_expense
   WHERE cam_pool_id = p_cam_pool_id AND is_recoverable;

  v_admin := round(v_recoverable * v_pool.admin_fee_rate, 4);
  v_total := v_recoverable + v_admin;

  RETURN QUERY
  SELECT l.id,
         l.lessee_party_id,
         lease_pro_rata_share(l.id, v_pool.location_id, v_pool.period_end),
         v_recoverable,
         v_admin,
         round(v_total * lease_pro_rata_share(l.id, v_pool.location_id, v_pool.period_end), 4)::kernel.money_amount,
         COALESCE((
           SELECT sum(jl.credit)
             FROM journal_line jl
             JOIN journal_entry_status je ON je.id = jl.journal_entry_id
            WHERE je.source = 'rent'
              AND je.source_ref = l.id::text
              AND je.reversed_by_id IS NULL
              AND jl.account_id = posting_account('cam_revenue')
              AND je.entry_date BETWEEN v_pool.period_start AND v_pool.period_end
         ), 0)::kernel.money_amount,
         (round(v_total * lease_pro_rata_share(l.id, v_pool.location_id, v_pool.period_end), 4)
          - COALESCE((
              SELECT sum(jl.credit)
                FROM journal_line jl
                JOIN journal_entry_status je ON je.id = jl.journal_entry_id
               WHERE je.source = 'rent'
                 AND je.source_ref = l.id::text
                 AND je.reversed_by_id IS NULL
                 AND jl.account_id = posting_account('cam_revenue')
                 AND je.entry_date BETWEEN v_pool.period_start AND v_pool.period_end
            ), 0))::kernel.money_amount
    FROM lease l
   WHERE l.location_id = v_pool.location_id
     AND l.deleted_at IS NULL
     AND l.start_date <= v_pool.period_end
     AND (l.end_date IS NULL OR l.end_date >= v_pool.period_start)
     AND lease_pro_rata_share(l.id, v_pool.location_id, v_pool.period_end) > 0
   ORDER BY l.lease_no;
END; $$;
COMMENT ON FUNCTION cam_reconciliation IS
  'CAM statement per lease: pro-rata share of actual pool vs estimates already billed.';

-- ----------------------------------------------------------------------------
-- post_cam_reconciliation — bill (or credit) one lease's CAM true-up.
--
-- Under-recovery debits AR and credits CAM revenue. Over-recovery does the
-- reverse, which is a genuine reduction of revenue: the landlord billed for
-- costs that were never incurred and is giving the money back.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION post_cam_reconciliation(
  p_cam_pool_id     uuid,
  p_lease_id        uuid,
  p_entry_date      date,
  p_idempotency_key text
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_row    record;
  v_lease  record;
  v_entry  uuid;
  v_ccy    kernel.currency_code := (SELECT functional_currency FROM tenant_config LIMIT 1);
  v_amt    kernel.money_amount;
BEGIN
  SELECT id INTO v_entry FROM journal_entry
   WHERE idempotency_key = p_idempotency_key AND tenant_id = kernel.current_tenant();
  IF v_entry IS NOT NULL THEN RETURN v_entry; END IF;

  SELECT * INTO v_row FROM cam_reconciliation(p_cam_pool_id) WHERE lease_id = p_lease_id;
  IF v_row IS NULL THEN
    RETURN NULL;   -- lease not in this pool
  END IF;

  v_amt := v_row.balance_due;
  IF v_amt = 0 THEN
    RETURN NULL;   -- estimates exactly matched actual
  END IF;

  SELECT * INTO v_lease FROM lease WHERE id = p_lease_id;

  IF v_amt > 0 THEN
    -- Under-recovered: bill the shortfall.
    v_entry := post_journal_entry(
      p_entry_date,
      'CAM true-up lease ' || v_lease.lease_no,
      'cam_reconciliation', p_lease_id::text, p_idempotency_key,
      jsonb_build_array(
        jsonb_build_object(
          'account_id', posting_account('ar_control'),
          'debit', v_amt, 'currency', v_ccy,
          'party_id', v_lease.lessee_party_id,
          'subledger_type_code', 'ar',
          'memo', 'CAM under-recovery'),
        jsonb_build_object(
          'account_id', posting_account('cam_revenue'),
          'credit', v_amt, 'currency', v_ccy,
          'memo', 'CAM true-up')
      )
    );

    IF NOT EXISTS (SELECT 1 FROM open_item WHERE journal_entry_id = v_entry) THEN
      PERFORM open_item_create(
        'ar', v_lease.lessee_party_id, 'cam_reconciliation', p_lease_id::text,
        'CAM-' || v_lease.lease_no || '-' || (SELECT pool_year FROM cam_pool WHERE id = p_cam_pool_id),
        v_amt, v_ccy, p_entry_date, p_entry_date + 30, v_entry
      );
    END IF;
  ELSE
    -- Over-recovered: credit it back. Reduces revenue and reduces AR.
    v_entry := post_journal_entry(
      p_entry_date,
      'CAM credit lease ' || v_lease.lease_no,
      'cam_reconciliation', p_lease_id::text, p_idempotency_key,
      jsonb_build_array(
        jsonb_build_object(
          'account_id', posting_account('cam_revenue'),
          'debit', -v_amt, 'currency', v_ccy,
          'memo', 'CAM over-recovery refunded'),
        jsonb_build_object(
          'account_id', posting_account('ar_control'),
          'credit', -v_amt, 'currency', v_ccy,
          'party_id', v_lease.lessee_party_id,
          'subledger_type_code', 'ar',
          'memo', 'CAM credit')
      )
    );

    -- A credit note is a negative open item, so FIFO settlement nets it
    -- against the next invoice instead of leaving a stranded credit.
    IF NOT EXISTS (SELECT 1 FROM open_item WHERE journal_entry_id = v_entry) THEN
      PERFORM open_item_create(
        'ar', v_lease.lessee_party_id, 'cam_reconciliation', p_lease_id::text,
        'CAMCR-' || v_lease.lease_no || '-' || (SELECT pool_year FROM cam_pool WHERE id = p_cam_pool_id),
        v_amt, v_ccy, p_entry_date, p_entry_date, v_entry
      );
    END IF;
  END IF;

  RETURN v_entry;
END; $$;
COMMENT ON FUNCTION post_cam_reconciliation IS
  'Bills CAM under-recovery or credits over-recovery for one lease. Idempotent; NULL when balanced.';

-- ============================================================================
-- RENEWALS AND ESCALATIONS
-- ============================================================================

-- ----------------------------------------------------------------------------
-- renew_lease — extend the term.
--
-- Extends in place rather than creating a new lease, so the AR history, the
-- deposit and the space allocation stay attached to one continuous agreement.
-- A renewal is the same contract with a later end date, not a new relationship.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION renew_lease(
  p_lease_id    uuid,
  p_new_end_date date,
  p_escalation_rate kernel.percent_rate DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_lease record;
BEGIN
  SELECT * INTO v_lease FROM lease WHERE id = p_lease_id AND deleted_at IS NULL;
  IF v_lease IS NULL THEN
    RAISE EXCEPTION 'Lease % not found', p_lease_id USING ERRCODE='23503';
  END IF;

  IF v_lease.status = 'terminated' THEN
    RAISE EXCEPTION 'Lease % is terminated and cannot be renewed; create a new lease',
      p_lease_id USING ERRCODE='23514';
  END IF;

  IF v_lease.end_date IS NOT NULL AND p_new_end_date <= v_lease.end_date THEN
    RAISE EXCEPTION 'Renewal end date % must be after the current end date %',
      p_new_end_date, v_lease.end_date USING ERRCODE='23514';
  END IF;

  UPDATE lease
     SET end_date = p_new_end_date,
         status   = CASE WHEN status = 'expired' THEN 'active' ELSE status END
   WHERE id = p_lease_id;

  IF p_escalation_rate IS NOT NULL THEN
    PERFORM apply_rent_escalation(
      p_lease_id,
      p_escalation_rate,
      COALESCE(v_lease.end_date, current_date) + 1
    );
  END IF;

  RETURN p_lease_id;
END; $$;
COMMENT ON FUNCTION renew_lease IS
  'Extends a lease term in place, optionally applying a rent escalation from the renewal date.';

-- ----------------------------------------------------------------------------
-- apply_rent_escalation — raise fixed rent components by a percentage.
--
-- Effective-dating rather than overwriting: rent_component carries a GiST
-- exclusion constraint forbidding overlapping periods for the same component
-- type, so the old row must be closed the day before the new one starts.
-- Overwriting the amount would silently rewrite history and make last year's
-- invoices unreproducible.
--
-- percentage_rent is deliberately untouched: escalating a rate is a different
-- negotiation from escalating a fixed amount.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION apply_rent_escalation(
  p_lease_id       uuid,
  p_rate           kernel.percent_rate,
  p_effective_from date
) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
  v_comp  record;
  v_count integer := 0;
  v_new   kernel.money_amount;
BEGIN
  IF p_rate <= -1 THEN
    RAISE EXCEPTION 'Escalation rate % would make rent negative', p_rate
      USING ERRCODE='23514';
  END IF;

  FOR v_comp IN
    SELECT * FROM rent_component
     WHERE lease_id = p_lease_id
       AND component_type_code <> 'percentage_rent'
       AND effective_from < p_effective_from
       AND (effective_thru IS NULL OR effective_thru >= p_effective_from)
     ORDER BY component_type_code
  LOOP
    v_new := round(v_comp.amount * (1 + p_rate), 4);

    -- Close the existing period the day before the new rate starts.
    UPDATE rent_component
       SET effective_thru = p_effective_from - 1
     WHERE id = v_comp.id;

    INSERT INTO rent_component (
      lease_id, component_type_code, amount, currency, percent_rate,
      breakpoint_amount, billing_frequency, effective_from, effective_thru
    ) VALUES (
      p_lease_id, v_comp.component_type_code, v_new, v_comp.currency,
      v_comp.percent_rate, v_comp.breakpoint_amount, v_comp.billing_frequency,
      p_effective_from, v_comp.effective_thru
    );

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END; $$;
COMMENT ON FUNCTION apply_rent_escalation IS
  'Effective-dates a percentage increase on fixed rent components. Closes old periods; never overwrites.';

-- ----------------------------------------------------------------------------
-- v_lease_expiring — leases ending soon, for the renewal worklist.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_lease_expiring AS
  SELECT l.id AS lease_id,
         l.lease_no,
         l.lessee_party_id,
         p.display_name AS lessee_name,
         l.location_id,
         l.start_date,
         l.end_date,
         (l.end_date - current_date) AS days_remaining,
         l.status
    FROM lease l
    JOIN party p ON p.id = l.lessee_party_id
   WHERE l.tenant_id = kernel.current_tenant()
     AND l.deleted_at IS NULL
     AND l.status IN ('active','draft')
     AND l.end_date IS NOT NULL
   ORDER BY l.end_date;
COMMENT ON VIEW v_lease_expiring IS 'Leases with an end date, nearest first. Renewal worklist.';
