-- ============================================================================
-- Ninja EMP — 30_ledger.sql  (TENANT-SCOPED)  *** THE HEART ***
-- Chart of Accounts, Journal Entry + Journal Line (append-only),
-- DB-enforced balance, reversal-not-edit, idempotent posting, period locking,
-- and account determination via posting_map (ADR-0020).
-- Conforms to docs/DATA_STANDARDS.md.
-- Run with: SET search_path = <tenant_schema>, kernel;
-- ============================================================================
\set ON_ERROR_STOP on

-- ----------------------------------------------------------------------------
-- Chart of Accounts — hierarchical, typed, with control-account flags.
-- Master data: audit block + optimistic locking + soft delete (ADR-0017).
-- ----------------------------------------------------------------------------
CREATE TABLE account (
  id                          uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id                   uuid NOT NULL DEFAULT kernel.current_tenant(),
  code                        text NOT NULL,
  name                        text NOT NULL,
  account_type_code           text NOT NULL REFERENCES kernel.account_type(code),
  parent_id                   uuid REFERENCES account(id) ON DELETE RESTRICT,
  is_control                  boolean NOT NULL DEFAULT false,
  control_subledger_type_code text REFERENCES kernel.subledger_type(code),
  currency                    kernel.currency_code REFERENCES kernel.currency(code),
  is_active                   boolean NOT NULL DEFAULT true,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  created_by                  uuid DEFAULT kernel.current_actor(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),
  updated_by                  uuid DEFAULT kernel.current_actor(),
  version                     integer NOT NULL DEFAULT 1,
  deleted_at                  timestamptz,
  deleted_by                  uuid,
  UNIQUE (tenant_id, code),
  -- A control account must declare which subledger it controls.
  CHECK ( (is_control AND control_subledger_type_code IS NOT NULL)
       OR (NOT is_control AND control_subledger_type_code IS NULL) )
);
COMMENT ON TABLE account IS 'Chart of Accounts. is_control marks GL control accounts that subledgers tie to.';

CREATE INDEX ix_account_parent ON account(parent_id);
CREATE INDEX ix_account_active ON account(tenant_id) WHERE deleted_at IS NULL;

CREATE TRIGGER trg_account_audit
  BEFORE UPDATE ON account
  FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();
CREATE TRIGGER trg_account_audit_row
  AFTER INSERT OR UPDATE OR DELETE ON account
  FOR EACH ROW EXECUTE FUNCTION kernel.audit_row();

-- ----------------------------------------------------------------------------
-- Posting map (account determination, ADR-0020). Domain code resolves a posting
-- role to a concrete account_id here — never by hard-coded account code.
-- ----------------------------------------------------------------------------
CREATE TABLE posting_map (
  id          uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id   uuid NOT NULL DEFAULT kernel.current_tenant(),
  role_code   text NOT NULL REFERENCES kernel.posting_role(code),
  account_id  uuid NOT NULL REFERENCES account(id) ON DELETE RESTRICT,
  created_at  timestamptz NOT NULL DEFAULT now(),
  created_by  uuid DEFAULT kernel.current_actor(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  uuid DEFAULT kernel.current_actor(),
  version     integer NOT NULL DEFAULT 1,
  UNIQUE (tenant_id, role_code)
);
COMMENT ON TABLE posting_map IS 'Account determination: posting role -> account. Domain posting resolves accounts here (ADR-0020).';

CREATE TRIGGER trg_posting_map_audit
  BEFORE UPDATE ON posting_map
  FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- Resolve a posting role to its account id (raises if unmapped).
CREATE OR REPLACE FUNCTION posting_account(p_role text) RETURNS uuid
LANGUAGE plpgsql STABLE AS $$
DECLARE v_id uuid;
BEGIN
  SELECT account_id INTO v_id FROM posting_map WHERE role_code = p_role;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'No posting_map entry for role %', p_role USING ERRCODE='23514';
  END IF;
  RETURN v_id;
END; $$;
COMMENT ON FUNCTION posting_account IS 'Resolves a posting role to its account_id via posting_map (ADR-0020).';

-- ----------------------------------------------------------------------------
-- Fiscal periods — period close / locking.
-- ----------------------------------------------------------------------------
CREATE TABLE fiscal_period (
  id          uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id   uuid NOT NULL DEFAULT kernel.current_tenant(),
  fiscal_year smallint NOT NULL,
  period_no   smallint NOT NULL CHECK (period_no BETWEEN 1 AND 13),
  start_date  date NOT NULL,
  end_date    date NOT NULL,
  status      text NOT NULL DEFAULT 'open' CHECK (status IN ('open','closed','locked')),
  closed_at   timestamptz,
  closed_by   uuid,
  created_at  timestamptz NOT NULL DEFAULT now(),
  created_by  uuid DEFAULT kernel.current_actor(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  uuid DEFAULT kernel.current_actor(),
  version     integer NOT NULL DEFAULT 1,
  CHECK (end_date >= start_date),
  UNIQUE (tenant_id, fiscal_year, period_no)
);
COMMENT ON TABLE fiscal_period IS 'Fiscal calendar. status=closed/locked blocks new postings into the period.';

CREATE TRIGGER trg_fiscal_period_audit
  BEFORE UPDATE ON fiscal_period
  FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- ----------------------------------------------------------------------------
-- Journal Entry — append-only header. Corrections are reversals, never edits.
-- ----------------------------------------------------------------------------
CREATE TABLE journal_entry (
  id              uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id       uuid NOT NULL DEFAULT kernel.current_tenant(),
  entry_no        bigint GENERATED ALWAYS AS IDENTITY,
  entry_date      date NOT NULL,
  posting_date    timestamptz NOT NULL DEFAULT now(),
  memo            text,
  source          text NOT NULL DEFAULT 'manual',   -- manual | pos | rent | settlement | ...
  source_ref      text,
  idempotency_key text,
  reversal_of_id  uuid REFERENCES journal_entry(id) ON DELETE RESTRICT,
  -- B1/JI-3: tamper-evident hash chain. entry_hash = SHA-256 over this entry's
  -- immutable header content plus its predecessor's hash; prev_hash links back.
  prev_hash       text,
  entry_hash      text,
  created_by      uuid,
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, entry_no),
  UNIQUE (tenant_id, idempotency_key)
);
COMMENT ON TABLE journal_entry IS 'Append-only journal header. Idempotent via idempotency_key. Reversal links via reversal_of_id. Hash-chained (JI-3).';

CREATE INDEX ix_journal_entry_date ON journal_entry(entry_date);
CREATE INDEX ix_journal_entry_source ON journal_entry(source, source_ref);

-- ----------------------------------------------------------------------------
-- Journal Line — append-only. Debit XOR credit. Base amounts in functional ccy.
-- party_id + subledger_type_code tag a line to a subledger (AR/AP/vendor payable).
-- ----------------------------------------------------------------------------
CREATE TABLE journal_line (
  -- ADR-0006: highest-volume table, never referenced externally -> bigint identity.
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id           uuid NOT NULL DEFAULT kernel.current_tenant(),
  journal_entry_id    uuid NOT NULL REFERENCES journal_entry(id) ON DELETE RESTRICT,
  line_no             smallint NOT NULL,
  account_id          uuid NOT NULL REFERENCES account(id) ON DELETE RESTRICT,
  debit               kernel.money_amount NOT NULL DEFAULT 0,
  credit              kernel.money_amount NOT NULL DEFAULT 0,
  currency            kernel.currency_code NOT NULL,
  fx_rate             kernel.fx_rate NOT NULL DEFAULT 1,
  base_debit          kernel.money_amount NOT NULL DEFAULT 0,
  base_credit         kernel.money_amount NOT NULL DEFAULT 0,
  party_id            uuid REFERENCES party(id) ON DELETE RESTRICT,
  subledger_type_code text REFERENCES kernel.subledger_type(code),
  memo                text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (journal_entry_id, line_no),
  -- Exactly one side is non-zero; amounts are never negative.
  CHECK (debit >= 0 AND credit >= 0),
  CHECK ( (debit > 0 AND credit = 0) OR (credit > 0 AND debit = 0) ),
  CHECK (base_debit >= 0 AND base_credit >= 0),
  CHECK ( (base_debit > 0 AND base_credit = 0) OR (base_credit > 0 AND base_debit = 0) ),
  -- Subledger tagging is all-or-nothing: a party tag requires a subledger type.
  CHECK ( (party_id IS NULL AND subledger_type_code IS NULL)
       OR (party_id IS NOT NULL AND subledger_type_code IS NOT NULL) ),
  -- B2/MO-1: no sub-cent amount may be posted (scale follows the currency).
  CHECK (kernel.money_scale_ok(debit, currency)),
  CHECK (kernel.money_scale_ok(credit, currency))
);
COMMENT ON TABLE journal_line IS 'Append-only journal lines. Debit XOR credit. party_id+subledger_type_code tag subledger lines.';

CREATE INDEX ix_journal_line_entry ON journal_line(journal_entry_id);
CREATE INDEX ix_journal_line_account ON journal_line(account_id);
CREATE INDEX ix_journal_line_party ON journal_line(party_id, subledger_type_code);

-- ============================================================================
-- INVARIANT ENFORCEMENT (DB-level, not application-level)
-- ============================================================================

-- (1) APPEND-ONLY: block UPDATE/DELETE on journal tables (kernel.forbid_mutation).
CREATE TRIGGER trg_journal_entry_append_only
  BEFORE UPDATE OR DELETE ON journal_entry
  FOR EACH ROW EXECUTE FUNCTION kernel.forbid_mutation();

CREATE TRIGGER trg_journal_line_append_only
  BEFORE UPDATE OR DELETE ON journal_line
  FOR EACH ROW EXECUTE FUNCTION kernel.forbid_mutation();

-- (1b) HASH CHAIN (B1/JI-3): each entry is chained to its predecessor so any
--      later edit to history is detectable. The digest covers the immutable
--      header content; the BEFORE INSERT trigger fills prev_hash/entry_hash.
CREATE OR REPLACE FUNCTION journal_entry_digest(
  p_prev            text,
  p_entry_no        bigint,
  p_entry_date      date,
  p_memo            text,
  p_source          text,
  p_source_ref      text,
  p_idempotency_key text,
  p_reversal_of_id  uuid
) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT encode(kernel.digest(
    COALESCE(p_prev,'')            || E'\x1f' || p_entry_no::text        || E'\x1f' ||
    p_entry_date::text             || E'\x1f' || COALESCE(p_memo,'')     || E'\x1f' ||
    p_source                       || E'\x1f' || COALESCE(p_source_ref,'') || E'\x1f' ||
    COALESCE(p_idempotency_key,'') || E'\x1f' || COALESCE(p_reversal_of_id::text,'')
  , 'sha256'), 'hex');
$$;
COMMENT ON FUNCTION journal_entry_digest IS
  'SHA-256 over an entry''s immutable header content plus its predecessor hash (JI-3).';

CREATE OR REPLACE FUNCTION journal_entry_hash_chain() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_prev text;
BEGIN
  SELECT entry_hash INTO v_prev
    FROM journal_entry
   WHERE tenant_id = NEW.tenant_id
   ORDER BY entry_no DESC
   LIMIT 1;
  NEW.prev_hash  := v_prev;
  NEW.entry_hash := journal_entry_digest(v_prev, NEW.entry_no, NEW.entry_date, NEW.memo,
                                         NEW.source, NEW.source_ref, NEW.idempotency_key, NEW.reversal_of_id);
  RETURN NEW;
END; $$;
COMMENT ON FUNCTION journal_entry_hash_chain IS
  'BEFORE INSERT: chains each entry to its predecessor (JI-3).';

CREATE TRIGGER trg_journal_entry_hash_chain
  BEFORE INSERT ON journal_entry
  FOR EACH ROW EXECUTE FUNCTION journal_entry_hash_chain();

-- One entry per hash; one successor per prev_hash; exactly one genesis.
CREATE UNIQUE INDEX ux_journal_entry_hash
  ON journal_entry (tenant_id, entry_hash);
CREATE UNIQUE INDEX ux_journal_entry_prev_hash
  ON journal_entry (tenant_id, prev_hash) WHERE prev_hash IS NOT NULL;
CREATE UNIQUE INDEX ux_journal_entry_genesis
  ON journal_entry (tenant_id) WHERE prev_hash IS NULL;

CREATE OR REPLACE FUNCTION verify_journal_chain()
RETURNS TABLE (entry_no bigint, entry_id uuid, problem text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  r        record;
  v_prev   text := NULL;
  v_expect text;
BEGIN
  FOR r IN SELECT * FROM journal_entry ORDER BY entry_no LOOP
    v_expect := journal_entry_digest(v_prev, r.entry_no, r.entry_date, r.memo,
                                     r.source, r.source_ref, r.idempotency_key, r.reversal_of_id);
    IF r.prev_hash IS DISTINCT FROM v_prev THEN
      entry_no := r.entry_no; entry_id := r.id; problem := 'prev_hash does not match predecessor';
      RETURN NEXT;
    END IF;
    IF r.entry_hash IS DISTINCT FROM v_expect THEN
      entry_no := r.entry_no; entry_id := r.id; problem := 'entry_hash does not match content';
      RETURN NEXT;
    END IF;
    v_prev := r.entry_hash;
  END LOOP;
END; $$;
COMMENT ON FUNCTION verify_journal_chain IS
  'Returns one row per broken link in the journal hash chain. Must return zero rows.';

-- (2) BALANCED ENTRY: deferred constraint trigger — Σ debits = Σ credits per entry.
--     Deferred to COMMIT so multi-line inserts within a transaction are allowed.
CREATE OR REPLACE FUNCTION assert_entry_balanced() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_entry uuid := COALESCE(NEW.journal_entry_id, OLD.journal_entry_id);
  v_lines int;
  v_debit kernel.money_amount;
  v_credit kernel.money_amount;
BEGIN
  SELECT count(*), COALESCE(sum(debit),0), COALESCE(sum(credit),0)
    INTO v_lines, v_debit, v_credit
    FROM journal_line WHERE journal_entry_id = v_entry;

  IF v_lines < 2 THEN
    RAISE EXCEPTION 'Journal entry % must have at least 2 lines (has %)', v_entry, v_lines
      USING ERRCODE = '23514';
  END IF;
  IF v_debit <> v_credit THEN
    RAISE EXCEPTION 'Journal entry % is unbalanced: debits % <> credits %', v_entry, v_debit, v_credit
      USING ERRCODE = '23514';
  END IF;
  IF v_debit = 0 THEN
    RAISE EXCEPTION 'Journal entry % has zero value; refusing to post', v_entry
      USING ERRCODE = '23514';
  END IF;
  RETURN NULL;
END; $$;

CREATE CONSTRAINT TRIGGER trg_journal_line_balanced
  AFTER INSERT OR UPDATE OR DELETE ON journal_line
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION assert_entry_balanced();

-- (3) PERIOD LOCK: reject postings into closed/locked periods.
CREATE OR REPLACE FUNCTION assert_period_open() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_status text;
BEGIN
  SELECT status INTO v_status FROM fiscal_period
    WHERE start_date <= NEW.entry_date AND end_date >= NEW.entry_date
    LIMIT 1;
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'No fiscal period covers entry_date %', NEW.entry_date USING ERRCODE='23514';
  END IF;
  IF v_status <> 'open' THEN
    RAISE EXCEPTION 'Fiscal period for % is %; postings are blocked', NEW.entry_date, v_status
      USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END; $$;

CREATE TRIGGER trg_journal_entry_period_open
  BEFORE INSERT ON journal_entry
  FOR EACH ROW EXECUTE FUNCTION assert_period_open();

-- (4) SUBLEDGER ↔ CONTROL ACCOUNT: a tagged line must post to the matching control account.
CREATE OR REPLACE FUNCTION assert_subledger_control() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_control text;
BEGIN
  IF NEW.subledger_type_code IS NULL THEN RETURN NEW; END IF;
  SELECT control_subledger_type_code INTO v_control FROM account WHERE id = NEW.account_id;
  IF v_control IS DISTINCT FROM NEW.subledger_type_code THEN
    RAISE EXCEPTION 'Line tagged subledger % must post to a control account for %, but account % controls %',
      NEW.subledger_type_code, NEW.subledger_type_code, NEW.account_id, COALESCE(v_control,'<none>')
      USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END; $$;

CREATE TRIGGER trg_journal_line_subledger_control
  BEFORE INSERT ON journal_line
  FOR EACH ROW EXECUTE FUNCTION assert_subledger_control();

-- (5) THE REVERSE DIRECTION: a line posting TO a control account must be TAGGED.
--
-- assert_subledger_control() above only guards one way: it stops a TAGGED line
-- from landing on the wrong account. It says nothing about an UNTAGGED line
-- landing on a control account, and that gap is the more dangerous of the two.
--
-- Without this trigger it was possible to debit Accounts Receivable with no
-- party at all. The entry balances, the trial balance stays at zero, and
-- nothing complains -- but the money is ORPHANED: no party owes it, it appears
-- on no statement, no one can be invoiced for it, and it will never be
-- collected. It shows up only later as an unexplained difference in
-- subledger_control_check(), by which time the originating transaction is
-- buried in months of history.
--
-- A detective control that tells you the books are wrong is worth far less
-- than a preventive one that stops them going wrong. subledger_control_check()
-- remains as the backstop; this trigger is what makes it boring.
--
-- The single legitimate exception is a BEARER instrument (an anonymous gift
-- certificate), whitelisted per subledger type via allows_untagged so the
-- exemption is a reviewable data decision rather than a hole in the rule.
CREATE OR REPLACE FUNCTION assert_control_account_tagged() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_sub     text;
  v_untagged boolean;
  v_code    text;
  v_name    text;
BEGIN
  IF NEW.subledger_type_code IS NOT NULL THEN RETURN NEW; END IF;

  SELECT a.control_subledger_type_code, a.code, a.name
    INTO v_sub, v_code, v_name
    FROM account a
   WHERE a.id = NEW.account_id AND a.is_control;

  IF v_sub IS NULL THEN RETURN NEW; END IF;   -- not a control account

  SELECT st.allows_untagged INTO v_untagged
    FROM kernel.subledger_type st WHERE st.code = v_sub;

  IF COALESCE(v_untagged, false) THEN RETURN NEW; END IF;

  RAISE EXCEPTION
    'Account % (%) is the % control account; a posting to it must name the party (party_id + subledger_type_code). Untagged money here is owed to nobody and will never be collected or paid.',
    v_code, v_name, v_sub
    USING ERRCODE = '23514';
END; $$;
COMMENT ON FUNCTION assert_control_account_tagged IS
  'Prevents orphaned balances: every line hitting a control account must identify the party, unless the subledger allows bearer instruments.';

CREATE TRIGGER trg_journal_line_control_tagged
  BEFORE INSERT ON journal_line
  FOR EACH ROW EXECUTE FUNCTION assert_control_account_tagged();

-- ============================================================================
-- POSTING API (idempotent) + REVERSAL + TRIAL BALANCE
-- ============================================================================

-- Idempotent posting. Returns the entry id; safe to retry with the same key.
-- p_lines: jsonb array of {account_id, debit, credit, currency, fx_rate, party_id, subledger_type_code, memo}
CREATE OR REPLACE FUNCTION post_journal_entry(
  p_entry_date      date,
  p_memo            text,
  p_source          text,
  p_source_ref      text,
  p_idempotency_key text,
  p_lines           jsonb
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_entry uuid;
  v_line  jsonb;
  v_no    smallint := 0;
  v_ccy   kernel.currency_code;
  v_rate  kernel.fx_rate;
BEGIN
  -- Idempotency: return the existing entry if this key was already posted.
  IF p_idempotency_key IS NOT NULL THEN
    SELECT id INTO v_entry FROM journal_entry
      WHERE idempotency_key = p_idempotency_key AND tenant_id = kernel.current_tenant();
    IF v_entry IS NOT NULL THEN RETURN v_entry; END IF;
  END IF;

  INSERT INTO journal_entry (entry_date, memo, source, source_ref, idempotency_key, created_by)
  VALUES (p_entry_date, p_memo, p_source, p_source_ref, p_idempotency_key, kernel.current_actor())
  RETURNING id INTO v_entry;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    v_no := v_no + 1;
    v_ccy := COALESCE((v_line->>'currency')::kernel.currency_code,
                      (SELECT functional_currency FROM tenant_config LIMIT 1));
    v_rate := COALESCE((v_line->>'fx_rate')::kernel.fx_rate, fx_to_functional(v_ccy, p_entry_date));
    INSERT INTO journal_line (
      journal_entry_id, line_no, account_id, debit, credit, currency, fx_rate,
      base_debit, base_credit, party_id, subledger_type_code, memo
    ) VALUES (
      v_entry, v_no,
      (v_line->>'account_id')::uuid,
      COALESCE((v_line->>'debit')::kernel.money_amount, 0),
      COALESCE((v_line->>'credit')::kernel.money_amount, 0),
      v_ccy, v_rate,
      round(COALESCE((v_line->>'debit')::kernel.money_amount, 0)  * v_rate, 4),
      round(COALESCE((v_line->>'credit')::kernel.money_amount, 0) * v_rate, 4),
      NULLIF(v_line->>'party_id','')::uuid,
      NULLIF(v_line->>'subledger_type_code',''),
      v_line->>'memo'
    );
  END LOOP;

  RETURN v_entry;
END; $$;
COMMENT ON FUNCTION post_journal_entry IS 'Idempotent posting. Same idempotency_key returns the same entry id.';

-- Reversal: post a mirror entry (debits<->credits) linked to the original.
-- RV-4: reversal is a DOCUMENT STATUS. A reversed entry cannot be reversed
-- again, and a reversal is itself terminal.
-- RV-5: the mirror restores the GL control; unapply_for_entry restores the
-- open items the original settled (defined in 45_openitem.sql).
CREATE OR REPLACE FUNCTION reverse_journal_entry(
  p_entry_id        uuid,
  p_reversal_date   date,
  p_memo            text DEFAULT NULL,
  p_idempotency_key text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_new uuid;
  v_no  smallint := 0;
  v_line record;
BEGIN
  IF p_idempotency_key IS NOT NULL THEN
    SELECT id INTO v_new FROM journal_entry
      WHERE idempotency_key = p_idempotency_key AND tenant_id = kernel.current_tenant();
    IF v_new IS NOT NULL THEN RETURN v_new; END IF;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM journal_entry WHERE id = p_entry_id) THEN
    RAISE EXCEPTION 'Journal entry % not found', p_entry_id USING ERRCODE='23503';
  END IF;

  -- RV-4: reversal is a document status. A reversed entry cannot be reversed
  -- again, and a reversal is itself terminal.
  IF EXISTS (SELECT 1 FROM journal_entry WHERE reversal_of_id = p_entry_id) THEN
    RAISE EXCEPTION 'Entry % has already been reversed; a reversed entry cannot be reversed again',
      p_entry_id USING ERRCODE='23514';
  END IF;
  IF EXISTS (SELECT 1 FROM journal_entry WHERE id = p_entry_id AND reversal_of_id IS NOT NULL) THEN
    RAISE EXCEPTION 'Entry % is itself a reversal; reversals are terminal', p_entry_id USING ERRCODE='23514';
  END IF;

  INSERT INTO journal_entry (entry_date, memo, source, source_ref, idempotency_key, reversal_of_id, created_by)
  SELECT p_reversal_date,
         COALESCE(p_memo, 'Reversal of entry ' || je.entry_no),
         'reversal', je.id::text, p_idempotency_key, je.id, kernel.current_actor()
    FROM journal_entry je WHERE je.id = p_entry_id
  RETURNING id INTO v_new;

  FOR v_line IN SELECT * FROM journal_line WHERE journal_entry_id = p_entry_id ORDER BY line_no LOOP
    v_no := v_no + 1;
    INSERT INTO journal_line (
      journal_entry_id, line_no, account_id, debit, credit, currency, fx_rate,
      base_debit, base_credit, party_id, subledger_type_code, memo
    ) VALUES (
      v_new, v_no, v_line.account_id,
      v_line.credit, v_line.debit,          -- swap sides
      v_line.currency, v_line.fx_rate,
      v_line.base_credit, v_line.base_debit,
      v_line.party_id, v_line.subledger_type_code,
      'Reversal: ' || COALESCE(v_line.memo,'')
    );
  END LOOP;

  -- F1: the mirror restores the GL control; this restores the open items.
  PERFORM unapply_for_entry(p_entry_id, v_new);

  RETURN v_new;
END; $$;
COMMENT ON FUNCTION reverse_journal_entry IS
  'Posts a mirror entry linked via reversal_of_id, un-applies any settlement, and refuses to re-reverse.';

-- Trial balance — must always net to zero.
CREATE OR REPLACE FUNCTION trial_balance(p_as_of date DEFAULT current_date)
RETURNS TABLE (account_id uuid, code text, name text, debit numeric, credit numeric, balance numeric)
LANGUAGE sql STABLE AS $$
  SELECT a.id, a.code, a.name,
         COALESCE(sum(jl.base_debit),0)  AS debit,
         COALESCE(sum(jl.base_credit),0) AS credit,
         COALESCE(sum(jl.base_debit - jl.base_credit),0) AS balance
    FROM account a
    LEFT JOIN journal_line jl ON jl.account_id = a.id
    LEFT JOIN journal_entry je ON je.id = jl.journal_entry_id AND je.entry_date <= p_as_of
    WHERE jl.id IS NULL OR je.id IS NOT NULL
    GROUP BY a.id, a.code, a.name
    ORDER BY a.code;
$$;
COMMENT ON FUNCTION trial_balance IS 'Per-account debit/credit/balance as of a date. Sum of balance must be 0.';

-- Reversal status is derived, never stored (keeps the journal append-only).
CREATE VIEW journal_entry_status AS
  SELECT je.*,
         (r.id IS NOT NULL) AS is_reversed,
         r.id AS reversed_by_id
    FROM journal_entry je
    LEFT JOIN journal_entry r ON r.reversal_of_id = je.id;
COMMENT ON VIEW journal_entry_status IS 'Derived reversal status; the journal itself is never mutated.';
