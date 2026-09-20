--
-- PostgreSQL database dump
--

\restrict Lxr0Lt8efdYD3w0PRxWR7usntf1EZMMzVuAX2QgzxUqBv4bBwDY3rndyGSmPJFx

-- Dumped from database version 18.6 (Debian 18.6-1.pgdg12+2)
-- Dumped by pg_dump version 18.6 (Debian 18.6-1.pgdg12+2)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: kernel; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA kernel;


--
-- Name: SCHEMA kernel; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA kernel IS 'Ninja EMP shared kernel: domains, helper functions, global reference data. Read-only to tenant roles.';


--
-- Name: tenant_demo; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA tenant_demo;


--
-- Name: btree_gist; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA kernel;


--
-- Name: EXTENSION btree_gist; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION btree_gist IS 'support for indexing common datatypes in GiST';


--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA kernel;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: currency_code; Type: DOMAIN; Schema: kernel; Owner: -
--

CREATE DOMAIN kernel.currency_code AS character(3)
	CONSTRAINT currency_code_check CHECK ((((VALUE)::text = upper((VALUE)::text)) AND (VALUE ~ '^[A-Z]{3}$'::text)));


--
-- Name: DOMAIN currency_code; Type: COMMENT; Schema: kernel; Owner: -
--

COMMENT ON DOMAIN kernel.currency_code IS 'ISO-4217 alpha-3, uppercase.';


--
-- Name: fx_rate; Type: DOMAIN; Schema: kernel; Owner: -
--

CREATE DOMAIN kernel.fx_rate AS numeric(19,10)
	CONSTRAINT fx_rate_check CHECK ((VALUE > (0)::numeric));


--
-- Name: DOMAIN fx_rate; Type: COMMENT; Schema: kernel; Owner: -
--

COMMENT ON DOMAIN kernel.fx_rate IS 'Exchange rate. 10 dp to avoid compounding rounding error.';


--
-- Name: money_amount; Type: DOMAIN; Schema: kernel; Owner: -
--

CREATE DOMAIN kernel.money_amount AS numeric(19,4);


--
-- Name: DOMAIN money_amount; Type: COMMENT; Schema: kernel; Owner: -
--

COMMENT ON DOMAIN kernel.money_amount IS 'Monetary amount. Scale 4 is the rounding boundary. Never PG money type.';


--
-- Name: percent_rate; Type: DOMAIN; Schema: kernel; Owner: -
--

CREATE DOMAIN kernel.percent_rate AS numeric(9,6);


--
-- Name: DOMAIN percent_rate; Type: COMMENT; Schema: kernel; Owner: -
--

COMMENT ON DOMAIN kernel.percent_rate IS 'A rate expressed as a fraction (0.075000 = 7.5%).';


--
-- Name: quantity; Type: DOMAIN; Schema: kernel; Owner: -
--

CREATE DOMAIN kernel.quantity AS numeric(19,4);


--
-- Name: DOMAIN quantity; Type: COMMENT; Schema: kernel; Owner: -
--

COMMENT ON DOMAIN kernel.quantity IS 'Countable/measurable quantity (units, weight).';


--
-- Name: audit_row(); Type: FUNCTION; Schema: kernel; Owner: -
--

CREATE FUNCTION kernel.audit_row() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: FUNCTION audit_row(); Type: COMMENT; Schema: kernel; Owner: -
--

COMMENT ON FUNCTION kernel.audit_row() IS 'AFTER I/U/D trigger: writes before/after JSON to the tenant audit_log.';


--
-- Name: current_actor(); Type: FUNCTION; Schema: kernel; Owner: -
--

CREATE FUNCTION kernel.current_actor() RETURNS uuid
    LANGUAGE sql STABLE
    AS $$
  SELECT NULLIF(current_setting('app.actor_id', true), '')::uuid
$$;


--
-- Name: FUNCTION current_actor(); Type: COMMENT; Schema: kernel; Owner: -
--

COMMENT ON FUNCTION kernel.current_actor() IS 'Acting user/service id from app.actor_id session GUC.';


--
-- Name: current_tenant(); Type: FUNCTION; Schema: kernel; Owner: -
--

CREATE FUNCTION kernel.current_tenant() RETURNS uuid
    LANGUAGE sql STABLE
    AS $$
  SELECT NULLIF(current_setting('app.tenant_id', true), '')::uuid
$$;


--
-- Name: FUNCTION current_tenant(); Type: COMMENT; Schema: kernel; Owner: -
--

COMMENT ON FUNCTION kernel.current_tenant() IS 'Tenant id from app.tenant_id session GUC. NULL when unset (RLS then hides all rows).';


--
-- Name: forbid_mutation(); Type: FUNCTION; Schema: kernel; Owner: -
--

CREATE FUNCTION kernel.forbid_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'Table % is append-only; % is not permitted. Post a reversal entry instead.',
    TG_TABLE_NAME, TG_OP USING ERRCODE = '55000';
END; $$;


--
-- Name: FUNCTION forbid_mutation(); Type: COMMENT; Schema: kernel; Owner: -
--

COMMENT ON FUNCTION kernel.forbid_mutation() IS 'Append-only guard: blocks UPDATE/DELETE.';


--
-- Name: mask_tail(text, integer); Type: FUNCTION; Schema: kernel; Owner: -
--

CREATE FUNCTION kernel.mask_tail(p_value text, p_keep integer DEFAULT 4) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
  SELECT CASE
    WHEN p_value IS NULL THEN NULL
    WHEN length(p_value) <= p_keep THEN repeat('*', length(p_value))
    ELSE repeat('*', length(p_value) - p_keep) || right(p_value, p_keep)
  END
$$;


--
-- Name: FUNCTION mask_tail(p_value text, p_keep integer); Type: COMMENT; Schema: kernel; Owner: -
--

COMMENT ON FUNCTION kernel.mask_tail(p_value text, p_keep integer) IS 'Mask all but the last n characters (PII display).';


--
-- Name: now_utc(); Type: FUNCTION; Schema: kernel; Owner: -
--

CREATE FUNCTION kernel.now_utc() RETURNS timestamp with time zone
    LANGUAGE sql STABLE
    AS $$ SELECT now() $$;


--
-- Name: FUNCTION now_utc(); Type: COMMENT; Schema: kernel; Owner: -
--

COMMENT ON FUNCTION kernel.now_utc() IS 'Current instant (timestamptz is stored UTC).';


--
-- Name: touch_audit(); Type: FUNCTION; Schema: kernel; Owner: -
--

CREATE FUNCTION kernel.touch_audit() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.updated_at := now();
  NEW.updated_by := kernel.current_actor();
  NEW.version    := COALESCE(OLD.version, 1) + 1;
  RETURN NEW;
END; $$;


--
-- Name: FUNCTION touch_audit(); Type: COMMENT; Schema: kernel; Owner: -
--

COMMENT ON FUNCTION kernel.touch_audit() IS 'BEFORE UPDATE trigger: stamps updated_at/updated_by, increments version (optimistic locking).';


--
-- Name: apply_payment(uuid, text, kernel.money_amount, date, text); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.apply_payment(p_party_id uuid, p_subledger_type text, p_amount kernel.money_amount, p_entry_date date, p_idempotency_key text) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_receipt   boolean;   -- true = store receives cash (AR), false = store pays (AP-like)
  v_control   uuid;
  v_cash      uuid;
  v_ccy       kernel.currency_code;
  v_entry     uuid;
  v_remaining kernel.money_amount := p_amount;
  v_item      record;
  v_apply     kernel.money_amount;
  v_lines     jsonb;
BEGIN
  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'Payment amount must be positive' USING ERRCODE='23514';
  END IF;

  -- Direction: AR is debit-normal (we receive); all payable-like subledgers are credit-normal (we pay).
  v_receipt := p_subledger_type = 'ar';
  v_control := posting_account(subledger_control_role(p_subledger_type));
  v_cash    := posting_account('cash');
  v_ccy     := (SELECT functional_currency FROM tenant_config LIMIT 1);

  -- Post the cash entry first (idempotent).
  IF v_receipt THEN
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', v_cash, 'debit', p_amount, 'currency', v_ccy, 'memo', 'Payment received'),
      jsonb_build_object('account_id', v_control, 'credit', p_amount, 'currency', v_ccy,
                         'party_id', p_party_id, 'subledger_type_code', p_subledger_type, 'memo', 'Payment applied')
    );
  ELSE
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', v_control, 'debit', p_amount, 'currency', v_ccy,
                         'party_id', p_party_id, 'subledger_type_code', p_subledger_type, 'memo', 'Payment applied'),
      jsonb_build_object('account_id', v_cash, 'credit', p_amount, 'currency', v_ccy, 'memo', 'Payment made')
    );
  END IF;

  v_entry := post_journal_entry(
    p_entry_date, 'Payment ' || p_subledger_type || ' party ' || p_party_id,
    'payment', p_party_id::text, p_idempotency_key, v_lines
  );

  -- If this idempotency key was already applied, do not double-allocate.
  IF EXISTS (SELECT 1 FROM payment_application WHERE journal_entry_id = v_entry) THEN
    RETURN v_entry;
  END IF;

  -- Allocate FIFO across the party's open items.
  FOR v_item IN
    SELECT * FROM open_item
     WHERE party_id = p_party_id
       AND subledger_type_code = p_subledger_type
       AND status IN ('open','partial')
       AND deleted_at IS NULL
     ORDER BY COALESCE(due_date, issue_date), issue_date, id
     FOR UPDATE
  LOOP
    EXIT WHEN v_remaining <= 0;
    v_apply := LEAST(v_remaining, v_item.open_amount);
    IF v_apply <= 0 THEN CONTINUE; END IF;

    INSERT INTO payment_application (open_item_id, applied_amount, currency, applied_date, journal_entry_id)
    VALUES (v_item.id, v_apply, v_ccy, p_entry_date, v_entry);

    UPDATE open_item
       SET open_amount = open_amount - v_apply,
           status = CASE WHEN open_amount - v_apply = 0 THEN 'settled' ELSE 'partial' END
     WHERE id = v_item.id;

    v_remaining := v_remaining - v_apply;
  END LOOP;

  IF v_remaining > 0 THEN
    RAISE EXCEPTION 'Payment of % exceeds open items for party % subledger % (unapplied %)',
      p_amount, p_party_id, p_subledger_type, v_remaining USING ERRCODE='23514';
  END IF;

  RETURN v_entry;
END; $$;


--
-- Name: FUNCTION apply_payment(p_party_id uuid, p_subledger_type text, p_amount kernel.money_amount, p_entry_date date, p_idempotency_key text); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.apply_payment(p_party_id uuid, p_subledger_type text, p_amount kernel.money_amount, p_entry_date date, p_idempotency_key text) IS 'Idempotent payment: posts cash entry and allocates FIFO across open items (ADR-0023).';


--
-- Name: assert_entry_balanced(); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.assert_entry_balanced() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: assert_entry_balanced_p(); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.assert_entry_balanced_p() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_entry uuid := COALESCE(NEW.journal_entry_id, OLD.journal_entry_id);
  v_d kernel.money_amount; v_c kernel.money_amount;
BEGIN
  SELECT COALESCE(sum(debit),0), COALESCE(sum(credit),0) INTO v_d, v_c
    FROM jl_p WHERE journal_entry_id = v_entry;
  IF v_d <> v_c THEN
    RAISE EXCEPTION 'Partitioned entry % unbalanced: % <> %', v_entry, v_d, v_c USING ERRCODE='23514';
  END IF;
  RETURN NULL;
END; $$;


--
-- Name: assert_party_subtype(); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.assert_party_subtype() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE v_type text;
BEGIN
  SELECT party_type INTO v_type FROM party WHERE id = NEW.party_id;
  IF v_type IS NULL THEN
    RAISE EXCEPTION 'party % does not exist', NEW.party_id USING ERRCODE='23503';
  END IF;
  IF v_type <> TG_ARGV[0] THEN
    RAISE EXCEPTION 'party % is %, but % subtype requires %',
      NEW.party_id, v_type, TG_TABLE_NAME, TG_ARGV[0] USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END; $$;


--
-- Name: assert_payment_tenders(); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.assert_payment_tenders() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_payment uuid := COALESCE(NEW.payment_id, OLD.payment_id);
  v_sum     numeric;
  r         record;
BEGIN
  SELECT * INTO r FROM payment WHERE id = v_payment;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF r.status = 'pending' THEN RETURN NULL; END IF;

  SELECT COALESCE(sum(amount), 0) INTO v_sum
    FROM payment_tender WHERE payment_id = v_payment;

  IF v_sum <> r.amount THEN
    RAISE EXCEPTION 'Payment % tenders (%) do not equal payment amount (%)',
      v_payment, v_sum, r.amount;
  END IF;
  RETURN NULL;
END $$;


--
-- Name: assert_period_open(); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.assert_period_open() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: assert_sale_totals(); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.assert_sale_totals() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_sale    uuid := COALESCE(NEW.sale_id, OLD.sale_id);
  v_sub     numeric;
  v_disc    numeric;
  v_tax     numeric;
  r         record;
BEGIN
  -- Resolve the sale row; skip if it has been removed.
  SELECT * INTO r FROM sale WHERE id = v_sale;
  IF NOT FOUND THEN RETURN NULL; END IF;

  SELECT COALESCE(sum(quantity * unit_price), 0),
         COALESCE(sum(discount_amount), 0),
         COALESCE(sum(tax_amount), 0)
    INTO v_sub, v_disc, v_tax
    FROM sale_line WHERE sale_id = v_sale;

  IF r.subtotal <> v_sub OR r.discount_total <> v_disc OR r.tax_total <> v_tax THEN
    RAISE EXCEPTION
      'Sale % totals do not match its lines: header(sub=%, disc=%, tax=%) lines(sub=%, disc=%, tax=%)',
      v_sale, r.subtotal, r.discount_total, r.tax_total, v_sub, v_disc, v_tax;
  END IF;
  RETURN NULL;
END $$;


--
-- Name: assert_subledger_control(); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.assert_subledger_control() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: effective_tax_rate(uuid, date); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.effective_tax_rate(p_jurisdiction uuid, p_on date) RETURNS numeric
    LANGUAGE sql STABLE
    AS $$
  SELECT rate FROM tax_rate
   WHERE jurisdiction_id = p_jurisdiction
     AND p_on >= effective_from
     AND (effective_thru IS NULL OR p_on <= effective_thru)
   LIMIT 1
$$;


--
-- Name: FUNCTION effective_tax_rate(p_jurisdiction uuid, p_on date); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.effective_tax_rate(p_jurisdiction uuid, p_on date) IS 'Effective-dated tax rate lookup (ADR-0021).';


--
-- Name: ensure_fiscal_calendar(); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.ensure_fiscal_calendar() RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM generate_fiscal_year(EXTRACT(year FROM current_date)::int);
  PERFORM generate_fiscal_year(EXTRACT(year FROM current_date)::int + 1);
END; $$;


--
-- Name: FUNCTION ensure_fiscal_calendar(); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.ensure_fiscal_calendar() IS 'Generates current + next fiscal year of periods (ADR-0014).';


--
-- Name: fx_to_functional(kernel.currency_code, date); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.fx_to_functional(p_from kernel.currency_code, p_as_of date) RETURNS kernel.fx_rate
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
  v_func kernel.currency_code;
  v_rate kernel.fx_rate;
BEGIN
  SELECT functional_currency INTO v_func FROM tenant_config LIMIT 1;
  IF p_from = v_func THEN RETURN 1; END IF;
  SELECT rate INTO v_rate FROM exchange_rate
    WHERE from_currency = p_from AND to_currency = v_func AND as_of <= p_as_of
    ORDER BY as_of DESC LIMIT 1;
  IF v_rate IS NULL THEN
    RAISE EXCEPTION 'No exchange rate % -> % as of %', p_from, v_func, p_as_of;
  END IF;
  RETURN v_rate;
END; $$;


--
-- Name: FUNCTION fx_to_functional(p_from kernel.currency_code, p_as_of date); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.fx_to_functional(p_from kernel.currency_code, p_as_of date) IS 'Latest rate converting p_from into the tenant functional currency as of a date.';


--
-- Name: generate_fiscal_year(integer); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.generate_fiscal_year(p_year integer) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_start_month smallint;
  v_i int;
  v_start date;
  v_end date;
  v_count int := 0;
BEGIN
  SELECT fiscal_year_start_month INTO v_start_month FROM tenant_config LIMIT 1;
  IF v_start_month IS NULL THEN
    RAISE EXCEPTION 'tenant_config row is required before generating fiscal periods' USING ERRCODE='23514';
  END IF;

  FOR v_i IN 0..11 LOOP
    v_start := make_date(p_year, 1, 1) + make_interval(months => (v_start_month - 1 + v_i));
    v_end   := (v_start + make_interval(months => 1)) - interval '1 day';
    INSERT INTO fiscal_period (fiscal_year, period_no, start_date, end_date, status)
    VALUES (p_year, v_i + 1, v_start::date, v_end::date, 'open')
    ON CONFLICT (tenant_id, fiscal_year, period_no) DO NOTHING;
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END; $$;


--
-- Name: FUNCTION generate_fiscal_year(p_year integer); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.generate_fiscal_year(p_year integer) IS 'Creates 12 monthly fiscal periods for a year (idempotent). ADR-0014 provisioning requirement.';


--
-- Name: open_item_control_check(); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.open_item_control_check() RETURNS TABLE(subledger_type_code text, open_item_total numeric, control_total numeric, difference numeric)
    LANGUAGE sql STABLE
    AS $$
  WITH oi AS (
    SELECT subledger_type_code AS st, sum(open_amount) AS total
      FROM open_item
     WHERE status IN ('open','partial') AND deleted_at IS NULL
     GROUP BY subledger_type_code
  ),
  ctl AS (
    SELECT a.control_subledger_type_code AS st,
           abs(sum(jl.base_debit - jl.base_credit)) AS total
      FROM journal_line jl
      JOIN account a ON a.id = jl.account_id
     WHERE a.is_control
     GROUP BY a.control_subledger_type_code
  )
  SELECT COALESCE(oi.st, ctl.st),
         COALESCE(oi.total, 0),
         COALESCE(ctl.total, 0),
         COALESCE(oi.total, 0) - COALESCE(ctl.total, 0)
    FROM oi FULL OUTER JOIN ctl ON oi.st = ctl.st
   ORDER BY 1;
$$;


--
-- Name: FUNCTION open_item_control_check(); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.open_item_control_check() IS 'Invariant: Σ open items must equal the GL control balance per subledger type (difference = 0).';


--
-- Name: open_item_create(text, uuid, text, text, text, kernel.money_amount, kernel.currency_code, date, date, uuid); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.open_item_create(p_subledger_type text, p_party_id uuid, p_source text, p_source_ref text, p_document_no text, p_amount kernel.money_amount, p_currency kernel.currency_code, p_issue_date date, p_due_date date, p_journal_entry uuid) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_id uuid;
BEGIN
  INSERT INTO open_item (
    subledger_type_code, party_id, source, source_ref, document_no,
    original_amount, open_amount, currency, issue_date, due_date, journal_entry_id
  ) VALUES (
    p_subledger_type, p_party_id, p_source, p_source_ref, p_document_no,
    p_amount, p_amount, p_currency, p_issue_date, p_due_date, p_journal_entry
  ) RETURNING id INTO v_id;
  RETURN v_id;
END; $$;


--
-- Name: FUNCTION open_item_create(p_subledger_type text, p_party_id uuid, p_source text, p_source_ref text, p_document_no text, p_amount kernel.money_amount, p_currency kernel.currency_code, p_issue_date date, p_due_date date, p_journal_entry uuid); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.open_item_create(p_subledger_type text, p_party_id uuid, p_source text, p_source_ref text, p_document_no text, p_amount kernel.money_amount, p_currency kernel.currency_code, p_issue_date date, p_due_date date, p_journal_entry uuid) IS 'Creates an open item (AR/AP detail) linked to its originating journal entry.';


--
-- Name: post_consignment_sale(uuid, date, text); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.post_consignment_sale(p_sale_id uuid, p_entry_date date, p_idempotency_key text) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_sale      record;
  v_lines     jsonb := '[]'::jsonb;
  v_gross     kernel.money_amount := 0;
  v_net       kernel.money_amount := 0;
  v_ccy       kernel.currency_code;
  v_entry     uuid;
  v_line      record;
BEGIN
  SELECT * INTO v_sale FROM consignment_sale WHERE id = p_sale_id;
  IF v_sale IS NULL THEN
    RAISE EXCEPTION 'Consignment sale % not found', p_sale_id USING ERRCODE='23503';
  END IF;
  IF v_sale.status <> 'completed' THEN
    RAISE EXCEPTION 'Sale % is not completed (status=%)', p_sale_id, v_sale.status USING ERRCODE='23514';
  END IF;

  v_ccy := (SELECT functional_currency FROM tenant_config LIMIT 1);

  -- Totals.
  SELECT COALESCE(sum(sale_price),0), COALESCE(sum(net_to_consignor),0)
    INTO v_gross, v_net
    FROM consignment_sale_line WHERE sale_id = p_sale_id;

  IF v_gross = 0 THEN
    RAISE EXCEPTION 'Sale % has no lines', p_sale_id USING ERRCODE='23514';
  END IF;

  -- Cash debit (sale total) + revenue credit.
  v_lines := v_lines || jsonb_build_object(
    'account_id', posting_account('cash'), 'debit', v_gross, 'currency', v_ccy,
    'memo', 'Consignment sale ' || v_sale.sale_no);
  v_lines := v_lines || jsonb_build_object(
    'account_id', posting_account('sales_revenue'), 'credit', v_gross, 'currency', v_ccy,
    'memo', 'Consignment sale ' || v_sale.sale_no);

  -- COGS debit (net total) + consignor payable credit, tagged per consignor.
  v_lines := v_lines || jsonb_build_object(
    'account_id', posting_account('consignment_cogs'), 'debit', v_net, 'currency', v_ccy,
    'memo', 'Consignment COGS sale ' || v_sale.sale_no);

  FOR v_line IN
    SELECT consignor_party_id, sum(net_to_consignor) AS net
      FROM consignment_sale_line WHERE sale_id = p_sale_id
     GROUP BY consignor_party_id
  LOOP
    v_lines := v_lines || jsonb_build_object(
      'account_id', posting_account('consignor_payable_control'),
      'credit', v_line.net, 'currency', v_ccy,
      'party_id', v_line.consignor_party_id,
      'subledger_type_code', 'consignor_payable',
      'memo', 'Consignor payable sale ' || v_sale.sale_no);
  END LOOP;

  v_entry := post_journal_entry(
    p_entry_date, 'Consignment sale ' || v_sale.sale_no,
    'consignment', p_sale_id::text, p_idempotency_key, v_lines
  );

  UPDATE consignment_sale SET journal_entry_id = v_entry WHERE id = p_sale_id;

  -- Open-item AP detail: one open item per consignor for this sale (ADR-0023).
  IF NOT EXISTS (SELECT 1 FROM open_item WHERE journal_entry_id = v_entry) THEN
    FOR v_line IN
      SELECT consignor_party_id, sum(net_to_consignor) AS net
        FROM consignment_sale_line WHERE sale_id = p_sale_id
       GROUP BY consignor_party_id
    LOOP
      PERFORM open_item_create(
        'consignor_payable', v_line.consignor_party_id, 'consignment', p_sale_id::text,
        'CSALE-' || v_sale.sale_no, v_line.net, v_ccy, p_entry_date, NULL, v_entry);
    END LOOP;
  END IF;

  RETURN v_entry;
END; $$;


--
-- Name: FUNCTION post_consignment_sale(p_sale_id uuid, p_entry_date date, p_idempotency_key text); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.post_consignment_sale(p_sale_id uuid, p_entry_date date, p_idempotency_key text) IS 'Idempotent consignment sale: cash/revenue + COGS/consignor-payable; opens AP items.';


--
-- Name: post_consignor_payout(uuid, date, text); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.post_consignor_payout(p_payout_id uuid, p_entry_date date, p_idempotency_key text) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_pay   record;
  v_set   record;
  v_entry uuid;
  v_lines jsonb;
BEGIN
  SELECT * INTO v_pay FROM consignor_payout WHERE id = p_payout_id;
  IF v_pay IS NULL THEN
    RAISE EXCEPTION 'Consignor payout % not found', p_payout_id USING ERRCODE='23503';
  END IF;
  SELECT * INTO v_set FROM consignor_settlement WHERE id = v_pay.settlement_id;

  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', posting_account('consignor_payable_control'),
                       'debit', v_pay.payout_amount, 'currency', v_pay.currency,
                       'party_id', v_set.consignor_party_id,
                       'subledger_type_code', 'consignor_payable',
                       'memo', 'Consignor payout settlement ' || v_set.settlement_no),
    jsonb_build_object('account_id', posting_account('cash'),
                       'credit', v_pay.payout_amount, 'currency', v_pay.currency,
                       'memo', 'Consignor payout settlement ' || v_set.settlement_no)
  );

  v_entry := post_journal_entry(
    p_entry_date, 'Consignor payout settlement ' || v_set.settlement_no,
    'payout', p_payout_id::text, p_idempotency_key, v_lines
  );

  UPDATE consignor_payout SET journal_entry_id = v_entry WHERE id = p_payout_id;
  UPDATE consignor_settlement SET status = 'paid' WHERE id = v_pay.settlement_id;

  -- Settle the consignor's open items FIFO (ADR-0023) so open items stay tied
  -- to the control account. Skip if already applied (idempotent).
  IF NOT EXISTS (SELECT 1 FROM payment_application WHERE journal_entry_id = v_entry) THEN
    DECLARE
      v_remaining kernel.money_amount := v_pay.payout_amount;
      v_item      record;
      v_apply     kernel.money_amount;
    BEGIN
      FOR v_item IN
        SELECT * FROM open_item
         WHERE party_id = v_set.consignor_party_id
           AND subledger_type_code = 'consignor_payable'
           AND status IN ('open','partial')
           AND deleted_at IS NULL
         ORDER BY COALESCE(due_date, issue_date), issue_date, id
         FOR UPDATE
      LOOP
        EXIT WHEN v_remaining <= 0;
        v_apply := LEAST(v_remaining, v_item.open_amount);
        IF v_apply <= 0 THEN CONTINUE; END IF;
        INSERT INTO payment_application (open_item_id, applied_amount, currency, applied_date, journal_entry_id)
        VALUES (v_item.id, v_apply, v_pay.currency, p_entry_date, v_entry);
        UPDATE open_item
           SET open_amount = open_amount - v_apply,
               status = CASE WHEN open_amount - v_apply = 0 THEN 'settled' ELSE 'partial' END
         WHERE id = v_item.id;
        v_remaining := v_remaining - v_apply;
      END LOOP;
    END;
  END IF;

  RETURN v_entry;
END; $$;


--
-- Name: FUNCTION post_consignor_payout(p_payout_id uuid, p_entry_date date, p_idempotency_key text); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.post_consignor_payout(p_payout_id uuid, p_entry_date date, p_idempotency_key text) IS 'Idempotent consignor payout: payable debit / cash credit; marks settlement paid.';


--
-- Name: post_deposit_receipt(uuid, date, text); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.post_deposit_receipt(p_deposit_id uuid, p_entry_date date, p_idempotency_key text) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_dep   record;
  v_entry uuid;
  v_lines jsonb;
BEGIN
  SELECT * INTO v_dep FROM lease_deposit WHERE id = p_deposit_id;
  IF v_dep IS NULL THEN
    RAISE EXCEPTION 'Lease deposit % not found', p_deposit_id USING ERRCODE='23503';
  END IF;

  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', posting_account('cash'),
                       'debit', v_dep.deposit_amount, 'currency', v_dep.currency,
                       'memo', 'Security deposit received'),
    jsonb_build_object('account_id', posting_account('security_deposit_control'),
                       'credit', v_dep.deposit_amount, 'currency', v_dep.currency,
                       'party_id', (SELECT lessee_party_id FROM lease WHERE id = v_dep.lease_id),
                       'subledger_type_code', 'security_deposit',
                       'memo', 'Security deposit held')
  );

  v_entry := post_journal_entry(
    p_entry_date, 'Security deposit for lease ' || v_dep.lease_id,
    'deposit', p_deposit_id::text, p_idempotency_key, v_lines
  );

  UPDATE lease_deposit
     SET journal_entry_id = v_entry,
         status = 'held',
         received_date = COALESCE(received_date, p_entry_date)
   WHERE id = p_deposit_id;

  RETURN v_entry;
END; $$;


--
-- Name: FUNCTION post_deposit_receipt(p_deposit_id uuid, p_entry_date date, p_idempotency_key text); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.post_deposit_receipt(p_deposit_id uuid, p_entry_date date, p_idempotency_key text) IS 'Idempotent deposit receipt: cash debit / deposit liability credit; links the ledger entry.';


--
-- Name: post_journal_entry(date, text, text, text, text, jsonb); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.post_journal_entry(p_entry_date date, p_memo text, p_source text, p_source_ref text, p_idempotency_key text, p_lines jsonb) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: FUNCTION post_journal_entry(p_entry_date date, p_memo text, p_source text, p_source_ref text, p_idempotency_key text, p_lines jsonb); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.post_journal_entry(p_entry_date date, p_memo text, p_source text, p_source_ref text, p_idempotency_key text, p_lines jsonb) IS 'Idempotent posting. Same idempotency_key returns the same entry id.';


--
-- Name: post_merchant_settlement(uuid, date, text); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.post_merchant_settlement(p_settlement_id uuid, p_entry_date date, p_idempotency_key text) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_s     record;
  v_lines jsonb;
  v_entry uuid;
BEGIN
  SELECT * INTO v_s FROM merchant_settlement WHERE id = p_settlement_id;
  IF v_s IS NULL THEN
    RAISE EXCEPTION 'Merchant settlement % not found', p_settlement_id USING ERRCODE='23503';
  END IF;

  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', posting_account('bank'),
                       'debit', v_s.net_amount, 'currency', v_s.currency,
                       'memo', 'Processor deposit ' || v_s.settlement_no));

  IF v_s.fee_amount > 0 THEN
    v_lines := v_lines || jsonb_build_object(
      'account_id', posting_account('merchant_fees'),
      'debit', v_s.fee_amount, 'currency', v_s.currency,
      'memo', 'Merchant fees ' || v_s.settlement_no);
  END IF;

  v_lines := v_lines || jsonb_build_object(
    'account_id', posting_account('card_clearing'),
    'credit', v_s.gross_amount, 'currency', v_s.currency,
    'memo', 'Clearing released ' || v_s.settlement_no);

  v_entry := post_journal_entry(
    p_entry_date, 'Merchant settlement ' || v_s.settlement_no,
    'merchant', p_settlement_id::text, p_idempotency_key, v_lines);

  UPDATE merchant_settlement SET journal_entry_id = v_entry WHERE id = p_settlement_id;
  RETURN v_entry;
END $$;


--
-- Name: FUNCTION post_merchant_settlement(p_settlement_id uuid, p_entry_date date, p_idempotency_key text); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.post_merchant_settlement(p_settlement_id uuid, p_entry_date date, p_idempotency_key text) IS 'Clearing -> bank with merchant fee expensed (ADR-0029).';


--
-- Name: post_refund(uuid, date, text); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.post_refund(p_refund_sale_id uuid, p_entry_date date, p_idempotency_key text) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_sale    record;
  v_lines   jsonb := '[]'::jsonb;
  v_ccy     kernel.currency_code;
  v_entry   uuid;
  v_t       record;
  v_net_rev kernel.money_amount;
  v_cons    kernel.money_amount;
BEGIN
  SELECT * INTO v_sale FROM sale WHERE id = p_refund_sale_id;
  IF v_sale IS NULL THEN
    RAISE EXCEPTION 'Refund % not found', p_refund_sale_id USING ERRCODE='23503';
  END IF;
  IF NOT v_sale.is_refund THEN
    RAISE EXCEPTION 'Sale % is not a refund document', p_refund_sale_id USING ERRCODE='23514';
  END IF;

  v_ccy     := v_sale.currency;
  v_net_rev := v_sale.subtotal - v_sale.discount_total;

  -- CREDIT the tenders (money going back out).
  FOR v_t IN
    SELECT tt.debit_role_code, tt.settlement_kind, tt.subledger_type_code,
           pt.party_id, sum(pt.amount) AS amt
      FROM payment p
      JOIN payment_tender pt ON pt.payment_id = p.id
      JOIN tender_type tt ON tt.code = pt.tender_type_code
     WHERE p.sale_id = p_refund_sale_id AND p.status = 'captured'
     GROUP BY tt.debit_role_code, tt.settlement_kind, tt.subledger_type_code, pt.party_id
  LOOP
    IF v_t.settlement_kind = 'liability' THEN
      v_lines := v_lines || jsonb_build_object(
        'account_id', posting_account(v_t.debit_role_code),
        'credit', v_t.amt, 'currency', v_ccy,
        'party_id', v_t.party_id,
        'subledger_type_code', v_t.subledger_type_code,
        'memo', 'Refund tender sale ' || v_sale.sale_no);
    ELSE
      v_lines := v_lines || jsonb_build_object(
        'account_id', posting_account(v_t.debit_role_code),
        'credit', v_t.amt, 'currency', v_ccy,
        'memo', 'Refund tender sale ' || v_sale.sale_no);
    END IF;
  END LOOP;

  -- DEBIT revenue + tax back.
  IF v_net_rev <> 0 THEN
    v_lines := v_lines || jsonb_build_object(
      'account_id', posting_account('sales_revenue'),
      'debit', v_net_rev, 'currency', v_ccy,
      'memo', 'Refund ' || v_sale.sale_no);
  END IF;
  IF v_sale.tax_total <> 0 THEN
    v_lines := v_lines || jsonb_build_object(
      'account_id', posting_account('sales_tax_payable'),
      'debit', v_sale.tax_total, 'currency', v_ccy,
      'memo', 'Refund tax ' || v_sale.sale_no);
  END IF;

  -- Reverse the consignor accrual too (their liability falls back).
  SELECT COALESCE(sum(net_to_consignor), 0) INTO v_cons
    FROM sale_line WHERE sale_id = p_refund_sale_id AND line_kind = 'consignment';

  IF v_cons > 0 THEN
    v_lines := v_lines || jsonb_build_object(
      'account_id', posting_account('consignment_cogs'),
      'credit', v_cons, 'currency', v_ccy,
      'memo', 'Reverse consignment COGS ' || v_sale.sale_no);
    FOR v_t IN
      SELECT consignor_party_id, sum(net_to_consignor) AS net
        FROM sale_line
       WHERE sale_id = p_refund_sale_id AND line_kind = 'consignment'
       GROUP BY consignor_party_id
    LOOP
      v_lines := v_lines || jsonb_build_object(
        'account_id', posting_account('consignor_payable_control'),
        'debit', v_t.net, 'currency', v_ccy,
        'party_id', v_t.consignor_party_id,
        'subledger_type_code', 'consignor_payable',
        'memo', 'Reverse consignor payable ' || v_sale.sale_no);
    END LOOP;
  END IF;

  v_entry := post_journal_entry(
    p_entry_date, 'POS refund ' || v_sale.sale_no,
    'pos_refund', p_refund_sale_id::text, p_idempotency_key, v_lines);

  UPDATE sale SET journal_entry_id = v_entry WHERE id = p_refund_sale_id;
  UPDATE sale SET status = 'refunded' WHERE id = v_sale.refunds_sale_id;

  -- The refund cancels the obligation to the consignor, so the matching OPEN
  -- ITEMS must be relieved too — otherwise the open-item layer would still show
  -- money owed that the GL control account no longer carries (ADR-0023).
  -- Idempotent: skip if this entry already produced applications.
  IF v_cons > 0
     AND NOT EXISTS (SELECT 1 FROM payment_application WHERE journal_entry_id = v_entry) THEN
    DECLARE
      v_party     record;
      v_remaining kernel.money_amount;
      v_item      record;
      v_apply     kernel.money_amount;
    BEGIN
      FOR v_party IN
        SELECT consignor_party_id, sum(net_to_consignor) AS net
          FROM sale_line
         WHERE sale_id = p_refund_sale_id AND line_kind = 'consignment'
         GROUP BY consignor_party_id
      LOOP
        v_remaining := v_party.net;
        FOR v_item IN
          SELECT * FROM open_item
           WHERE party_id = v_party.consignor_party_id
             AND subledger_type_code = 'consignor_payable'
             AND status IN ('open','partial')
             AND deleted_at IS NULL
           ORDER BY COALESCE(due_date, issue_date), issue_date, id
           FOR UPDATE
        LOOP
          EXIT WHEN v_remaining <= 0;
          v_apply := LEAST(v_remaining, v_item.open_amount);
          IF v_apply <= 0 THEN CONTINUE; END IF;
          INSERT INTO payment_application (open_item_id, applied_amount, currency, applied_date, journal_entry_id)
          VALUES (v_item.id, v_apply, v_ccy, p_entry_date, v_entry);
          UPDATE open_item
             SET open_amount = open_amount - v_apply,
                 status = CASE WHEN open_amount - v_apply = 0 THEN 'settled' ELSE 'partial' END
           WHERE id = v_item.id;
          v_remaining := v_remaining - v_apply;
        END LOOP;
      END LOOP;
    END;
  END IF;

  RETURN v_entry;
END $$;


--
-- Name: FUNCTION post_refund(p_refund_sale_id uuid, p_entry_date date, p_idempotency_key text); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.post_refund(p_refund_sale_id uuid, p_entry_date date, p_idempotency_key text) IS 'Idempotent refund posting (reversal-not-edit; reverses consignor accrual and relieves open items).';


--
-- Name: post_rent_invoice(uuid, date, date, date, text); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.post_rent_invoice(p_lease_id uuid, p_period_start date, p_period_end date, p_entry_date date, p_idempotency_key text) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_lease      record;
  v_lines      jsonb := '[]'::jsonb;
  v_total      kernel.money_amount := 0;
  v_comp       record;
  v_role       text;
  v_acct       uuid;
  v_amt        kernel.money_amount;
  v_entry      uuid;
BEGIN
  SELECT * INTO v_lease FROM lease WHERE id = p_lease_id AND deleted_at IS NULL;
  IF v_lease IS NULL THEN
    RAISE EXCEPTION 'Lease % not found', p_lease_id USING ERRCODE='23503';
  END IF;

  -- Sum fixed components effective within the period.
  FOR v_comp IN
    SELECT * FROM rent_component
     WHERE lease_id = p_lease_id
       AND component_type_code <> 'percentage_rent'
       AND effective_from <= p_period_end
       AND (effective_thru IS NULL OR effective_thru >= p_period_start)
     ORDER BY component_type_code
  LOOP
    v_amt := v_comp.amount;
    IF v_amt = 0 THEN CONTINUE; END IF;
    v_role := rent_component_posting_role(v_comp.component_type_code);
    v_acct := posting_account(v_role);
    v_total := v_total + v_amt;
    v_lines := v_lines || jsonb_build_object(
      'account_id', v_acct, 'credit', v_amt, 'currency', v_comp.currency,
      'memo', v_comp.component_type_code || ' ' || p_period_start || '..' || p_period_end
    );
  END LOOP;

  IF v_total = 0 THEN
    RAISE EXCEPTION 'Lease % has no billable rent components for %..%',
      p_lease_id, p_period_start, p_period_end USING ERRCODE='23514';
  END IF;

  -- AR debit line, tagged to the lessee on the 'ar' subledger.
  v_lines := jsonb_build_array(jsonb_build_object(
      'account_id', posting_account('ar_control'),
      'debit', v_total,
      'currency', (SELECT functional_currency FROM tenant_config LIMIT 1),
      'party_id', v_lease.lessee_party_id,
      'subledger_type_code', 'ar',
      'memo', 'Rent invoice lease ' || v_lease.lease_no
    )) || v_lines;

  v_entry := post_journal_entry(
    p_entry_date,
    'Rent invoice lease ' || v_lease.lease_no || ' ' || p_period_start || '..' || p_period_end,
    'rent', p_lease_id::text, p_idempotency_key, v_lines
  );

  -- Open-item AR detail (ADR-0023): one open item per invoice, due on the lease
  -- billing day of the period end month. Idempotent — skip if already opened.
  IF NOT EXISTS (SELECT 1 FROM open_item WHERE journal_entry_id = v_entry) THEN
    PERFORM open_item_create(
      'ar', v_lease.lessee_party_id, 'rent', p_lease_id::text,
      'RENT-' || v_lease.lease_no || '-' || to_char(p_period_end, 'YYYYMM'),
      v_total, (SELECT functional_currency FROM tenant_config LIMIT 1),
      p_entry_date,
      (date_trunc('month', p_period_end)
        + (LEAST(v_lease.billing_day, 28) - 1) * interval '1 day')::date,
      v_entry
    );
  END IF;

  RETURN v_entry;
END; $$;


--
-- Name: FUNCTION post_rent_invoice(p_lease_id uuid, p_period_start date, p_period_end date, p_entry_date date, p_idempotency_key text); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.post_rent_invoice(p_lease_id uuid, p_period_start date, p_period_end date, p_entry_date date, p_idempotency_key text) IS 'Idempotent rent invoice: AR debit (lessee) / revenue credits, resolved via posting_map.';


--
-- Name: post_sale(uuid, date, text); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.post_sale(p_sale_id uuid, p_entry_date date, p_idempotency_key text) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_sale     record;
  v_lines    jsonb := '[]'::jsonb;
  v_ccy      kernel.currency_code;
  v_entry    uuid;
  v_t        record;
  v_net_rev  kernel.money_amount;
  v_tender   kernel.money_amount;
  v_consignor_net kernel.money_amount;
  v_role     text;
  v_sub      text;
BEGIN
  SELECT * INTO v_sale FROM sale WHERE id = p_sale_id;
  IF v_sale IS NULL THEN
    RAISE EXCEPTION 'Sale % not found', p_sale_id USING ERRCODE='23503';
  END IF;
  IF v_sale.is_refund THEN
    RAISE EXCEPTION 'Sale % is a refund document; use post_refund()', p_sale_id USING ERRCODE='23514';
  END IF;
  IF v_sale.status <> 'completed' THEN
    RAISE EXCEPTION 'Sale % is not completed (status=%)', p_sale_id, v_sale.status USING ERRCODE='23514';
  END IF;

  v_ccy     := v_sale.currency;
  v_net_rev := v_sale.subtotal - v_sale.discount_total;

  -- --- DEBIT side: one line per tender ------------------------------------
  SELECT COALESCE(sum(pt.amount), 0) INTO v_tender
    FROM payment p JOIN payment_tender pt ON pt.payment_id = p.id
   WHERE p.sale_id = p_sale_id AND p.status = 'captured';

  IF v_tender <> v_sale.total THEN
    RAISE EXCEPTION 'Sale % tenders (%) do not equal sale total (%)',
      p_sale_id, v_tender, v_sale.total USING ERRCODE='23514';
  END IF;

  FOR v_t IN
    SELECT tt.debit_role_code, tt.settlement_kind, tt.subledger_type_code,
           pt.party_id, sum(pt.amount) AS amt
      FROM payment p
      JOIN payment_tender pt ON pt.payment_id = p.id
      JOIN tender_type tt ON tt.code = pt.tender_type_code
     WHERE p.sale_id = p_sale_id AND p.status = 'captured'
     GROUP BY tt.debit_role_code, tt.settlement_kind, tt.subledger_type_code, pt.party_id
  LOOP
    -- Liability tenders must be subledger-tagged to the party whose balance falls.
    IF v_t.settlement_kind = 'liability' THEN
      IF v_t.party_id IS NULL THEN
        RAISE EXCEPTION 'Liability tender on sale % requires party_id', p_sale_id USING ERRCODE='23514';
      END IF;
      v_lines := v_lines || jsonb_build_object(
        'account_id', posting_account(v_t.debit_role_code),
        'debit', v_t.amt, 'currency', v_ccy,
        'party_id', v_t.party_id,
        'subledger_type_code', v_t.subledger_type_code,
        'memo', 'Tender ' || v_t.debit_role_code || ' sale ' || v_sale.sale_no);
    ELSE
      v_lines := v_lines || jsonb_build_object(
        'account_id', posting_account(v_t.debit_role_code),
        'debit', v_t.amt, 'currency', v_ccy,
        'memo', 'Tender ' || v_t.debit_role_code || ' sale ' || v_sale.sale_no);
    END IF;
  END LOOP;

  -- --- CREDIT side: revenue + tax -----------------------------------------
  IF v_net_rev <> 0 THEN
    v_lines := v_lines || jsonb_build_object(
      'account_id', posting_account('sales_revenue'),
      'credit', v_net_rev, 'currency', v_ccy,
      'memo', 'Sale ' || v_sale.sale_no);
  END IF;

  IF v_sale.tax_total <> 0 THEN
    v_lines := v_lines || jsonb_build_object(
      'account_id', posting_account('sales_tax_payable'),
      'credit', v_sale.tax_total, 'currency', v_ccy,
      'memo', 'Sales tax sale ' || v_sale.sale_no);
  END IF;

  -- --- Consignor accrual AT SALE (ADR-0028) --------------------------------
  SELECT COALESCE(sum(net_to_consignor), 0) INTO v_consignor_net
    FROM sale_line WHERE sale_id = p_sale_id AND line_kind = 'consignment';

  IF v_consignor_net > 0 THEN
    v_lines := v_lines || jsonb_build_object(
      'account_id', posting_account('consignment_cogs'),
      'debit', v_consignor_net, 'currency', v_ccy,
      'memo', 'Consignment COGS sale ' || v_sale.sale_no);

    FOR v_t IN
      SELECT consignor_party_id, sum(net_to_consignor) AS net
        FROM sale_line
       WHERE sale_id = p_sale_id AND line_kind = 'consignment'
       GROUP BY consignor_party_id
    LOOP
      v_lines := v_lines || jsonb_build_object(
        'account_id', posting_account('consignor_payable_control'),
        'credit', v_t.net, 'currency', v_ccy,
        'party_id', v_t.consignor_party_id,
        'subledger_type_code', 'consignor_payable',
        'memo', 'Consignor payable sale ' || v_sale.sale_no);
    END LOOP;
  END IF;

  v_entry := post_journal_entry(
    p_entry_date, 'POS sale ' || v_sale.sale_no,
    'pos', p_sale_id::text, p_idempotency_key, v_lines);

  UPDATE sale SET journal_entry_id = v_entry WHERE id = p_sale_id;
  UPDATE payment SET journal_entry_id = v_entry
   WHERE sale_id = p_sale_id AND journal_entry_id IS NULL;

  -- Open-item AP per consignor so aging + portal read one source of truth.
  IF v_consignor_net > 0
     AND NOT EXISTS (SELECT 1 FROM open_item WHERE journal_entry_id = v_entry) THEN
    FOR v_t IN
      SELECT consignor_party_id, sum(net_to_consignor) AS net
        FROM sale_line
       WHERE sale_id = p_sale_id AND line_kind = 'consignment'
       GROUP BY consignor_party_id
    LOOP
      PERFORM open_item_create(
        'consignor_payable', v_t.consignor_party_id, 'pos', p_sale_id::text,
        'POS-' || v_sale.sale_no, v_t.net, v_ccy, p_entry_date, NULL, v_entry);
    END LOOP;
  END IF;

  RETURN v_entry;
END $$;


--
-- Name: FUNCTION post_sale(p_sale_id uuid, p_entry_date date, p_idempotency_key text); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.post_sale(p_sale_id uuid, p_entry_date date, p_idempotency_key text) IS 'Idempotent POS sale posting; accrues consignor payable AT SALE (ADR-0028).';


--
-- Name: post_shift_close(uuid, kernel.money_amount, date, text); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.post_shift_close(p_shift_id uuid, p_counted_cash kernel.money_amount, p_entry_date date, p_idempotency_key text) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_shift    record;
  v_cash_in  kernel.money_amount;
  v_expected kernel.money_amount;
  v_diff     kernel.money_amount;
  v_lines    jsonb;
  v_entry    uuid;
  v_ccy      kernel.currency_code;
BEGIN
  SELECT * INTO v_shift FROM shift WHERE id = p_shift_id;
  IF v_shift IS NULL THEN
    RAISE EXCEPTION 'Shift % not found', p_shift_id USING ERRCODE='23503';
  END IF;
  v_ccy := v_shift.currency;

  -- Cash actually taken in this shift (cash-kind tenders only).
  SELECT COALESCE(sum(pt.amount), 0) INTO v_cash_in
    FROM sale s
    JOIN payment p ON p.sale_id = s.id AND p.status = 'captured'
    JOIN payment_tender pt ON pt.payment_id = p.id
    JOIN tender_type tt ON tt.code = pt.tender_type_code
   WHERE s.shift_id = p_shift_id
     AND tt.settlement_kind = 'cash'
     AND NOT s.is_refund;

  v_expected := v_shift.opening_float + v_cash_in;
  v_diff     := p_counted_cash - v_expected;

  UPDATE shift
     SET counted_cash = p_counted_cash,
         expected_cash = v_expected,
         over_short    = v_diff,
         closed_at     = COALESCE(closed_at, now()),
         status        = 'closed'
   WHERE id = p_shift_id;

  -- No difference -> nothing to post. That is the good case.
  IF v_diff = 0 THEN
    RETURN NULL;
  END IF;

  IF v_diff > 0 THEN
    -- Drawer is OVER: more cash than expected -> income.
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', posting_account('undeposited_funds'),
                         'debit', v_diff, 'currency', v_ccy,
                         'memo', 'Drawer over shift ' || v_shift.shift_no),
      jsonb_build_object('account_id', posting_account('cash_over_short'),
                         'credit', v_diff, 'currency', v_ccy,
                         'memo', 'Drawer over shift ' || v_shift.shift_no));
  ELSE
    -- Drawer is SHORT: less cash than expected -> expense (contra-income).
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', posting_account('cash_over_short'),
                         'debit', -v_diff, 'currency', v_ccy,
                         'memo', 'Drawer short shift ' || v_shift.shift_no),
      jsonb_build_object('account_id', posting_account('undeposited_funds'),
                         'credit', -v_diff, 'currency', v_ccy,
                         'memo', 'Drawer short shift ' || v_shift.shift_no));
  END IF;

  v_entry := post_journal_entry(
    p_entry_date, 'Shift close ' || v_shift.shift_no,
    'pos_shift', p_shift_id::text, p_idempotency_key, v_lines);

  UPDATE shift SET journal_entry_id = v_entry WHERE id = p_shift_id;
  RETURN v_entry;
END $$;


--
-- Name: FUNCTION post_shift_close(p_shift_id uuid, p_counted_cash kernel.money_amount, p_entry_date date, p_idempotency_key text); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.post_shift_close(p_shift_id uuid, p_counted_cash kernel.money_amount, p_entry_date date, p_idempotency_key text) IS 'Closes a drawer session and books over/short (ADR-0029).';


--
-- Name: posting_account(text); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.posting_account(p_role text) RETURNS uuid
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE v_id uuid;
BEGIN
  SELECT account_id INTO v_id FROM posting_map WHERE role_code = p_role;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'No posting_map entry for role %', p_role USING ERRCODE='23514';
  END IF;
  RETURN v_id;
END; $$;


--
-- Name: FUNCTION posting_account(p_role text); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.posting_account(p_role text) IS 'Resolves a posting role to its account_id via posting_map (ADR-0020).';


--
-- Name: rent_component_posting_role(text); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.rent_component_posting_role(p_type text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
  SELECT CASE p_type
    WHEN 'base_rent'       THEN 'rent_revenue'
    WHEN 'cam'             THEN 'cam_revenue'
    WHEN 'percentage_rent' THEN 'percentage_rent_revenue'
    ELSE 'other_income'
  END
$$;


--
-- Name: FUNCTION rent_component_posting_role(p_type text); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.rent_component_posting_role(p_type text) IS 'Maps a rent component type to its revenue posting role.';


--
-- Name: reverse_journal_entry(uuid, date, text, text); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.reverse_journal_entry(p_entry_id uuid, p_reversal_date date, p_memo text DEFAULT NULL::text, p_idempotency_key text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
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

  INSERT INTO journal_entry (entry_date, memo, source, source_ref, idempotency_key, reversal_of_id, created_by)
  SELECT p_reversal_date,
         COALESCE(p_memo, 'Reversal of entry ' || je.entry_no),
         'reversal', je.id::text, p_idempotency_key, je.id, kernel.current_actor()
    FROM journal_entry je WHERE je.id = p_entry_id
  RETURNING id INTO v_new;

  IF v_new IS NULL THEN
    RAISE EXCEPTION 'Journal entry % not found', p_entry_id USING ERRCODE='23503';
  END IF;

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

  RETURN v_new;
END; $$;


--
-- Name: FUNCTION reverse_journal_entry(p_entry_id uuid, p_reversal_date date, p_memo text, p_idempotency_key text); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.reverse_journal_entry(p_entry_id uuid, p_reversal_date date, p_memo text, p_idempotency_key text) IS 'Posts a mirror entry linked via reversal_of_id. Never edits the original.';


--
-- Name: set_party_identifier(uuid, text, text, text); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.set_party_identifier(p_party_id uuid, p_type text, p_value text, p_authority text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_key  text := current_setting('app.pii_key', true);
  v_hash text;
  v_id   uuid;
BEGIN
  IF v_key IS NULL OR v_key = '' THEN
    RAISE EXCEPTION 'app.pii_key is not set; cannot store PII (ADR-0018)' USING ERRCODE='28000';
  END IF;
  v_hash := encode(digest(p_value, 'sha256'), 'hex');
  SELECT id INTO v_id FROM party_identifier
    WHERE tenant_id = kernel.current_tenant() AND identifier_type = p_type
      AND identifier_hash = v_hash AND deleted_at IS NULL;
  IF v_id IS NOT NULL THEN
    UPDATE party_identifier
       SET identifier_value_enc = pgp_sym_encrypt(p_value, v_key),
           issuing_authority = p_authority
     WHERE id = v_id;
    RETURN v_id;
  END IF;
  INSERT INTO party_identifier (party_id, identifier_type, identifier_value_enc, identifier_hash, issuing_authority)
  VALUES (p_party_id, p_type, pgp_sym_encrypt(p_value, v_key), v_hash, p_authority)
  RETURNING id INTO v_id;
  RETURN v_id;
END; $$;


--
-- Name: FUNCTION set_party_identifier(p_party_id uuid, p_type text, p_value text, p_authority text); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.set_party_identifier(p_party_id uuid, p_type text, p_value text, p_authority text) IS 'Encrypts and stores a party identifier; uniqueness via sha256. Requires app.pii_key.';


--
-- Name: subledger_control_check(); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.subledger_control_check() RETURNS TABLE(subledger_type_code text, subledger_total numeric, control_total numeric, difference numeric)
    LANGUAGE sql STABLE
    AS $$
  WITH sub AS (
    SELECT jl.subledger_type_code AS st, sum(jl.base_debit - jl.base_credit) AS total
      FROM journal_line jl
     WHERE jl.subledger_type_code IS NOT NULL
     GROUP BY jl.subledger_type_code
  ),
  ctl AS (
    SELECT a.control_subledger_type_code AS st, sum(jl.base_debit - jl.base_credit) AS total
      FROM journal_line jl
      JOIN account a ON a.id = jl.account_id
     WHERE a.is_control
     GROUP BY a.control_subledger_type_code
  )
  SELECT COALESCE(sub.st, ctl.st),
         COALESCE(sub.total, 0),
         COALESCE(ctl.total, 0),
         COALESCE(sub.total, 0) - COALESCE(ctl.total, 0)
    FROM sub FULL OUTER JOIN ctl ON sub.st = ctl.st
   ORDER BY 1;
$$;


--
-- Name: FUNCTION subledger_control_check(); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.subledger_control_check() IS 'Invariant: subledger totals must equal GL control account balances (difference = 0).';


--
-- Name: subledger_control_role(text); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.subledger_control_role(p_subledger_type text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
  SELECT CASE p_subledger_type
    WHEN 'ar'                THEN 'ar_control'
    WHEN 'ap'                THEN 'ap_control'
    WHEN 'vendor_payable'    THEN 'vendor_payable_control'
    WHEN 'consignor_payable' THEN 'consignor_payable_control'
    WHEN 'customer_credit'   THEN 'customer_credit_control'
    WHEN 'gift_certificate'  THEN 'gift_certificate_control'
    WHEN 'security_deposit'  THEN 'security_deposit_control'
    ELSE NULL
  END
$$;


--
-- Name: FUNCTION subledger_control_role(p_subledger_type text); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.subledger_control_role(p_subledger_type text) IS 'Maps a subledger type to its GL control posting role (ADR-0020).';


--
-- Name: trial_balance(date); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.trial_balance(p_as_of date DEFAULT CURRENT_DATE) RETURNS TABLE(account_id uuid, code text, name text, debit numeric, credit numeric, balance numeric)
    LANGUAGE sql STABLE
    AS $$
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


--
-- Name: FUNCTION trial_balance(p_as_of date); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.trial_balance(p_as_of date) IS 'Per-account debit/credit/balance as of a date. Sum of balance must be 0.';


--
-- Name: vendor_portal_check(text); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.vendor_portal_check(p_subledger text DEFAULT 'consignor_payable'::text) RETURNS TABLE(portal_total kernel.money_amount, gl_total kernel.money_amount, difference kernel.money_amount)
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_portal kernel.money_amount;
  v_gl     kernel.money_amount;
  v_acct   uuid;
BEGIN
  SELECT COALESCE(sum(balance_owed), 0) INTO v_portal
    FROM v_vendor_balance_realtime WHERE subledger_type_code = p_subledger;

  SELECT id INTO v_acct FROM account
   WHERE is_control AND control_subledger_type_code = p_subledger
   LIMIT 1;

  SELECT COALESCE(sum(jl.base_credit - jl.base_debit), 0) INTO v_gl
    FROM journal_line jl
   WHERE jl.account_id = v_acct;

  RETURN QUERY SELECT v_portal, v_gl, (v_portal - v_gl)::kernel.money_amount;
END $$;


--
-- Name: FUNCTION vendor_portal_check(p_subledger text); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.vendor_portal_check(p_subledger text) IS 'Asserts the realtime portal balance equals the GL control balance.';


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: account_type; Type: TABLE; Schema: kernel; Owner: -
--

CREATE TABLE kernel.account_type (
    code text NOT NULL,
    name text NOT NULL,
    normal_balance character(1) NOT NULL,
    statement text NOT NULL,
    sort_order smallint NOT NULL,
    CONSTRAINT account_type_normal_balance_check CHECK ((normal_balance = ANY (ARRAY['D'::bpchar, 'C'::bpchar]))),
    CONSTRAINT account_type_statement_check CHECK ((statement = ANY (ARRAY['balance_sheet'::text, 'income_statement'::text])))
);


--
-- Name: TABLE account_type; Type: COMMENT; Schema: kernel; Owner: -
--

COMMENT ON TABLE kernel.account_type IS 'The five account types + normal balance + which statement they roll into.';


--
-- Name: contact_mechanism_type; Type: TABLE; Schema: kernel; Owner: -
--

CREATE TABLE kernel.contact_mechanism_type (
    code text NOT NULL,
    name text NOT NULL
);


--
-- Name: currency; Type: TABLE; Schema: kernel; Owner: -
--

CREATE TABLE kernel.currency (
    code kernel.currency_code NOT NULL,
    numeric_code smallint NOT NULL,
    name text NOT NULL,
    minor_unit smallint DEFAULT 2 NOT NULL,
    symbol text,
    is_active boolean DEFAULT true NOT NULL,
    CONSTRAINT currency_minor_unit_check CHECK (((minor_unit >= 0) AND (minor_unit <= 4)))
);


--
-- Name: TABLE currency; Type: COMMENT; Schema: kernel; Owner: -
--

COMMENT ON TABLE kernel.currency IS 'ISO-4217 currency reference. minor_unit = display scale.';


--
-- Name: data_classification; Type: TABLE; Schema: kernel; Owner: -
--

CREATE TABLE kernel.data_classification (
    schema_name text NOT NULL,
    table_name text NOT NULL,
    column_name text NOT NULL,
    class text NOT NULL,
    note text,
    CONSTRAINT data_classification_class_check CHECK ((class = ANY (ARRAY['public'::text, 'internal'::text, 'confidential'::text, 'pii'::text, 'pii_sensitive'::text])))
);


--
-- Name: TABLE data_classification; Type: COMMENT; Schema: kernel; Owner: -
--

COMMENT ON TABLE kernel.data_classification IS 'Column-level data classification registry. pii_sensitive => encrypted + masked.';


--
-- Name: identifier_type; Type: TABLE; Schema: kernel; Owner: -
--

CREATE TABLE kernel.identifier_type (
    code text NOT NULL,
    name text NOT NULL,
    is_pii boolean DEFAULT false NOT NULL,
    is_sensitive boolean DEFAULT false NOT NULL
);


--
-- Name: TABLE identifier_type; Type: COMMENT; Schema: kernel; Owner: -
--

COMMENT ON TABLE kernel.identifier_type IS 'External identifier kinds. is_sensitive => encrypted at rest + masked.';


--
-- Name: migration; Type: TABLE; Schema: kernel; Owner: -
--

CREATE TABLE kernel.migration (
    schema_name text NOT NULL,
    version text NOT NULL,
    checksum text,
    applied_at timestamp with time zone DEFAULT now() NOT NULL,
    applied_by text,
    execution_ms integer
);


--
-- Name: TABLE migration; Type: COMMENT; Schema: kernel; Owner: -
--

COMMENT ON TABLE kernel.migration IS 'Per-schema applied-migration ledger for the resumable migration runner.';


--
-- Name: party_relationship_type; Type: TABLE; Schema: kernel; Owner: -
--

CREATE TABLE kernel.party_relationship_type (
    code text NOT NULL,
    name text NOT NULL,
    description text
);


--
-- Name: party_role_type; Type: TABLE; Schema: kernel; Owner: -
--

CREATE TABLE kernel.party_role_type (
    code text NOT NULL,
    name text NOT NULL,
    description text
);


--
-- Name: TABLE party_role_type; Type: COMMENT; Schema: kernel; Owner: -
--

COMMENT ON TABLE kernel.party_role_type IS 'Roles a Party can play. is_house lives on the role instance, not here.';


--
-- Name: posting_role; Type: TABLE; Schema: kernel; Owner: -
--

CREATE TABLE kernel.posting_role (
    code text NOT NULL,
    name text NOT NULL,
    description text
);


--
-- Name: TABLE posting_role; Type: COMMENT; Schema: kernel; Owner: -
--

COMMENT ON TABLE kernel.posting_role IS 'Account-determination keys. Domain posting resolves account_id via tenant posting_map (ADR-0020).';


--
-- Name: rent_component_type; Type: TABLE; Schema: kernel; Owner: -
--

CREATE TABLE kernel.rent_component_type (
    code text NOT NULL,
    name text NOT NULL,
    is_variable boolean DEFAULT false NOT NULL,
    description text
);


--
-- Name: space_type; Type: TABLE; Schema: kernel; Owner: -
--

CREATE TABLE kernel.space_type (
    code text NOT NULL,
    name text NOT NULL,
    description text
);


--
-- Name: subledger_type; Type: TABLE; Schema: kernel; Owner: -
--

CREATE TABLE kernel.subledger_type (
    code text NOT NULL,
    name text NOT NULL,
    description text
);


--
-- Name: TABLE subledger_type; Type: COMMENT; Schema: kernel; Owner: -
--

COMMENT ON TABLE kernel.subledger_type IS 'Subledger kinds that must tie to a GL control account.';


--
-- Name: account; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.account (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    account_type_code text NOT NULL,
    parent_id uuid,
    is_control boolean DEFAULT false NOT NULL,
    control_subledger_type_code text,
    currency kernel.currency_code,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    deleted_at timestamp with time zone,
    deleted_by uuid,
    CONSTRAINT account_check CHECK (((is_control AND (control_subledger_type_code IS NOT NULL)) OR ((NOT is_control) AND (control_subledger_type_code IS NULL))))
);

ALTER TABLE ONLY tenant_demo.account FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE account; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.account IS 'Chart of Accounts. is_control marks GL control accounts that subledgers tie to.';


--
-- Name: audit_log; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.audit_log (
    id bigint NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    table_schema text NOT NULL,
    table_name text NOT NULL,
    row_id text,
    op text NOT NULL,
    actor_id uuid,
    before_data jsonb,
    after_data jsonb,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT audit_log_op_check CHECK ((op = ANY (ARRAY['INSERT'::text, 'UPDATE'::text, 'DELETE'::text])))
);

ALTER TABLE ONLY tenant_demo.audit_log FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE audit_log; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.audit_log IS 'Append-only row history for high-value tables (ADR-0017). before/after JSON snapshots.';


--
-- Name: audit_log_id_seq; Type: SEQUENCE; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.audit_log ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME tenant_demo.audit_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: commission_rule; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.commission_rule (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    agreement_id uuid NOT NULL,
    rule_type text DEFAULT 'flat'::text NOT NULL,
    rate kernel.percent_rate NOT NULL,
    breakpoint_amount kernel.money_amount,
    effective_from date DEFAULT CURRENT_DATE NOT NULL,
    effective_thru date,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    CONSTRAINT commission_rule_check CHECK (((effective_thru IS NULL) OR (effective_thru >= effective_from))),
    CONSTRAINT commission_rule_check1 CHECK ((((rule_type = 'tiered'::text) AND (breakpoint_amount IS NOT NULL)) OR (rule_type = 'flat'::text))),
    CONSTRAINT commission_rule_rate_check CHECK ((((rate)::numeric >= (0)::numeric) AND ((rate)::numeric <= (1)::numeric))),
    CONSTRAINT commission_rule_rule_type_check CHECK ((rule_type = ANY (ARRAY['flat'::text, 'tiered'::text])))
);

ALTER TABLE ONLY tenant_demo.commission_rule FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE commission_rule; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.commission_rule IS 'Effective-dated commission terms (flat or tiered) per agreement.';


--
-- Name: consignment_item; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.consignment_item (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    agreement_id uuid NOT NULL,
    item_no bigint NOT NULL,
    sku text,
    description text NOT NULL,
    category text,
    condition text,
    agreed_price kernel.money_amount NOT NULL,
    currency kernel.currency_code DEFAULT 'USD'::bpchar NOT NULL,
    received_date date DEFAULT CURRENT_DATE NOT NULL,
    status text DEFAULT 'received'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    deleted_at timestamp with time zone,
    deleted_by uuid,
    CONSTRAINT consignment_item_agreed_price_check CHECK (((agreed_price)::numeric >= (0)::numeric)),
    CONSTRAINT consignment_item_status_check CHECK ((status = ANY (ARRAY['received'::text, 'available'::text, 'sold'::text, 'returned'::text, 'withdrawn'::text, 'lost'::text])))
);

ALTER TABLE ONLY tenant_demo.consignment_item FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE consignment_item; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.consignment_item IS 'A consigned item: received, offered, sold, returned, or withdrawn.';


--
-- Name: consignment_item_item_no_seq; Type: SEQUENCE; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.consignment_item ALTER COLUMN item_no ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME tenant_demo.consignment_item_item_no_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: consignment_sale; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.consignment_sale (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    sale_no bigint NOT NULL,
    sale_date date DEFAULT CURRENT_DATE NOT NULL,
    channel text DEFAULT 'store'::text NOT NULL,
    customer_party_id uuid,
    status text DEFAULT 'completed'::text NOT NULL,
    journal_entry_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    CONSTRAINT consignment_sale_channel_check CHECK ((channel = ANY (ARRAY['store'::text, 'online'::text, 'event'::text, 'other'::text]))),
    CONSTRAINT consignment_sale_status_check CHECK ((status = ANY (ARRAY['completed'::text, 'voided'::text])))
);

ALTER TABLE ONLY tenant_demo.consignment_sale FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE consignment_sale; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.consignment_sale IS 'A consignment sale header. Lines carry item, price, commission, and net-to-consignor.';


--
-- Name: consignment_sale_line; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.consignment_sale_line (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    sale_id uuid NOT NULL,
    item_id uuid NOT NULL,
    consignor_party_id uuid NOT NULL,
    sale_price kernel.money_amount NOT NULL,
    commission_rate kernel.percent_rate NOT NULL,
    commission_amount kernel.money_amount NOT NULL,
    net_to_consignor kernel.money_amount NOT NULL,
    currency kernel.currency_code DEFAULT 'USD'::bpchar NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    CONSTRAINT consignment_sale_line_check CHECK ((((commission_amount)::numeric + (net_to_consignor)::numeric) = (sale_price)::numeric)),
    CONSTRAINT consignment_sale_line_commission_amount_check CHECK (((commission_amount)::numeric >= (0)::numeric)),
    CONSTRAINT consignment_sale_line_commission_rate_check CHECK ((((commission_rate)::numeric >= (0)::numeric) AND ((commission_rate)::numeric <= (1)::numeric))),
    CONSTRAINT consignment_sale_line_net_to_consignor_check CHECK (((net_to_consignor)::numeric >= (0)::numeric)),
    CONSTRAINT consignment_sale_line_sale_price_check CHECK (((sale_price)::numeric >= (0)::numeric))
);

ALTER TABLE ONLY tenant_demo.consignment_sale_line FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE consignment_sale_line; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.consignment_sale_line IS 'A sold consignment item; commission + net_to_consignor = sale_price (exact).';


--
-- Name: consignment_sale_sale_no_seq; Type: SEQUENCE; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.consignment_sale ALTER COLUMN sale_no ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME tenant_demo.consignment_sale_sale_no_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: consignor_agreement; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.consignor_agreement (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    agreement_no bigint NOT NULL,
    consignor_party_id uuid NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    start_date date DEFAULT CURRENT_DATE NOT NULL,
    end_date date,
    settlement_frequency text DEFAULT 'monthly'::text NOT NULL,
    default_commission_rate kernel.percent_rate DEFAULT 0.40 NOT NULL,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    deleted_at timestamp with time zone,
    deleted_by uuid,
    CONSTRAINT consignor_agreement_check CHECK (((end_date IS NULL) OR (end_date >= start_date))),
    CONSTRAINT consignor_agreement_default_commission_rate_check CHECK ((((default_commission_rate)::numeric >= (0)::numeric) AND ((default_commission_rate)::numeric <= (1)::numeric))),
    CONSTRAINT consignor_agreement_settlement_frequency_check CHECK ((settlement_frequency = ANY (ARRAY['on_demand'::text, 'weekly'::text, 'biweekly'::text, 'monthly'::text]))),
    CONSTRAINT consignor_agreement_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'active'::text, 'suspended'::text, 'terminated'::text])))
);

ALTER TABLE ONLY tenant_demo.consignor_agreement FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE consignor_agreement; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.consignor_agreement IS 'Consignment contract: terms, commission default, settlement cadence.';


--
-- Name: consignor_agreement_agreement_no_seq; Type: SEQUENCE; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.consignor_agreement ALTER COLUMN agreement_no ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME tenant_demo.consignor_agreement_agreement_no_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: consignor_payout; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.consignor_payout (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    settlement_id uuid NOT NULL,
    payout_amount kernel.money_amount NOT NULL,
    currency kernel.currency_code DEFAULT 'USD'::bpchar NOT NULL,
    payout_date date DEFAULT CURRENT_DATE NOT NULL,
    method text DEFAULT 'cash'::text NOT NULL,
    journal_entry_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    CONSTRAINT consignor_payout_method_check CHECK ((method = ANY (ARRAY['cash'::text, 'check'::text, 'ach'::text, 'store_credit'::text, 'other'::text]))),
    CONSTRAINT consignor_payout_payout_amount_check CHECK (((payout_amount)::numeric > (0)::numeric))
);

ALTER TABLE ONLY tenant_demo.consignor_payout FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE consignor_payout; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.consignor_payout IS 'Cash payout to a consignor for a settlement; links the ledger entry.';


--
-- Name: consignor_settlement; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.consignor_settlement (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    settlement_no bigint NOT NULL,
    consignor_party_id uuid NOT NULL,
    period_start date NOT NULL,
    period_end date NOT NULL,
    gross_sales kernel.money_amount DEFAULT 0 NOT NULL,
    commission_total kernel.money_amount DEFAULT 0 NOT NULL,
    net_payable kernel.money_amount DEFAULT 0 NOT NULL,
    currency kernel.currency_code DEFAULT 'USD'::bpchar NOT NULL,
    status text DEFAULT 'draft'::text NOT NULL,
    journal_entry_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    CONSTRAINT consignor_settlement_check CHECK ((period_end >= period_start)),
    CONSTRAINT consignor_settlement_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'finalized'::text, 'paid'::text, 'voided'::text])))
);

ALTER TABLE ONLY tenant_demo.consignor_settlement FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE consignor_settlement; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.consignor_settlement IS 'A settlement batch: gross sales, commission, net payable to a consignor.';


--
-- Name: consignor_settlement_settlement_no_seq; Type: SEQUENCE; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.consignor_settlement ALTER COLUMN settlement_no ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME tenant_demo.consignor_settlement_settlement_no_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: delinquency; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.delinquency (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    lease_id uuid NOT NULL,
    as_of_date date NOT NULL,
    amount_due kernel.money_amount DEFAULT 0 NOT NULL,
    amount_paid kernel.money_amount DEFAULT 0 NOT NULL,
    days_past_due integer DEFAULT 0 NOT NULL,
    status text DEFAULT 'current'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    CONSTRAINT delinquency_days_past_due_check CHECK ((days_past_due >= 0)),
    CONSTRAINT delinquency_status_check CHECK ((status = ANY (ARRAY['current'::text, 'delinquent'::text, 'collections'::text, 'written_off'::text])))
);

ALTER TABLE ONLY tenant_demo.delinquency FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE delinquency; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.delinquency IS 'Point-in-time arrears snapshot per lease.';


--
-- Name: exchange_rate; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.exchange_rate (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    from_currency kernel.currency_code NOT NULL,
    to_currency kernel.currency_code NOT NULL,
    rate kernel.fx_rate NOT NULL,
    as_of date NOT NULL,
    source text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    CONSTRAINT exchange_rate_check CHECK (((from_currency)::bpchar <> (to_currency)::bpchar))
);

ALTER TABLE ONLY tenant_demo.exchange_rate FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE exchange_rate; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.exchange_rate IS 'Dated FX rates. Lookup = latest as_of <= target date.';


--
-- Name: fiscal_period; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.fiscal_period (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    fiscal_year smallint NOT NULL,
    period_no smallint NOT NULL,
    start_date date NOT NULL,
    end_date date NOT NULL,
    status text DEFAULT 'open'::text NOT NULL,
    closed_at timestamp with time zone,
    closed_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    CONSTRAINT fiscal_period_check CHECK ((end_date >= start_date)),
    CONSTRAINT fiscal_period_period_no_check CHECK (((period_no >= 1) AND (period_no <= 13))),
    CONSTRAINT fiscal_period_status_check CHECK ((status = ANY (ARRAY['open'::text, 'closed'::text, 'locked'::text])))
);

ALTER TABLE ONLY tenant_demo.fiscal_period FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE fiscal_period; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.fiscal_period IS 'Fiscal calendar. status=closed/locked blocks new postings into the period.';


--
-- Name: floor; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.floor (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    location_id uuid NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    level_no smallint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    deleted_at timestamp with time zone,
    deleted_by uuid
);

ALTER TABLE ONLY tenant_demo.floor FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE floor; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.floor IS 'A level within a location. Master data (soft-deleted).';


--
-- Name: item_price_change; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.item_price_change (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    item_id uuid NOT NULL,
    old_price kernel.money_amount,
    new_price kernel.money_amount NOT NULL,
    reason text,
    changed_at timestamp with time zone DEFAULT now() NOT NULL,
    changed_by uuid DEFAULT kernel.current_actor(),
    CONSTRAINT item_price_change_new_price_check CHECK (((new_price)::numeric >= (0)::numeric))
);

ALTER TABLE ONLY tenant_demo.item_price_change FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE item_price_change; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.item_price_change IS 'Price-change history for a consigned item (append-only detail).';


--
-- Name: je_p; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.je_p (
    id uuid DEFAULT uuidv7() NOT NULL,
    entry_date date NOT NULL,
    memo text
)
PARTITION BY RANGE (entry_date);


--
-- Name: je_p_2026; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.je_p_2026 (
    id uuid DEFAULT uuidv7() CONSTRAINT je_p_id_not_null NOT NULL,
    entry_date date CONSTRAINT je_p_entry_date_not_null NOT NULL,
    memo text
);


--
-- Name: je_p_2027; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.je_p_2027 (
    id uuid DEFAULT uuidv7() CONSTRAINT je_p_id_not_null NOT NULL,
    entry_date date CONSTRAINT je_p_entry_date_not_null NOT NULL,
    memo text
);


--
-- Name: jl_p; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.jl_p (
    id bigint NOT NULL,
    journal_entry_id uuid NOT NULL,
    entry_date date NOT NULL,
    line_no smallint NOT NULL,
    debit kernel.money_amount DEFAULT 0 NOT NULL,
    credit kernel.money_amount DEFAULT 0 NOT NULL
)
PARTITION BY RANGE (entry_date);


--
-- Name: jl_p_2026; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.jl_p_2026 (
    id bigint CONSTRAINT jl_p_id_not_null NOT NULL,
    journal_entry_id uuid CONSTRAINT jl_p_journal_entry_id_not_null NOT NULL,
    entry_date date CONSTRAINT jl_p_entry_date_not_null NOT NULL,
    line_no smallint CONSTRAINT jl_p_line_no_not_null NOT NULL,
    debit kernel.money_amount DEFAULT 0 CONSTRAINT jl_p_debit_not_null NOT NULL,
    credit kernel.money_amount DEFAULT 0 CONSTRAINT jl_p_credit_not_null NOT NULL
);


--
-- Name: jl_p_2027; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.jl_p_2027 (
    id bigint CONSTRAINT jl_p_id_not_null NOT NULL,
    journal_entry_id uuid CONSTRAINT jl_p_journal_entry_id_not_null NOT NULL,
    entry_date date CONSTRAINT jl_p_entry_date_not_null NOT NULL,
    line_no smallint CONSTRAINT jl_p_line_no_not_null NOT NULL,
    debit kernel.money_amount DEFAULT 0 CONSTRAINT jl_p_debit_not_null NOT NULL,
    credit kernel.money_amount DEFAULT 0 CONSTRAINT jl_p_credit_not_null NOT NULL
);


--
-- Name: jl_p_id_seq; Type: SEQUENCE; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.jl_p ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME tenant_demo.jl_p_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: journal_entry; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.journal_entry (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    entry_no bigint NOT NULL,
    entry_date date NOT NULL,
    posting_date timestamp with time zone DEFAULT now() NOT NULL,
    memo text,
    source text DEFAULT 'manual'::text NOT NULL,
    source_ref text,
    idempotency_key text,
    reversal_of_id uuid,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE journal_entry; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.journal_entry IS 'Append-only journal header. RLS intentionally OFF (ADR-0007, measured 3x cost); relies on schema isolation.';


--
-- Name: journal_entry_entry_no_seq; Type: SEQUENCE; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.journal_entry ALTER COLUMN entry_no ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME tenant_demo.journal_entry_entry_no_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: journal_entry_status; Type: VIEW; Schema: tenant_demo; Owner: -
--

CREATE VIEW tenant_demo.journal_entry_status AS
 SELECT je.id,
    je.tenant_id,
    je.entry_no,
    je.entry_date,
    je.posting_date,
    je.memo,
    je.source,
    je.source_ref,
    je.idempotency_key,
    je.reversal_of_id,
    je.created_by,
    je.created_at,
    (r.id IS NOT NULL) AS is_reversed,
    r.id AS reversed_by_id
   FROM (tenant_demo.journal_entry je
     LEFT JOIN tenant_demo.journal_entry r ON ((r.reversal_of_id = je.id)));


--
-- Name: VIEW journal_entry_status; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON VIEW tenant_demo.journal_entry_status IS 'Derived reversal status; the journal itself is never mutated.';


--
-- Name: journal_line; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.journal_line (
    id bigint NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    journal_entry_id uuid NOT NULL,
    line_no smallint NOT NULL,
    account_id uuid NOT NULL,
    debit kernel.money_amount DEFAULT 0 NOT NULL,
    credit kernel.money_amount DEFAULT 0 NOT NULL,
    currency kernel.currency_code NOT NULL,
    fx_rate kernel.fx_rate DEFAULT 1 NOT NULL,
    base_debit kernel.money_amount DEFAULT 0 NOT NULL,
    base_credit kernel.money_amount DEFAULT 0 NOT NULL,
    party_id uuid,
    subledger_type_code text,
    memo text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT journal_line_check CHECK ((((debit)::numeric >= (0)::numeric) AND ((credit)::numeric >= (0)::numeric))),
    CONSTRAINT journal_line_check1 CHECK (((((debit)::numeric > (0)::numeric) AND ((credit)::numeric = (0)::numeric)) OR (((credit)::numeric > (0)::numeric) AND ((debit)::numeric = (0)::numeric)))),
    CONSTRAINT journal_line_check2 CHECK ((((base_debit)::numeric >= (0)::numeric) AND ((base_credit)::numeric >= (0)::numeric))),
    CONSTRAINT journal_line_check3 CHECK (((((base_debit)::numeric > (0)::numeric) AND ((base_credit)::numeric = (0)::numeric)) OR (((base_credit)::numeric > (0)::numeric) AND ((base_debit)::numeric = (0)::numeric)))),
    CONSTRAINT journal_line_check4 CHECK ((((party_id IS NULL) AND (subledger_type_code IS NULL)) OR ((party_id IS NOT NULL) AND (subledger_type_code IS NOT NULL))))
);


--
-- Name: TABLE journal_line; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.journal_line IS 'Append-only journal lines. RLS intentionally OFF (ADR-0007, measured 3x cost); relies on schema isolation.';


--
-- Name: journal_line_id_seq; Type: SEQUENCE; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.journal_line ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME tenant_demo.journal_line_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: lease; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.lease (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    lease_no bigint NOT NULL,
    lessee_party_id uuid NOT NULL,
    location_id uuid NOT NULL,
    status text DEFAULT 'draft'::text NOT NULL,
    start_date date NOT NULL,
    end_date date,
    signed_date date,
    billing_day smallint DEFAULT 1 NOT NULL,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    deleted_at timestamp with time zone,
    deleted_by uuid,
    CONSTRAINT lease_billing_day_check CHECK (((billing_day >= 1) AND (billing_day <= 28))),
    CONSTRAINT lease_check CHECK (((end_date IS NULL) OR (end_date >= start_date))),
    CONSTRAINT lease_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'active'::text, 'expired'::text, 'terminated'::text])))
);

ALTER TABLE ONLY tenant_demo.lease FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE lease; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.lease IS 'Lease contract. lessee_party_id is the tenant of the space. Master data (soft-deleted).';


--
-- Name: lease_deposit; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.lease_deposit (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    lease_id uuid NOT NULL,
    deposit_amount kernel.money_amount NOT NULL,
    currency kernel.currency_code DEFAULT 'USD'::bpchar NOT NULL,
    received_date date,
    status text DEFAULT 'pending'::text NOT NULL,
    journal_entry_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    CONSTRAINT lease_deposit_deposit_amount_check CHECK (((deposit_amount)::numeric >= (0)::numeric)),
    CONSTRAINT lease_deposit_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'held'::text, 'applied'::text, 'refunded'::text, 'forfeited'::text])))
);

ALTER TABLE ONLY tenant_demo.lease_deposit FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE lease_deposit; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.lease_deposit IS 'Refundable security deposit. journal_entry_id ties it to the ledger.';


--
-- Name: lease_lease_no_seq; Type: SEQUENCE; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.lease ALTER COLUMN lease_no ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME tenant_demo.lease_lease_no_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: lease_space; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.lease_space (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    lease_id uuid NOT NULL,
    space_id uuid NOT NULL,
    allocated_area_sqft numeric(12,2),
    from_date date DEFAULT CURRENT_DATE NOT NULL,
    thru_date date,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    CONSTRAINT lease_space_allocated_area_sqft_check CHECK (((allocated_area_sqft IS NULL) OR (allocated_area_sqft >= (0)::numeric))),
    CONSTRAINT lease_space_check CHECK (((thru_date IS NULL) OR (thru_date >= from_date)))
);

ALTER TABLE ONLY tenant_demo.lease_space FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE lease_space; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.lease_space IS 'Time-bounded allocation of spaces to a lease.';


--
-- Name: location; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.location (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    timezone text DEFAULT 'UTC'::text NOT NULL,
    address_line1 text,
    address_line2 text,
    city text,
    region text,
    postal_code text,
    country_code character(2),
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    deleted_at timestamp with time zone,
    deleted_by uuid
);

ALTER TABLE ONLY tenant_demo.location FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE location; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.location IS 'A physical mall property/site. Master data (soft-deleted).';


--
-- Name: merchant_settlement; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.merchant_settlement (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    settlement_no bigint NOT NULL,
    settlement_date date DEFAULT CURRENT_DATE NOT NULL,
    gross_amount kernel.money_amount NOT NULL,
    fee_amount kernel.money_amount DEFAULT 0 NOT NULL,
    net_amount kernel.money_amount NOT NULL,
    currency kernel.currency_code DEFAULT 'USD'::bpchar NOT NULL,
    processor_ref text,
    journal_entry_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    CONSTRAINT merchant_settlement_check CHECK (((net_amount)::numeric = ((gross_amount)::numeric - (fee_amount)::numeric))),
    CONSTRAINT merchant_settlement_fee_amount_check CHECK (((fee_amount)::numeric >= (0)::numeric)),
    CONSTRAINT merchant_settlement_gross_amount_check CHECK (((gross_amount)::numeric >= (0)::numeric)),
    CONSTRAINT merchant_settlement_net_amount_check CHECK (((net_amount)::numeric >= (0)::numeric))
);

ALTER TABLE ONLY tenant_demo.merchant_settlement FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE merchant_settlement; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.merchant_settlement IS 'Processor payout: clearing -> bank, with fee expensed (ADR-0029).';


--
-- Name: merchant_settlement_settlement_no_seq; Type: SEQUENCE; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.merchant_settlement ALTER COLUMN settlement_no ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME tenant_demo.merchant_settlement_settlement_no_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: open_item; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.open_item (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    subledger_type_code text NOT NULL,
    party_id uuid NOT NULL,
    source text NOT NULL,
    source_ref text,
    document_no text,
    original_amount kernel.money_amount NOT NULL,
    open_amount kernel.money_amount NOT NULL,
    currency kernel.currency_code DEFAULT 'USD'::bpchar NOT NULL,
    issue_date date NOT NULL,
    due_date date,
    status text DEFAULT 'open'::text NOT NULL,
    journal_entry_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    deleted_at timestamp with time zone,
    deleted_by uuid,
    CONSTRAINT open_item_check CHECK (((open_amount)::numeric <= (original_amount)::numeric)),
    CONSTRAINT open_item_check1 CHECK (((due_date IS NULL) OR (due_date >= issue_date))),
    CONSTRAINT open_item_open_amount_check CHECK (((open_amount)::numeric >= (0)::numeric)),
    CONSTRAINT open_item_original_amount_check CHECK (((original_amount)::numeric >= (0)::numeric)),
    CONSTRAINT open_item_status_check CHECK ((status = ANY (ARRAY['open'::text, 'partial'::text, 'settled'::text, 'written_off'::text, 'void'::text])))
);

ALTER TABLE ONLY tenant_demo.open_item FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE open_item; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.open_item IS 'Open-item AR/AP detail (ADR-0023). open_amount is a positive magnitude; subledger_type_code gives direction.';


--
-- Name: organization; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.organization (
    party_id uuid NOT NULL,
    legal_name text NOT NULL,
    trading_name text,
    entity_type text,
    incorporation_date date,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    version integer DEFAULT 1 NOT NULL
);

ALTER TABLE ONLY tenant_demo.organization FORCE ROW LEVEL SECURITY;


--
-- Name: party; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.party (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    party_type text NOT NULL,
    display_name text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    deleted_at timestamp with time zone,
    deleted_by uuid,
    CONSTRAINT party_party_type_check CHECK ((party_type = ANY (ARRAY['person'::text, 'organization'::text])))
);

ALTER TABLE ONLY tenant_demo.party FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE party; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.party IS 'Party supertype. Person or Organization. Store owner is a Party with an is_house role.';


--
-- Name: party_contact_mechanism; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.party_contact_mechanism (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    party_id uuid NOT NULL,
    mechanism_type_code text NOT NULL,
    value text NOT NULL,
    is_primary boolean DEFAULT false NOT NULL,
    valid_from date,
    valid_thru date,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL
);

ALTER TABLE ONLY tenant_demo.party_contact_mechanism FORCE ROW LEVEL SECURITY;


--
-- Name: party_identifier; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.party_identifier (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    party_id uuid NOT NULL,
    identifier_type text NOT NULL,
    identifier_value_enc bytea NOT NULL,
    identifier_hash text NOT NULL,
    issuing_authority text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    deleted_at timestamp with time zone,
    deleted_by uuid
);

ALTER TABLE ONLY tenant_demo.party_identifier FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE party_identifier; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.party_identifier IS 'External identifiers. Values encrypted at rest (ADR-0018); uniqueness via sha256 hash.';


--
-- Name: party_relationship; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.party_relationship (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    from_party_id uuid NOT NULL,
    to_party_id uuid NOT NULL,
    relationship_type_code text NOT NULL,
    from_date date DEFAULT CURRENT_DATE NOT NULL,
    thru_date date,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    CONSTRAINT party_relationship_check CHECK ((from_party_id <> to_party_id)),
    CONSTRAINT party_relationship_check1 CHECK (((thru_date IS NULL) OR (thru_date >= from_date)))
);

ALTER TABLE ONLY tenant_demo.party_relationship FORCE ROW LEVEL SECURITY;


--
-- Name: party_role; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.party_role (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    party_id uuid NOT NULL,
    role_type_code text NOT NULL,
    is_house boolean DEFAULT false NOT NULL,
    from_date date DEFAULT CURRENT_DATE NOT NULL,
    thru_date date,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    CONSTRAINT party_role_check CHECK (((thru_date IS NULL) OR (thru_date >= from_date)))
);

ALTER TABLE ONLY tenant_demo.party_role FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE party_role; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.party_role IS 'Roles a party plays. is_house=true routes settlement to owner equity/draw.';


--
-- Name: payment; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.payment (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    payment_no bigint NOT NULL,
    sale_id uuid NOT NULL,
    payment_date date DEFAULT CURRENT_DATE NOT NULL,
    amount kernel.money_amount NOT NULL,
    currency kernel.currency_code DEFAULT 'USD'::bpchar NOT NULL,
    status text DEFAULT 'captured'::text NOT NULL,
    journal_entry_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    CONSTRAINT payment_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'captured'::text, 'voided'::text, 'refunded'::text])))
);

ALTER TABLE ONLY tenant_demo.payment FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE payment; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.payment IS 'Money received (or refunded) for a sale. May comprise several tenders.';


--
-- Name: payment_application; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.payment_application (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    open_item_id uuid NOT NULL,
    applied_amount kernel.money_amount NOT NULL,
    currency kernel.currency_code DEFAULT 'USD'::bpchar NOT NULL,
    applied_date date NOT NULL,
    journal_entry_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    CONSTRAINT payment_application_applied_amount_check CHECK (((applied_amount)::numeric > (0)::numeric))
);

ALTER TABLE ONLY tenant_demo.payment_application FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE payment_application; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.payment_application IS 'Allocation of a cash settlement to an open item (ADR-0023).';


--
-- Name: payment_payment_no_seq; Type: SEQUENCE; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.payment ALTER COLUMN payment_no ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME tenant_demo.payment_payment_no_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: payment_tender; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.payment_tender (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    payment_id uuid NOT NULL,
    tender_type_code text NOT NULL,
    amount kernel.money_amount NOT NULL,
    currency kernel.currency_code DEFAULT 'USD'::bpchar NOT NULL,
    party_id uuid,
    card_last4 character(4),
    processor_ref text,
    settled_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    CONSTRAINT payment_tender_amount_check CHECK (((amount)::numeric > (0)::numeric))
);

ALTER TABLE ONLY tenant_demo.payment_tender FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE payment_tender; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.payment_tender IS 'One tender within a payment. Split tenders are first-class (ADR-0029).';


--
-- Name: person; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.person (
    party_id uuid NOT NULL,
    given_name text,
    middle_name text,
    family_name text,
    name_prefix text,
    name_suffix text,
    date_of_birth date,
    gender text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    version integer DEFAULT 1 NOT NULL
);

ALTER TABLE ONLY tenant_demo.person FORCE ROW LEVEL SECURITY;


--
-- Name: postal_address; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.postal_address (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    party_id uuid NOT NULL,
    label text,
    line1 text,
    line2 text,
    city text,
    region text,
    postal_code text,
    country_code character(2),
    is_primary boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL
);

ALTER TABLE ONLY tenant_demo.postal_address FORCE ROW LEVEL SECURITY;


--
-- Name: posting_map; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.posting_map (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    role_code text NOT NULL,
    account_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL
);

ALTER TABLE ONLY tenant_demo.posting_map FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE posting_map; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.posting_map IS 'Account determination: posting role -> account. Domain posting resolves accounts here (ADR-0020).';


--
-- Name: register; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.register (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    location_id uuid,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    deleted_at timestamp with time zone,
    deleted_by uuid
);

ALTER TABLE ONLY tenant_demo.register FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE register; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.register IS 'A checkout station (central counter or vendor-run register).';


--
-- Name: rent_component; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.rent_component (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    lease_id uuid NOT NULL,
    component_type_code text NOT NULL,
    amount kernel.money_amount DEFAULT 0 NOT NULL,
    currency kernel.currency_code DEFAULT 'USD'::bpchar NOT NULL,
    percent_rate kernel.percent_rate,
    breakpoint_amount kernel.money_amount,
    billing_frequency text DEFAULT 'monthly'::text NOT NULL,
    effective_from date DEFAULT CURRENT_DATE NOT NULL,
    effective_thru date,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    CONSTRAINT rent_component_billing_frequency_check CHECK ((billing_frequency = ANY (ARRAY['monthly'::text, 'quarterly'::text, 'annual'::text]))),
    CONSTRAINT rent_component_check CHECK (((effective_thru IS NULL) OR (effective_thru >= effective_from))),
    CONSTRAINT rent_component_check1 CHECK ((((component_type_code = 'percentage_rent'::text) AND (percent_rate IS NOT NULL)) OR ((component_type_code <> 'percentage_rent'::text) AND ((amount)::numeric >= (0)::numeric))))
);

ALTER TABLE ONLY tenant_demo.rent_component FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE rent_component; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.rent_component IS 'Periodic lease charges. percentage_rent uses percent_rate; others use amount.';


--
-- Name: sale; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.sale (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    sale_no bigint NOT NULL,
    register_id uuid,
    shift_id uuid,
    customer_party_id uuid,
    sale_date date DEFAULT CURRENT_DATE NOT NULL,
    channel text DEFAULT 'in_store'::text NOT NULL,
    subtotal kernel.money_amount DEFAULT 0 NOT NULL,
    discount_total kernel.money_amount DEFAULT 0 NOT NULL,
    tax_total kernel.money_amount DEFAULT 0 NOT NULL,
    total kernel.money_amount DEFAULT 0 NOT NULL,
    currency kernel.currency_code DEFAULT 'USD'::bpchar NOT NULL,
    status text DEFAULT 'draft'::text NOT NULL,
    refunds_sale_id uuid,
    is_refund boolean DEFAULT false NOT NULL,
    journal_entry_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    deleted_at timestamp with time zone,
    deleted_by uuid,
    CONSTRAINT sale_channel_check CHECK ((channel = ANY (ARRAY['in_store'::text, 'online'::text, 'phone'::text, 'event'::text]))),
    CONSTRAINT sale_check CHECK (((total)::numeric = (((subtotal)::numeric - (discount_total)::numeric) + (tax_total)::numeric))),
    CONSTRAINT sale_check1 CHECK ((is_refund = (refunds_sale_id IS NOT NULL))),
    CONSTRAINT sale_discount_total_check CHECK (((discount_total)::numeric >= (0)::numeric)),
    CONSTRAINT sale_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'completed'::text, 'voided'::text, 'refunded'::text, 'partially_refunded'::text]))),
    CONSTRAINT sale_tax_total_check CHECK (((tax_total)::numeric >= (0)::numeric))
);

ALTER TABLE ONLY tenant_demo.sale FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE sale; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.sale IS 'POS sale document. Refunds are separate documents (reversal-not-edit).';


--
-- Name: sale_line; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.sale_line (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    sale_id uuid NOT NULL,
    line_no integer NOT NULL,
    line_kind text NOT NULL,
    consignment_item_id uuid,
    consignor_party_id uuid,
    vendor_party_id uuid,
    sku text,
    description text NOT NULL,
    quantity kernel.quantity DEFAULT 1 NOT NULL,
    unit_price kernel.money_amount NOT NULL,
    discount_amount kernel.money_amount DEFAULT 0 NOT NULL,
    extended_price kernel.money_amount NOT NULL,
    commission_rate kernel.percent_rate,
    commission_amount kernel.money_amount DEFAULT 0 NOT NULL,
    net_to_consignor kernel.money_amount DEFAULT 0 NOT NULL,
    unit_cost kernel.money_amount,
    is_taxable boolean DEFAULT true NOT NULL,
    tax_amount kernel.money_amount DEFAULT 0 NOT NULL,
    currency kernel.currency_code DEFAULT 'USD'::bpchar NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    CONSTRAINT sale_line_check CHECK (((extended_price)::numeric = (((quantity)::numeric * (unit_price)::numeric) - (discount_amount)::numeric))),
    CONSTRAINT sale_line_check1 CHECK (((line_kind <> 'consignment'::text) OR (consignor_party_id IS NOT NULL))),
    CONSTRAINT sale_line_check2 CHECK (((line_kind <> 'consignment'::text) OR (((commission_amount)::numeric + (net_to_consignor)::numeric) = (extended_price)::numeric))),
    CONSTRAINT sale_line_check3 CHECK (((line_kind <> 'owned'::text) OR ((consignor_party_id IS NULL) AND ((commission_amount)::numeric = (0)::numeric) AND ((net_to_consignor)::numeric = (0)::numeric)))),
    CONSTRAINT sale_line_commission_amount_check CHECK (((commission_amount)::numeric >= (0)::numeric)),
    CONSTRAINT sale_line_discount_amount_check CHECK (((discount_amount)::numeric >= (0)::numeric)),
    CONSTRAINT sale_line_extended_price_check CHECK (((extended_price)::numeric >= (0)::numeric)),
    CONSTRAINT sale_line_line_kind_check CHECK ((line_kind = ANY (ARRAY['consignment'::text, 'owned'::text]))),
    CONSTRAINT sale_line_net_to_consignor_check CHECK (((net_to_consignor)::numeric >= (0)::numeric)),
    CONSTRAINT sale_line_quantity_check CHECK (((quantity)::numeric > (0)::numeric)),
    CONSTRAINT sale_line_tax_amount_check CHECK (((tax_amount)::numeric >= (0)::numeric)),
    CONSTRAINT sale_line_unit_price_check CHECK (((unit_price)::numeric >= (0)::numeric))
);

ALTER TABLE ONLY tenant_demo.sale_line FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE sale_line; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.sale_line IS 'Sale line. Consignment lines accrue consignor payable AT SALE (ADR-0028).';


--
-- Name: sale_line_tax; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.sale_line_tax (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    sale_line_id uuid NOT NULL,
    jurisdiction_id uuid NOT NULL,
    rate kernel.percent_rate NOT NULL,
    tax_amount kernel.money_amount NOT NULL,
    currency kernel.currency_code DEFAULT 'USD'::bpchar NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    CONSTRAINT sale_line_tax_tax_amount_check CHECK (((tax_amount)::numeric >= (0)::numeric))
);

ALTER TABLE ONLY tenant_demo.sale_line_tax FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE sale_line_tax; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.sale_line_tax IS 'Tax detail per line per jurisdiction (supports multi-jurisdiction tax).';


--
-- Name: sale_sale_no_seq; Type: SEQUENCE; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.sale ALTER COLUMN sale_no ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME tenant_demo.sale_sale_no_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: settlement_line; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.settlement_line (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    settlement_id uuid NOT NULL,
    sale_line_id uuid NOT NULL,
    gross_amount kernel.money_amount NOT NULL,
    commission_amount kernel.money_amount NOT NULL,
    net_amount kernel.money_amount NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor()
);

ALTER TABLE ONLY tenant_demo.settlement_line FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE settlement_line; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.settlement_line IS 'Sale lines rolled into a settlement batch.';


--
-- Name: shift; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.shift (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    shift_no bigint NOT NULL,
    register_id uuid NOT NULL,
    opened_at timestamp with time zone DEFAULT now() NOT NULL,
    opened_by_party_id uuid,
    opening_float kernel.money_amount DEFAULT 0 NOT NULL,
    closed_at timestamp with time zone,
    counted_cash kernel.money_amount,
    expected_cash kernel.money_amount,
    over_short kernel.money_amount,
    status text DEFAULT 'open'::text NOT NULL,
    journal_entry_id uuid,
    currency kernel.currency_code DEFAULT 'USD'::bpchar NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    CONSTRAINT shift_check CHECK (((status = 'open'::text) OR (closed_at IS NOT NULL))),
    CONSTRAINT shift_opening_float_check CHECK (((opening_float)::numeric >= (0)::numeric)),
    CONSTRAINT shift_status_check CHECK ((status = ANY (ARRAY['open'::text, 'closed'::text])))
);

ALTER TABLE ONLY tenant_demo.shift FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE shift; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.shift IS 'Cash-drawer session. Over/short is booked at close (ADR-0029).';


--
-- Name: shift_shift_no_seq; Type: SEQUENCE; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.shift ALTER COLUMN shift_no ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME tenant_demo.shift_shift_no_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: space; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.space (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    floor_id uuid NOT NULL,
    code text NOT NULL,
    name text,
    space_type_code text NOT NULL,
    area_sqft numeric(12,2),
    status text DEFAULT 'available'::text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    deleted_at timestamp with time zone,
    deleted_by uuid,
    CONSTRAINT space_area_sqft_check CHECK (((area_sqft IS NULL) OR (area_sqft >= (0)::numeric))),
    CONSTRAINT space_status_check CHECK ((status = ANY (ARRAY['available'::text, 'reserved'::text, 'leased'::text, 'maintenance'::text, 'inactive'::text])))
);

ALTER TABLE ONLY tenant_demo.space FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE space; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.space IS 'A rentable unit. status tracks availability. Master data (soft-deleted).';


--
-- Name: space_attribute; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.space_attribute (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    space_id uuid NOT NULL,
    attr_key text NOT NULL,
    attr_value text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL
);

ALTER TABLE ONLY tenant_demo.space_attribute FORCE ROW LEVEL SECURITY;


--
-- Name: tax_jurisdiction; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.tax_jurisdiction (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    deleted_at timestamp with time zone,
    deleted_by uuid
);

ALTER TABLE ONLY tenant_demo.tax_jurisdiction FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE tax_jurisdiction; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.tax_jurisdiction IS 'Sales-tax authority (state/county/city/special district).';


--
-- Name: tax_rate; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.tax_rate (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    jurisdiction_id uuid NOT NULL,
    rate kernel.percent_rate NOT NULL,
    effective_from date DEFAULT CURRENT_DATE NOT NULL,
    effective_thru date,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    CONSTRAINT tax_rate_check CHECK (((effective_thru IS NULL) OR (effective_thru >= effective_from))),
    CONSTRAINT tax_rate_rate_check CHECK ((((rate)::numeric >= (0)::numeric) AND ((rate)::numeric <= (1)::numeric)))
);

ALTER TABLE ONLY tenant_demo.tax_rate FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE tax_rate; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.tax_rate IS 'Effective-dated tax rate per jurisdiction (non-overlapping, ADR-0021).';


--
-- Name: tenant_config; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.tenant_config (
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    legal_name text NOT NULL,
    functional_currency kernel.currency_code DEFAULT 'USD'::bpchar NOT NULL,
    fiscal_year_start_month smallint DEFAULT 1 NOT NULL,
    timezone text DEFAULT 'UTC'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    CONSTRAINT tenant_config_fiscal_year_start_month_check CHECK (((fiscal_year_start_month >= 1) AND (fiscal_year_start_month <= 12)))
);

ALTER TABLE ONLY tenant_demo.tenant_config FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE tenant_config; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.tenant_config IS 'One row per tenant. functional_currency is the ledger base currency.';


--
-- Name: tender_type; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.tender_type (
    code text NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    name text NOT NULL,
    settlement_kind text NOT NULL,
    debit_role_code text NOT NULL,
    subledger_type_code text,
    opens_drawer boolean DEFAULT false NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    CONSTRAINT tender_type_check CHECK (((settlement_kind = 'liability'::text) = (subledger_type_code IS NOT NULL))),
    CONSTRAINT tender_type_settlement_kind_check CHECK ((settlement_kind = ANY (ARRAY['cash'::text, 'clearing'::text, 'liability'::text])))
);

ALTER TABLE ONLY tenant_demo.tender_type FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE tender_type; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.tender_type IS 'Payment methods. settlement_kind drives which account is debited (ADR-0029).';


--
-- Name: v_active_lease; Type: VIEW; Schema: tenant_demo; Owner: -
--

CREATE VIEW tenant_demo.v_active_lease AS
 SELECT l.id AS lease_id,
    l.lease_no,
    l.status,
    l.start_date,
    l.end_date,
    p.display_name AS lessee_name,
    loc.name AS location_name,
    s.code AS space_code,
    s.space_type_code
   FROM ((((tenant_demo.lease l
     JOIN tenant_demo.party p ON ((p.id = l.lessee_party_id)))
     JOIN tenant_demo.location loc ON ((loc.id = l.location_id)))
     LEFT JOIN tenant_demo.lease_space ls ON (((ls.lease_id = l.id) AND (ls.thru_date IS NULL))))
     LEFT JOIN tenant_demo.space s ON ((s.id = ls.space_id)))
  WHERE (l.deleted_at IS NULL);


--
-- Name: VIEW v_active_lease; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON VIEW tenant_demo.v_active_lease IS 'Active leases joined to lessee, location, and current space.';


--
-- Name: v_open_item; Type: VIEW; Schema: tenant_demo; Owner: -
--

CREATE VIEW tenant_demo.v_open_item AS
 SELECT oi.id,
    oi.subledger_type_code,
    oi.party_id,
    p.display_name AS party_name,
    oi.source,
    oi.source_ref,
    oi.document_no,
    oi.original_amount,
    oi.open_amount,
    oi.currency,
    oi.issue_date,
    oi.due_date,
    oi.status,
    (CURRENT_DATE - COALESCE(oi.due_date, oi.issue_date)) AS days_outstanding
   FROM (tenant_demo.open_item oi
     JOIN tenant_demo.party p ON ((p.id = oi.party_id)))
  WHERE (oi.deleted_at IS NULL);


--
-- Name: VIEW v_open_item; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON VIEW tenant_demo.v_open_item IS 'Open items with party name and days outstanding.';


--
-- Name: v_aging; Type: VIEW; Schema: tenant_demo; Owner: -
--

CREATE VIEW tenant_demo.v_aging AS
 SELECT subledger_type_code,
    party_id,
    party_name,
    sum(
        CASE
            WHEN (days_outstanding <= 30) THEN (open_amount)::numeric
            ELSE (0)::numeric
        END) AS bucket_0_30,
    sum(
        CASE
            WHEN ((days_outstanding >= 31) AND (days_outstanding <= 60)) THEN (open_amount)::numeric
            ELSE (0)::numeric
        END) AS bucket_31_60,
    sum(
        CASE
            WHEN ((days_outstanding >= 61) AND (days_outstanding <= 90)) THEN (open_amount)::numeric
            ELSE (0)::numeric
        END) AS bucket_61_90,
    sum(
        CASE
            WHEN (days_outstanding > 90) THEN (open_amount)::numeric
            ELSE (0)::numeric
        END) AS bucket_90_plus,
    sum((open_amount)::numeric) AS total_open
   FROM tenant_demo.v_open_item
  WHERE (status = ANY (ARRAY['open'::text, 'partial'::text]))
  GROUP BY subledger_type_code, party_id, party_name;


--
-- Name: VIEW v_aging; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON VIEW tenant_demo.v_aging IS 'AR/AP aging buckets per party per subledger type.';


--
-- Name: v_subledger; Type: VIEW; Schema: tenant_demo; Owner: -
--

CREATE VIEW tenant_demo.v_subledger AS
 SELECT jl.subledger_type_code,
    jl.party_id,
    p.display_name AS party_name,
    sum((jl.base_debit)::numeric) AS total_debit,
    sum((jl.base_credit)::numeric) AS total_credit,
    sum(((jl.base_debit)::numeric - (jl.base_credit)::numeric)) AS balance
   FROM (tenant_demo.journal_line jl
     JOIN tenant_demo.party p ON ((p.id = jl.party_id)))
  WHERE (jl.subledger_type_code IS NOT NULL)
  GROUP BY jl.subledger_type_code, jl.party_id, p.display_name;


--
-- Name: VIEW v_subledger; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON VIEW tenant_demo.v_subledger IS 'Open balance per party per subledger type, derived from tagged journal lines.';


--
-- Name: v_ap; Type: VIEW; Schema: tenant_demo; Owner: -
--

CREATE VIEW tenant_demo.v_ap AS
 SELECT subledger_type_code,
    party_id,
    party_name,
    total_debit,
    total_credit,
    balance
   FROM tenant_demo.v_subledger
  WHERE (subledger_type_code = 'ap'::text);


--
-- Name: v_ar; Type: VIEW; Schema: tenant_demo; Owner: -
--

CREATE VIEW tenant_demo.v_ar AS
 SELECT subledger_type_code,
    party_id,
    party_name,
    total_debit,
    total_credit,
    balance
   FROM tenant_demo.v_subledger
  WHERE (subledger_type_code = 'ar'::text);


--
-- Name: v_consignor_payable; Type: VIEW; Schema: tenant_demo; Owner: -
--

CREATE VIEW tenant_demo.v_consignor_payable AS
 SELECT oi.party_id,
    p.display_name AS consignor_name,
    sum((oi.open_amount)::numeric) AS open_payable
   FROM (tenant_demo.open_item oi
     JOIN tenant_demo.party p ON ((p.id = oi.party_id)))
  WHERE ((oi.subledger_type_code = 'consignor_payable'::text) AND (oi.status = ANY (ARRAY['open'::text, 'partial'::text])) AND (oi.deleted_at IS NULL))
  GROUP BY oi.party_id, p.display_name;


--
-- Name: VIEW v_consignor_payable; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON VIEW tenant_demo.v_consignor_payable IS 'Open consignor payable per consignor (from open items).';


--
-- Name: v_customer_credit; Type: VIEW; Schema: tenant_demo; Owner: -
--

CREATE VIEW tenant_demo.v_customer_credit AS
 SELECT subledger_type_code,
    party_id,
    party_name,
    total_debit,
    total_credit,
    balance
   FROM tenant_demo.v_subledger
  WHERE (subledger_type_code = 'customer_credit'::text);


--
-- Name: v_gift_certificate; Type: VIEW; Schema: tenant_demo; Owner: -
--

CREATE VIEW tenant_demo.v_gift_certificate AS
 SELECT subledger_type_code,
    party_id,
    party_name,
    total_debit,
    total_credit,
    balance
   FROM tenant_demo.v_subledger
  WHERE (subledger_type_code = 'gift_certificate'::text);


--
-- Name: v_party_identifier_masked; Type: VIEW; Schema: tenant_demo; Owner: -
--

CREATE VIEW tenant_demo.v_party_identifier_masked AS
 SELECT id,
    tenant_id,
    party_id,
    identifier_type,
    kernel.mask_tail(kernel.pgp_sym_decrypt(identifier_value_enc, current_setting('app.pii_key'::text, true)), 4) AS identifier_masked,
    issuing_authority,
    created_at
   FROM tenant_demo.party_identifier
  WHERE (deleted_at IS NULL);


--
-- Name: VIEW v_party_identifier_masked; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON VIEW tenant_demo.v_party_identifier_masked IS 'PII-safe view of party identifiers (masked). Requires app.pii_key to decrypt.';


--
-- Name: v_vendor_balance_realtime; Type: VIEW; Schema: tenant_demo; Owner: -
--

CREATE VIEW tenant_demo.v_vendor_balance_realtime AS
 SELECT jl.party_id,
    p.display_name AS vendor_name,
    jl.subledger_type_code,
    sum(((jl.base_credit)::numeric - (jl.base_debit)::numeric)) AS balance_owed,
    max(je.entry_date) AS last_activity_date,
    count(*) AS ledger_line_count
   FROM ((tenant_demo.journal_line jl
     JOIN tenant_demo.journal_entry je ON ((je.id = jl.journal_entry_id)))
     JOIN tenant_demo.party p ON ((p.id = jl.party_id)))
  WHERE (jl.subledger_type_code = ANY (ARRAY['consignor_payable'::text, 'vendor_payable'::text]))
  GROUP BY jl.party_id, p.display_name, jl.subledger_type_code;


--
-- Name: VIEW v_vendor_balance_realtime; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON VIEW tenant_demo.v_vendor_balance_realtime IS 'Realtime payable balance per vendor/consignor, straight from the ledger (ADR-0028).';


--
-- Name: v_vendor_payable; Type: VIEW; Schema: tenant_demo; Owner: -
--

CREATE VIEW tenant_demo.v_vendor_payable AS
 SELECT subledger_type_code,
    party_id,
    party_name,
    total_debit,
    total_credit,
    balance
   FROM tenant_demo.v_subledger
  WHERE (subledger_type_code = 'vendor_payable'::text);


--
-- Name: v_vendor_payout_available; Type: VIEW; Schema: tenant_demo; Owner: -
--

CREATE VIEW tenant_demo.v_vendor_payout_available AS
 SELECT oi.party_id,
    p.display_name AS vendor_name,
    oi.subledger_type_code,
    sum((oi.open_amount)::numeric) AS available_amount,
    count(*) AS open_item_count,
    min(oi.issue_date) AS oldest_item_date
   FROM (tenant_demo.open_item oi
     JOIN tenant_demo.party p ON ((p.id = oi.party_id)))
  WHERE ((oi.subledger_type_code = ANY (ARRAY['consignor_payable'::text, 'vendor_payable'::text])) AND (oi.status = ANY (ARRAY['open'::text, 'partial'::text])) AND (oi.deleted_at IS NULL))
  GROUP BY oi.party_id, p.display_name, oi.subledger_type_code;


--
-- Name: VIEW v_vendor_payout_available; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON VIEW tenant_demo.v_vendor_payout_available IS 'Unsettled amounts available for payout, per vendor (realtime).';


--
-- Name: v_vendor_sales_realtime; Type: VIEW; Schema: tenant_demo; Owner: -
--

CREATE VIEW tenant_demo.v_vendor_sales_realtime AS
 SELECT COALESCE(sl.consignor_party_id, sl.vendor_party_id) AS party_id,
    pt.display_name AS vendor_name,
    s.sale_date,
    s.id AS sale_id,
    s.sale_no,
    sl.id AS sale_line_id,
    sl.line_kind,
    sl.sku,
    sl.description,
    sl.quantity,
    sl.extended_price AS gross_amount,
    sl.commission_amount,
    sl.net_to_consignor AS net_amount,
    s.is_refund
   FROM ((tenant_demo.sale_line sl
     JOIN tenant_demo.sale s ON ((s.id = sl.sale_id)))
     JOIN tenant_demo.party pt ON ((pt.id = COALESCE(sl.consignor_party_id, sl.vendor_party_id))))
  WHERE ((s.status = ANY (ARRAY['completed'::text, 'refunded'::text, 'partially_refunded'::text])) AND (s.deleted_at IS NULL));


--
-- Name: VIEW v_vendor_sales_realtime; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON VIEW tenant_demo.v_vendor_sales_realtime IS 'Line-level realtime sales feed for the vendor portal.';


--
-- Name: v_vendor_sales_today; Type: VIEW; Schema: tenant_demo; Owner: -
--

CREATE VIEW tenant_demo.v_vendor_sales_today AS
 SELECT party_id,
    vendor_name,
    sale_date,
    count(*) FILTER (WHERE (NOT is_refund)) AS items_sold,
    (COALESCE(sum((gross_amount)::numeric) FILTER (WHERE (NOT is_refund)), (0)::numeric) - COALESCE(sum((gross_amount)::numeric) FILTER (WHERE is_refund), (0)::numeric)) AS gross_sales,
    (COALESCE(sum((commission_amount)::numeric) FILTER (WHERE (NOT is_refund)), (0)::numeric) - COALESCE(sum((commission_amount)::numeric) FILTER (WHERE is_refund), (0)::numeric)) AS commission,
    (COALESCE(sum((net_amount)::numeric) FILTER (WHERE (NOT is_refund)), (0)::numeric) - COALESCE(sum((net_amount)::numeric) FILTER (WHERE is_refund), (0)::numeric)) AS net_earned
   FROM tenant_demo.v_vendor_sales_realtime
  GROUP BY party_id, vendor_name, sale_date;


--
-- Name: VIEW v_vendor_sales_today; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON VIEW tenant_demo.v_vendor_sales_today IS 'Per-vendor per-day sales summary (net of refunds) for the portal dashboard.';


--
-- Name: v_vendor_statement; Type: VIEW; Schema: tenant_demo; Owner: -
--

CREATE VIEW tenant_demo.v_vendor_statement AS
 SELECT jl.party_id,
    p.display_name AS vendor_name,
    je.entry_date,
    je.source,
    je.source_ref,
    je.memo,
    jl.base_debit AS debit_amount,
    jl.base_credit AS credit_amount,
    ((jl.base_credit)::numeric - (jl.base_debit)::numeric) AS net_change,
    sum(((jl.base_credit)::numeric - (jl.base_debit)::numeric)) OVER (PARTITION BY jl.party_id ORDER BY je.entry_date, je.id, jl.id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_balance
   FROM ((tenant_demo.journal_line jl
     JOIN tenant_demo.journal_entry je ON ((je.id = jl.journal_entry_id)))
     JOIN tenant_demo.party p ON ((p.id = jl.party_id)))
  WHERE (jl.subledger_type_code = ANY (ARRAY['consignor_payable'::text, 'vendor_payable'::text]));


--
-- Name: VIEW v_vendor_statement; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON VIEW tenant_demo.v_vendor_statement IS 'Per-vendor statement with running balance, derived from the ledger.';


--
-- Name: waitlist; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.waitlist (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    party_id uuid NOT NULL,
    space_type_code text,
    preferred_location_id uuid,
    requested_at timestamp with time zone DEFAULT now() NOT NULL,
    status text DEFAULT 'waiting'::text NOT NULL,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    CONSTRAINT waitlist_status_check CHECK ((status = ANY (ARRAY['waiting'::text, 'offered'::text, 'converted'::text, 'expired'::text, 'cancelled'::text])))
);

ALTER TABLE ONLY tenant_demo.waitlist FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE waitlist; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.waitlist IS 'Parties waiting for space. status drives the queue.';


--
-- Name: je_p_2026; Type: TABLE ATTACH; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.je_p ATTACH PARTITION tenant_demo.je_p_2026 FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');


--
-- Name: je_p_2027; Type: TABLE ATTACH; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.je_p ATTACH PARTITION tenant_demo.je_p_2027 FOR VALUES FROM ('2027-01-01') TO ('2028-01-01');


--
-- Name: jl_p_2026; Type: TABLE ATTACH; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.jl_p ATTACH PARTITION tenant_demo.jl_p_2026 FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');


--
-- Name: jl_p_2027; Type: TABLE ATTACH; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.jl_p ATTACH PARTITION tenant_demo.jl_p_2027 FOR VALUES FROM ('2027-01-01') TO ('2028-01-01');


--
-- Name: account_type account_type_pkey; Type: CONSTRAINT; Schema: kernel; Owner: -
--

ALTER TABLE ONLY kernel.account_type
    ADD CONSTRAINT account_type_pkey PRIMARY KEY (code);


--
-- Name: contact_mechanism_type contact_mechanism_type_pkey; Type: CONSTRAINT; Schema: kernel; Owner: -
--

ALTER TABLE ONLY kernel.contact_mechanism_type
    ADD CONSTRAINT contact_mechanism_type_pkey PRIMARY KEY (code);


--
-- Name: currency currency_pkey; Type: CONSTRAINT; Schema: kernel; Owner: -
--

ALTER TABLE ONLY kernel.currency
    ADD CONSTRAINT currency_pkey PRIMARY KEY (code);


--
-- Name: data_classification data_classification_pkey; Type: CONSTRAINT; Schema: kernel; Owner: -
--

ALTER TABLE ONLY kernel.data_classification
    ADD CONSTRAINT data_classification_pkey PRIMARY KEY (schema_name, table_name, column_name);


--
-- Name: identifier_type identifier_type_pkey; Type: CONSTRAINT; Schema: kernel; Owner: -
--

ALTER TABLE ONLY kernel.identifier_type
    ADD CONSTRAINT identifier_type_pkey PRIMARY KEY (code);


--
-- Name: migration migration_pkey; Type: CONSTRAINT; Schema: kernel; Owner: -
--

ALTER TABLE ONLY kernel.migration
    ADD CONSTRAINT migration_pkey PRIMARY KEY (schema_name, version);


--
-- Name: party_relationship_type party_relationship_type_pkey; Type: CONSTRAINT; Schema: kernel; Owner: -
--

ALTER TABLE ONLY kernel.party_relationship_type
    ADD CONSTRAINT party_relationship_type_pkey PRIMARY KEY (code);


--
-- Name: party_role_type party_role_type_pkey; Type: CONSTRAINT; Schema: kernel; Owner: -
--

ALTER TABLE ONLY kernel.party_role_type
    ADD CONSTRAINT party_role_type_pkey PRIMARY KEY (code);


--
-- Name: posting_role posting_role_pkey; Type: CONSTRAINT; Schema: kernel; Owner: -
--

ALTER TABLE ONLY kernel.posting_role
    ADD CONSTRAINT posting_role_pkey PRIMARY KEY (code);


--
-- Name: rent_component_type rent_component_type_pkey; Type: CONSTRAINT; Schema: kernel; Owner: -
--

ALTER TABLE ONLY kernel.rent_component_type
    ADD CONSTRAINT rent_component_type_pkey PRIMARY KEY (code);


--
-- Name: space_type space_type_pkey; Type: CONSTRAINT; Schema: kernel; Owner: -
--

ALTER TABLE ONLY kernel.space_type
    ADD CONSTRAINT space_type_pkey PRIMARY KEY (code);


--
-- Name: subledger_type subledger_type_pkey; Type: CONSTRAINT; Schema: kernel; Owner: -
--

ALTER TABLE ONLY kernel.subledger_type
    ADD CONSTRAINT subledger_type_pkey PRIMARY KEY (code);


--
-- Name: account account_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.account
    ADD CONSTRAINT account_pkey PRIMARY KEY (id);


--
-- Name: account account_tenant_id_code_key; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.account
    ADD CONSTRAINT account_tenant_id_code_key UNIQUE (tenant_id, code);


--
-- Name: audit_log audit_log_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.audit_log
    ADD CONSTRAINT audit_log_pkey PRIMARY KEY (id);


--
-- Name: commission_rule commission_rule_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.commission_rule
    ADD CONSTRAINT commission_rule_pkey PRIMARY KEY (id);


--
-- Name: consignment_item consignment_item_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.consignment_item
    ADD CONSTRAINT consignment_item_pkey PRIMARY KEY (id);


--
-- Name: consignment_sale_line consignment_sale_line_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.consignment_sale_line
    ADD CONSTRAINT consignment_sale_line_pkey PRIMARY KEY (id);


--
-- Name: consignment_sale consignment_sale_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.consignment_sale
    ADD CONSTRAINT consignment_sale_pkey PRIMARY KEY (id);


--
-- Name: consignor_agreement consignor_agreement_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.consignor_agreement
    ADD CONSTRAINT consignor_agreement_pkey PRIMARY KEY (id);


--
-- Name: consignor_payout consignor_payout_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.consignor_payout
    ADD CONSTRAINT consignor_payout_pkey PRIMARY KEY (id);


--
-- Name: consignor_settlement consignor_settlement_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.consignor_settlement
    ADD CONSTRAINT consignor_settlement_pkey PRIMARY KEY (id);


--
-- Name: delinquency delinquency_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.delinquency
    ADD CONSTRAINT delinquency_pkey PRIMARY KEY (id);


--
-- Name: delinquency delinquency_tenant_id_lease_id_as_of_date_key; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.delinquency
    ADD CONSTRAINT delinquency_tenant_id_lease_id_as_of_date_key UNIQUE (tenant_id, lease_id, as_of_date);


--
-- Name: commission_rule ex_commission_rule_no_overlap; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.commission_rule
    ADD CONSTRAINT ex_commission_rule_no_overlap EXCLUDE USING gist (agreement_id WITH =, daterange(effective_from, effective_thru, '[]'::text) WITH &&);


--
-- Name: rent_component ex_rent_component_no_overlap; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.rent_component
    ADD CONSTRAINT ex_rent_component_no_overlap EXCLUDE USING gist (lease_id WITH =, component_type_code WITH =, daterange(effective_from, effective_thru, '[]'::text) WITH &&);


--
-- Name: tax_rate ex_tax_rate_no_overlap; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.tax_rate
    ADD CONSTRAINT ex_tax_rate_no_overlap EXCLUDE USING gist (jurisdiction_id WITH =, daterange(effective_from, COALESCE(effective_thru, 'infinity'::date), '[]'::text) WITH &&);


--
-- Name: exchange_rate exchange_rate_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.exchange_rate
    ADD CONSTRAINT exchange_rate_pkey PRIMARY KEY (id);


--
-- Name: exchange_rate exchange_rate_tenant_id_from_currency_to_currency_as_of_key; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.exchange_rate
    ADD CONSTRAINT exchange_rate_tenant_id_from_currency_to_currency_as_of_key UNIQUE (tenant_id, from_currency, to_currency, as_of);


--
-- Name: fiscal_period fiscal_period_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.fiscal_period
    ADD CONSTRAINT fiscal_period_pkey PRIMARY KEY (id);


--
-- Name: fiscal_period fiscal_period_tenant_id_fiscal_year_period_no_key; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.fiscal_period
    ADD CONSTRAINT fiscal_period_tenant_id_fiscal_year_period_no_key UNIQUE (tenant_id, fiscal_year, period_no);


--
-- Name: floor floor_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.floor
    ADD CONSTRAINT floor_pkey PRIMARY KEY (id);


--
-- Name: floor floor_tenant_id_location_id_code_key; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.floor
    ADD CONSTRAINT floor_tenant_id_location_id_code_key UNIQUE (tenant_id, location_id, code);


--
-- Name: item_price_change item_price_change_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.item_price_change
    ADD CONSTRAINT item_price_change_pkey PRIMARY KEY (id);


--
-- Name: je_p je_p_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.je_p
    ADD CONSTRAINT je_p_pkey PRIMARY KEY (id, entry_date);


--
-- Name: je_p_2026 je_p_2026_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.je_p_2026
    ADD CONSTRAINT je_p_2026_pkey PRIMARY KEY (id, entry_date);


--
-- Name: je_p_2027 je_p_2027_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.je_p_2027
    ADD CONSTRAINT je_p_2027_pkey PRIMARY KEY (id, entry_date);


--
-- Name: jl_p jl_p_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.jl_p
    ADD CONSTRAINT jl_p_pkey PRIMARY KEY (id, entry_date);


--
-- Name: jl_p_2026 jl_p_2026_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.jl_p_2026
    ADD CONSTRAINT jl_p_2026_pkey PRIMARY KEY (id, entry_date);


--
-- Name: jl_p_2027 jl_p_2027_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.jl_p_2027
    ADD CONSTRAINT jl_p_2027_pkey PRIMARY KEY (id, entry_date);


--
-- Name: journal_entry journal_entry_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.journal_entry
    ADD CONSTRAINT journal_entry_pkey PRIMARY KEY (id);


--
-- Name: journal_entry journal_entry_tenant_id_entry_no_key; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.journal_entry
    ADD CONSTRAINT journal_entry_tenant_id_entry_no_key UNIQUE (tenant_id, entry_no);


--
-- Name: journal_entry journal_entry_tenant_id_idempotency_key_key; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.journal_entry
    ADD CONSTRAINT journal_entry_tenant_id_idempotency_key_key UNIQUE (tenant_id, idempotency_key);


--
-- Name: journal_line journal_line_journal_entry_id_line_no_key; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.journal_line
    ADD CONSTRAINT journal_line_journal_entry_id_line_no_key UNIQUE (journal_entry_id, line_no);


--
-- Name: journal_line journal_line_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.journal_line
    ADD CONSTRAINT journal_line_pkey PRIMARY KEY (id);


--
-- Name: lease_deposit lease_deposit_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.lease_deposit
    ADD CONSTRAINT lease_deposit_pkey PRIMARY KEY (id);


--
-- Name: lease lease_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.lease
    ADD CONSTRAINT lease_pkey PRIMARY KEY (id);


--
-- Name: lease_space lease_space_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.lease_space
    ADD CONSTRAINT lease_space_pkey PRIMARY KEY (id);


--
-- Name: lease lease_tenant_id_lease_no_key; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.lease
    ADD CONSTRAINT lease_tenant_id_lease_no_key UNIQUE (tenant_id, lease_no);


--
-- Name: location location_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.location
    ADD CONSTRAINT location_pkey PRIMARY KEY (id);


--
-- Name: location location_tenant_id_code_key; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.location
    ADD CONSTRAINT location_tenant_id_code_key UNIQUE (tenant_id, code);


--
-- Name: merchant_settlement merchant_settlement_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.merchant_settlement
    ADD CONSTRAINT merchant_settlement_pkey PRIMARY KEY (id);


--
-- Name: open_item open_item_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.open_item
    ADD CONSTRAINT open_item_pkey PRIMARY KEY (id);


--
-- Name: organization organization_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.organization
    ADD CONSTRAINT organization_pkey PRIMARY KEY (party_id);


--
-- Name: party_contact_mechanism party_contact_mechanism_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.party_contact_mechanism
    ADD CONSTRAINT party_contact_mechanism_pkey PRIMARY KEY (id);


--
-- Name: party_identifier party_identifier_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.party_identifier
    ADD CONSTRAINT party_identifier_pkey PRIMARY KEY (id);


--
-- Name: party party_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.party
    ADD CONSTRAINT party_pkey PRIMARY KEY (id);


--
-- Name: party_relationship party_relationship_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.party_relationship
    ADD CONSTRAINT party_relationship_pkey PRIMARY KEY (id);


--
-- Name: party_role party_role_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.party_role
    ADD CONSTRAINT party_role_pkey PRIMARY KEY (id);


--
-- Name: payment_application payment_application_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.payment_application
    ADD CONSTRAINT payment_application_pkey PRIMARY KEY (id);


--
-- Name: payment payment_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.payment
    ADD CONSTRAINT payment_pkey PRIMARY KEY (id);


--
-- Name: payment_tender payment_tender_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.payment_tender
    ADD CONSTRAINT payment_tender_pkey PRIMARY KEY (id);


--
-- Name: person person_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.person
    ADD CONSTRAINT person_pkey PRIMARY KEY (party_id);


--
-- Name: postal_address postal_address_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.postal_address
    ADD CONSTRAINT postal_address_pkey PRIMARY KEY (id);


--
-- Name: posting_map posting_map_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.posting_map
    ADD CONSTRAINT posting_map_pkey PRIMARY KEY (id);


--
-- Name: posting_map posting_map_tenant_id_role_code_key; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.posting_map
    ADD CONSTRAINT posting_map_tenant_id_role_code_key UNIQUE (tenant_id, role_code);


--
-- Name: register register_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.register
    ADD CONSTRAINT register_pkey PRIMARY KEY (id);


--
-- Name: register register_tenant_id_code_key; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.register
    ADD CONSTRAINT register_tenant_id_code_key UNIQUE (tenant_id, code);


--
-- Name: rent_component rent_component_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.rent_component
    ADD CONSTRAINT rent_component_pkey PRIMARY KEY (id);


--
-- Name: sale_line sale_line_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.sale_line
    ADD CONSTRAINT sale_line_pkey PRIMARY KEY (id);


--
-- Name: sale_line sale_line_sale_id_line_no_key; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.sale_line
    ADD CONSTRAINT sale_line_sale_id_line_no_key UNIQUE (sale_id, line_no);


--
-- Name: sale_line_tax sale_line_tax_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.sale_line_tax
    ADD CONSTRAINT sale_line_tax_pkey PRIMARY KEY (id);


--
-- Name: sale_line_tax sale_line_tax_sale_line_id_jurisdiction_id_key; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.sale_line_tax
    ADD CONSTRAINT sale_line_tax_sale_line_id_jurisdiction_id_key UNIQUE (sale_line_id, jurisdiction_id);


--
-- Name: sale sale_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.sale
    ADD CONSTRAINT sale_pkey PRIMARY KEY (id);


--
-- Name: settlement_line settlement_line_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.settlement_line
    ADD CONSTRAINT settlement_line_pkey PRIMARY KEY (id);


--
-- Name: settlement_line settlement_line_settlement_id_sale_line_id_key; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.settlement_line
    ADD CONSTRAINT settlement_line_settlement_id_sale_line_id_key UNIQUE (settlement_id, sale_line_id);


--
-- Name: shift shift_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.shift
    ADD CONSTRAINT shift_pkey PRIMARY KEY (id);


--
-- Name: space_attribute space_attribute_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.space_attribute
    ADD CONSTRAINT space_attribute_pkey PRIMARY KEY (id);


--
-- Name: space_attribute space_attribute_space_id_attr_key_key; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.space_attribute
    ADD CONSTRAINT space_attribute_space_id_attr_key_key UNIQUE (space_id, attr_key);


--
-- Name: space space_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.space
    ADD CONSTRAINT space_pkey PRIMARY KEY (id);


--
-- Name: space space_tenant_id_code_key; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.space
    ADD CONSTRAINT space_tenant_id_code_key UNIQUE (tenant_id, code);


--
-- Name: tax_jurisdiction tax_jurisdiction_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.tax_jurisdiction
    ADD CONSTRAINT tax_jurisdiction_pkey PRIMARY KEY (id);


--
-- Name: tax_jurisdiction tax_jurisdiction_tenant_id_code_key; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.tax_jurisdiction
    ADD CONSTRAINT tax_jurisdiction_tenant_id_code_key UNIQUE (tenant_id, code);


--
-- Name: tax_rate tax_rate_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.tax_rate
    ADD CONSTRAINT tax_rate_pkey PRIMARY KEY (id);


--
-- Name: tenant_config tenant_config_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.tenant_config
    ADD CONSTRAINT tenant_config_pkey PRIMARY KEY (tenant_id);


--
-- Name: tender_type tender_type_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.tender_type
    ADD CONSTRAINT tender_type_pkey PRIMARY KEY (code);


--
-- Name: waitlist waitlist_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.waitlist
    ADD CONSTRAINT waitlist_pkey PRIMARY KEY (id);


--
-- Name: ix_account_active; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_account_active ON tenant_demo.account USING btree (tenant_id) WHERE (deleted_at IS NULL);


--
-- Name: ix_account_parent; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_account_parent ON tenant_demo.account USING btree (parent_id);


--
-- Name: ix_audit_log_row; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_audit_log_row ON tenant_demo.audit_log USING btree (table_name, row_id);


--
-- Name: ix_audit_log_time; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_audit_log_time ON tenant_demo.audit_log USING btree (occurred_at);


--
-- Name: ix_commission_rule_agreement; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_commission_rule_agreement ON tenant_demo.commission_rule USING btree (agreement_id);


--
-- Name: ix_consignment_item_agreement; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_consignment_item_agreement ON tenant_demo.consignment_item USING btree (agreement_id) WHERE (deleted_at IS NULL);


--
-- Name: ix_consignment_item_status; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_consignment_item_status ON tenant_demo.consignment_item USING btree (tenant_id, status) WHERE (deleted_at IS NULL);


--
-- Name: ix_consignment_sale_date; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_consignment_sale_date ON tenant_demo.consignment_sale USING btree (sale_date);


--
-- Name: ix_consignment_sale_line_consignor; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_consignment_sale_line_consignor ON tenant_demo.consignment_sale_line USING btree (consignor_party_id);


--
-- Name: ix_consignment_sale_line_sale; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_consignment_sale_line_sale ON tenant_demo.consignment_sale_line USING btree (sale_id);


--
-- Name: ix_consignor_agreement_party; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_consignor_agreement_party ON tenant_demo.consignor_agreement USING btree (consignor_party_id) WHERE (deleted_at IS NULL);


--
-- Name: ix_consignor_payout_settlement; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_consignor_payout_settlement ON tenant_demo.consignor_payout USING btree (settlement_id);


--
-- Name: ix_consignor_settlement_party; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_consignor_settlement_party ON tenant_demo.consignor_settlement USING btree (consignor_party_id);


--
-- Name: ix_delinquency_lease; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_delinquency_lease ON tenant_demo.delinquency USING btree (lease_id);


--
-- Name: ix_floor_location; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_floor_location ON tenant_demo.floor USING btree (location_id);


--
-- Name: ix_item_price_change_item; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_item_price_change_item ON tenant_demo.item_price_change USING btree (item_id);


--
-- Name: ix_journal_entry_date; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_journal_entry_date ON tenant_demo.journal_entry USING btree (entry_date);


--
-- Name: ix_journal_entry_source; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_journal_entry_source ON tenant_demo.journal_entry USING btree (source, source_ref);


--
-- Name: ix_journal_line_account; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_journal_line_account ON tenant_demo.journal_line USING btree (account_id);


--
-- Name: ix_journal_line_entry; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_journal_line_entry ON tenant_demo.journal_line USING btree (journal_entry_id);


--
-- Name: ix_journal_line_party; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_journal_line_party ON tenant_demo.journal_line USING btree (party_id, subledger_type_code);


--
-- Name: ix_lease_active; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_lease_active ON tenant_demo.lease USING btree (tenant_id, status) WHERE (deleted_at IS NULL);


--
-- Name: ix_lease_deposit_lease; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_lease_deposit_lease ON tenant_demo.lease_deposit USING btree (lease_id);


--
-- Name: ix_lease_lessee; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_lease_lessee ON tenant_demo.lease USING btree (lessee_party_id);


--
-- Name: ix_lease_location; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_lease_location ON tenant_demo.lease USING btree (location_id);


--
-- Name: ix_lease_space_lease; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_lease_space_lease ON tenant_demo.lease_space USING btree (lease_id);


--
-- Name: ix_lease_space_space; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_lease_space_space ON tenant_demo.lease_space USING btree (space_id);


--
-- Name: ix_location_active; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_location_active ON tenant_demo.location USING btree (tenant_id) WHERE (deleted_at IS NULL);


--
-- Name: ix_open_item_open; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_open_item_open ON tenant_demo.open_item USING btree (tenant_id, subledger_type_code, due_date) WHERE ((status = ANY (ARRAY['open'::text, 'partial'::text])) AND (deleted_at IS NULL));


--
-- Name: ix_open_item_party; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_open_item_party ON tenant_demo.open_item USING btree (tenant_id, subledger_type_code, party_id) WHERE (deleted_at IS NULL);


--
-- Name: ix_open_item_source; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_open_item_source ON tenant_demo.open_item USING btree (source, source_ref);


--
-- Name: ix_party_active; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_party_active ON tenant_demo.party USING btree (tenant_id) WHERE (deleted_at IS NULL);


--
-- Name: ix_party_contact_party; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_party_contact_party ON tenant_demo.party_contact_mechanism USING btree (party_id);


--
-- Name: ix_party_identifier_party; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_party_identifier_party ON tenant_demo.party_identifier USING btree (party_id);


--
-- Name: ix_party_relationship_from; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_party_relationship_from ON tenant_demo.party_relationship USING btree (from_party_id);


--
-- Name: ix_party_relationship_to; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_party_relationship_to ON tenant_demo.party_relationship USING btree (to_party_id);


--
-- Name: ix_party_role_party; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_party_role_party ON tenant_demo.party_role USING btree (party_id);


--
-- Name: ix_payment_application_item; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_payment_application_item ON tenant_demo.payment_application USING btree (open_item_id);


--
-- Name: ix_payment_application_je; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_payment_application_je ON tenant_demo.payment_application USING btree (journal_entry_id);


--
-- Name: ix_payment_sale; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_payment_sale ON tenant_demo.payment USING btree (sale_id);


--
-- Name: ix_payment_tender_payment; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_payment_tender_payment ON tenant_demo.payment_tender USING btree (payment_id);


--
-- Name: ix_payment_tender_type; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_payment_tender_type ON tenant_demo.payment_tender USING btree (tender_type_code);


--
-- Name: ix_postal_address_party; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_postal_address_party ON tenant_demo.postal_address USING btree (party_id);


--
-- Name: ix_rent_component_lease; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_rent_component_lease ON tenant_demo.rent_component USING btree (lease_id);


--
-- Name: ix_sale_customer; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_sale_customer ON tenant_demo.sale USING btree (customer_party_id) WHERE (deleted_at IS NULL);


--
-- Name: ix_sale_date; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_sale_date ON tenant_demo.sale USING btree (sale_date) WHERE (deleted_at IS NULL);


--
-- Name: ix_sale_line_consignor; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_sale_line_consignor ON tenant_demo.sale_line USING btree (consignor_party_id);


--
-- Name: ix_sale_line_item; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_sale_line_item ON tenant_demo.sale_line USING btree (consignment_item_id);


--
-- Name: ix_sale_line_sale; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_sale_line_sale ON tenant_demo.sale_line USING btree (sale_id);


--
-- Name: ix_sale_line_tax_line; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_sale_line_tax_line ON tenant_demo.sale_line_tax USING btree (sale_line_id);


--
-- Name: ix_sale_line_vendor; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_sale_line_vendor ON tenant_demo.sale_line USING btree (vendor_party_id);


--
-- Name: ix_sale_shift; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_sale_shift ON tenant_demo.sale USING btree (shift_id);


--
-- Name: ix_settlement_line_settlement; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_settlement_line_settlement ON tenant_demo.settlement_line USING btree (settlement_id);


--
-- Name: ix_shift_register; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_shift_register ON tenant_demo.shift USING btree (register_id, status);


--
-- Name: ix_space_attribute_space; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_space_attribute_space ON tenant_demo.space_attribute USING btree (space_id);


--
-- Name: ix_space_floor; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_space_floor ON tenant_demo.space USING btree (floor_id);


--
-- Name: ix_space_status; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_space_status ON tenant_demo.space USING btree (tenant_id, status) WHERE (deleted_at IS NULL);


--
-- Name: ix_waitlist_open; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_waitlist_open ON tenant_demo.waitlist USING btree (tenant_id, requested_at) WHERE (status = 'waiting'::text);


--
-- Name: ix_waitlist_party; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_waitlist_party ON tenant_demo.waitlist USING btree (party_id);


--
-- Name: ux_consignment_item_sku; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE UNIQUE INDEX ux_consignment_item_sku ON tenant_demo.consignment_item USING btree (tenant_id, sku) WHERE ((sku IS NOT NULL) AND (deleted_at IS NULL));


--
-- Name: ux_lease_space_active; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE UNIQUE INDEX ux_lease_space_active ON tenant_demo.lease_space USING btree (space_id) WHERE (thru_date IS NULL);


--
-- Name: ux_party_identifier_active; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE UNIQUE INDEX ux_party_identifier_active ON tenant_demo.party_identifier USING btree (tenant_id, identifier_type, identifier_hash) WHERE (deleted_at IS NULL);


--
-- Name: ux_party_role_active; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE UNIQUE INDEX ux_party_role_active ON tenant_demo.party_role USING btree (party_id, role_type_code) WHERE (thru_date IS NULL);


--
-- Name: ux_shift_one_open_per_register; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE UNIQUE INDEX ux_shift_one_open_per_register ON tenant_demo.shift USING btree (register_id) WHERE (status = 'open'::text);


--
-- Name: je_p_2026_pkey; Type: INDEX ATTACH; Schema: tenant_demo; Owner: -
--

ALTER INDEX tenant_demo.je_p_pkey ATTACH PARTITION tenant_demo.je_p_2026_pkey;


--
-- Name: je_p_2027_pkey; Type: INDEX ATTACH; Schema: tenant_demo; Owner: -
--

ALTER INDEX tenant_demo.je_p_pkey ATTACH PARTITION tenant_demo.je_p_2027_pkey;


--
-- Name: jl_p_2026_pkey; Type: INDEX ATTACH; Schema: tenant_demo; Owner: -
--

ALTER INDEX tenant_demo.jl_p_pkey ATTACH PARTITION tenant_demo.jl_p_2026_pkey;


--
-- Name: jl_p_2027_pkey; Type: INDEX ATTACH; Schema: tenant_demo; Owner: -
--

ALTER INDEX tenant_demo.jl_p_pkey ATTACH PARTITION tenant_demo.jl_p_2027_pkey;


--
-- Name: account trg_account_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_account_audit BEFORE UPDATE ON tenant_demo.account FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: account trg_account_audit_row; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_account_audit_row AFTER INSERT OR DELETE OR UPDATE ON tenant_demo.account FOR EACH ROW EXECUTE FUNCTION kernel.audit_row();


--
-- Name: audit_log trg_audit_log_append_only; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_audit_log_append_only BEFORE DELETE OR UPDATE ON tenant_demo.audit_log FOR EACH ROW EXECUTE FUNCTION kernel.forbid_mutation();


--
-- Name: commission_rule trg_commission_rule_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_commission_rule_audit BEFORE UPDATE ON tenant_demo.commission_rule FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: consignment_item trg_consignment_item_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_consignment_item_audit BEFORE UPDATE ON tenant_demo.consignment_item FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: consignment_sale trg_consignment_sale_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_consignment_sale_audit BEFORE UPDATE ON tenant_demo.consignment_sale FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: consignment_sale_line trg_consignment_sale_line_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_consignment_sale_line_audit BEFORE UPDATE ON tenant_demo.consignment_sale_line FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: consignor_agreement trg_consignor_agreement_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_consignor_agreement_audit BEFORE UPDATE ON tenant_demo.consignor_agreement FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: consignor_payout trg_consignor_payout_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_consignor_payout_audit BEFORE UPDATE ON tenant_demo.consignor_payout FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: consignor_settlement trg_consignor_settlement_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_consignor_settlement_audit BEFORE UPDATE ON tenant_demo.consignor_settlement FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: delinquency trg_delinquency_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_delinquency_audit BEFORE UPDATE ON tenant_demo.delinquency FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: exchange_rate trg_exchange_rate_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_exchange_rate_audit BEFORE UPDATE ON tenant_demo.exchange_rate FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: fiscal_period trg_fiscal_period_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_fiscal_period_audit BEFORE UPDATE ON tenant_demo.fiscal_period FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: floor trg_floor_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_floor_audit BEFORE UPDATE ON tenant_demo.floor FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: jl_p trg_jl_p_balanced; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE CONSTRAINT TRIGGER trg_jl_p_balanced AFTER INSERT OR DELETE OR UPDATE ON tenant_demo.jl_p DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION tenant_demo.assert_entry_balanced_p();


--
-- Name: journal_entry trg_journal_entry_append_only; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_journal_entry_append_only BEFORE DELETE OR UPDATE ON tenant_demo.journal_entry FOR EACH ROW EXECUTE FUNCTION kernel.forbid_mutation();


--
-- Name: journal_entry trg_journal_entry_period_open; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_journal_entry_period_open BEFORE INSERT ON tenant_demo.journal_entry FOR EACH ROW EXECUTE FUNCTION tenant_demo.assert_period_open();


--
-- Name: journal_line trg_journal_line_append_only; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_journal_line_append_only BEFORE DELETE OR UPDATE ON tenant_demo.journal_line FOR EACH ROW EXECUTE FUNCTION kernel.forbid_mutation();


--
-- Name: journal_line trg_journal_line_balanced; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE CONSTRAINT TRIGGER trg_journal_line_balanced AFTER INSERT OR DELETE OR UPDATE ON tenant_demo.journal_line DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION tenant_demo.assert_entry_balanced();


--
-- Name: journal_line trg_journal_line_subledger_control; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_journal_line_subledger_control BEFORE INSERT ON tenant_demo.journal_line FOR EACH ROW EXECUTE FUNCTION tenant_demo.assert_subledger_control();


--
-- Name: lease trg_lease_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_lease_audit BEFORE UPDATE ON tenant_demo.lease FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: lease trg_lease_audit_row; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_lease_audit_row AFTER INSERT OR DELETE OR UPDATE ON tenant_demo.lease FOR EACH ROW EXECUTE FUNCTION kernel.audit_row();


--
-- Name: lease_deposit trg_lease_deposit_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_lease_deposit_audit BEFORE UPDATE ON tenant_demo.lease_deposit FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: lease_space trg_lease_space_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_lease_space_audit BEFORE UPDATE ON tenant_demo.lease_space FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: location trg_location_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_location_audit BEFORE UPDATE ON tenant_demo.location FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: merchant_settlement trg_merchant_settlement_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_merchant_settlement_audit BEFORE UPDATE ON tenant_demo.merchant_settlement FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: open_item trg_open_item_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_open_item_audit BEFORE UPDATE ON tenant_demo.open_item FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: organization trg_organization_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_organization_audit BEFORE UPDATE ON tenant_demo.organization FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: organization trg_organization_subtype; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_organization_subtype BEFORE INSERT OR UPDATE ON tenant_demo.organization FOR EACH ROW EXECUTE FUNCTION tenant_demo.assert_party_subtype('organization');


--
-- Name: party trg_party_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_party_audit BEFORE UPDATE ON tenant_demo.party FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: party trg_party_audit_row; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_party_audit_row AFTER INSERT OR DELETE OR UPDATE ON tenant_demo.party FOR EACH ROW EXECUTE FUNCTION kernel.audit_row();


--
-- Name: party_contact_mechanism trg_party_contact_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_party_contact_audit BEFORE UPDATE ON tenant_demo.party_contact_mechanism FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: party_identifier trg_party_identifier_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_party_identifier_audit BEFORE UPDATE ON tenant_demo.party_identifier FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: party_relationship trg_party_relationship_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_party_relationship_audit BEFORE UPDATE ON tenant_demo.party_relationship FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: party_role trg_party_role_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_party_role_audit BEFORE UPDATE ON tenant_demo.party_role FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: payment_application trg_payment_application_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_payment_application_audit BEFORE UPDATE ON tenant_demo.payment_application FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: payment trg_payment_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_payment_audit BEFORE UPDATE ON tenant_demo.payment FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: payment_tender trg_payment_tender_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_payment_tender_audit BEFORE UPDATE ON tenant_demo.payment_tender FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: payment_tender trg_payment_tender_sum; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE CONSTRAINT TRIGGER trg_payment_tender_sum AFTER INSERT OR DELETE OR UPDATE ON tenant_demo.payment_tender DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION tenant_demo.assert_payment_tenders();


--
-- Name: person trg_person_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_person_audit BEFORE UPDATE ON tenant_demo.person FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: person trg_person_subtype; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_person_subtype BEFORE INSERT OR UPDATE ON tenant_demo.person FOR EACH ROW EXECUTE FUNCTION tenant_demo.assert_party_subtype('person');


--
-- Name: postal_address trg_postal_address_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_postal_address_audit BEFORE UPDATE ON tenant_demo.postal_address FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: posting_map trg_posting_map_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_posting_map_audit BEFORE UPDATE ON tenant_demo.posting_map FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: register trg_register_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_register_audit BEFORE UPDATE ON tenant_demo.register FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: rent_component trg_rent_component_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_rent_component_audit BEFORE UPDATE ON tenant_demo.rent_component FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: sale trg_sale_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_sale_audit BEFORE UPDATE ON tenant_demo.sale FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: sale_line trg_sale_line_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_sale_line_audit BEFORE UPDATE ON tenant_demo.sale_line FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: sale_line trg_sale_line_totals; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE CONSTRAINT TRIGGER trg_sale_line_totals AFTER INSERT OR DELETE OR UPDATE ON tenant_demo.sale_line DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION tenant_demo.assert_sale_totals();


--
-- Name: shift trg_shift_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_shift_audit BEFORE UPDATE ON tenant_demo.shift FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: space_attribute trg_space_attribute_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_space_attribute_audit BEFORE UPDATE ON tenant_demo.space_attribute FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: space trg_space_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_space_audit BEFORE UPDATE ON tenant_demo.space FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: tax_jurisdiction trg_tax_jurisdiction_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_tax_jurisdiction_audit BEFORE UPDATE ON tenant_demo.tax_jurisdiction FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: tax_rate trg_tax_rate_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_tax_rate_audit BEFORE UPDATE ON tenant_demo.tax_rate FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: tenant_config trg_tenant_config_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_tenant_config_audit BEFORE UPDATE ON tenant_demo.tenant_config FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: tenant_config trg_tenant_config_audit_row; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_tenant_config_audit_row AFTER INSERT OR DELETE OR UPDATE ON tenant_demo.tenant_config FOR EACH ROW EXECUTE FUNCTION kernel.audit_row();


--
-- Name: tender_type trg_tender_type_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_tender_type_audit BEFORE UPDATE ON tenant_demo.tender_type FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: waitlist trg_waitlist_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_waitlist_audit BEFORE UPDATE ON tenant_demo.waitlist FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: account account_account_type_code_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.account
    ADD CONSTRAINT account_account_type_code_fkey FOREIGN KEY (account_type_code) REFERENCES kernel.account_type(code);


--
-- Name: account account_control_subledger_type_code_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.account
    ADD CONSTRAINT account_control_subledger_type_code_fkey FOREIGN KEY (control_subledger_type_code) REFERENCES kernel.subledger_type(code);


--
-- Name: account account_currency_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.account
    ADD CONSTRAINT account_currency_fkey FOREIGN KEY (currency) REFERENCES kernel.currency(code);


--
-- Name: account account_parent_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.account
    ADD CONSTRAINT account_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES tenant_demo.account(id) ON DELETE RESTRICT;


--
-- Name: commission_rule commission_rule_agreement_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.commission_rule
    ADD CONSTRAINT commission_rule_agreement_id_fkey FOREIGN KEY (agreement_id) REFERENCES tenant_demo.consignor_agreement(id) ON DELETE RESTRICT;


--
-- Name: consignment_item consignment_item_agreement_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.consignment_item
    ADD CONSTRAINT consignment_item_agreement_id_fkey FOREIGN KEY (agreement_id) REFERENCES tenant_demo.consignor_agreement(id) ON DELETE RESTRICT;


--
-- Name: consignment_sale consignment_sale_customer_party_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.consignment_sale
    ADD CONSTRAINT consignment_sale_customer_party_id_fkey FOREIGN KEY (customer_party_id) REFERENCES tenant_demo.party(id) ON DELETE RESTRICT;


--
-- Name: consignment_sale consignment_sale_journal_entry_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.consignment_sale
    ADD CONSTRAINT consignment_sale_journal_entry_id_fkey FOREIGN KEY (journal_entry_id) REFERENCES tenant_demo.journal_entry(id) ON DELETE RESTRICT;


--
-- Name: consignment_sale_line consignment_sale_line_consignor_party_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.consignment_sale_line
    ADD CONSTRAINT consignment_sale_line_consignor_party_id_fkey FOREIGN KEY (consignor_party_id) REFERENCES tenant_demo.party(id) ON DELETE RESTRICT;


--
-- Name: consignment_sale_line consignment_sale_line_item_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.consignment_sale_line
    ADD CONSTRAINT consignment_sale_line_item_id_fkey FOREIGN KEY (item_id) REFERENCES tenant_demo.consignment_item(id) ON DELETE RESTRICT;


--
-- Name: consignment_sale_line consignment_sale_line_sale_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.consignment_sale_line
    ADD CONSTRAINT consignment_sale_line_sale_id_fkey FOREIGN KEY (sale_id) REFERENCES tenant_demo.consignment_sale(id) ON DELETE RESTRICT;


--
-- Name: consignor_agreement consignor_agreement_consignor_party_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.consignor_agreement
    ADD CONSTRAINT consignor_agreement_consignor_party_id_fkey FOREIGN KEY (consignor_party_id) REFERENCES tenant_demo.party(id) ON DELETE RESTRICT;


--
-- Name: consignor_payout consignor_payout_journal_entry_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.consignor_payout
    ADD CONSTRAINT consignor_payout_journal_entry_id_fkey FOREIGN KEY (journal_entry_id) REFERENCES tenant_demo.journal_entry(id) ON DELETE RESTRICT;


--
-- Name: consignor_payout consignor_payout_settlement_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.consignor_payout
    ADD CONSTRAINT consignor_payout_settlement_id_fkey FOREIGN KEY (settlement_id) REFERENCES tenant_demo.consignor_settlement(id) ON DELETE RESTRICT;


--
-- Name: consignor_settlement consignor_settlement_consignor_party_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.consignor_settlement
    ADD CONSTRAINT consignor_settlement_consignor_party_id_fkey FOREIGN KEY (consignor_party_id) REFERENCES tenant_demo.party(id) ON DELETE RESTRICT;


--
-- Name: consignor_settlement consignor_settlement_journal_entry_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.consignor_settlement
    ADD CONSTRAINT consignor_settlement_journal_entry_id_fkey FOREIGN KEY (journal_entry_id) REFERENCES tenant_demo.journal_entry(id) ON DELETE RESTRICT;


--
-- Name: delinquency delinquency_lease_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.delinquency
    ADD CONSTRAINT delinquency_lease_id_fkey FOREIGN KEY (lease_id) REFERENCES tenant_demo.lease(id) ON DELETE RESTRICT;


--
-- Name: exchange_rate exchange_rate_from_currency_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.exchange_rate
    ADD CONSTRAINT exchange_rate_from_currency_fkey FOREIGN KEY (from_currency) REFERENCES kernel.currency(code);


--
-- Name: exchange_rate exchange_rate_to_currency_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.exchange_rate
    ADD CONSTRAINT exchange_rate_to_currency_fkey FOREIGN KEY (to_currency) REFERENCES kernel.currency(code);


--
-- Name: floor floor_location_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.floor
    ADD CONSTRAINT floor_location_id_fkey FOREIGN KEY (location_id) REFERENCES tenant_demo.location(id) ON DELETE RESTRICT;


--
-- Name: item_price_change item_price_change_item_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.item_price_change
    ADD CONSTRAINT item_price_change_item_id_fkey FOREIGN KEY (item_id) REFERENCES tenant_demo.consignment_item(id) ON DELETE CASCADE;


--
-- Name: journal_entry journal_entry_reversal_of_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.journal_entry
    ADD CONSTRAINT journal_entry_reversal_of_id_fkey FOREIGN KEY (reversal_of_id) REFERENCES tenant_demo.journal_entry(id) ON DELETE RESTRICT;


--
-- Name: journal_line journal_line_account_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.journal_line
    ADD CONSTRAINT journal_line_account_id_fkey FOREIGN KEY (account_id) REFERENCES tenant_demo.account(id) ON DELETE RESTRICT;


--
-- Name: journal_line journal_line_journal_entry_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.journal_line
    ADD CONSTRAINT journal_line_journal_entry_id_fkey FOREIGN KEY (journal_entry_id) REFERENCES tenant_demo.journal_entry(id) ON DELETE RESTRICT;


--
-- Name: journal_line journal_line_party_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.journal_line
    ADD CONSTRAINT journal_line_party_id_fkey FOREIGN KEY (party_id) REFERENCES tenant_demo.party(id) ON DELETE RESTRICT;


--
-- Name: journal_line journal_line_subledger_type_code_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.journal_line
    ADD CONSTRAINT journal_line_subledger_type_code_fkey FOREIGN KEY (subledger_type_code) REFERENCES kernel.subledger_type(code);


--
-- Name: lease_deposit lease_deposit_journal_entry_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.lease_deposit
    ADD CONSTRAINT lease_deposit_journal_entry_id_fkey FOREIGN KEY (journal_entry_id) REFERENCES tenant_demo.journal_entry(id) ON DELETE RESTRICT;


--
-- Name: lease_deposit lease_deposit_lease_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.lease_deposit
    ADD CONSTRAINT lease_deposit_lease_id_fkey FOREIGN KEY (lease_id) REFERENCES tenant_demo.lease(id) ON DELETE RESTRICT;


--
-- Name: lease lease_lessee_party_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.lease
    ADD CONSTRAINT lease_lessee_party_id_fkey FOREIGN KEY (lessee_party_id) REFERENCES tenant_demo.party(id) ON DELETE RESTRICT;


--
-- Name: lease lease_location_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.lease
    ADD CONSTRAINT lease_location_id_fkey FOREIGN KEY (location_id) REFERENCES tenant_demo.location(id) ON DELETE RESTRICT;


--
-- Name: lease_space lease_space_lease_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.lease_space
    ADD CONSTRAINT lease_space_lease_id_fkey FOREIGN KEY (lease_id) REFERENCES tenant_demo.lease(id) ON DELETE RESTRICT;


--
-- Name: lease_space lease_space_space_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.lease_space
    ADD CONSTRAINT lease_space_space_id_fkey FOREIGN KEY (space_id) REFERENCES tenant_demo.space(id) ON DELETE RESTRICT;


--
-- Name: merchant_settlement merchant_settlement_journal_entry_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.merchant_settlement
    ADD CONSTRAINT merchant_settlement_journal_entry_id_fkey FOREIGN KEY (journal_entry_id) REFERENCES tenant_demo.journal_entry(id) ON DELETE RESTRICT;


--
-- Name: open_item open_item_journal_entry_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.open_item
    ADD CONSTRAINT open_item_journal_entry_id_fkey FOREIGN KEY (journal_entry_id) REFERENCES tenant_demo.journal_entry(id) ON DELETE RESTRICT;


--
-- Name: open_item open_item_party_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.open_item
    ADD CONSTRAINT open_item_party_id_fkey FOREIGN KEY (party_id) REFERENCES tenant_demo.party(id) ON DELETE RESTRICT;


--
-- Name: open_item open_item_subledger_type_code_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.open_item
    ADD CONSTRAINT open_item_subledger_type_code_fkey FOREIGN KEY (subledger_type_code) REFERENCES kernel.subledger_type(code);


--
-- Name: organization organization_party_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.organization
    ADD CONSTRAINT organization_party_id_fkey FOREIGN KEY (party_id) REFERENCES tenant_demo.party(id) ON DELETE CASCADE;


--
-- Name: party_contact_mechanism party_contact_mechanism_mechanism_type_code_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.party_contact_mechanism
    ADD CONSTRAINT party_contact_mechanism_mechanism_type_code_fkey FOREIGN KEY (mechanism_type_code) REFERENCES kernel.contact_mechanism_type(code);


--
-- Name: party_contact_mechanism party_contact_mechanism_party_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.party_contact_mechanism
    ADD CONSTRAINT party_contact_mechanism_party_id_fkey FOREIGN KEY (party_id) REFERENCES tenant_demo.party(id) ON DELETE CASCADE;


--
-- Name: party_identifier party_identifier_identifier_type_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.party_identifier
    ADD CONSTRAINT party_identifier_identifier_type_fkey FOREIGN KEY (identifier_type) REFERENCES kernel.identifier_type(code);


--
-- Name: party_identifier party_identifier_party_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.party_identifier
    ADD CONSTRAINT party_identifier_party_id_fkey FOREIGN KEY (party_id) REFERENCES tenant_demo.party(id) ON DELETE RESTRICT;


--
-- Name: party_relationship party_relationship_from_party_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.party_relationship
    ADD CONSTRAINT party_relationship_from_party_id_fkey FOREIGN KEY (from_party_id) REFERENCES tenant_demo.party(id) ON DELETE RESTRICT;


--
-- Name: party_relationship party_relationship_relationship_type_code_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.party_relationship
    ADD CONSTRAINT party_relationship_relationship_type_code_fkey FOREIGN KEY (relationship_type_code) REFERENCES kernel.party_relationship_type(code);


--
-- Name: party_relationship party_relationship_to_party_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.party_relationship
    ADD CONSTRAINT party_relationship_to_party_id_fkey FOREIGN KEY (to_party_id) REFERENCES tenant_demo.party(id) ON DELETE RESTRICT;


--
-- Name: party_role party_role_party_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.party_role
    ADD CONSTRAINT party_role_party_id_fkey FOREIGN KEY (party_id) REFERENCES tenant_demo.party(id) ON DELETE RESTRICT;


--
-- Name: party_role party_role_role_type_code_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.party_role
    ADD CONSTRAINT party_role_role_type_code_fkey FOREIGN KEY (role_type_code) REFERENCES kernel.party_role_type(code);


--
-- Name: payment_application payment_application_journal_entry_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.payment_application
    ADD CONSTRAINT payment_application_journal_entry_id_fkey FOREIGN KEY (journal_entry_id) REFERENCES tenant_demo.journal_entry(id) ON DELETE RESTRICT;


--
-- Name: payment_application payment_application_open_item_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.payment_application
    ADD CONSTRAINT payment_application_open_item_id_fkey FOREIGN KEY (open_item_id) REFERENCES tenant_demo.open_item(id) ON DELETE RESTRICT;


--
-- Name: payment payment_journal_entry_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.payment
    ADD CONSTRAINT payment_journal_entry_id_fkey FOREIGN KEY (journal_entry_id) REFERENCES tenant_demo.journal_entry(id) ON DELETE RESTRICT;


--
-- Name: payment payment_sale_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.payment
    ADD CONSTRAINT payment_sale_id_fkey FOREIGN KEY (sale_id) REFERENCES tenant_demo.sale(id) ON DELETE RESTRICT;


--
-- Name: payment_tender payment_tender_party_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.payment_tender
    ADD CONSTRAINT payment_tender_party_id_fkey FOREIGN KEY (party_id) REFERENCES tenant_demo.party(id) ON DELETE RESTRICT;


--
-- Name: payment_tender payment_tender_payment_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.payment_tender
    ADD CONSTRAINT payment_tender_payment_id_fkey FOREIGN KEY (payment_id) REFERENCES tenant_demo.payment(id) ON DELETE RESTRICT;


--
-- Name: payment_tender payment_tender_tender_type_code_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.payment_tender
    ADD CONSTRAINT payment_tender_tender_type_code_fkey FOREIGN KEY (tender_type_code) REFERENCES tenant_demo.tender_type(code) ON DELETE RESTRICT;


--
-- Name: person person_party_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.person
    ADD CONSTRAINT person_party_id_fkey FOREIGN KEY (party_id) REFERENCES tenant_demo.party(id) ON DELETE CASCADE;


--
-- Name: postal_address postal_address_party_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.postal_address
    ADD CONSTRAINT postal_address_party_id_fkey FOREIGN KEY (party_id) REFERENCES tenant_demo.party(id) ON DELETE CASCADE;


--
-- Name: posting_map posting_map_account_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.posting_map
    ADD CONSTRAINT posting_map_account_id_fkey FOREIGN KEY (account_id) REFERENCES tenant_demo.account(id) ON DELETE RESTRICT;


--
-- Name: posting_map posting_map_role_code_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.posting_map
    ADD CONSTRAINT posting_map_role_code_fkey FOREIGN KEY (role_code) REFERENCES kernel.posting_role(code);


--
-- Name: register register_location_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.register
    ADD CONSTRAINT register_location_id_fkey FOREIGN KEY (location_id) REFERENCES tenant_demo.location(id) ON DELETE RESTRICT;


--
-- Name: rent_component rent_component_component_type_code_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.rent_component
    ADD CONSTRAINT rent_component_component_type_code_fkey FOREIGN KEY (component_type_code) REFERENCES kernel.rent_component_type(code);


--
-- Name: rent_component rent_component_lease_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.rent_component
    ADD CONSTRAINT rent_component_lease_id_fkey FOREIGN KEY (lease_id) REFERENCES tenant_demo.lease(id) ON DELETE RESTRICT;


--
-- Name: sale sale_customer_party_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.sale
    ADD CONSTRAINT sale_customer_party_id_fkey FOREIGN KEY (customer_party_id) REFERENCES tenant_demo.party(id) ON DELETE RESTRICT;


--
-- Name: sale sale_journal_entry_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.sale
    ADD CONSTRAINT sale_journal_entry_id_fkey FOREIGN KEY (journal_entry_id) REFERENCES tenant_demo.journal_entry(id) ON DELETE RESTRICT;


--
-- Name: sale_line sale_line_consignment_item_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.sale_line
    ADD CONSTRAINT sale_line_consignment_item_id_fkey FOREIGN KEY (consignment_item_id) REFERENCES tenant_demo.consignment_item(id) ON DELETE RESTRICT;


--
-- Name: sale_line sale_line_consignor_party_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.sale_line
    ADD CONSTRAINT sale_line_consignor_party_id_fkey FOREIGN KEY (consignor_party_id) REFERENCES tenant_demo.party(id) ON DELETE RESTRICT;


--
-- Name: sale_line sale_line_sale_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.sale_line
    ADD CONSTRAINT sale_line_sale_id_fkey FOREIGN KEY (sale_id) REFERENCES tenant_demo.sale(id) ON DELETE RESTRICT;


--
-- Name: sale_line_tax sale_line_tax_jurisdiction_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.sale_line_tax
    ADD CONSTRAINT sale_line_tax_jurisdiction_id_fkey FOREIGN KEY (jurisdiction_id) REFERENCES tenant_demo.tax_jurisdiction(id) ON DELETE RESTRICT;


--
-- Name: sale_line_tax sale_line_tax_sale_line_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.sale_line_tax
    ADD CONSTRAINT sale_line_tax_sale_line_id_fkey FOREIGN KEY (sale_line_id) REFERENCES tenant_demo.sale_line(id) ON DELETE RESTRICT;


--
-- Name: sale_line sale_line_vendor_party_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.sale_line
    ADD CONSTRAINT sale_line_vendor_party_id_fkey FOREIGN KEY (vendor_party_id) REFERENCES tenant_demo.party(id) ON DELETE RESTRICT;


--
-- Name: sale sale_refunds_sale_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.sale
    ADD CONSTRAINT sale_refunds_sale_id_fkey FOREIGN KEY (refunds_sale_id) REFERENCES tenant_demo.sale(id) ON DELETE RESTRICT;


--
-- Name: sale sale_register_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.sale
    ADD CONSTRAINT sale_register_id_fkey FOREIGN KEY (register_id) REFERENCES tenant_demo.register(id) ON DELETE RESTRICT;


--
-- Name: sale sale_shift_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.sale
    ADD CONSTRAINT sale_shift_id_fkey FOREIGN KEY (shift_id) REFERENCES tenant_demo.shift(id) ON DELETE RESTRICT;


--
-- Name: settlement_line settlement_line_sale_line_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.settlement_line
    ADD CONSTRAINT settlement_line_sale_line_id_fkey FOREIGN KEY (sale_line_id) REFERENCES tenant_demo.consignment_sale_line(id) ON DELETE RESTRICT;


--
-- Name: settlement_line settlement_line_settlement_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.settlement_line
    ADD CONSTRAINT settlement_line_settlement_id_fkey FOREIGN KEY (settlement_id) REFERENCES tenant_demo.consignor_settlement(id) ON DELETE RESTRICT;


--
-- Name: shift shift_journal_entry_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.shift
    ADD CONSTRAINT shift_journal_entry_id_fkey FOREIGN KEY (journal_entry_id) REFERENCES tenant_demo.journal_entry(id) ON DELETE RESTRICT;


--
-- Name: shift shift_opened_by_party_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.shift
    ADD CONSTRAINT shift_opened_by_party_id_fkey FOREIGN KEY (opened_by_party_id) REFERENCES tenant_demo.party(id) ON DELETE RESTRICT;


--
-- Name: shift shift_register_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.shift
    ADD CONSTRAINT shift_register_id_fkey FOREIGN KEY (register_id) REFERENCES tenant_demo.register(id) ON DELETE RESTRICT;


--
-- Name: space_attribute space_attribute_space_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.space_attribute
    ADD CONSTRAINT space_attribute_space_id_fkey FOREIGN KEY (space_id) REFERENCES tenant_demo.space(id) ON DELETE CASCADE;


--
-- Name: space space_floor_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.space
    ADD CONSTRAINT space_floor_id_fkey FOREIGN KEY (floor_id) REFERENCES tenant_demo.floor(id) ON DELETE RESTRICT;


--
-- Name: space space_space_type_code_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.space
    ADD CONSTRAINT space_space_type_code_fkey FOREIGN KEY (space_type_code) REFERENCES kernel.space_type(code);


--
-- Name: tax_rate tax_rate_jurisdiction_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.tax_rate
    ADD CONSTRAINT tax_rate_jurisdiction_id_fkey FOREIGN KEY (jurisdiction_id) REFERENCES tenant_demo.tax_jurisdiction(id) ON DELETE RESTRICT;


--
-- Name: tenant_config tenant_config_functional_currency_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.tenant_config
    ADD CONSTRAINT tenant_config_functional_currency_fkey FOREIGN KEY (functional_currency) REFERENCES kernel.currency(code);


--
-- Name: tender_type tender_type_debit_role_code_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.tender_type
    ADD CONSTRAINT tender_type_debit_role_code_fkey FOREIGN KEY (debit_role_code) REFERENCES kernel.posting_role(code);


--
-- Name: tender_type tender_type_subledger_type_code_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.tender_type
    ADD CONSTRAINT tender_type_subledger_type_code_fkey FOREIGN KEY (subledger_type_code) REFERENCES kernel.subledger_type(code);


--
-- Name: waitlist waitlist_party_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.waitlist
    ADD CONSTRAINT waitlist_party_id_fkey FOREIGN KEY (party_id) REFERENCES tenant_demo.party(id) ON DELETE RESTRICT;


--
-- Name: waitlist waitlist_preferred_location_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.waitlist
    ADD CONSTRAINT waitlist_preferred_location_id_fkey FOREIGN KEY (preferred_location_id) REFERENCES tenant_demo.location(id) ON DELETE RESTRICT;


--
-- Name: waitlist waitlist_space_type_code_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.waitlist
    ADD CONSTRAINT waitlist_space_type_code_fkey FOREIGN KEY (space_type_code) REFERENCES kernel.space_type(code);


--
-- Name: account; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.account ENABLE ROW LEVEL SECURITY;

--
-- Name: audit_log; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.audit_log ENABLE ROW LEVEL SECURITY;

--
-- Name: commission_rule; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.commission_rule ENABLE ROW LEVEL SECURITY;

--
-- Name: consignment_item; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.consignment_item ENABLE ROW LEVEL SECURITY;

--
-- Name: consignment_sale; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.consignment_sale ENABLE ROW LEVEL SECURITY;

--
-- Name: consignment_sale_line; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.consignment_sale_line ENABLE ROW LEVEL SECURITY;

--
-- Name: consignor_agreement; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.consignor_agreement ENABLE ROW LEVEL SECURITY;

--
-- Name: consignor_payout; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.consignor_payout ENABLE ROW LEVEL SECURITY;

--
-- Name: consignor_settlement; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.consignor_settlement ENABLE ROW LEVEL SECURITY;

--
-- Name: delinquency; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.delinquency ENABLE ROW LEVEL SECURITY;

--
-- Name: exchange_rate; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.exchange_rate ENABLE ROW LEVEL SECURITY;

--
-- Name: fiscal_period; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.fiscal_period ENABLE ROW LEVEL SECURITY;

--
-- Name: floor; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.floor ENABLE ROW LEVEL SECURITY;

--
-- Name: item_price_change; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.item_price_change ENABLE ROW LEVEL SECURITY;

--
-- Name: lease; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.lease ENABLE ROW LEVEL SECURITY;

--
-- Name: lease_deposit; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.lease_deposit ENABLE ROW LEVEL SECURITY;

--
-- Name: lease_space; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.lease_space ENABLE ROW LEVEL SECURITY;

--
-- Name: location; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.location ENABLE ROW LEVEL SECURITY;

--
-- Name: merchant_settlement; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.merchant_settlement ENABLE ROW LEVEL SECURITY;

--
-- Name: open_item; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.open_item ENABLE ROW LEVEL SECURITY;

--
-- Name: organization; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.organization ENABLE ROW LEVEL SECURITY;

--
-- Name: party; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.party ENABLE ROW LEVEL SECURITY;

--
-- Name: party_contact_mechanism; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.party_contact_mechanism ENABLE ROW LEVEL SECURITY;

--
-- Name: party_identifier; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.party_identifier ENABLE ROW LEVEL SECURITY;

--
-- Name: party_relationship; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.party_relationship ENABLE ROW LEVEL SECURITY;

--
-- Name: party_role; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.party_role ENABLE ROW LEVEL SECURITY;

--
-- Name: payment; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.payment ENABLE ROW LEVEL SECURITY;

--
-- Name: payment_application; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.payment_application ENABLE ROW LEVEL SECURITY;

--
-- Name: payment_tender; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.payment_tender ENABLE ROW LEVEL SECURITY;

--
-- Name: person; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.person ENABLE ROW LEVEL SECURITY;

--
-- Name: postal_address; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.postal_address ENABLE ROW LEVEL SECURITY;

--
-- Name: posting_map; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.posting_map ENABLE ROW LEVEL SECURITY;

--
-- Name: register; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.register ENABLE ROW LEVEL SECURITY;

--
-- Name: rent_component; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.rent_component ENABLE ROW LEVEL SECURITY;

--
-- Name: sale; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.sale ENABLE ROW LEVEL SECURITY;

--
-- Name: sale_line; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.sale_line ENABLE ROW LEVEL SECURITY;

--
-- Name: sale_line_tax; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.sale_line_tax ENABLE ROW LEVEL SECURITY;

--
-- Name: settlement_line; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.settlement_line ENABLE ROW LEVEL SECURITY;

--
-- Name: shift; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.shift ENABLE ROW LEVEL SECURITY;

--
-- Name: space; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.space ENABLE ROW LEVEL SECURITY;

--
-- Name: space_attribute; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.space_attribute ENABLE ROW LEVEL SECURITY;

--
-- Name: tax_jurisdiction; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.tax_jurisdiction ENABLE ROW LEVEL SECURITY;

--
-- Name: tax_rate; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.tax_rate ENABLE ROW LEVEL SECURITY;

--
-- Name: tenant_config; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.tenant_config ENABLE ROW LEVEL SECURITY;

--
-- Name: account tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.account USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: audit_log tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.audit_log USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: commission_rule tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.commission_rule USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: consignment_item tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.consignment_item USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: consignment_sale tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.consignment_sale USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: consignment_sale_line tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.consignment_sale_line USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: consignor_agreement tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.consignor_agreement USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: consignor_payout tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.consignor_payout USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: consignor_settlement tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.consignor_settlement USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: delinquency tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.delinquency USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: exchange_rate tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.exchange_rate USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: fiscal_period tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.fiscal_period USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: floor tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.floor USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: item_price_change tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.item_price_change USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: lease tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.lease USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: lease_deposit tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.lease_deposit USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: lease_space tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.lease_space USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: location tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.location USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: merchant_settlement tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.merchant_settlement USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: open_item tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.open_item USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: organization tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.organization USING ((EXISTS ( SELECT 1
   FROM tenant_demo.party p
  WHERE ((p.id = organization.party_id) AND (p.tenant_id = kernel.current_tenant()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM tenant_demo.party p
  WHERE ((p.id = organization.party_id) AND (p.tenant_id = kernel.current_tenant())))));


--
-- Name: party tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.party USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: party_contact_mechanism tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.party_contact_mechanism USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: party_identifier tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.party_identifier USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: party_relationship tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.party_relationship USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: party_role tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.party_role USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: payment tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.payment USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: payment_application tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.payment_application USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: payment_tender tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.payment_tender USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: person tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.person USING ((EXISTS ( SELECT 1
   FROM tenant_demo.party p
  WHERE ((p.id = person.party_id) AND (p.tenant_id = kernel.current_tenant()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM tenant_demo.party p
  WHERE ((p.id = person.party_id) AND (p.tenant_id = kernel.current_tenant())))));


--
-- Name: postal_address tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.postal_address USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: posting_map tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.posting_map USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: register tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.register USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: rent_component tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.rent_component USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: sale tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.sale USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: sale_line tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.sale_line USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: sale_line_tax tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.sale_line_tax USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: settlement_line tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.settlement_line USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: shift tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.shift USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: space tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.space USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: space_attribute tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.space_attribute USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: tax_jurisdiction tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.tax_jurisdiction USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: tax_rate tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.tax_rate USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: tenant_config tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.tenant_config USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: tender_type tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.tender_type USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: waitlist tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.waitlist USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: tender_type; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.tender_type ENABLE ROW LEVEL SECURITY;

--
-- Name: waitlist; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.waitlist ENABLE ROW LEVEL SECURITY;

--
-- Name: SCHEMA kernel; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA kernel TO ninja_app;
GRANT USAGE ON SCHEMA kernel TO ninja_migrator;


--
-- Name: SCHEMA tenant_demo; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA tenant_demo TO ninja_app;
GRANT USAGE ON SCHEMA tenant_demo TO ninja_migrator;


--
-- Name: TABLE account_type; Type: ACL; Schema: kernel; Owner: -
--

GRANT SELECT ON TABLE kernel.account_type TO ninja_app;
GRANT SELECT ON TABLE kernel.account_type TO ninja_migrator;


--
-- Name: TABLE contact_mechanism_type; Type: ACL; Schema: kernel; Owner: -
--

GRANT SELECT ON TABLE kernel.contact_mechanism_type TO ninja_app;
GRANT SELECT ON TABLE kernel.contact_mechanism_type TO ninja_migrator;


--
-- Name: TABLE currency; Type: ACL; Schema: kernel; Owner: -
--

GRANT SELECT ON TABLE kernel.currency TO ninja_app;
GRANT SELECT ON TABLE kernel.currency TO ninja_migrator;


--
-- Name: TABLE data_classification; Type: ACL; Schema: kernel; Owner: -
--

GRANT SELECT ON TABLE kernel.data_classification TO ninja_app;
GRANT SELECT ON TABLE kernel.data_classification TO ninja_migrator;


--
-- Name: TABLE identifier_type; Type: ACL; Schema: kernel; Owner: -
--

GRANT SELECT ON TABLE kernel.identifier_type TO ninja_app;
GRANT SELECT ON TABLE kernel.identifier_type TO ninja_migrator;


--
-- Name: TABLE migration; Type: ACL; Schema: kernel; Owner: -
--

GRANT SELECT ON TABLE kernel.migration TO ninja_app;
GRANT SELECT ON TABLE kernel.migration TO ninja_migrator;


--
-- Name: TABLE party_relationship_type; Type: ACL; Schema: kernel; Owner: -
--

GRANT SELECT ON TABLE kernel.party_relationship_type TO ninja_app;
GRANT SELECT ON TABLE kernel.party_relationship_type TO ninja_migrator;


--
-- Name: TABLE party_role_type; Type: ACL; Schema: kernel; Owner: -
--

GRANT SELECT ON TABLE kernel.party_role_type TO ninja_app;
GRANT SELECT ON TABLE kernel.party_role_type TO ninja_migrator;


--
-- Name: TABLE posting_role; Type: ACL; Schema: kernel; Owner: -
--

GRANT SELECT ON TABLE kernel.posting_role TO ninja_app;
GRANT SELECT ON TABLE kernel.posting_role TO ninja_migrator;


--
-- Name: TABLE rent_component_type; Type: ACL; Schema: kernel; Owner: -
--

GRANT SELECT ON TABLE kernel.rent_component_type TO ninja_app;
GRANT SELECT ON TABLE kernel.rent_component_type TO ninja_migrator;


--
-- Name: TABLE space_type; Type: ACL; Schema: kernel; Owner: -
--

GRANT SELECT ON TABLE kernel.space_type TO ninja_app;
GRANT SELECT ON TABLE kernel.space_type TO ninja_migrator;


--
-- Name: TABLE subledger_type; Type: ACL; Schema: kernel; Owner: -
--

GRANT SELECT ON TABLE kernel.subledger_type TO ninja_app;
GRANT SELECT ON TABLE kernel.subledger_type TO ninja_migrator;


--
-- Name: TABLE account; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.account TO ninja_app;
GRANT ALL ON TABLE tenant_demo.account TO ninja_migrator;


--
-- Name: TABLE audit_log; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.audit_log TO ninja_app;
GRANT ALL ON TABLE tenant_demo.audit_log TO ninja_migrator;


--
-- Name: SEQUENCE audit_log_id_seq; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE tenant_demo.audit_log_id_seq TO ninja_app;
GRANT SELECT,USAGE ON SEQUENCE tenant_demo.audit_log_id_seq TO ninja_migrator;


--
-- Name: TABLE commission_rule; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.commission_rule TO ninja_app;
GRANT ALL ON TABLE tenant_demo.commission_rule TO ninja_migrator;


--
-- Name: TABLE consignment_item; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.consignment_item TO ninja_app;
GRANT ALL ON TABLE tenant_demo.consignment_item TO ninja_migrator;


--
-- Name: SEQUENCE consignment_item_item_no_seq; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE tenant_demo.consignment_item_item_no_seq TO ninja_app;
GRANT SELECT,USAGE ON SEQUENCE tenant_demo.consignment_item_item_no_seq TO ninja_migrator;


--
-- Name: TABLE consignment_sale; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.consignment_sale TO ninja_app;
GRANT ALL ON TABLE tenant_demo.consignment_sale TO ninja_migrator;


--
-- Name: TABLE consignment_sale_line; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.consignment_sale_line TO ninja_app;
GRANT ALL ON TABLE tenant_demo.consignment_sale_line TO ninja_migrator;


--
-- Name: SEQUENCE consignment_sale_sale_no_seq; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE tenant_demo.consignment_sale_sale_no_seq TO ninja_app;
GRANT SELECT,USAGE ON SEQUENCE tenant_demo.consignment_sale_sale_no_seq TO ninja_migrator;


--
-- Name: TABLE consignor_agreement; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.consignor_agreement TO ninja_app;
GRANT ALL ON TABLE tenant_demo.consignor_agreement TO ninja_migrator;


--
-- Name: SEQUENCE consignor_agreement_agreement_no_seq; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE tenant_demo.consignor_agreement_agreement_no_seq TO ninja_app;
GRANT SELECT,USAGE ON SEQUENCE tenant_demo.consignor_agreement_agreement_no_seq TO ninja_migrator;


--
-- Name: TABLE consignor_payout; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.consignor_payout TO ninja_app;
GRANT ALL ON TABLE tenant_demo.consignor_payout TO ninja_migrator;


--
-- Name: TABLE consignor_settlement; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.consignor_settlement TO ninja_app;
GRANT ALL ON TABLE tenant_demo.consignor_settlement TO ninja_migrator;


--
-- Name: SEQUENCE consignor_settlement_settlement_no_seq; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE tenant_demo.consignor_settlement_settlement_no_seq TO ninja_app;
GRANT SELECT,USAGE ON SEQUENCE tenant_demo.consignor_settlement_settlement_no_seq TO ninja_migrator;


--
-- Name: TABLE delinquency; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.delinquency TO ninja_app;
GRANT ALL ON TABLE tenant_demo.delinquency TO ninja_migrator;


--
-- Name: TABLE exchange_rate; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.exchange_rate TO ninja_app;
GRANT ALL ON TABLE tenant_demo.exchange_rate TO ninja_migrator;


--
-- Name: TABLE fiscal_period; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.fiscal_period TO ninja_app;
GRANT ALL ON TABLE tenant_demo.fiscal_period TO ninja_migrator;


--
-- Name: TABLE floor; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.floor TO ninja_app;
GRANT ALL ON TABLE tenant_demo.floor TO ninja_migrator;


--
-- Name: TABLE item_price_change; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.item_price_change TO ninja_app;
GRANT ALL ON TABLE tenant_demo.item_price_change TO ninja_migrator;


--
-- Name: TABLE journal_entry; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.journal_entry TO ninja_app;
GRANT ALL ON TABLE tenant_demo.journal_entry TO ninja_migrator;


--
-- Name: SEQUENCE journal_entry_entry_no_seq; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE tenant_demo.journal_entry_entry_no_seq TO ninja_app;
GRANT SELECT,USAGE ON SEQUENCE tenant_demo.journal_entry_entry_no_seq TO ninja_migrator;


--
-- Name: TABLE journal_entry_status; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.journal_entry_status TO ninja_app;
GRANT ALL ON TABLE tenant_demo.journal_entry_status TO ninja_migrator;


--
-- Name: TABLE journal_line; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.journal_line TO ninja_app;
GRANT ALL ON TABLE tenant_demo.journal_line TO ninja_migrator;


--
-- Name: SEQUENCE journal_line_id_seq; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE tenant_demo.journal_line_id_seq TO ninja_app;
GRANT SELECT,USAGE ON SEQUENCE tenant_demo.journal_line_id_seq TO ninja_migrator;


--
-- Name: TABLE lease; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.lease TO ninja_app;
GRANT ALL ON TABLE tenant_demo.lease TO ninja_migrator;


--
-- Name: TABLE lease_deposit; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.lease_deposit TO ninja_app;
GRANT ALL ON TABLE tenant_demo.lease_deposit TO ninja_migrator;


--
-- Name: SEQUENCE lease_lease_no_seq; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE tenant_demo.lease_lease_no_seq TO ninja_app;
GRANT SELECT,USAGE ON SEQUENCE tenant_demo.lease_lease_no_seq TO ninja_migrator;


--
-- Name: TABLE lease_space; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.lease_space TO ninja_app;
GRANT ALL ON TABLE tenant_demo.lease_space TO ninja_migrator;


--
-- Name: TABLE location; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.location TO ninja_app;
GRANT ALL ON TABLE tenant_demo.location TO ninja_migrator;


--
-- Name: TABLE merchant_settlement; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.merchant_settlement TO ninja_app;
GRANT ALL ON TABLE tenant_demo.merchant_settlement TO ninja_migrator;


--
-- Name: SEQUENCE merchant_settlement_settlement_no_seq; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE tenant_demo.merchant_settlement_settlement_no_seq TO ninja_app;
GRANT SELECT,USAGE ON SEQUENCE tenant_demo.merchant_settlement_settlement_no_seq TO ninja_migrator;


--
-- Name: TABLE open_item; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.open_item TO ninja_app;
GRANT ALL ON TABLE tenant_demo.open_item TO ninja_migrator;


--
-- Name: TABLE organization; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.organization TO ninja_app;
GRANT ALL ON TABLE tenant_demo.organization TO ninja_migrator;


--
-- Name: TABLE party; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.party TO ninja_app;
GRANT ALL ON TABLE tenant_demo.party TO ninja_migrator;


--
-- Name: TABLE party_contact_mechanism; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.party_contact_mechanism TO ninja_app;
GRANT ALL ON TABLE tenant_demo.party_contact_mechanism TO ninja_migrator;


--
-- Name: TABLE party_identifier; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.party_identifier TO ninja_app;
GRANT ALL ON TABLE tenant_demo.party_identifier TO ninja_migrator;


--
-- Name: TABLE party_relationship; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.party_relationship TO ninja_app;
GRANT ALL ON TABLE tenant_demo.party_relationship TO ninja_migrator;


--
-- Name: TABLE party_role; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.party_role TO ninja_app;
GRANT ALL ON TABLE tenant_demo.party_role TO ninja_migrator;


--
-- Name: TABLE payment; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.payment TO ninja_app;
GRANT ALL ON TABLE tenant_demo.payment TO ninja_migrator;


--
-- Name: TABLE payment_application; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.payment_application TO ninja_app;
GRANT ALL ON TABLE tenant_demo.payment_application TO ninja_migrator;


--
-- Name: SEQUENCE payment_payment_no_seq; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE tenant_demo.payment_payment_no_seq TO ninja_app;
GRANT SELECT,USAGE ON SEQUENCE tenant_demo.payment_payment_no_seq TO ninja_migrator;


--
-- Name: TABLE payment_tender; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.payment_tender TO ninja_app;
GRANT ALL ON TABLE tenant_demo.payment_tender TO ninja_migrator;


--
-- Name: TABLE person; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.person TO ninja_app;
GRANT ALL ON TABLE tenant_demo.person TO ninja_migrator;


--
-- Name: TABLE postal_address; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.postal_address TO ninja_app;
GRANT ALL ON TABLE tenant_demo.postal_address TO ninja_migrator;


--
-- Name: TABLE posting_map; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.posting_map TO ninja_app;
GRANT ALL ON TABLE tenant_demo.posting_map TO ninja_migrator;


--
-- Name: TABLE register; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.register TO ninja_app;
GRANT ALL ON TABLE tenant_demo.register TO ninja_migrator;


--
-- Name: TABLE rent_component; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.rent_component TO ninja_app;
GRANT ALL ON TABLE tenant_demo.rent_component TO ninja_migrator;


--
-- Name: TABLE sale; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.sale TO ninja_app;
GRANT ALL ON TABLE tenant_demo.sale TO ninja_migrator;


--
-- Name: TABLE sale_line; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.sale_line TO ninja_app;
GRANT ALL ON TABLE tenant_demo.sale_line TO ninja_migrator;


--
-- Name: TABLE sale_line_tax; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.sale_line_tax TO ninja_app;
GRANT ALL ON TABLE tenant_demo.sale_line_tax TO ninja_migrator;


--
-- Name: SEQUENCE sale_sale_no_seq; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE tenant_demo.sale_sale_no_seq TO ninja_app;
GRANT SELECT,USAGE ON SEQUENCE tenant_demo.sale_sale_no_seq TO ninja_migrator;


--
-- Name: TABLE settlement_line; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.settlement_line TO ninja_app;
GRANT ALL ON TABLE tenant_demo.settlement_line TO ninja_migrator;


--
-- Name: TABLE shift; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.shift TO ninja_app;
GRANT ALL ON TABLE tenant_demo.shift TO ninja_migrator;


--
-- Name: SEQUENCE shift_shift_no_seq; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE tenant_demo.shift_shift_no_seq TO ninja_app;
GRANT SELECT,USAGE ON SEQUENCE tenant_demo.shift_shift_no_seq TO ninja_migrator;


--
-- Name: TABLE space; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.space TO ninja_app;
GRANT ALL ON TABLE tenant_demo.space TO ninja_migrator;


--
-- Name: TABLE space_attribute; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.space_attribute TO ninja_app;
GRANT ALL ON TABLE tenant_demo.space_attribute TO ninja_migrator;


--
-- Name: TABLE tax_jurisdiction; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.tax_jurisdiction TO ninja_app;
GRANT ALL ON TABLE tenant_demo.tax_jurisdiction TO ninja_migrator;


--
-- Name: TABLE tax_rate; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.tax_rate TO ninja_app;
GRANT ALL ON TABLE tenant_demo.tax_rate TO ninja_migrator;


--
-- Name: TABLE tenant_config; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.tenant_config TO ninja_app;
GRANT ALL ON TABLE tenant_demo.tenant_config TO ninja_migrator;


--
-- Name: TABLE tender_type; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.tender_type TO ninja_app;
GRANT ALL ON TABLE tenant_demo.tender_type TO ninja_migrator;


--
-- Name: TABLE v_active_lease; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.v_active_lease TO ninja_app;
GRANT ALL ON TABLE tenant_demo.v_active_lease TO ninja_migrator;


--
-- Name: TABLE v_open_item; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.v_open_item TO ninja_app;
GRANT ALL ON TABLE tenant_demo.v_open_item TO ninja_migrator;


--
-- Name: TABLE v_aging; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.v_aging TO ninja_app;
GRANT ALL ON TABLE tenant_demo.v_aging TO ninja_migrator;


--
-- Name: TABLE v_subledger; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.v_subledger TO ninja_app;
GRANT ALL ON TABLE tenant_demo.v_subledger TO ninja_migrator;


--
-- Name: TABLE v_ap; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.v_ap TO ninja_app;
GRANT ALL ON TABLE tenant_demo.v_ap TO ninja_migrator;


--
-- Name: TABLE v_ar; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.v_ar TO ninja_app;
GRANT ALL ON TABLE tenant_demo.v_ar TO ninja_migrator;


--
-- Name: TABLE v_consignor_payable; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.v_consignor_payable TO ninja_app;
GRANT ALL ON TABLE tenant_demo.v_consignor_payable TO ninja_migrator;


--
-- Name: TABLE v_customer_credit; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.v_customer_credit TO ninja_app;
GRANT ALL ON TABLE tenant_demo.v_customer_credit TO ninja_migrator;


--
-- Name: TABLE v_gift_certificate; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.v_gift_certificate TO ninja_app;
GRANT ALL ON TABLE tenant_demo.v_gift_certificate TO ninja_migrator;


--
-- Name: TABLE v_party_identifier_masked; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.v_party_identifier_masked TO ninja_app;
GRANT ALL ON TABLE tenant_demo.v_party_identifier_masked TO ninja_migrator;


--
-- Name: TABLE v_vendor_balance_realtime; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.v_vendor_balance_realtime TO ninja_app;
GRANT ALL ON TABLE tenant_demo.v_vendor_balance_realtime TO ninja_migrator;


--
-- Name: TABLE v_vendor_payable; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.v_vendor_payable TO ninja_app;
GRANT ALL ON TABLE tenant_demo.v_vendor_payable TO ninja_migrator;


--
-- Name: TABLE v_vendor_payout_available; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.v_vendor_payout_available TO ninja_app;
GRANT ALL ON TABLE tenant_demo.v_vendor_payout_available TO ninja_migrator;


--
-- Name: TABLE v_vendor_sales_realtime; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.v_vendor_sales_realtime TO ninja_app;
GRANT ALL ON TABLE tenant_demo.v_vendor_sales_realtime TO ninja_migrator;


--
-- Name: TABLE v_vendor_sales_today; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.v_vendor_sales_today TO ninja_app;
GRANT ALL ON TABLE tenant_demo.v_vendor_sales_today TO ninja_migrator;


--
-- Name: TABLE v_vendor_statement; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.v_vendor_statement TO ninja_app;
GRANT ALL ON TABLE tenant_demo.v_vendor_statement TO ninja_migrator;


--
-- Name: TABLE waitlist; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.waitlist TO ninja_app;
GRANT ALL ON TABLE tenant_demo.waitlist TO ninja_migrator;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: kernel; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA kernel GRANT SELECT ON TABLES TO ninja_app;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA kernel GRANT SELECT ON TABLES TO ninja_migrator;


--
-- PostgreSQL database dump complete
--

\unrestrict Lxr0Lt8efdYD3w0PRxWR7usntf1EZMMzVuAX2QgzxUqBv4bBwDY3rndyGSmPJFx

