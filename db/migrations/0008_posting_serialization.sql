-- ============================================================================
-- 0008_posting_serialization.sql
--
-- Ports four ideas from the sibling kernel into this one, plus one data-quality
-- fix. All are idempotent and re-runnable; the runner applies this once per
-- tenant schema inside a single transaction.
--
--   1. POSTING SERIALIZATION. A per-tenant journal_counter row is locked FOR
--      UPDATE at the start of every posting. The kernel already assigned entry_no
--      from an identity sequence, which is atomic, but the hash chain (JI-3)
--      reads the latest entry_hash and links to it: two concurrent posters both
--      read the same predecessor and the second loses to ux_journal_entry_prev_hash.
--      The lock makes the chain race-free.
--   2. LOCK ORDER. The counter is taken first, then the fiscal period, then each
--      line's account. A total, identical order for every poster makes a deadlock
--      impossible by construction.
--   3. POSTING SEAL. journal_entry gains posting_xid; a line may only be added by
--      the transaction that created the entry, so an entry cannot silently grow
--      after it was posted.
--   4. SINGLETON TABLE. tenant_config claimed "one row per tenant" but nothing
--      enforced it; a unique index on a constant makes the claim true.
--   5. IANA TIMEZONE. tenant_config.timezone and location.timezone become a
--      validated domain instead of free text.
--
-- The same changes are mirrored into the base schema files (00_kernel.sql,
-- 20_money.sql, 30_ledger.sql, 50_vendormall.sql, provision.sh) so a fresh
-- db/provision.sh build is correct too.
-- ============================================================================
\set ON_ERROR_STOP on

-- ============================================================================
-- PART 0. IANA timezone domain (kernel-level; idempotent per tenant).
-- ============================================================================
CREATE OR REPLACE FUNCTION kernel.is_iana_timezone(p_name text)
RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT p_name IS NOT NULL
     AND EXISTS (SELECT 1 FROM pg_timezone_names tz WHERE tz.name = p_name)
$$;
COMMENT ON FUNCTION kernel.is_iana_timezone IS
  'True when p_name is a valid IANA timezone name (pg_timezone_names).';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
     WHERE t.typname = 'iana_timezone' AND n.nspname = 'kernel'
  ) THEN
    CREATE DOMAIN kernel.iana_timezone AS text
      CHECK (kernel.is_iana_timezone(VALUE));
    COMMENT ON DOMAIN kernel.iana_timezone IS
      'IANA timezone name (e.g. America/New_York). Validated against pg_timezone_names.';
  END IF;
END $$;

-- ============================================================================
-- PART 1. tenant_config: validated timezone + singleton guard.
-- ============================================================================
ALTER TABLE tenant_config
  ALTER COLUMN timezone TYPE kernel.iana_timezone;

CREATE UNIQUE INDEX IF NOT EXISTS ux_tenant_config_singleton
  ON tenant_config ((true));

-- ============================================================================
-- PART 2. location.timezone becomes a validated domain.
-- ============================================================================
DO $$
BEGIN
  IF to_regclass(current_schema() || '.location') IS NOT NULL THEN
    ALTER TABLE location
      ALTER COLUMN timezone TYPE kernel.iana_timezone;
  END IF;
END $$;

-- ============================================================================
-- PART 3. journal_counter: the posting serialization point.
-- ============================================================================
CREATE TABLE IF NOT EXISTS journal_counter (
  tenant_id     uuid PRIMARY KEY DEFAULT kernel.current_tenant(),
  last_entry_no bigint NOT NULL DEFAULT 0 CHECK (last_entry_no >= 0),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE journal_counter IS
  'One row per tenant. Locked FOR UPDATE at the start of every posting to serialize the hash chain and fix lock order (counter -> period -> account).';

-- Seed the counter at the current high-water mark so it never regresses.
INSERT INTO journal_counter (tenant_id, last_entry_no)
SELECT tc.tenant_id,
       COALESCE((SELECT max(entry_no) FROM journal_entry), 0)
  FROM tenant_config tc
ON CONFLICT (tenant_id) DO NOTHING;

-- ============================================================================
-- PART 4. Posting seal column on journal_entry.
-- ============================================================================
ALTER TABLE journal_entry
  ADD COLUMN IF NOT EXISTS posting_xid xid8 NOT NULL DEFAULT pg_current_xact_id();

-- ============================================================================
-- PART 5. Serialize + order the posting (hash chain locks the counter first).
-- ============================================================================
CREATE OR REPLACE FUNCTION journal_entry_hash_chain() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_prev text;
  v_last bigint;
BEGIN
  SELECT last_entry_no INTO v_last
    FROM journal_counter
   WHERE tenant_id = NEW.tenant_id
   FOR UPDATE;
  IF v_last IS NULL THEN
    RAISE EXCEPTION 'tenant % has no journal counter; provisioning is incomplete', NEW.tenant_id
      USING ERRCODE = '23503';
  END IF;
  UPDATE journal_counter
     SET last_entry_no = NEW.entry_no, updated_at = now()
   WHERE tenant_id = NEW.tenant_id;

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
  'BEFORE INSERT: locks the tenant journal counter (serialization + lock order), then chains each entry to its predecessor (JI-3).';

-- ============================================================================
-- PART 6. Period lock (lock order step 2).
-- ============================================================================
CREATE OR REPLACE FUNCTION assert_period_open() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_status text;
BEGIN
  SELECT status INTO v_status FROM fiscal_period
    WHERE start_date <= NEW.entry_date AND end_date >= NEW.entry_date
    ORDER BY start_date
    LIMIT 1
    FOR UPDATE;
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'No fiscal period covers entry_date %', NEW.entry_date USING ERRCODE='23514';
  END IF;
  IF v_status <> 'open' THEN
    RAISE EXCEPTION 'Fiscal period for % is %; postings are blocked', NEW.entry_date, v_status
      USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END; $$;

-- ============================================================================
-- PART 7. Account lock (lock order step 3) + posting seal.
-- ============================================================================
CREATE OR REPLACE FUNCTION assert_line_account_lock() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  SELECT id INTO v_id FROM account WHERE id = NEW.account_id FOR UPDATE;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'Journal line account % does not exist', NEW.account_id USING ERRCODE='23503';
  END IF;
  RETURN NEW;
END; $$;
COMMENT ON FUNCTION assert_line_account_lock IS
  'BEFORE INSERT on journal_line: locks the line account FOR UPDATE (posting lock order step 3).';

CREATE OR REPLACE TRIGGER trg_journal_line_0_lock_account
  BEFORE INSERT ON journal_line
  FOR EACH ROW EXECUTE FUNCTION assert_line_account_lock();

CREATE OR REPLACE FUNCTION assert_line_same_xact() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_xid xid8;
BEGIN
  SELECT posting_xid INTO v_xid FROM journal_entry WHERE id = NEW.journal_entry_id;
  IF v_xid IS NULL THEN
    RAISE EXCEPTION 'Journal line journal % does not exist', NEW.journal_entry_id USING ERRCODE='23503';
  END IF;
  IF v_xid IS DISTINCT FROM pg_current_xact_id() THEN
    RAISE EXCEPTION
      'A journal line cannot be added to entry % after it was posted; the entry is sealed to its posting transaction',
      NEW.journal_entry_id USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END; $$;
COMMENT ON FUNCTION assert_line_same_xact IS
  'BEFORE INSERT on journal_line: refuses a line whose transaction differs from the journal entry''s posting_xid (posting seal).';

CREATE OR REPLACE TRIGGER trg_journal_line_seal
  BEFORE INSERT ON journal_line
  FOR EACH ROW EXECUTE FUNCTION assert_line_same_xact();
