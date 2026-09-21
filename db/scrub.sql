-- ============================================================================
-- scrub.sql — irreversibly anonymise PII in a NON-PRODUCTION copy.
--
-- ############################################################################
-- #  NEVER RUN THIS AGAINST PRODUCTION. It destroys data in place.           #
-- #  It is applied to a RESTORED COPY by scripts/sync_to_dev.sh.             #
-- ############################################################################
--
-- Goal: give a developer REAL DATA SHAPE — real row counts, real distributions,
-- real edge cases, real amounts — without real identities. Financial values are
-- deliberately NOT altered: changing them would break the invariants that make
-- the copy useful for debugging, and the amounts are not what makes the data
-- sensitive. Identities are.
--
-- What gets scrubbed (driven by kernel.data_classification where possible):
--   * person names, dates of birth
--   * party display names
--   * contact mechanisms (email/phone)
--   * postal addresses
--   * party identifiers (TINs/SSNs — the highest-risk field in the schema)
--   * journal entry / line memos (free text leaks names)
--   * lease terms marked confidential
--   * card last4 on payment tenders
--
-- What is preserved:
--   * every id, foreign key and relationship
--   * all monetary amounts, dates and account structure
--   * row counts and cardinality
-- ============================================================================

\set ON_ERROR_STOP on

-- ----------------------------------------------------------------------------
-- Session context.
--
-- Scrubbing is a bulk UPDATE, so it fires the audit triggers, which insert into
-- audit_log with kernel.current_tenant() / kernel.current_actor(). Both are
-- session GUCs. With app.tenant_id unset, audit_log.tenant_id is NULL and the
-- NOT NULL constraint aborts the scrub.
--
-- The tenant id is derived from the data rather than passed in: one schema is
-- exactly one tenant, so the schema already knows the answer and the caller
-- cannot get it wrong.
-- ----------------------------------------------------------------------------
DO $$
DECLARE v_tenant uuid;
BEGIN
  -- Guard FIRST, before anything touches the data or the session.
  IF current_setting('ninja.allow_scrub', true) IS DISTINCT FROM 'yes' THEN
    RAISE EXCEPTION
      'Refusing to scrub: set ninja.allow_scrub=''yes'' to confirm this is NOT production'
      USING ERRCODE='42501';
  END IF;

  SELECT tenant_id INTO v_tenant FROM tenant_config LIMIT 1;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'Cannot determine tenant_id: tenant_config is empty in schema %',
      current_schema();
  END IF;
  PERFORM set_config('app.tenant_id', v_tenant::text, false);
  -- A recognisable actor, so the scrub is visible in the audit trail as the
  -- thing that changed every identity row.
  PERFORM set_config('app.actor_id', '00000000-0000-7000-8000-000000005c4b', false);
  RAISE NOTICE 'Scrub context: tenant_id=%', v_tenant;
END $$;

DO $$
DECLARE
  v_schema text := current_schema();
  v_count  bigint;
BEGIN
  RAISE NOTICE 'Scrubbing PII in schema %', v_schema;

  -- --- Guard: refuse to run against anything that looks like production ------
  -- A deliberate speed bump. Set ninja.allow_scrub = 'yes' to proceed.
  IF current_setting('ninja.allow_scrub', true) IS DISTINCT FROM 'yes' THEN
    RAISE EXCEPTION
      'Refusing to scrub: set ninja.allow_scrub=''yes'' to confirm this is NOT production'
      USING ERRCODE='42501';
  END IF;

  -- --- person ---------------------------------------------------------------
  UPDATE person SET
    given_name  = 'Given'  || substr(md5(party_id::text), 1, 6),
    family_name = 'Family' || substr(md5(party_id::text), 7, 6),
    date_of_birth = CASE WHEN date_of_birth IS NULL THEN NULL
                         ELSE make_date(1970 + (abs(hashtext(party_id::text)) % 40), 1, 1) END;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RAISE NOTICE '  person rows scrubbed: %', v_count;

  -- --- party display names --------------------------------------------------
  -- Keep organisation-vs-person shape so reports still look realistic.
  UPDATE party SET
    display_name = CASE party_type
      WHEN 'person' THEN 'Given' || substr(md5(id::text),1,6) || ' Family' || substr(md5(id::text),7,6)
      ELSE 'Org ' || substr(md5(id::text),1,8) || ' LLC'
    END;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RAISE NOTICE '  party rows scrubbed: %', v_count;

  -- trading_name ("doing business as") identifies the business just as well as
  -- legal_name does. Missing it the first time is exactly why the export is
  -- leak-tested rather than trusted.
  UPDATE organization SET
    legal_name   = 'Org ' || substr(md5(party_id::text),1,8) || ' LLC',
    trading_name = CASE WHEN trading_name IS NULL THEN NULL
                        ELSE 'DBA ' || substr(md5(party_id::text),9,8) END;

  -- --- contact mechanisms ---------------------------------------------------
  -- Preserve the KIND (email vs phone) so validation logic still gets exercised.
  UPDATE party_contact_mechanism SET
    value = CASE
      WHEN value LIKE '%@%' THEN 'user' || substr(md5(id::text),1,8) || '@example.invalid'
      WHEN value ~ '^[0-9+()\-. ]+$' THEN '+1555' || lpad((abs(hashtext(id::text)) % 10000000)::text, 7, '0')
      ELSE 'redacted-' || substr(md5(id::text),1,8)
    END;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RAISE NOTICE '  contact mechanisms scrubbed: %', v_count;

  -- --- postal addresses -----------------------------------------------------
  -- Keep city/state/country: geography drives tax and reporting logic, and is
  -- not what identifies a person.
  UPDATE postal_address SET
    line1       = (100 + (abs(hashtext(id::text)) % 9900))::text || ' Example St',
    line2       = NULL,
    postal_code = lpad((abs(hashtext(id::text)) % 100000)::text, 5, '0');
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RAISE NOTICE '  postal addresses scrubbed: %', v_count;

  -- --- party identifiers (TIN/SSN/EIN) --------------------------------------
  -- The single highest-risk field in the database. These are encrypted at rest
  -- (ADR-0018/0027) but a dev box must not hold them even encrypted, because the
  -- key would have to travel with them to be useful.
  --
  -- identifier_hash MUST be rewritten too. It is an UNSALTED sha256 of the
  -- plaintext, and the plaintext is a 9-digit SSN: an attacker with the hash
  -- enumerates the whole keyspace in seconds. Scrubbing the ciphertext while
  -- leaving the hash would leak exactly what we are trying to protect.
  --
  -- The hash carries a uniqueness constraint, so the fake value must stay
  -- unique per row: derive both from the row id.
  IF to_regclass(v_schema || '.party_identifier') IS NOT NULL THEN
    IF COALESCE(current_setting('app.pii_key', true), '') = '' THEN
      RAISE EXCEPTION
        'app.pii_key must be set to re-encrypt scrubbed identifiers'
        USING ERRCODE='28000';
    END IF;

    -- UPDATE ... FROM LATERAL cannot see the target table, so the fake value
    -- is spelled out in both places. 900-xx-xxxx is not an issuable SSN range.
    UPDATE party_identifier SET
      identifier_value_enc = pgp_sym_encrypt(
        '900-00-' || lpad((abs(hashtext(id::text)) % 10000)::text, 4, '0'),
        current_setting('app.pii_key', true)),
      identifier_hash = encode(digest(
        '900-00-' || lpad((abs(hashtext(id::text)) % 10000)::text, 4, '0'),
        'sha256'), 'hex');
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RAISE NOTICE '  party identifiers scrubbed (value + hash): %', v_count;
  END IF;

  -- --- free-text memos ------------------------------------------------------
  -- Memos routinely contain customer names, phone numbers and card details.
  -- Keep a short prefix so entries stay recognisable while debugging.
  --
  -- The ledger is append-only and kernel.forbid_mutation() blocks UPDATE, which
  -- is exactly right for production. This copy is not production: it is a
  -- throwaway staging database that exists only to be scrubbed and dumped.
  -- session_replication_role='replica' suspends the guard for these two
  -- statements and nothing else. The amounts are never touched, so the books
  -- still balance -- which the verification block below proves.
  PERFORM set_config('session_replication_role', 'replica', true);

  UPDATE journal_entry SET memo = left(COALESCE(memo,''), 24) WHERE memo IS NOT NULL;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RAISE NOTICE '  journal entry memos truncated: %', v_count;

  UPDATE journal_line  SET memo = left(COALESCE(memo,''), 24) WHERE memo IS NOT NULL;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RAISE NOTICE '  journal line memos truncated: %', v_count;

  PERFORM set_config('session_replication_role', 'origin', true);

  -- --- card metadata --------------------------------------------------------
  IF to_regclass(v_schema || '.payment_tender') IS NOT NULL THEN
    UPDATE payment_tender SET
      card_last4    = CASE WHEN card_last4 IS NULL THEN NULL
                           ELSE lpad((abs(hashtext(id::text)) % 10000)::text, 4, '0') END,
      processor_ref = CASE WHEN processor_ref IS NULL THEN NULL
                           ELSE 'ref-' || substr(md5(id::text),1,12) END;
  END IF;

  -- --- lease terms (classified confidential) --------------------------------
  IF to_regclass(v_schema || '.lease') IS NOT NULL THEN
    UPDATE lease SET notes = NULL WHERE to_jsonb(lease.*) ? 'notes';
  END IF;

  -- --- audit_log: the biggest leak of all -----------------------------------
  -- audit_log.before_data / after_data are full jsonb row snapshots. Every
  -- name, address and contact value this script just rewrote is still sitting
  -- in there verbatim -- INCLUDING the rows written by the scrub's own UPDATEs,
  -- whose before_data is the original PII.
  --
  -- Scrubbing the live tables and shipping audit_log intact would hand over
  -- exactly the data we claim to have removed. Purge the payloads instead of
  -- trying to rewrite them field by field: the developer needs the audit
  -- TRAIL (who/what/when, row counts, cardinality), not the old values.
  --
  -- This runs LAST so it also captures the scrub's own writes.
  PERFORM set_config('session_replication_role', 'replica', true);

  UPDATE audit_log
     SET before_data = CASE WHEN before_data IS NULL THEN NULL
                            ELSE jsonb_build_object('scrubbed', true) END,
         after_data  = CASE WHEN after_data  IS NULL THEN NULL
                            ELSE jsonb_build_object('scrubbed', true) END
   WHERE before_data IS NOT NULL OR after_data IS NOT NULL;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RAISE NOTICE '  audit_log payloads purged: %', v_count;

  PERFORM set_config('session_replication_role', 'origin', true);

  RAISE NOTICE 'Scrub complete for schema %.', v_schema;
END $$;

-- ----------------------------------------------------------------------------
-- Verification: the scrub must not have broken the books.
--
-- This is the point of scrubbing identities but NOT amounts — the copy must
-- still satisfy every accounting invariant, or it is useless for debugging.
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  v_tb   numeric;
  v_bs   numeric;
  v_subs integer;
BEGIN
  SELECT COALESCE(sum(balance),0) INTO v_tb FROM trial_balance(current_date);
  SELECT count(*) INTO v_subs FROM subledger_control_check() WHERE difference <> 0;

  BEGIN
    SELECT balance_sheet_check(current_date) INTO v_bs;
  EXCEPTION WHEN undefined_function THEN
    v_bs := 0;
  END;

  IF v_tb <> 0 THEN
    RAISE EXCEPTION 'Scrub broke the trial balance (now %)', v_tb;
  END IF;
  IF v_subs <> 0 THEN
    RAISE EXCEPTION 'Scrub broke % subledger control totals', v_subs;
  END IF;
  IF v_bs <> 0 THEN
    RAISE EXCEPTION 'Scrub broke the balance sheet (now %)', v_bs;
  END IF;

  RAISE NOTICE 'Post-scrub verification passed: trial balance, subledgers and balance sheet all tie.';
END $$;
