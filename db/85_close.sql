-- ============================================================================
-- 85_close.sql — Period close, year-end close, and financial statements.
--
-- ADR-0030 (period & year-end close):
--   * close_period()      — soft lock. Refuses if the books do not balance.
--   * reopen_period()     — reversible, audited. Refuses if the YEAR is locked.
--   * close_fiscal_year() — rolls revenue/expense into Retained Earnings through
--                           an Income Summary clearing account, then hard-locks
--                           every period in the year.
--
-- Design rules honoured here:
--   * The journal stays append-only. Closing posts a REAL journal entry; it
--     never mutates history.
--   * Close entries are idempotent via idempotency_key, like every other poster.
--   * close_fiscal_year posts on the LAST DAY of the year, while that period is
--     still open, then locks. Order matters.
--   * Statements read the ledger directly. No summary tables, so they cannot
--     drift from the GL (same principle as the realtime vendor portal, ADR-0028).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- period_balance_check — is the whole book in balance as of a date?
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION period_balance_check(p_as_of date)
RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(sum(jl.base_debit - jl.base_credit), 0)
    FROM journal_line jl
    JOIN journal_entry je ON je.id = jl.journal_entry_id
   WHERE je.entry_date <= p_as_of;
$$;
COMMENT ON FUNCTION period_balance_check IS 'Sum of (base_debit - base_credit) through a date. Must be 0.';

-- ----------------------------------------------------------------------------
-- close_period — soft lock a single period.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION close_period(p_fiscal_year smallint, p_period_no smallint)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  v_period fiscal_period;
  v_diff   numeric;
BEGIN
  SELECT * INTO v_period FROM fiscal_period
   WHERE fiscal_year = p_fiscal_year AND period_no = p_period_no;

  IF v_period.id IS NULL THEN
    RAISE EXCEPTION 'No fiscal period %-%', p_fiscal_year, p_period_no USING ERRCODE='23514';
  END IF;

  IF v_period.status = 'locked' THEN
    RAISE EXCEPTION 'Period %-% is locked by year-end close and cannot be modified',
      p_fiscal_year, p_period_no USING ERRCODE='23514';
  END IF;

  IF v_period.status = 'closed' THEN
    RETURN;  -- idempotent
  END IF;

  -- Never close a book that does not balance.
  v_diff := period_balance_check(v_period.end_date);
  IF v_diff <> 0 THEN
    RAISE EXCEPTION 'Cannot close %-%: ledger out of balance by % as of %',
      p_fiscal_year, p_period_no, v_diff, v_period.end_date USING ERRCODE='23514';
  END IF;

  -- Earlier periods must be closed first; closing out of order hides gaps.
  IF EXISTS (
    SELECT 1 FROM fiscal_period
     WHERE status = 'open'
       AND end_date < v_period.start_date
  ) THEN
    RAISE EXCEPTION 'Cannot close %-%: an earlier period is still open',
      p_fiscal_year, p_period_no USING ERRCODE='23514';
  END IF;

  UPDATE fiscal_period
     SET status = 'closed', closed_at = now(), closed_by = kernel.current_actor()
   WHERE id = v_period.id;
END; $$;
COMMENT ON FUNCTION close_period IS 'Soft-locks a period. Refuses if out of balance or if an earlier period is open.';

-- ----------------------------------------------------------------------------
-- reopen_period — undo a soft close. Refuses once the year is hard-locked.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reopen_period(p_fiscal_year smallint, p_period_no smallint)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_status text;
BEGIN
  SELECT status INTO v_status FROM fiscal_period
   WHERE fiscal_year = p_fiscal_year AND period_no = p_period_no;

  IF v_status IS NULL THEN
    RAISE EXCEPTION 'No fiscal period %-%', p_fiscal_year, p_period_no USING ERRCODE='23514';
  END IF;

  IF v_status = 'locked' THEN
    RAISE EXCEPTION 'Period %-% is locked by year-end close; reverse the close entry first',
      p_fiscal_year, p_period_no USING ERRCODE='23514';
  END IF;

  UPDATE fiscal_period
     SET status = 'open', closed_at = NULL, closed_by = NULL
   WHERE fiscal_year = p_fiscal_year AND period_no = p_period_no;
END; $$;
COMMENT ON FUNCTION reopen_period IS 'Reopens a soft-closed period. Hard-locked (year-end) periods refuse.';

-- ----------------------------------------------------------------------------
-- net_income — revenue less expense over a date range, in functional currency.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION net_income(p_from date, p_to date)
RETURNS numeric
LANGUAGE sql STABLE AS $$
  -- Net income = revenue - expense. Revenue is credit-normal and contributes
  -- (credit - debit); expense is debit-normal and contributes -(debit - credit),
  -- which is also (credit - debit). Both sides reduce to the same expression.
  SELECT COALESCE(sum(jl.base_credit - jl.base_debit), 0)
    FROM journal_line jl
    JOIN journal_entry je ON je.id = jl.journal_entry_id
    JOIN account a        ON a.id  = jl.account_id
    JOIN kernel.account_type at ON at.code = a.account_type_code
   WHERE at.statement = 'income_statement'
     AND je.entry_date BETWEEN p_from AND p_to;
$$;
COMMENT ON FUNCTION net_income IS 'Net income (revenue - expense) for a date range, functional currency.';

-- ----------------------------------------------------------------------------
-- close_fiscal_year — roll P&L into Retained Earnings, then hard-lock the year.
--
-- Posts on the last day of the final period while it is still open. Each
-- income-statement account is zeroed against Income Summary, then Income
-- Summary is cleared to Retained Earnings. Income Summary nets to zero.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION close_fiscal_year(
  p_fiscal_year     smallint,
  p_idempotency_key text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_start   date;
  v_end     date;
  v_key     text;
  v_entry   uuid;
  v_lines   jsonb := '[]'::jsonb;
  v_summary uuid;
  v_re      uuid;
  v_net     numeric := 0;
  v_bal     numeric;
  r         record;
BEGIN
  SELECT min(start_date), max(end_date) INTO v_start, v_end
    FROM fiscal_period WHERE fiscal_year = p_fiscal_year;

  IF v_start IS NULL THEN
    RAISE EXCEPTION 'No fiscal calendar for year %', p_fiscal_year USING ERRCODE='23514';
  END IF;

  v_key := COALESCE(p_idempotency_key, 'year_end_close:' || p_fiscal_year);

  -- Idempotency, checked the same way as every other poster: the KEY is the
  -- identity, not the year. Matching on source_ref alone would return a stale
  -- (possibly already-reversed) close entry from an earlier attempt.
  SELECT id INTO v_entry FROM journal_entry
    WHERE idempotency_key = v_key AND tenant_id = kernel.current_tenant();
  IF v_entry IS NOT NULL THEN
    RETURN v_entry;
  END IF;

  -- Guard against a second, DIFFERENT close of an already-locked year. An
  -- un-reversed close entry means the year is genuinely closed.
  IF EXISTS (SELECT 1 FROM fiscal_period WHERE fiscal_year = p_fiscal_year AND status = 'locked')
     AND EXISTS (
       SELECT 1 FROM journal_entry je
        WHERE je.source = 'year_end_close'
          AND je.source_ref = p_fiscal_year::text
          AND NOT EXISTS (SELECT 1 FROM journal_entry rev WHERE rev.reversal_of_id = je.id))
  THEN
    RAISE EXCEPTION 'Fiscal year % is already closed; reverse the close entry before closing again',
      p_fiscal_year USING ERRCODE='23514';
  END IF;

  v_summary := posting_account('income_summary');
  v_re      := posting_account('retained_earnings');

  -- Zero every income-statement account that has activity this year.
  FOR r IN
    SELECT a.id AS account_id,
           at.normal_balance,
           COALESCE(sum(jl.base_debit - jl.base_credit), 0) AS dr_less_cr
      FROM account a
      JOIN kernel.account_type at ON at.code = a.account_type_code
      JOIN journal_line jl  ON jl.account_id = a.id
      JOIN journal_entry je ON je.id = jl.journal_entry_id
     WHERE at.statement = 'income_statement'
       AND je.entry_date BETWEEN v_start AND v_end
     GROUP BY a.id, at.normal_balance
    HAVING COALESCE(sum(jl.base_debit - jl.base_credit), 0) <> 0
  LOOP
    -- A revenue account carries a credit balance (dr_less_cr < 0): debit it to zero.
    -- An expense account carries a debit balance (dr_less_cr > 0): credit it to zero.
    IF r.dr_less_cr < 0 THEN
      v_lines := v_lines || jsonb_build_object(
        'account_id', r.account_id, 'debit', -r.dr_less_cr, 'memo', 'Year-end close');
    ELSE
      v_lines := v_lines || jsonb_build_object(
        'account_id', r.account_id, 'credit', r.dr_less_cr, 'memo', 'Year-end close');
    END IF;
    -- Net income accumulates as the opposite sign of the account balances.
    v_net := v_net - r.dr_less_cr;
  END LOOP;

  IF jsonb_array_length(v_lines) = 0 THEN
    -- No P&L activity. Nothing to roll; just lock the year.
    UPDATE fiscal_period SET status = 'locked', closed_at = now(), closed_by = kernel.current_actor()
     WHERE fiscal_year = p_fiscal_year;
    RETURN NULL;
  END IF;

  -- Balance the entry against Income Summary, then clear Income Summary to
  -- Retained Earnings in the same entry. Net effect on Income Summary = 0.
  IF v_net > 0 THEN
    -- Profit: credit Income Summary, then debit it and credit Retained Earnings.
    v_lines := v_lines || jsonb_build_object('account_id', v_summary, 'credit', v_net, 'memo','Income Summary');
    v_lines := v_lines || jsonb_build_object('account_id', v_summary, 'debit',  v_net, 'memo','Clear to Retained Earnings');
    v_lines := v_lines || jsonb_build_object('account_id', v_re,      'credit', v_net, 'memo','Net income');
  ELSIF v_net < 0 THEN
    v_lines := v_lines || jsonb_build_object('account_id', v_summary, 'debit',  -v_net, 'memo','Income Summary');
    v_lines := v_lines || jsonb_build_object('account_id', v_summary, 'credit', -v_net, 'memo','Clear to Retained Earnings');
    v_lines := v_lines || jsonb_build_object('account_id', v_re,      'debit',  -v_net, 'memo','Net loss');
  END IF;

  v_entry := post_journal_entry(
    v_end,
    'Year-end close ' || p_fiscal_year,
    'year_end_close',
    p_fiscal_year::text,
    v_key,
    v_lines
  );

  -- Hard-lock every period in the year. Do this AFTER posting.
  UPDATE fiscal_period
     SET status = 'locked', closed_at = now(), closed_by = kernel.current_actor()
   WHERE fiscal_year = p_fiscal_year;

  -- Income Summary must be flat once the close is done.
  SELECT COALESCE(sum(jl.base_debit - jl.base_credit), 0) INTO v_bal
    FROM journal_line jl WHERE jl.account_id = v_summary;
  IF v_bal <> 0 THEN
    RAISE EXCEPTION 'Year-end close left Income Summary at %; expected 0', v_bal USING ERRCODE='23514';
  END IF;

  RETURN v_entry;
END; $$;
COMMENT ON FUNCTION close_fiscal_year IS 'Rolls P&L into Retained Earnings via Income Summary, then hard-locks the year (ADR-0030).';

-- ============================================================================
-- FINANCIAL STATEMENTS
--
-- All read the ledger directly. No summary tables -> cannot drift from the GL.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- income_statement — revenue & expense for a date range.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION income_statement(p_from date, p_to date)
RETURNS TABLE (
  account_type_code text,
  account_code      text,
  account_name      text,
  amount            numeric,
  sort_order        smallint
)
LANGUAGE sql STABLE AS $$
  SELECT a.account_type_code,
         a.code,
         a.name,
         -- Present each account as a positive figure in its natural direction.
         CASE at.normal_balance
           WHEN 'C' THEN COALESCE(sum(jl.base_credit - jl.base_debit), 0)
           ELSE          COALESCE(sum(jl.base_debit  - jl.base_credit), 0)
         END AS amount,
         at.sort_order
    FROM account a
    JOIN kernel.account_type at ON at.code = a.account_type_code
    LEFT JOIN journal_line jl   ON jl.account_id = a.id
    LEFT JOIN journal_entry je  ON je.id = jl.journal_entry_id
                               AND je.entry_date BETWEEN p_from AND p_to
   WHERE at.statement = 'income_statement'
     AND (jl.id IS NULL OR je.id IS NOT NULL)
   GROUP BY a.account_type_code, a.code, a.name, at.normal_balance, at.sort_order
  HAVING CASE at.normal_balance
           WHEN 'C' THEN COALESCE(sum(jl.base_credit - jl.base_debit), 0)
           ELSE          COALESCE(sum(jl.base_debit  - jl.base_credit), 0)
         END <> 0
   ORDER BY at.sort_order, a.code;
$$;
COMMENT ON FUNCTION income_statement IS 'Accrual-basis P&L for a date range (ADR-0022: accrual is the book of record).';

-- ----------------------------------------------------------------------------
-- balance_sheet — assets, liabilities, equity as of a date.
--
-- Equity includes current-year earnings that have not been closed yet, so the
-- statement balances on any date, closed or not.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION balance_sheet(p_as_of date DEFAULT current_date)
RETURNS TABLE (
  account_type_code text,
  account_code      text,
  account_name      text,
  amount            numeric,
  sort_order        smallint
)
LANGUAGE sql STABLE AS $$
  WITH bs AS (
    SELECT a.account_type_code,
           a.code,
           a.name,
           CASE at.normal_balance
             WHEN 'D' THEN COALESCE(sum(jl.base_debit  - jl.base_credit), 0)
             ELSE          COALESCE(sum(jl.base_credit - jl.base_debit), 0)
           END AS amount,
           at.sort_order
      FROM account a
      JOIN kernel.account_type at ON at.code = a.account_type_code
      LEFT JOIN journal_line jl   ON jl.account_id = a.id
      LEFT JOIN journal_entry je  ON je.id = jl.journal_entry_id
                                 AND je.entry_date <= p_as_of
     WHERE at.statement = 'balance_sheet'
       AND (jl.id IS NULL OR je.id IS NOT NULL)
     GROUP BY a.account_type_code, a.code, a.name, at.normal_balance, at.sort_order
  ),
  -- Unclosed earnings: ALL income-statement activity through p_as_of.
  --
  -- This is deliberately measured from the beginning of time rather than from
  -- the start of the current fiscal year. close_fiscal_year() zeroes every P&L
  -- account by posting offsetting lines, so a closed year contributes exactly
  -- zero here and drops out on its own. Anything left is genuinely unclosed --
  -- including prior years that were never closed. Scoping this to the current
  -- year alone would silently drop prior-year unclosed P&L and the balance
  -- sheet would not balance.
  cye AS (
    SELECT 'equity'::text AS account_type_code,
           '3999'::text   AS code,
           'Unclosed Earnings'::text AS name,
           net_income('-infinity'::date, p_as_of) AS amount,
           (SELECT at.sort_order FROM kernel.account_type at WHERE at.code = 'equity') AS sort_order
  )
  SELECT * FROM bs  WHERE amount <> 0
  UNION ALL
  SELECT * FROM cye WHERE amount <> 0
  ORDER BY sort_order, code;
$$;
COMMENT ON FUNCTION balance_sheet IS 'Balance sheet as of a date, including unclosed current-year earnings so it always balances.';

-- ----------------------------------------------------------------------------
-- balance_sheet_check — assets - (liabilities + equity). Must be 0.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION balance_sheet_check(p_as_of date DEFAULT current_date)
RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(sum(CASE WHEN account_type_code = 'asset' THEN amount ELSE -amount END), 0)
    FROM balance_sheet(p_as_of);
$$;
COMMENT ON FUNCTION balance_sheet_check IS 'Assets - (Liabilities + Equity). Must be exactly 0.';

-- ----------------------------------------------------------------------------
-- cash_basis_income_statement — ADR-0022 derivation.
--
-- Accrual is the book of record. Cash basis is DERIVED, never stored: we take
-- only P&L lines that share a journal entry with a cash-kind account, so revenue
-- and expense are recognised when money actually moved.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cash_basis_income_statement(p_from date, p_to date)
RETURNS TABLE (
  account_type_code text,
  account_code      text,
  account_name      text,
  amount            numeric,
  sort_order        smallint
)
LANGUAGE sql STABLE AS $$
  WITH cash_accounts AS (
    SELECT account_id FROM posting_map
     WHERE role_code IN ('cash','bank','undeposited_funds')
  ),
  cash_entries AS (
    SELECT DISTINCT je.id
      FROM journal_entry je
      JOIN journal_line jl ON jl.journal_entry_id = je.id
     WHERE jl.account_id IN (SELECT account_id FROM cash_accounts)
       AND je.entry_date BETWEEN p_from AND p_to
  )
  SELECT a.account_type_code,
         a.code,
         a.name,
         CASE at.normal_balance
           WHEN 'C' THEN COALESCE(sum(jl.base_credit - jl.base_debit), 0)
           ELSE          COALESCE(sum(jl.base_debit  - jl.base_credit), 0)
         END AS amount,
         at.sort_order
    FROM journal_line jl
    JOIN journal_entry je ON je.id = jl.journal_entry_id
    JOIN account a        ON a.id  = jl.account_id
    JOIN kernel.account_type at ON at.code = a.account_type_code
   WHERE at.statement = 'income_statement'
     AND je.id IN (SELECT id FROM cash_entries)
   GROUP BY a.account_type_code, a.code, a.name, at.normal_balance, at.sort_order
  HAVING CASE at.normal_balance
           WHEN 'C' THEN COALESCE(sum(jl.base_credit - jl.base_debit), 0)
           ELSE          COALESCE(sum(jl.base_debit  - jl.base_credit), 0)
         END <> 0
   ORDER BY at.sort_order, a.code;
$$;
COMMENT ON FUNCTION cash_basis_income_statement IS
  'Cash-basis P&L DERIVED from the accrual ledger (ADR-0022). Only P&L lines in entries that touched cash.';

-- ============================================================================
-- AR WRITE-OFF — wires up the bad_debt_expense role.
-- ============================================================================

CREATE OR REPLACE FUNCTION write_off_open_item(
  p_open_item_id    uuid,
  p_entry_date      date,
  p_amount          kernel.money_amount DEFAULT NULL,
  p_memo            text DEFAULT NULL,
  p_idempotency_key text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_item    open_item;
  v_amt     numeric;
  v_entry   uuid;
  v_control uuid;
  v_expense uuid;
  v_role    text;
BEGIN
  SELECT * INTO v_item FROM open_item WHERE id = p_open_item_id;
  IF v_item.id IS NULL THEN
    RAISE EXCEPTION 'No open item %', p_open_item_id USING ERRCODE='23514';
  END IF;

  v_amt := COALESCE(p_amount, v_item.open_amount);

  IF v_amt <= 0 THEN
    RAISE EXCEPTION 'Write-off amount must be positive, got %', v_amt USING ERRCODE='23514';
  END IF;
  IF v_amt > v_item.open_amount THEN
    RAISE EXCEPTION 'Cannot write off % against an open balance of %',
      v_amt, v_item.open_amount USING ERRCODE='23514';
  END IF;

  v_role    := subledger_control_role(v_item.subledger_type_code);
  v_control := posting_account(v_role);
  v_expense := posting_account('bad_debt_expense');

  -- Debit bad debt expense, credit the AR control (tagged to the subledger so
  -- the control-account invariant still holds).
  v_entry := post_journal_entry(
    p_entry_date,
    COALESCE(p_memo, 'Write-off ' || COALESCE(v_item.document_no, v_item.id::text)),
    'write_off',
    v_item.id::text,
    COALESCE(p_idempotency_key, 'write_off:' || v_item.id::text || ':' || p_entry_date::text),
    jsonb_build_array(
      jsonb_build_object('account_id', v_expense, 'debit', v_amt, 'memo','Bad debt'),
      jsonb_build_object('account_id', v_control, 'credit', v_amt,
                         'party_id', v_item.party_id,
                         'subledger_type_code', v_item.subledger_type_code)
    )
  );

  -- Relieve the open item to match the GL movement.
  UPDATE open_item
     SET open_amount = open_amount - v_amt,
         status = CASE WHEN open_amount - v_amt = 0 THEN 'written_off' ELSE 'partial' END
   WHERE id = v_item.id;

  RETURN v_entry;
END; $$;
COMMENT ON FUNCTION write_off_open_item IS
  'Writes off an uncollectible open item: debit bad debt expense, credit the control, relieve the item.';
