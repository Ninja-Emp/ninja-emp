--
-- PostgreSQL database dump
--

\restrict 3tOsByOaSrMH7TBJh8VKV52RlbIfhMNhB73alyxgu9RhhcPzBfmPBfjoTZCBghz

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
-- Name: adjust_inventory(uuid, numeric, date, text, text); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.adjust_inventory(p_item_id uuid, p_quantity_delta numeric, p_entry_date date, p_memo text DEFAULT NULL::text, p_idempotency_key text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_item    inventory_item;
  v_value   numeric;
  v_new_qty numeric;
  v_entry   uuid;
  v_key     text;
BEGIN
  IF p_quantity_delta = 0 THEN
    RAISE EXCEPTION 'Adjustment quantity cannot be zero' USING ERRCODE='23514';
  END IF;

  SELECT * INTO v_item FROM inventory_item WHERE id = p_item_id FOR UPDATE;
  IF v_item.id IS NULL THEN
    RAISE EXCEPTION 'No inventory item %', p_item_id USING ERRCODE='23514';
  END IF;

  v_new_qty := v_item.on_hand + p_quantity_delta;
  IF v_new_qty < 0 THEN
    RAISE EXCEPTION 'Adjustment would drive % negative (% on hand, delta %)',
      v_item.sku, v_item.on_hand, p_quantity_delta USING ERRCODE='23514';
  END IF;

  v_key := COALESCE(p_idempotency_key,
                    'inv_adj:' || p_item_id::text || ':' || p_entry_date::text || ':' || p_quantity_delta::text);
  SELECT id INTO v_entry FROM journal_entry
    WHERE idempotency_key = v_key AND tenant_id = kernel.current_tenant();
  IF v_entry IS NOT NULL THEN RETURN v_entry; END IF;

  v_value := round(abs(p_quantity_delta) * v_item.avg_cost, 4);

  IF v_value > 0 THEN
    IF p_quantity_delta < 0 THEN
      -- Shrink: expense the loss.
      v_entry := post_journal_entry(
        p_entry_date, COALESCE(p_memo,'Inventory shrink ' || v_item.sku),
        'inventory_adjustment', p_item_id::text, v_key,
        jsonb_build_array(
          jsonb_build_object('account_id', posting_account('inventory_adjustment'),'debit', v_value),
          jsonb_build_object('account_id', posting_account('inventory'),           'credit',v_value)));
    ELSE
      -- Found stock: reduce the expense.
      v_entry := post_journal_entry(
        p_entry_date, COALESCE(p_memo,'Inventory found ' || v_item.sku),
        'inventory_adjustment', p_item_id::text, v_key,
        jsonb_build_array(
          jsonb_build_object('account_id', posting_account('inventory'),           'debit', v_value),
          jsonb_build_object('account_id', posting_account('inventory_adjustment'),'credit',v_value)));
    END IF;
  END IF;

  UPDATE inventory_item SET on_hand = v_new_qty WHERE id = p_item_id;

  INSERT INTO inventory_movement (
    item_id, movement_kind, movement_date, quantity, unit_cost, extended_cost,
    currency, on_hand_after, avg_cost_after, source, source_ref, journal_entry_id, memo)
  VALUES (p_item_id,'adjustment',p_entry_date,p_quantity_delta,v_item.avg_cost,
          round(p_quantity_delta * v_item.avg_cost,4),
          v_item.currency,v_new_qty,v_item.avg_cost,'inventory_adjustment',p_item_id::text,v_entry,p_memo);

  RETURN v_entry;
END; $$;


--
-- Name: FUNCTION adjust_inventory(p_item_id uuid, p_quantity_delta numeric, p_entry_date date, p_memo text, p_idempotency_key text); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.adjust_inventory(p_item_id uuid, p_quantity_delta numeric, p_entry_date date, p_memo text, p_idempotency_key text) IS 'Shrink/found-stock adjustment at average cost, expensed to inventory_adjustment.';


--
-- Name: apply_markdown(uuid, kernel.money_amount, text, text, kernel.percent_rate, date, text); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.apply_markdown(p_consignment_item_id uuid, p_new_price kernel.money_amount, p_reason_code text, p_absorbed_by text DEFAULT NULL::text, p_share_store_rate kernel.percent_rate DEFAULT NULL::numeric, p_effective_from date DEFAULT CURRENT_DATE, p_note text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_item     record;
  v_reason   record;
  v_absorb   text;
  v_share    kernel.percent_rate;
  v_id       uuid;
BEGIN
  SELECT * INTO v_item FROM consignment_item WHERE id = p_consignment_item_id;
  IF v_item IS NULL THEN
    RAISE EXCEPTION 'Consignment item % not found', p_consignment_item_id USING ERRCODE='23503';
  END IF;
  IF v_item.status NOT IN ('received','available') THEN
    RAISE EXCEPTION 'Item % is % and cannot be marked down', p_consignment_item_id, v_item.status
      USING ERRCODE='23514';
  END IF;

  SELECT * INTO v_reason FROM markdown_reason
   WHERE code = p_reason_code AND tenant_id = kernel.current_tenant();
  IF v_reason IS NULL THEN
    RAISE EXCEPTION 'Unknown markdown reason %', p_reason_code USING ERRCODE='23503';
  END IF;

  -- Fall back to the reason's default rather than forcing every caller to
  -- restate policy. The stored value is still explicit on the row.
  v_absorb := COALESCE(p_absorbed_by, v_reason.default_absorbed_by);
  v_share  := CASE WHEN v_absorb = 'shared' THEN COALESCE(p_share_store_rate, 0.5) ELSE NULL END;

  IF p_new_price >= v_item.agreed_price THEN
    RAISE EXCEPTION 'Markdown to % is not below the current price % on item %',
      p_new_price, v_item.agreed_price, p_consignment_item_id USING ERRCODE='23514';
  END IF;

  INSERT INTO markdown_event (
    consignment_item_id, reason_code, old_price, new_price, currency,
    absorbed_by, share_store_rate, effective_from, note
  ) VALUES (
    p_consignment_item_id, p_reason_code, v_item.agreed_price, p_new_price, v_item.currency,
    v_absorb, v_share, p_effective_from, p_note
  ) RETURNING id INTO v_id;

  -- Keep the existing price-history mechanism authoritative.
  INSERT INTO item_price_change (item_id, old_price, new_price, reason)
  VALUES (p_consignment_item_id, v_item.agreed_price, p_new_price,
          'markdown:' || p_reason_code);

  UPDATE consignment_item
     SET agreed_price = p_new_price
   WHERE id = p_consignment_item_id;

  RETURN v_id;
END; $$;


--
-- Name: FUNCTION apply_markdown(p_consignment_item_id uuid, p_new_price kernel.money_amount, p_reason_code text, p_absorbed_by text, p_share_store_rate kernel.percent_rate, p_effective_from date, p_note text); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.apply_markdown(p_consignment_item_id uuid, p_new_price kernel.money_amount, p_reason_code text, p_absorbed_by text, p_share_store_rate kernel.percent_rate, p_effective_from date, p_note text) IS 'Records a markdown event + price history and moves the item price. Posts no journal entry (ADR-0036).';


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
       -- Credit memos are not payable. Cash settles what is OWED; an open
       -- credit is netted at invoicing time, not paid off with more cash.
       -- Including them here would let a payment "settle" a credit and then
       -- fail with an unapplied remainder on the invoice it should have paid.
       AND item_kind = 'invoice'
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
-- Name: apply_rent_escalation(uuid, kernel.percent_rate, date); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.apply_rent_escalation(p_lease_id uuid, p_rate kernel.percent_rate, p_effective_from date) RETURNS integer
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: FUNCTION apply_rent_escalation(p_lease_id uuid, p_rate kernel.percent_rate, p_effective_from date); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.apply_rent_escalation(p_lease_id uuid, p_rate kernel.percent_rate, p_effective_from date) IS 'Effective-dates a percentage increase on fixed rent components. Closes old periods; never overwrites.';


--
-- Name: assert_control_account_tagged(); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.assert_control_account_tagged() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
      DECLARE
        v_sub      text;
        v_untagged boolean;
        v_code     text;
        v_name     text;
      BEGIN
        IF NEW.subledger_type_code IS NOT NULL THEN RETURN NEW; END IF;

        SELECT a.control_subledger_type_code, a.code, a.name
          INTO v_sub, v_code, v_name
          FROM tenant_demo.account a
         WHERE a.id = NEW.account_id AND a.is_control;

        IF v_sub IS NULL THEN RETURN NEW; END IF;

        SELECT st.allows_untagged INTO v_untagged
          FROM kernel.subledger_type st WHERE st.code = v_sub;

        IF COALESCE(v_untagged, false) THEN RETURN NEW; END IF;

        RAISE EXCEPTION
          'Account % (%) is the % control account; a posting to it must name the party (party_id + subledger_type_code). Untagged money here is owed to nobody and will never be collected or paid.',
          v_code, v_name, v_sub
          USING ERRCODE = '23514';
      END; $$;


--
-- Name: FUNCTION assert_control_account_tagged(); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.assert_control_account_tagged() IS 'Prevents orphaned balances: every line hitting a control account must identify the party, unless the subledger allows bearer instruments.';


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
-- Name: assert_layaway_item_free(); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.assert_layaway_item_free() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.consignment_item_id IS NULL THEN RETURN NEW; END IF;
  IF EXISTS (
    SELECT 1
      FROM layaway_line ll
      JOIN layaway l ON l.id = ll.layaway_id
     WHERE ll.consignment_item_id = NEW.consignment_item_id
       AND ll.id <> NEW.id
       AND l.status = 'open'
  ) THEN
    RAISE EXCEPTION 'Consignment item % is already on an open layaway', NEW.consignment_item_id
      USING ERRCODE='23505';
  END IF;
  RETURN NEW;
END; $$;


--
-- Name: FUNCTION assert_layaway_item_free(); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.assert_layaway_item_free() IS 'Prevents the same consigned item being reserved on two open layaways. Cancelled layaways free it.';


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
-- Name: assert_posting_map_sane(); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.assert_posting_map_sane() RETURNS TABLE(role_code text, account_code text, account_name text, problem text)
    LANGUAGE sql STABLE
    AS $$
  WITH wired AS (
    SELECT pm.role_code, a.code AS account_code, a.name AS account_name,
           a.account_type_code
      FROM posting_map pm
      JOIN account a ON a.id = pm.account_id
  ),
  -- Roles that legitimately point at the same account as another role.
  -- Empty today. Anything added here is a deliberate, reviewed decision.
  allowed_alias AS (
    SELECT * FROM (VALUES (NULL::text, NULL::text)) AS v(role_a, role_b) WHERE false
  )
  -- Rule 1: no two roles on one account.
  SELECT string_agg(w.role_code, ' + ' ORDER BY w.role_code),
         w.account_code, w.account_name,
         'ACCOUNT CODE COLLISION: ' || count(*)::text
           || ' posting roles share this one account'
    FROM wired w
   GROUP BY w.account_code, w.account_name
  HAVING count(*) > 1
     AND NOT EXISTS (
       SELECT 1 FROM allowed_alias aa
        WHERE aa.role_a = min(w.role_code) AND aa.role_b = max(w.role_code))

  UNION ALL

  -- Rule 2: role suffix must agree with the account type.
  SELECT w.role_code, w.account_code, w.account_name,
         'TYPE MISMATCH: role implies ' ||
           CASE
             WHEN w.role_code LIKE '%\_revenue'    THEN 'revenue'
             WHEN w.role_code LIKE '%\_expense'    THEN 'expense'
             WHEN w.role_code LIKE '%\_payable%'   THEN 'liability'
             WHEN w.role_code LIKE '%\_receivable' THEN 'asset'
           END
           || ' but the account is ' || w.account_type_code
    FROM wired w
   WHERE (w.role_code LIKE '%\_revenue'    AND w.account_type_code <> 'revenue')
      OR (w.role_code LIKE '%\_expense'    AND w.account_type_code <> 'expense')
      OR (w.role_code LIKE '%\_payable%'   AND w.account_type_code <> 'liability')
      OR (w.role_code LIKE '%\_receivable' AND w.account_type_code <> 'asset');
$$;


--
-- Name: FUNCTION assert_posting_map_sane(); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.assert_posting_map_sane() IS 'Detects account-code collisions: two roles sharing an account, or a role wired to an incompatible account type. Empty result = sane.';


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
-- Name: assert_vendor_draw_covered(); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.assert_vendor_draw_covered() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_party     uuid;
  v_available numeric;
  v_drawn     numeric;
BEGIN
  IF NEW.tender_type_code <> 'vendor_draw' THEN RETURN NEW; END IF;

  v_party := NEW.party_id;
  IF v_party IS NULL THEN
    RAISE EXCEPTION 'A vendor_draw tender must identify the vendor (party_id)' USING ERRCODE='23514';
  END IF;

  -- What the ledger says we owe them right now. Because this trigger is
  -- DEFERRED, any payable accrued by this same sale is already included.
  v_available := vendor_draw_available(v_party);

  -- Total drawn by this vendor in the current transaction, including rows the
  -- ledger has not yet reflected. Checking only the balance would let a vendor
  -- with 0.00 owed still tender a draw -- the balance must COVER the draw.
  SELECT COALESCE(sum(pt.amount), 0) INTO v_drawn
    FROM payment_tender pt
   WHERE pt.tender_type_code = 'vendor_draw'
     AND pt.party_id = v_party
     AND pt.settled_at IS NULL
     AND EXISTS (SELECT 1 FROM payment p
                  WHERE p.id = pt.payment_id AND p.journal_entry_id IS NULL);

  IF v_available < v_drawn THEN
    RAISE EXCEPTION
      'Vendor % cannot draw %: only % available',
      v_party, v_drawn, v_available USING ERRCODE='23514';
  END IF;

  RETURN NEW;
END; $$;


--
-- Name: FUNCTION assert_vendor_draw_covered(); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.assert_vendor_draw_covered() IS 'Deferred guard: a vendor cannot draw their payable negative. Runs at COMMIT so same-sale accruals count.';


--
-- Name: balance_sheet(date); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.balance_sheet(p_as_of date DEFAULT CURRENT_DATE) RETURNS TABLE(account_type_code text, account_code text, account_name text, amount numeric, sort_order smallint)
    LANGUAGE sql STABLE
    AS $$
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


--
-- Name: FUNCTION balance_sheet(p_as_of date); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.balance_sheet(p_as_of date) IS 'Balance sheet as of a date, including unclosed current-year earnings so it always balances.';


--
-- Name: balance_sheet_check(date); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.balance_sheet_check(p_as_of date DEFAULT CURRENT_DATE) RETURNS numeric
    LANGUAGE sql STABLE
    AS $$
  SELECT COALESCE(sum(CASE WHEN account_type_code = 'asset' THEN amount ELSE -amount END), 0)
    FROM balance_sheet(p_as_of);
$$;


--
-- Name: FUNCTION balance_sheet_check(p_as_of date); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.balance_sheet_check(p_as_of date) IS 'Assets - (Liabilities + Equity). Must be exactly 0.';


--
-- Name: cam_reconciliation(uuid); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.cam_reconciliation(p_cam_pool_id uuid) RETURNS TABLE(lease_id uuid, lessee_party_id uuid, pro_rata_share numeric, recoverable_pool kernel.money_amount, admin_fee kernel.money_amount, share_of_pool kernel.money_amount, estimates_billed kernel.money_amount, balance_due kernel.money_amount)
    LANGUAGE plpgsql STABLE
    AS $$
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


--
-- Name: FUNCTION cam_reconciliation(p_cam_pool_id uuid); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.cam_reconciliation(p_cam_pool_id uuid) IS 'CAM statement per lease: pro-rata share of actual pool vs estimates already billed.';


--
-- Name: cancel_layaway(uuid, date, text, kernel.money_amount); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.cancel_layaway(p_layaway_id uuid, p_cancel_date date, p_idempotency_key text, p_fee_override kernel.money_amount DEFAULT NULL::numeric) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_lay    record;
  v_fee    kernel.money_amount;
  v_refund kernel.money_amount;
  v_entry  uuid;
  v_lines  jsonb;
BEGIN
  SELECT * INTO v_lay FROM layaway WHERE id = p_layaway_id FOR UPDATE;
  IF v_lay IS NULL THEN
    RAISE EXCEPTION 'Layaway % not found', p_layaway_id USING ERRCODE='23503';
  END IF;
  IF v_lay.status <> 'open' THEN
    RAISE EXCEPTION 'Layaway % is % and cannot be cancelled', p_layaway_id, v_lay.status
      USING ERRCODE='23514';
  END IF;

  v_fee := COALESCE(p_fee_override, v_lay.cancellation_fee);
  -- Never keep more than the customer actually paid.
  v_fee := LEAST(v_fee, v_lay.paid_total);
  v_refund := v_lay.paid_total - v_fee;

  IF v_lay.paid_total = 0 THEN
    -- Nothing was ever collected, so there is no liability to unwind and no
    -- journal entry to post. Release the goods and close it.
    UPDATE consignment_item ci SET status = 'available'
      FROM layaway_line ll
     WHERE ll.layaway_id = p_layaway_id
       AND ci.id = ll.consignment_item_id
       AND ci.status = 'reserved';
    UPDATE layaway SET status = 'cancelled', closed_date = p_cancel_date
     WHERE id = p_layaway_id;
    RETURN NULL;
  END IF;

  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', posting_account('layaway_deposit_control'),
                       'debit', v_lay.paid_total, 'currency', v_lay.currency,
                       'party_id', v_lay.customer_party_id,
                       'subledger_type_code', 'layaway_deposit',
                       'memo', 'Layaway cancellation ' || v_lay.layaway_no)
  );

  IF v_refund > 0 THEN
    v_lines := v_lines || jsonb_build_object(
      'account_id', posting_account('cash'),
      'credit', v_refund, 'currency', v_lay.currency,
      'memo', 'Layaway refund ' || v_lay.layaway_no);
  END IF;

  IF v_fee > 0 THEN
    v_lines := v_lines || jsonb_build_object(
      'account_id', posting_account('other_income'),
      'credit', v_fee, 'currency', v_lay.currency,
      'memo', 'Layaway cancellation fee ' || v_lay.layaway_no);
  END IF;

  v_entry := post_journal_entry(
    p_cancel_date, 'Layaway cancellation ' || v_lay.layaway_no,
    'layaway', p_layaway_id::text, p_idempotency_key, v_lines);

  -- Record the refund as a negative payment so paid_total and the ledger agree.
  IF v_refund > 0 THEN
    INSERT INTO layaway_payment (layaway_id, payment_date, amount, currency,
                                 journal_entry_id, note)
    VALUES (p_layaway_id, p_cancel_date, -v_refund, v_lay.currency, v_entry,
            'Cancellation refund');
  END IF;

  -- Goods go back on the floor.
  UPDATE consignment_item ci SET status = 'available'
    FROM layaway_line ll
   WHERE ll.layaway_id = p_layaway_id
     AND ci.id = ll.consignment_item_id
     AND ci.status = 'reserved';

  UPDATE layaway
     SET status = 'cancelled', closed_date = p_cancel_date,
         paid_total = paid_total - v_refund
   WHERE id = p_layaway_id;

  RETURN v_entry;
END; $$;


--
-- Name: FUNCTION cancel_layaway(p_layaway_id uuid, p_cancel_date date, p_idempotency_key text, p_fee_override kernel.money_amount); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.cancel_layaway(p_layaway_id uuid, p_cancel_date date, p_idempotency_key text, p_fee_override kernel.money_amount) IS 'Cancellation: unwinds the liability, refunds cash, recognises any forfeited fee as income, frees the goods.';


--
-- Name: cash_basis_income_statement(date, date); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.cash_basis_income_statement(p_from date, p_to date) RETURNS TABLE(account_type_code text, account_code text, account_name text, amount numeric, sort_order smallint)
    LANGUAGE sql STABLE
    AS $$
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


--
-- Name: FUNCTION cash_basis_income_statement(p_from date, p_to date); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.cash_basis_income_statement(p_from date, p_to date) IS 'Cash-basis P&L DERIVED from the accrual ledger (ADR-0022). Only P&L lines in entries that touched cash.';


--
-- Name: close_fiscal_year(smallint, text); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.close_fiscal_year(p_fiscal_year smallint, p_idempotency_key text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: FUNCTION close_fiscal_year(p_fiscal_year smallint, p_idempotency_key text); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.close_fiscal_year(p_fiscal_year smallint, p_idempotency_key text) IS 'Rolls P&L into Retained Earnings via Income Summary, then hard-locks the year (ADR-0030).';


--
-- Name: close_period(smallint, smallint); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.close_period(p_fiscal_year smallint, p_period_no smallint) RETURNS void
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: FUNCTION close_period(p_fiscal_year smallint, p_period_no smallint); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.close_period(p_fiscal_year smallint, p_period_no smallint) IS 'Soft-locks a period. Refuses if out of balance or if an earlier period is open.';


--
-- Name: commission_period_actuals(uuid, date, date); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.commission_period_actuals(p_agreement_id uuid, p_start date, p_end date) RETURNS TABLE(gross_sales numeric, accrued_commission numeric)
    LANGUAGE sql STABLE
    AS $$
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


--
-- Name: FUNCTION commission_period_actuals(p_agreement_id uuid, p_start date, p_end date); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.commission_period_actuals(p_agreement_id uuid, p_start date, p_end date) IS 'Gross sales and commission actually accrued for an agreement in a period, across POS and consignment sales, net of refunds.';


--
-- Name: complete_layaway(uuid, date, text); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.complete_layaway(p_layaway_id uuid, p_pickup_date date, p_idempotency_key text) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_lay   record;
  v_entry uuid;
  v_lines jsonb;
  v_sale  uuid;
  v_line  record;
  v_no    integer := 0;
BEGIN
  SELECT * INTO v_lay FROM layaway WHERE id = p_layaway_id FOR UPDATE;
  IF v_lay IS NULL THEN
    RAISE EXCEPTION 'Layaway % not found', p_layaway_id USING ERRCODE='23503';
  END IF;
  IF v_lay.status = 'completed' THEN
    RETURN (SELECT journal_entry_id FROM sale WHERE id = v_lay.sale_id);
  END IF;
  IF v_lay.status <> 'open' THEN
    RAISE EXCEPTION 'Layaway % is % and cannot be completed', p_layaway_id, v_lay.status
      USING ERRCODE='23514';
  END IF;
  IF v_lay.paid_total < v_lay.total THEN
    RAISE EXCEPTION 'Layaway % is not paid in full (paid %, total %)',
      p_layaway_id, v_lay.paid_total, v_lay.total USING ERRCODE='23514';
  END IF;

  -- Recognise the sale document. Tender is already collected, so the sale
  -- exists to record WHAT was sold; the cash leg happened at deposit time.
  INSERT INTO sale (customer_party_id, sale_date, channel,
                    subtotal, discount_total, tax_total, total, currency, status)
  VALUES (v_lay.customer_party_id, p_pickup_date, 'in_store',
          v_lay.goods_total, 0, v_lay.tax_total, v_lay.total, v_lay.currency, 'completed')
  RETURNING id INTO v_sale;

  FOR v_line IN SELECT * FROM layaway_line WHERE layaway_id = p_layaway_id ORDER BY line_no LOOP
    v_no := v_no + 1;
    INSERT INTO sale_line (
      sale_id, line_no, line_kind, consignment_item_id, consignor_party_id,
      description, quantity, unit_price, discount_amount, extended_price,
      commission_amount, net_to_consignor, unit_cost, is_taxable, currency
    )
    SELECT v_sale, v_no,
           CASE WHEN v_line.consignment_item_id IS NOT NULL THEN 'consignment' ELSE 'owned' END,
           v_line.consignment_item_id,
           ca.consignor_party_id,
           v_line.description, v_line.quantity, v_line.unit_price, 0, v_line.extended_price,
           -- Commission split is resolved by the consignment settlement path;
           -- at pickup the whole extended price is provisionally the
           -- consignor's, and settlement applies the rule. For owned goods
           -- there is no split at all.
           CASE WHEN v_line.consignment_item_id IS NOT NULL THEN 0 ELSE 0 END,
           CASE WHEN v_line.consignment_item_id IS NOT NULL THEN v_line.extended_price ELSE 0 END,
           NULL, false, v_line.currency
      FROM (SELECT 1) _
      LEFT JOIN consignment_item ci ON ci.id = v_line.consignment_item_id
      LEFT JOIN consignor_agreement ca ON ca.id = ci.agreement_id;

    IF v_line.consignment_item_id IS NOT NULL THEN
      UPDATE consignment_item SET status = 'sold' WHERE id = v_line.consignment_item_id;
    END IF;
  END LOOP;

  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', posting_account('layaway_deposit_control'),
                       'debit', v_lay.total, 'currency', v_lay.currency,
                       'party_id', v_lay.customer_party_id,
                       'subledger_type_code', 'layaway_deposit',
                       'memo', 'Layaway pickup ' || v_lay.layaway_no),
    jsonb_build_object('account_id', posting_account('sales_revenue'),
                       'credit', v_lay.total, 'currency', v_lay.currency,
                       'memo', 'Layaway pickup ' || v_lay.layaway_no)
  );

  v_entry := post_journal_entry(
    p_pickup_date, 'Layaway pickup ' || v_lay.layaway_no,
    'layaway', p_layaway_id::text, p_idempotency_key, v_lines);

  UPDATE sale SET journal_entry_id = v_entry WHERE id = v_sale;

  UPDATE layaway
     SET status = 'completed', sale_id = v_sale, closed_date = p_pickup_date
   WHERE id = p_layaway_id;

  RETURN v_entry;
END; $$;


--
-- Name: FUNCTION complete_layaway(p_layaway_id uuid, p_pickup_date date, p_idempotency_key text); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.complete_layaway(p_layaway_id uuid, p_pickup_date date, p_idempotency_key text) IS 'Pickup: releases the layaway liability into revenue and creates the sale. Cash was taken at deposit time.';


--
-- Name: compute_commission_trueup(uuid, date, date); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.compute_commission_trueup(p_agreement_id uuid, p_start date, p_end date) RETURNS TABLE(gross_sales numeric, accrued_commission numeric, correct_commission numeric, adjustment_amount numeric, effective_rate numeric)
    LANGUAGE sql STABLE
    AS $$
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


--
-- Name: FUNCTION compute_commission_trueup(p_agreement_id uuid, p_start date, p_end date); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.compute_commission_trueup(p_agreement_id uuid, p_start date, p_end date) IS 'Dry run: what the period commission adjustment would be. Posts nothing.';


--
-- Name: consignor_price_floor(uuid); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.consignor_price_floor(p_consignment_item_id uuid) RETURNS kernel.money_amount
    LANGUAGE sql STABLE
    AS $$
  SELECT (ci.agreed_price + COALESCE((
           SELECT sum(CASE absorbed_by
                        WHEN 'store'  THEN (old_price - new_price)
                        WHEN 'shared' THEN round((old_price - new_price) * share_store_rate, 4)
                        ELSE 0 END)
             FROM markdown_event me
            WHERE me.consignment_item_id = p_consignment_item_id), 0))::kernel.money_amount
    FROM consignment_item ci
   WHERE ci.id = p_consignment_item_id;
$$;


--
-- Name: FUNCTION consignor_price_floor(p_consignment_item_id uuid); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.consignor_price_floor(p_consignment_item_id uuid) IS 'Price the consignor is settled on: sale price plus any reduction the store agreed to absorb.';


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
-- Name: form_1099_exceptions(smallint, text); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.form_1099_exceptions(p_tax_year smallint, p_form_code text DEFAULT '1099-NEC'::text) RETURNS TABLE(party_id uuid, recipient_name text, total_paid kernel.money_amount, blocker text)
    LANGUAGE sql STABLE
    AS $$
  SELECT e.party_id, e.recipient_name, e.total_paid, e.blocker
    FROM form_1099_extract(p_tax_year, p_form_code) e
   WHERE e.is_reportable AND e.blocker IS NOT NULL
   ORDER BY e.total_paid DESC;
$$;


--
-- Name: FUNCTION form_1099_exceptions(p_tax_year smallint, p_form_code text); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.form_1099_exceptions(p_tax_year smallint, p_form_code text) IS 'Reportable payees that cannot be filed yet (missing TIN, W-9 or address). Run before year end.';


--
-- Name: form_1099_extract(smallint, text); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.form_1099_extract(p_tax_year smallint, p_form_code text DEFAULT '1099-NEC'::text) RETURNS TABLE(party_id uuid, recipient_name text, tin_type text, has_tin boolean, w9_received boolean, total_paid kernel.money_amount, total_withheld kernel.money_amount, threshold_amount kernel.money_amount, is_reportable boolean, blocker text)
    LANGUAGE sql STABLE
    AS $$
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


--
-- Name: FUNCTION form_1099_extract(p_tax_year smallint, p_form_code text); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.form_1099_extract(p_tax_year smallint, p_form_code text) IS 'Filing worklist for a tax year: totals, threshold, reportability and blockers per payee.';


--
-- Name: form_1099_threshold_for(text, text, smallint); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.form_1099_threshold_for(p_form_code text, p_box_code text, p_tax_year smallint) RETURNS kernel.money_amount
    LANGUAGE sql STABLE
    AS $$
  SELECT threshold_amount
    FROM tax_form_threshold
   WHERE tenant_id = kernel.current_tenant()
     AND form_code = p_form_code
     AND box_code  = p_box_code
     AND tax_year <= p_tax_year
   ORDER BY tax_year DESC
   LIMIT 1;
$$;


--
-- Name: FUNCTION form_1099_threshold_for(p_form_code text, p_box_code text, p_tax_year smallint); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.form_1099_threshold_for(p_form_code text, p_box_code text, p_tax_year smallint) IS 'Threshold in force for a form/box/year; falls back to the most recent prior year on file.';


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
-- Name: income_statement(date, date); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.income_statement(p_from date, p_to date) RETURNS TABLE(account_type_code text, account_code text, account_name text, amount numeric, sort_order smallint)
    LANGUAGE sql STABLE
    AS $$
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


--
-- Name: FUNCTION income_statement(p_from date, p_to date); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.income_statement(p_from date, p_to date) IS 'Accrual-basis P&L for a date range (ADR-0022: accrual is the book of record).';


--
-- Name: inventory_integrity_check(); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.inventory_integrity_check() RETURNS TABLE(item_id uuid, sku text, item_on_hand numeric, movement_on_hand numeric, difference numeric)
    LANGUAGE sql STABLE
    AS $$
  SELECT i.id, i.sku, i.on_hand,
         COALESCE(m.qty, 0),
         i.on_hand - COALESCE(m.qty, 0)
    FROM inventory_item i
    LEFT JOIN (SELECT item_id, sum(quantity) AS qty FROM inventory_movement GROUP BY item_id) m
           ON m.item_id = i.id
   WHERE i.deleted_at IS NULL
     AND i.on_hand - COALESCE(m.qty, 0) <> 0;
$$;


--
-- Name: FUNCTION inventory_integrity_check(); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.inventory_integrity_check() IS 'Returns rows only when inventory_item.on_hand disagrees with Σ movements. Empty = healthy.';


--
-- Name: inventory_movement_immutable(); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.inventory_movement_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'inventory_movement is append-only; post a correcting movement instead'
    USING ERRCODE='23514';
END; $$;


--
-- Name: inventory_value_check(); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.inventory_value_check() RETURNS TABLE(inventory_total numeric, gl_total numeric, difference numeric)
    LANGUAGE sql STABLE
    AS $$
  WITH inv AS (
    SELECT COALESCE(sum(round(on_hand * avg_cost, 4)), 0) AS total
      FROM inventory_item WHERE deleted_at IS NULL
  ),
  gl AS (
    SELECT COALESCE(sum(jl.base_debit - jl.base_credit), 0) AS total
      FROM journal_line jl
     WHERE jl.account_id = posting_account('inventory')
  )
  SELECT inv.total, gl.total, inv.total - gl.total FROM inv, gl;
$$;


--
-- Name: FUNCTION inventory_value_check(); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.inventory_value_check() IS 'Invariant: Σ(on_hand × avg_cost) must equal the Inventory control account (difference = 0).';


--
-- Name: issue_inventory_for_sale_line(uuid, date, text); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.issue_inventory_for_sale_line(p_sale_line_id uuid, p_entry_date date, p_idempotency_key text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_line    sale_line;
  v_item    inventory_item;
  v_cost    numeric;
  v_new_qty numeric;
  v_entry   uuid;
  v_key     text;
BEGIN
  SELECT * INTO v_line FROM sale_line WHERE id = p_sale_line_id;
  IF v_line.id IS NULL THEN
    RAISE EXCEPTION 'No sale line %', p_sale_line_id USING ERRCODE='23514';
  END IF;
  IF v_line.line_kind <> 'owned' THEN
    RETURN NULL;  -- consigned goods carry no inventory value (ADR-0031)
  END IF;
  IF v_line.inventory_item_id IS NULL THEN
    RETURN NULL;  -- untracked owned line (e.g. a service); nothing to relieve
  END IF;

  SELECT * INTO v_item FROM inventory_item WHERE id = v_line.inventory_item_id FOR UPDATE;

  v_key := COALESCE(p_idempotency_key, 'inv_issue:' || p_sale_line_id::text);
  SELECT id INTO v_entry FROM journal_entry
    WHERE idempotency_key = v_key AND tenant_id = kernel.current_tenant();
  IF v_entry IS NOT NULL THEN RETURN v_entry; END IF;

  IF v_line.quantity > v_item.on_hand THEN
    RAISE EXCEPTION 'Cannot sell % of %; only % on hand',
      v_line.quantity, v_item.sku, v_item.on_hand USING ERRCODE='23514';
  END IF;

  v_cost    := round(v_line.quantity * v_item.avg_cost, 4);
  v_new_qty := v_item.on_hand - v_line.quantity;

  -- A zero-cost item (e.g. donated stock) produces no COGS entry, but the
  -- quantity movement is still recorded so on-hand stays accurate.
  IF v_cost > 0 THEN
    v_entry := post_journal_entry(
      p_entry_date, 'COGS ' || v_item.sku, 'inventory_issue', p_sale_line_id::text, v_key,
      jsonb_build_array(
        jsonb_build_object('account_id', posting_account('cogs'),      'debit',  v_cost),
        jsonb_build_object('account_id', posting_account('inventory'), 'credit', v_cost)));
  END IF;

  UPDATE inventory_item SET on_hand = v_new_qty WHERE id = v_item.id;

  INSERT INTO inventory_movement (
    item_id, movement_kind, movement_date, quantity, unit_cost, extended_cost,
    currency, on_hand_after, avg_cost_after, source, source_ref, sale_line_id, journal_entry_id, memo)
  VALUES (v_item.id,'issue',p_entry_date,-v_line.quantity,v_item.avg_cost,
          round(-v_line.quantity * v_item.avg_cost,4),
          v_item.currency,v_new_qty,v_item.avg_cost,'sale',p_sale_line_id::text,
          p_sale_line_id,v_entry,'COGS at average cost');

  RETURN v_entry;
END; $$;


--
-- Name: FUNCTION issue_inventory_for_sale_line(p_sale_line_id uuid, p_entry_date date, p_idempotency_key text); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.issue_inventory_for_sale_line(p_sale_line_id uuid, p_entry_date date, p_idempotency_key text) IS 'Relieves owned stock at average cost and books COGS at the sale (ADR-0028/0031).';


--
-- Name: issue_stored_value(text, text, uuid, kernel.money_amount, date, boolean, date, text); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.issue_stored_value(p_instrument_kind text, p_code text, p_party_id uuid, p_amount kernel.money_amount, p_entry_date date, p_paid_with_cash boolean DEFAULT true, p_expires_date date DEFAULT NULL::date, p_idempotency_key text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_sv      uuid;
  v_entry   uuid;
  v_role    text;
  v_control uuid;
  v_sub     text;
  v_key     text;
  v_oi      uuid;
BEGIN
  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'Stored value amount must be positive, got %', p_amount USING ERRCODE='23514';
  END IF;

  v_sub  := CASE p_instrument_kind
              WHEN 'gift_certificate' THEN 'gift_certificate'
              WHEN 'store_credit'     THEN 'customer_credit'
              ELSE NULL END;
  IF v_sub IS NULL THEN
    RAISE EXCEPTION 'Unknown instrument kind %', p_instrument_kind USING ERRCODE='23514';
  END IF;

  v_role    := subledger_control_role(v_sub);
  v_control := posting_account(v_role);
  v_key     := COALESCE(p_idempotency_key, 'sv_issue:' || p_code);

  SELECT id INTO v_entry FROM journal_entry
    WHERE idempotency_key = v_key AND tenant_id = kernel.current_tenant();
  IF v_entry IS NOT NULL THEN
    SELECT id INTO v_sv FROM stored_value WHERE journal_entry_id = v_entry;
    RETURN v_sv;
  END IF;

  -- A bearer gift certificate has no party, but an open item needs one to tie
  -- to the subledger. Only create the open item when we know the holder.
  IF p_paid_with_cash THEN
    v_entry := post_journal_entry(
      p_entry_date, 'Issue ' || p_instrument_kind || ' ' || p_code,
      'stored_value_issue', p_code, v_key,
      CASE WHEN p_party_id IS NOT NULL THEN
        jsonb_build_array(
          jsonb_build_object('account_id', posting_account('undeposited_funds'), 'debit', p_amount),
          jsonb_build_object('account_id', v_control, 'credit', p_amount,
                             'party_id', p_party_id, 'subledger_type_code', v_sub))
      ELSE
        jsonb_build_array(
          jsonb_build_object('account_id', posting_account('undeposited_funds'), 'debit', p_amount),
          jsonb_build_object('account_id', v_control, 'credit', p_amount))
      END);
  ELSE
    -- Credit issued without cash in (e.g. goodwill, or a refund to store credit).
    v_entry := post_journal_entry(
      p_entry_date, 'Grant ' || p_instrument_kind || ' ' || p_code,
      'stored_value_issue', p_code, v_key,
      CASE WHEN p_party_id IS NOT NULL THEN
        jsonb_build_array(
          jsonb_build_object('account_id', posting_account('sales_discounts'), 'debit', p_amount),
          jsonb_build_object('account_id', v_control, 'credit', p_amount,
                             'party_id', p_party_id, 'subledger_type_code', v_sub))
      ELSE
        jsonb_build_array(
          jsonb_build_object('account_id', posting_account('sales_discounts'), 'debit', p_amount),
          jsonb_build_object('account_id', v_control, 'credit', p_amount))
      END);
  END IF;

  IF p_party_id IS NOT NULL THEN
    v_oi := open_item_create(v_sub, p_party_id, 'stored_value_issue', p_code, p_code,
                             p_amount, 'USD', p_entry_date, NULL, v_entry);
  END IF;

  INSERT INTO stored_value (
    instrument_kind, code, party_id, original_amount, balance,
    issued_date, expires_date, last_activity_at, origin, origin_ref,
    journal_entry_id, open_item_id)
  VALUES (p_instrument_kind, p_code, p_party_id, p_amount, p_amount,
          p_entry_date, p_expires_date, p_entry_date, 'manual', p_code, v_entry, v_oi)
  RETURNING id INTO v_sv;

  INSERT INTO stored_value_activity (stored_value_id, activity_kind, activity_date,
                                     amount, balance_after, journal_entry_id, memo)
  VALUES (v_sv, 'issue', p_entry_date, p_amount, p_amount, v_entry, 'Issued');

  RETURN v_sv;
END; $$;


--
-- Name: FUNCTION issue_stored_value(p_instrument_kind text, p_code text, p_party_id uuid, p_amount kernel.money_amount, p_entry_date date, p_paid_with_cash boolean, p_expires_date date, p_idempotency_key text); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.issue_stored_value(p_instrument_kind text, p_code text, p_party_id uuid, p_amount kernel.money_amount, p_entry_date date, p_paid_with_cash boolean, p_expires_date date, p_idempotency_key text) IS 'Issues a gift certificate / store credit as a LIABILITY. No revenue recognised (ADR-0032).';


--
-- Name: layaway_liability_check(); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.layaway_liability_check() RETURNS TABLE(layaway_total numeric, control_total numeric, difference numeric)
    LANGUAGE sql STABLE
    AS $$
  WITH lay AS (
    SELECT COALESCE(sum(paid_total), 0) AS total
      FROM layaway WHERE status = 'open'
  ),
  ctl AS (
    SELECT COALESCE(sum(jl.base_credit - jl.base_debit), 0) AS total
      FROM journal_line jl
      JOIN account a ON a.id = jl.account_id
     WHERE a.id = posting_account('layaway_deposit_control')
  )
  SELECT lay.total, ctl.total, (lay.total - ctl.total) FROM lay, ctl;
$$;


--
-- Name: FUNCTION layaway_liability_check(); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.layaway_liability_check() IS 'Open layaway deposits vs the layaway control account. Difference must be zero.';


--
-- Name: lease_pos_sales(uuid, date, date); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.lease_pos_sales(p_lease_id uuid, p_period_start date, p_period_end date) RETURNS kernel.money_amount
    LANGUAGE sql STABLE
    AS $$
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


--
-- Name: FUNCTION lease_pos_sales(p_lease_id uuid, p_period_start date, p_period_end date); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.lease_pos_sales(p_lease_id uuid, p_period_start date, p_period_end date) IS 'Net POS sales (sales less refunds) for a lease''s lessee in a period.';


--
-- Name: lease_pro_rata_share(uuid, uuid, date); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.lease_pro_rata_share(p_lease_id uuid, p_location_id uuid, p_as_of date) RETURNS numeric
    LANGUAGE sql STABLE
    AS $$
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


--
-- Name: FUNCTION lease_pro_rata_share(p_lease_id uuid, p_location_id uuid, p_as_of date); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.lease_pro_rata_share(p_lease_id uuid, p_location_id uuid, p_as_of date) IS 'Lease share of a location by leased area. Denominator excludes vacant space.';


--
-- Name: markdown_absorption(uuid); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.markdown_absorption(p_consignment_item_id uuid) RETURNS TABLE(original_price numeric, current_price numeric, total_markdown numeric, store_absorbed numeric, consignor_absorbed numeric)
    LANGUAGE sql STABLE
    AS $$
  WITH ev AS (
    SELECT old_price, new_price, absorbed_by, share_store_rate,
           (old_price - new_price) AS gap
      FROM markdown_event
     WHERE consignment_item_id = p_consignment_item_id
  )
  SELECT
    COALESCE((SELECT max(old_price) FROM ev), ci.agreed_price)::numeric,
    ci.agreed_price::numeric,
    COALESCE((SELECT sum(gap) FROM ev), 0)::numeric,
    COALESCE((SELECT sum(CASE absorbed_by
                           WHEN 'store'  THEN gap
                           WHEN 'shared' THEN round(gap * share_store_rate, 4)
                           ELSE 0 END) FROM ev), 0)::numeric,
    COALESCE((SELECT sum(CASE absorbed_by
                           WHEN 'consignor' THEN gap
                           WHEN 'shared'    THEN gap - round(gap * share_store_rate, 4)
                           ELSE 0 END) FROM ev), 0)::numeric
    FROM consignment_item ci
   WHERE ci.id = p_consignment_item_id;
$$;


--
-- Name: FUNCTION markdown_absorption(p_consignment_item_id uuid); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.markdown_absorption(p_consignment_item_id uuid) IS 'Original vs current price for an item and how the reduction split between store and consignor.';


--
-- Name: net_income(date, date); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.net_income(p_from date, p_to date) RETURNS numeric
    LANGUAGE sql STABLE
    AS $$
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


--
-- Name: FUNCTION net_income(p_from date, p_to date); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.net_income(p_from date, p_to date) IS 'Net income (revenue - expense) for a date range, functional currency.';


--
-- Name: open_item_control_check(); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.open_item_control_check() RETURNS TABLE(subledger_type_code text, open_item_total numeric, control_total numeric, difference numeric)
    LANGUAGE sql STABLE
    AS $$
  WITH oi AS (
    -- SIGNED: a credit memo reduces the subledger balance. Summing
    -- open_amount raw would make a 400.00 credit look like 400.00 more owed,
    -- and the control check would then fail by 800.00 -- twice the credit,
    -- which is a confusing way to discover a correct credit memo.
    SELECT subledger_type_code AS st,
           sum(open_item_signed(item_kind, open_amount)) AS total
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
  -- Scoped to the subledgers whose detail actually lives in open_item.
  --
  -- Security deposits (lease_deposit), layaway deposits (layaway_payment),
  -- stored value (stored_value) and accrued vendor payables all carry a real
  -- GL control balance with NO open item behind it. That is correct by
  -- design, and reporting them here produced a permanent non-zero difference
  -- on a healthy database.
  --
  -- That matters more than it looks: a check that always shows failures is a
  -- check everybody learns to ignore, and it hides the one real imbalance
  -- when it finally appears. Each of those subledgers has its own
  -- reconciliation (layaway_liability_check, stored_value_control_check) and
  -- all of them are covered by subledger_control_check().
  --
  -- Driven by subledger_type.uses_open_items rather than a hard-coded list,
  -- so adding an open-item-backed subledger extends the check automatically
  -- instead of silently escaping it.
  SELECT COALESCE(oi.st, ctl.st),
         COALESCE(oi.total, 0),
         COALESCE(ctl.total, 0),
         COALESCE(oi.total, 0) - COALESCE(ctl.total, 0)
    FROM oi FULL OUTER JOIN ctl ON oi.st = ctl.st
   WHERE COALESCE(oi.st, ctl.st) IN (
           SELECT code FROM kernel.subledger_type WHERE uses_open_items)
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
  v_id   uuid;
  v_kind text;
  v_abs  kernel.money_amount;
BEGIN
  IF p_amount = 0 THEN
    RAISE EXCEPTION 'An open item of zero has nothing to settle' USING ERRCODE='23514';
  END IF;

  v_kind := CASE WHEN p_amount < 0 THEN 'credit_memo' ELSE 'invoice' END;
  v_abs  := abs(p_amount);

  INSERT INTO open_item (
    subledger_type_code, party_id, source, source_ref, document_no, item_kind,
    original_amount, open_amount, currency, issue_date, due_date, journal_entry_id
  ) VALUES (
    p_subledger_type, p_party_id, p_source, p_source_ref, p_document_no, v_kind,
    v_abs, v_abs, p_currency, p_issue_date, p_due_date, p_journal_entry
  ) RETURNING id INTO v_id;
  RETURN v_id;
END; $$;


--
-- Name: FUNCTION open_item_create(p_subledger_type text, p_party_id uuid, p_source text, p_source_ref text, p_document_no text, p_amount kernel.money_amount, p_currency kernel.currency_code, p_issue_date date, p_due_date date, p_journal_entry uuid); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.open_item_create(p_subledger_type text, p_party_id uuid, p_source text, p_source_ref text, p_document_no text, p_amount kernel.money_amount, p_currency kernel.currency_code, p_issue_date date, p_due_date date, p_journal_entry uuid) IS 'Creates an open item linked to its journal entry. A negative amount creates a CREDIT MEMO, never a negative invoice.';


--
-- Name: open_item_signed(text, kernel.money_amount); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.open_item_signed(p_kind text, p_amount kernel.money_amount) RETURNS kernel.money_amount
    LANGUAGE sql IMMUTABLE
    AS $$
  SELECT CASE WHEN p_kind = 'credit_memo' THEN -p_amount ELSE p_amount END;
$$;


--
-- Name: FUNCTION open_item_signed(p_kind text, p_amount kernel.money_amount); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.open_item_signed(p_kind text, p_amount kernel.money_amount) IS 'Signed contribution of an open item to its subledger balance: credit memos are negative.';


--
-- Name: open_layaway(uuid, jsonb, date, kernel.money_amount, date); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.open_layaway(p_customer_party_id uuid, p_lines jsonb, p_due_date date DEFAULT NULL::date, p_cancellation_fee kernel.money_amount DEFAULT 0, p_opened_date date DEFAULT CURRENT_DATE) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_id    uuid;
  v_line  jsonb;
  v_no    integer := 0;
  v_ccy   kernel.currency_code;
  v_goods kernel.money_amount := 0;
  v_ext   kernel.money_amount;
  v_citem uuid;
  v_stat  text;
BEGIN
  IF jsonb_array_length(COALESCE(p_lines,'[]'::jsonb)) = 0 THEN
    RAISE EXCEPTION 'A layaway must reserve at least one item' USING ERRCODE='23514';
  END IF;

  v_ccy := (SELECT functional_currency FROM tenant_config LIMIT 1);

  INSERT INTO layaway (customer_party_id, opened_date, due_date,
                       cancellation_fee, currency)
  VALUES (p_customer_party_id, p_opened_date, p_due_date,
          COALESCE(p_cancellation_fee,0), v_ccy)
  RETURNING id INTO v_id;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    v_no  := v_no + 1;
    v_ext := round(COALESCE((v_line->>'quantity')::numeric,1)
                   * (v_line->>'unit_price')::numeric, 4);
    v_citem := NULLIF(v_line->>'consignment_item_id','')::uuid;

    -- Reserve the consigned item: it must be available, and it comes off the
    -- floor immediately so it cannot also be sold at the register.
    IF v_citem IS NOT NULL THEN
      SELECT status INTO v_stat FROM consignment_item WHERE id = v_citem FOR UPDATE;
      IF v_stat IS NULL THEN
        RAISE EXCEPTION 'Consignment item % not found', v_citem USING ERRCODE='23503';
      END IF;
      IF v_stat NOT IN ('received','available') THEN
        RAISE EXCEPTION 'Consignment item % is % and cannot be put on layaway', v_citem, v_stat
          USING ERRCODE='23514';
      END IF;
      UPDATE consignment_item SET status = 'reserved' WHERE id = v_citem;
    END IF;

    INSERT INTO layaway_line (
      layaway_id, line_no, consignment_item_id, inventory_item_id,
      description, quantity, unit_price, extended_price, currency
    ) VALUES (
      v_id, v_no, v_citem, NULLIF(v_line->>'inventory_item_id','')::uuid,
      v_line->>'description',
      COALESCE((v_line->>'quantity')::kernel.quantity, 1),
      (v_line->>'unit_price')::kernel.money_amount,
      v_ext, v_ccy
    );
    v_goods := v_goods + v_ext;
  END LOOP;

  UPDATE layaway
     SET goods_total = v_goods,
         total       = v_goods + tax_total
   WHERE id = v_id;

  RETURN v_id;
END; $$;


--
-- Name: FUNCTION open_layaway(p_customer_party_id uuid, p_lines jsonb, p_due_date date, p_cancellation_fee kernel.money_amount, p_opened_date date); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.open_layaway(p_customer_party_id uuid, p_lines jsonb, p_due_date date, p_cancellation_fee kernel.money_amount, p_opened_date date) IS 'Opens a layaway and RESERVES the consigned items so they cannot be sold twice.';


--
-- Name: party_1099_total(uuid, smallint, text); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.party_1099_total(p_party_id uuid, p_tax_year smallint, p_form_code text DEFAULT '1099-NEC'::text) RETURNS kernel.money_amount
    LANGUAGE sql STABLE
    AS $$
  SELECT COALESCE(sum(amount), 0)::kernel.money_amount
    FROM tax_year_payment
   WHERE tenant_id = kernel.current_tenant()
     AND party_id  = p_party_id
     AND tax_year  = p_tax_year
     AND form_code = p_form_code;
$$;


--
-- Name: FUNCTION party_1099_total(p_party_id uuid, p_tax_year smallint, p_form_code text); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.party_1099_total(p_party_id uuid, p_tax_year smallint, p_form_code text) IS 'Cash-basis total paid to a payee in a tax year.';


--
-- Name: percentage_rent_due(uuid, date, date, kernel.money_amount); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.percentage_rent_due(p_lease_id uuid, p_period_start date, p_period_end date, p_sales_amount kernel.money_amount DEFAULT NULL::numeric) RETURNS kernel.money_amount
    LANGUAGE plpgsql STABLE
    AS $$
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


--
-- Name: FUNCTION percentage_rent_due(p_lease_id uuid, p_period_start date, p_period_end date, p_sales_amount kernel.money_amount); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.percentage_rent_due(p_lease_id uuid, p_period_start date, p_period_end date, p_sales_amount kernel.money_amount) IS 'Percentage rent owed for a period over the breakpoint, net of amounts already billed.';


--
-- Name: period_balance_check(date); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.period_balance_check(p_as_of date) RETURNS numeric
    LANGUAGE sql STABLE
    AS $$
  SELECT COALESCE(sum(jl.base_debit - jl.base_credit), 0)
    FROM journal_line jl
    JOIN journal_entry je ON je.id = jl.journal_entry_id
   WHERE je.entry_date <= p_as_of;
$$;


--
-- Name: FUNCTION period_balance_check(p_as_of date); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.period_balance_check(p_as_of date) IS 'Sum of (base_debit - base_credit) through a date. Must be 0.';


--
-- Name: post_cam_reconciliation(uuid, uuid, date, text); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.post_cam_reconciliation(p_cam_pool_id uuid, p_lease_id uuid, p_entry_date date, p_idempotency_key text) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: FUNCTION post_cam_reconciliation(p_cam_pool_id uuid, p_lease_id uuid, p_entry_date date, p_idempotency_key text); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.post_cam_reconciliation(p_cam_pool_id uuid, p_lease_id uuid, p_entry_date date, p_idempotency_key text) IS 'Bills CAM under-recovery or credits over-recovery for one lease. Idempotent; NULL when balanced.';


--
-- Name: post_commission_trueup(uuid, date, date, date, text); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.post_commission_trueup(p_agreement_id uuid, p_start date, p_end date, p_entry_date date, p_idempotency_key text) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: FUNCTION post_commission_trueup(p_agreement_id uuid, p_start date, p_end date, p_entry_date date, p_idempotency_key text); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.post_commission_trueup(p_agreement_id uuid, p_start date, p_end date, p_entry_date date, p_idempotency_key text) IS 'Idempotent per-period commission adjustment. Positive = store under-charged; negative = store owes the consignor.';


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
-- Name: post_layaway_payment(uuid, kernel.money_amount, date, text, text); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.post_layaway_payment(p_layaway_id uuid, p_amount kernel.money_amount, p_payment_date date, p_idempotency_key text, p_tender_type text DEFAULT 'cash'::text) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_lay   record;
  v_ccy   kernel.currency_code;
  v_entry uuid;
  v_lines jsonb;
BEGIN
  SELECT * INTO v_lay FROM layaway WHERE id = p_layaway_id FOR UPDATE;
  IF v_lay IS NULL THEN
    RAISE EXCEPTION 'Layaway % not found', p_layaway_id USING ERRCODE='23503';
  END IF;
  IF v_lay.status <> 'open' THEN
    RAISE EXCEPTION 'Layaway % is % and cannot take payments', p_layaway_id, v_lay.status
      USING ERRCODE='23514';
  END IF;
  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'Layaway payment must be positive (got %)', p_amount USING ERRCODE='23514';
  END IF;
  IF v_lay.paid_total + p_amount > v_lay.total THEN
    RAISE EXCEPTION 'Payment of % would overpay layaway % (paid %, total %)',
      p_amount, p_layaway_id, v_lay.paid_total, v_lay.total USING ERRCODE='23514';
  END IF;

  v_ccy := v_lay.currency;

  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', posting_account('cash'),
                       'debit', p_amount, 'currency', v_ccy,
                       'memo', 'Layaway deposit ' || v_lay.layaway_no),
    jsonb_build_object('account_id', posting_account('layaway_deposit_control'),
                       'credit', p_amount, 'currency', v_ccy,
                       'party_id', v_lay.customer_party_id,
                       'subledger_type_code', 'layaway_deposit',
                       'memo', 'Layaway deposit ' || v_lay.layaway_no)
  );

  v_entry := post_journal_entry(
    p_payment_date, 'Layaway deposit ' || v_lay.layaway_no,
    'layaway', p_layaway_id::text, p_idempotency_key, v_lines);

  -- Guard the append-only payment row against a replayed idempotency key.
  IF NOT EXISTS (SELECT 1 FROM layaway_payment
                  WHERE idempotency_key = p_idempotency_key
                    AND idempotency_key IS NOT NULL) THEN
    INSERT INTO layaway_payment (layaway_id, payment_date, amount, currency,
                                 tender_type_code, journal_entry_id, idempotency_key)
    VALUES (p_layaway_id, p_payment_date, p_amount, v_ccy,
            p_tender_type, v_entry, p_idempotency_key);

    UPDATE layaway SET paid_total = paid_total + p_amount WHERE id = p_layaway_id;
  END IF;

  RETURN v_entry;
END; $$;


--
-- Name: FUNCTION post_layaway_payment(p_layaway_id uuid, p_amount kernel.money_amount, p_payment_date date, p_idempotency_key text, p_tender_type text); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.post_layaway_payment(p_layaway_id uuid, p_amount kernel.money_amount, p_payment_date date, p_idempotency_key text, p_tender_type text) IS 'Idempotent layaway deposit: debit cash / credit layaway liability. Never revenue (ADR-0036).';


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
-- Name: post_percentage_rent_trueup(uuid, date, date, date, text, kernel.money_amount); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.post_percentage_rent_trueup(p_lease_id uuid, p_period_start date, p_period_end date, p_entry_date date, p_idempotency_key text, p_sales_amount kernel.money_amount DEFAULT NULL::numeric) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: FUNCTION post_percentage_rent_trueup(p_lease_id uuid, p_period_start date, p_period_end date, p_entry_date date, p_idempotency_key text, p_sales_amount kernel.money_amount); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.post_percentage_rent_trueup(p_lease_id uuid, p_period_start date, p_period_end date, p_entry_date date, p_idempotency_key text, p_sales_amount kernel.money_amount) IS 'Idempotently bills percentage rent for a period. Returns NULL when nothing is due.';


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
-- Name: post_refund_inventory(uuid, date); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.post_refund_inventory(p_refund_sale_id uuid, p_entry_date date) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_sale    record;
  v_line    record;
  v_orig    record;
  v_item    inventory_item;
  v_cost    numeric;
  v_new_qty numeric;
  v_entry   uuid;
  v_key     text;
  v_count   integer := 0;
BEGIN
  SELECT * INTO v_sale FROM sale WHERE id = p_refund_sale_id;
  IF NOT v_sale.is_refund THEN
    RAISE EXCEPTION 'Sale % is not a refund document', p_refund_sale_id USING ERRCODE='23514';
  END IF;

  FOR v_line IN
    SELECT * FROM sale_line
     WHERE sale_id = p_refund_sale_id
       AND line_kind = 'owned'
       AND inventory_item_id IS NOT NULL
     ORDER BY line_no
  LOOP
    v_key := 'inv_return:' || v_line.id::text;
    SELECT id INTO v_entry FROM journal_entry
      WHERE idempotency_key = v_key AND tenant_id = kernel.current_tenant();
    IF v_entry IS NOT NULL THEN CONTINUE; END IF;   -- already restocked

    SELECT * INTO v_item FROM inventory_item WHERE id = v_line.inventory_item_id FOR UPDATE;

    -- Recover the cost actually used when these goods left, via the original sale.
    SELECT m.unit_cost INTO v_orig
      FROM inventory_movement m
      JOIN sale_line sl ON sl.id = m.sale_line_id
     WHERE m.item_id = v_item.id
       AND m.movement_kind = 'issue'
       AND sl.sale_id = v_sale.refunds_sale_id
     ORDER BY m.id DESC LIMIT 1;

    v_cost    := round(v_line.quantity * COALESCE(v_orig.unit_cost, v_item.avg_cost), 4);
    v_new_qty := v_item.on_hand + v_line.quantity;

    IF v_cost > 0 THEN
      v_entry := post_journal_entry(
        p_entry_date, 'Restock ' || v_item.sku, 'inventory_return', v_line.id::text, v_key,
        jsonb_build_array(
          jsonb_build_object('account_id', posting_account('inventory'), 'debit',  v_cost),
          jsonb_build_object('account_id', posting_account('cogs'),      'credit', v_cost)));
    END IF;

    UPDATE inventory_item SET on_hand = v_new_qty WHERE id = v_item.id;

    INSERT INTO inventory_movement (
      item_id, movement_kind, movement_date, quantity, unit_cost, extended_cost,
      currency, on_hand_after, avg_cost_after, source, source_ref, sale_line_id, journal_entry_id, memo)
    VALUES (v_item.id,'customer_return',p_entry_date, v_line.quantity,
            COALESCE(v_orig.unit_cost, v_item.avg_cost),
            v_cost, v_item.currency, v_new_qty, v_item.avg_cost,
            'refund', v_line.id::text, v_line.id, v_entry, 'Restocked at original issue cost');

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END; $$;


--
-- Name: FUNCTION post_refund_inventory(p_refund_sale_id uuid, p_entry_date date); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.post_refund_inventory(p_refund_sale_id uuid, p_entry_date date) IS 'Restocks owned goods on refund at the original issue cost (avoids revaluation drift).';


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
-- Name: post_sale_inventory(uuid, date); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.post_sale_inventory(p_sale_id uuid, p_entry_date date) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_line  record;
  v_count integer := 0;
BEGIN
  FOR v_line IN
    SELECT id FROM sale_line
     WHERE sale_id = p_sale_id
       AND line_kind = 'owned'
       AND inventory_item_id IS NOT NULL
     ORDER BY line_no
  LOOP
    PERFORM issue_inventory_for_sale_line(v_line.id, p_entry_date, NULL);
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END; $$;


--
-- Name: FUNCTION post_sale_inventory(p_sale_id uuid, p_entry_date date); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.post_sale_inventory(p_sale_id uuid, p_entry_date date) IS 'Books COGS and relieves stock for the owned lines of a sale (ADR-0028/0031).';


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
-- Name: receive_inventory(uuid, numeric, numeric, date, text, boolean); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.receive_inventory(p_item_id uuid, p_quantity numeric, p_unit_cost numeric, p_entry_date date, p_idempotency_key text DEFAULT NULL::text, p_on_account boolean DEFAULT true) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_item    inventory_item;
  v_ext     numeric;
  v_new_qty numeric;
  v_new_avg numeric;
  v_entry   uuid;
  v_credit  uuid;
  v_key     text;
BEGIN
  IF p_quantity <= 0 THEN
    RAISE EXCEPTION 'Receipt quantity must be positive, got %', p_quantity USING ERRCODE='23514';
  END IF;
  IF p_unit_cost < 0 THEN
    RAISE EXCEPTION 'Unit cost cannot be negative, got %', p_unit_cost USING ERRCODE='23514';
  END IF;

  SELECT * INTO v_item FROM inventory_item WHERE id = p_item_id FOR UPDATE;
  IF v_item.id IS NULL THEN
    RAISE EXCEPTION 'No inventory item %', p_item_id USING ERRCODE='23514';
  END IF;

  v_key := COALESCE(p_idempotency_key,
                    'inv_recv:' || p_item_id::text || ':' || p_entry_date::text || ':' || p_quantity::text);

  SELECT id INTO v_entry FROM journal_entry
    WHERE idempotency_key = v_key AND tenant_id = kernel.current_tenant();
  IF v_entry IS NOT NULL THEN RETURN v_entry; END IF;

  v_ext     := round(p_quantity * p_unit_cost, 4);
  v_new_qty := v_item.on_hand + p_quantity;
  -- Moving weighted average. Guarded against divide-by-zero.
  v_new_avg := CASE WHEN v_new_qty = 0 THEN 0
                    ELSE round(((v_item.on_hand * v_item.avg_cost) + v_ext) / v_new_qty, 4) END;

  IF p_on_account AND v_item.supplier_party_id IS NOT NULL THEN
    v_credit := posting_account('ap_control');
    v_entry := post_journal_entry(
      p_entry_date, 'Inventory receipt ' || v_item.sku, 'inventory_receipt', p_item_id::text, v_key,
      jsonb_build_array(
        jsonb_build_object('account_id', posting_account('inventory'), 'debit', v_ext),
        jsonb_build_object('account_id', v_credit, 'credit', v_ext,
                           'party_id', v_item.supplier_party_id, 'subledger_type_code','ap')));
    PERFORM open_item_create('ap', v_item.supplier_party_id, 'inventory_receipt', p_item_id::text,
                             NULL, v_ext, v_item.currency, p_entry_date, p_entry_date + 30, v_entry);
  ELSE
    v_credit := posting_account('cash');
    v_entry := post_journal_entry(
      p_entry_date, 'Inventory receipt ' || v_item.sku, 'inventory_receipt', p_item_id::text, v_key,
      jsonb_build_array(
        jsonb_build_object('account_id', posting_account('inventory'), 'debit', v_ext),
        jsonb_build_object('account_id', v_credit, 'credit', v_ext)));
  END IF;

  UPDATE inventory_item SET on_hand = v_new_qty, avg_cost = v_new_avg WHERE id = p_item_id;

  INSERT INTO inventory_movement (
    item_id, movement_kind, movement_date, quantity, unit_cost, extended_cost,
    currency, on_hand_after, avg_cost_after, source, source_ref, journal_entry_id, memo)
  VALUES (p_item_id,'receipt',p_entry_date,p_quantity,p_unit_cost,v_ext,
          v_item.currency,v_new_qty,v_new_avg,'inventory_receipt',p_item_id::text,v_entry,
          'Received ' || p_quantity || ' @ ' || p_unit_cost);

  RETURN v_entry;
END; $$;


--
-- Name: FUNCTION receive_inventory(p_item_id uuid, p_quantity numeric, p_unit_cost numeric, p_entry_date date, p_idempotency_key text, p_on_account boolean); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.receive_inventory(p_item_id uuid, p_quantity numeric, p_unit_cost numeric, p_entry_date date, p_idempotency_key text, p_on_account boolean) IS 'Receives owned stock and recomputes moving weighted-average cost (ADR-0031).';


--
-- Name: recognize_breakage(date, text); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.recognize_breakage(p_as_of date, p_idempotency_key text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_months  smallint;
  v_lines   jsonb := '[]'::jsonb;
  v_total   numeric := 0;
  v_entry   uuid;
  v_key     text;
  r         record;
BEGIN
  SELECT breakage_after_months INTO v_months FROM tenant_config LIMIT 1;

  -- Default is NULL = never. Escheatment law usually forbids this; the tenant
  -- must opt in deliberately (ADR-0032).
  IF v_months IS NULL THEN
    RETURN NULL;
  END IF;

  v_key := COALESCE(p_idempotency_key, 'breakage:' || p_as_of::text);
  SELECT id INTO v_entry FROM journal_entry
    WHERE idempotency_key = v_key AND tenant_id = kernel.current_tenant();
  IF v_entry IS NOT NULL THEN RETURN v_entry; END IF;

  FOR r IN
    SELECT sv.id, sv.code, sv.balance, sv.party_id, sv.instrument_kind,
           CASE sv.instrument_kind
             WHEN 'gift_certificate' THEN 'gift_certificate'
             ELSE 'customer_credit' END AS sub
      FROM stored_value sv
     WHERE sv.status = 'active'
       AND sv.balance > 0
       AND sv.deleted_at IS NULL
       AND sv.last_activity_at + (v_months || ' months')::interval <= p_as_of
  LOOP
    v_lines := v_lines || CASE WHEN r.party_id IS NOT NULL THEN
        jsonb_build_object('account_id', posting_account(subledger_control_role(r.sub)),
                           'debit', r.balance, 'party_id', r.party_id,
                           'subledger_type_code', r.sub, 'memo','Breakage ' || r.code)
      ELSE
        jsonb_build_object('account_id', posting_account(subledger_control_role(r.sub)),
                           'debit', r.balance, 'memo','Breakage ' || r.code)
      END;
    v_total := v_total + r.balance;

    UPDATE stored_value SET balance = 0, status = 'broken', last_activity_at = p_as_of
     WHERE id = r.id;
    IF (SELECT open_item_id FROM stored_value WHERE id = r.id) IS NOT NULL THEN
      UPDATE open_item SET open_amount = 0, status = 'settled'
       WHERE id = (SELECT open_item_id FROM stored_value WHERE id = r.id);
    END IF;
    INSERT INTO stored_value_activity (stored_value_id, activity_kind, activity_date,
                                       amount, balance_after, memo)
    VALUES (r.id, 'breakage', p_as_of, -r.balance, 0, 'Recognized as breakage income');
  END LOOP;

  IF v_total = 0 THEN RETURN NULL; END IF;

  v_lines := v_lines || jsonb_build_object(
    'account_id', posting_account('gift_certificate_breakage'), 'credit', v_total,
    'memo','Breakage income');

  v_entry := post_journal_entry(p_as_of, 'Stored value breakage', 'breakage',
                                p_as_of::text, v_key, v_lines);
  RETURN v_entry;
END; $$;


--
-- Name: FUNCTION recognize_breakage(p_as_of date, p_idempotency_key text); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.recognize_breakage(p_as_of date, p_idempotency_key text) IS 'OPT-IN breakage recognition. Returns NULL unless tenant_config.breakage_after_months is set (ADR-0032).';


--
-- Name: record_reportable_payment(uuid, date, kernel.money_amount, text, text, uuid, text, text, text); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.record_reportable_payment(p_party_id uuid, p_payment_date date, p_amount kernel.money_amount, p_source text, p_source_ref text DEFAULT NULL::text, p_journal_entry uuid DEFAULT NULL::uuid, p_idempotency_key text DEFAULT NULL::text, p_form_code text DEFAULT '1099-NEC'::text, p_box_code text DEFAULT 'nec'::text) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: FUNCTION record_reportable_payment(p_party_id uuid, p_payment_date date, p_amount kernel.money_amount, p_source text, p_source_ref text, p_journal_entry uuid, p_idempotency_key text, p_form_code text, p_box_code text); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.record_reportable_payment(p_party_id uuid, p_payment_date date, p_amount kernel.money_amount, p_source text, p_source_ref text, p_journal_entry uuid, p_idempotency_key text, p_form_code text, p_box_code text) IS 'Idempotently records a cash-basis reportable payment. Returns NULL for exempt payees or zero amounts.';


--
-- Name: redeem_stored_value(text, kernel.money_amount, date, uuid, uuid); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.redeem_stored_value(p_code text, p_amount kernel.money_amount, p_entry_date date, p_sale_id uuid DEFAULT NULL::uuid, p_entry_id uuid DEFAULT NULL::uuid) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_sv  stored_value;
  v_new numeric;
BEGIN
  IF p_entry_id IS NULL AND p_sale_id IS NULL THEN
    RAISE EXCEPTION
      'redeem_stored_value requires a journal entry or sale for GL linkage; '
      'redeeming without one would break the stored-value control invariant'
      USING ERRCODE='23514';
  END IF;

  SELECT * INTO v_sv FROM stored_value WHERE code = p_code AND deleted_at IS NULL FOR UPDATE;
  IF v_sv.id IS NULL THEN
    RAISE EXCEPTION 'No stored value instrument with code %', p_code USING ERRCODE='23514';
  END IF;
  IF v_sv.status <> 'active' THEN
    RAISE EXCEPTION 'Instrument % is %, not active', p_code, v_sv.status USING ERRCODE='23514';
  END IF;
  IF v_sv.expires_date IS NOT NULL AND p_entry_date > v_sv.expires_date THEN
    RAISE EXCEPTION 'Instrument % expired on %', p_code, v_sv.expires_date USING ERRCODE='23514';
  END IF;
  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'Redemption must be positive, got %', p_amount USING ERRCODE='23514';
  END IF;
  IF p_amount > v_sv.balance THEN
    RAISE EXCEPTION 'Cannot redeem % against a balance of % on %',
      p_amount, v_sv.balance, p_code USING ERRCODE='23514';
  END IF;

  v_new := v_sv.balance - p_amount;

  UPDATE stored_value
     SET balance = v_new,
         status  = CASE WHEN v_new = 0 THEN 'redeemed' ELSE 'active' END,
         last_activity_at = p_entry_date
   WHERE id = v_sv.id;

  -- Keep the open item in step so the subledger still ties to the control.
  IF v_sv.open_item_id IS NOT NULL THEN
    UPDATE open_item
       SET open_amount = open_amount - p_amount,
           status = CASE WHEN open_amount - p_amount = 0 THEN 'settled' ELSE 'partial' END
     WHERE id = v_sv.open_item_id;
  END IF;

  INSERT INTO stored_value_activity (stored_value_id, activity_kind, activity_date,
                                     amount, balance_after, sale_id, journal_entry_id, memo)
  VALUES (v_sv.id, 'redeem', p_entry_date, -p_amount, v_new, p_sale_id, p_entry_id, 'Redeemed');

  RETURN v_sv.id;
END; $$;


--
-- Name: FUNCTION redeem_stored_value(p_code text, p_amount kernel.money_amount, p_entry_date date, p_sale_id uuid, p_entry_id uuid); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.redeem_stored_value(p_code text, p_amount kernel.money_amount, p_entry_date date, p_sale_id uuid, p_entry_id uuid) IS 'Draws down an instrument and keeps its open item in step. GL side comes from the POS tender.';


--
-- Name: renew_lease(uuid, date, kernel.percent_rate); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.renew_lease(p_lease_id uuid, p_new_end_date date, p_escalation_rate kernel.percent_rate DEFAULT NULL::numeric) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: FUNCTION renew_lease(p_lease_id uuid, p_new_end_date date, p_escalation_rate kernel.percent_rate); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.renew_lease(p_lease_id uuid, p_new_end_date date, p_escalation_rate kernel.percent_rate) IS 'Extends a lease term in place, optionally applying a rent escalation from the renewal date.';


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
-- Name: reopen_period(smallint, smallint); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.reopen_period(p_fiscal_year smallint, p_period_no smallint) RETURNS void
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: FUNCTION reopen_period(p_fiscal_year smallint, p_period_no smallint); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.reopen_period(p_fiscal_year smallint, p_period_no smallint) IS 'Reopens a soft-closed period. Hard-locked (year-end) periods refuse.';


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
-- Name: stored_value_activity_immutable(); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.stored_value_activity_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'stored_value_activity is append-only' USING ERRCODE='23514';
END; $$;


--
-- Name: stored_value_control_check(); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.stored_value_control_check() RETURNS TABLE(instrument_kind text, instrument_total numeric, gl_total numeric, difference numeric)
    LANGUAGE sql STABLE
    AS $$
  WITH sv AS (
    SELECT k.kind AS instrument_kind,
           COALESCE((SELECT sum(balance) FROM stored_value s
                      WHERE s.instrument_kind = k.kind AND s.deleted_at IS NULL), 0) AS total
      FROM (VALUES ('gift_certificate'),('store_credit')) AS k(kind)
  ),
  gl AS (
    SELECT 'gift_certificate'::text AS kind,
           COALESCE((SELECT sum(jl.base_credit - jl.base_debit) FROM journal_line jl
                      WHERE jl.account_id = posting_account('gift_certificate_control')),0) AS total
    UNION ALL
    SELECT 'store_credit',
           COALESCE((SELECT sum(jl.base_credit - jl.base_debit) FROM journal_line jl
                      WHERE jl.account_id = posting_account('customer_credit_control')),0)
  )
  SELECT sv.instrument_kind, sv.total, gl.total, sv.total - gl.total
    FROM sv JOIN gl ON gl.kind = sv.instrument_kind;
$$;


--
-- Name: FUNCTION stored_value_control_check(); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.stored_value_control_check() IS 'Invariant: Σ instrument balances must equal the GL liability control (difference = 0).';


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
-- Name: tax_1099_reconciliation_check(smallint); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.tax_1099_reconciliation_check(p_tax_year smallint) RETURNS TABLE(party_id uuid, form_total kernel.money_amount, ledger_total kernel.money_amount, difference kernel.money_amount)
    LANGUAGE sql STABLE
    AS $$
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


--
-- Name: FUNCTION tax_1099_reconciliation_check(p_tax_year smallint); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.tax_1099_reconciliation_check(p_tax_year smallint) IS 'Payees whose captured 1099 total differs from cash paid per the ledger. Empty result = reconciled.';


--
-- Name: tiered_commission(uuid, kernel.money_amount, date); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.tiered_commission(p_agreement_id uuid, p_gross kernel.money_amount, p_as_of date DEFAULT CURRENT_DATE) RETURNS kernel.money_amount
    LANGUAGE plpgsql STABLE
    AS $$
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


--
-- Name: FUNCTION tiered_commission(p_agreement_id uuid, p_gross kernel.money_amount, p_as_of date); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.tiered_commission(p_agreement_id uuid, p_gross kernel.money_amount, p_as_of date) IS 'Marginal tiered commission on a cumulative gross. Each band charged at its own rate (ADR-0037).';


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
-- Name: vendor_draw_available(uuid); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.vendor_draw_available(p_party_id uuid) RETURNS numeric
    LANGUAGE sql STABLE
    AS $$
  SELECT COALESCE(sum(jl.base_credit - jl.base_debit), 0)
    FROM journal_line jl
   WHERE jl.party_id = p_party_id
     AND jl.subledger_type_code IN ('vendor_payable','consignor_payable');
$$;


--
-- Name: FUNCTION vendor_draw_available(p_party_id uuid); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.vendor_draw_available(p_party_id uuid) IS 'Realtime spendable vendor/consignor balance straight from the ledger (ADR-0028).';


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


--
-- Name: write_off_open_item(uuid, date, kernel.money_amount, text, text); Type: FUNCTION; Schema: tenant_demo; Owner: -
--

CREATE FUNCTION tenant_demo.write_off_open_item(p_open_item_id uuid, p_entry_date date, p_amount kernel.money_amount DEFAULT NULL::numeric, p_memo text DEFAULT NULL::text, p_idempotency_key text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: FUNCTION write_off_open_item(p_open_item_id uuid, p_entry_date date, p_amount kernel.money_amount, p_memo text, p_idempotency_key text); Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON FUNCTION tenant_demo.write_off_open_item(p_open_item_id uuid, p_entry_date date, p_amount kernel.money_amount, p_memo text, p_idempotency_key text) IS 'Writes off an uncollectible open item: debit bad debt expense, credit the control, relieve the item.';


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
-- Name: schema_migration; Type: TABLE; Schema: kernel; Owner: -
--

CREATE TABLE kernel.schema_migration (
    tenant_schema text NOT NULL,
    version text NOT NULL,
    filename text NOT NULL,
    checksum text NOT NULL,
    applied_at timestamp with time zone DEFAULT now() NOT NULL,
    applied_by text DEFAULT CURRENT_USER NOT NULL,
    duration_ms integer
);


--
-- Name: TABLE schema_migration; Type: COMMENT; Schema: kernel; Owner: -
--

COMMENT ON TABLE kernel.schema_migration IS 'Applied migrations per tenant schema. Checksums detect edited migrations.';


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
    description text,
    allows_untagged boolean DEFAULT false NOT NULL,
    uses_open_items boolean DEFAULT false NOT NULL
);


--
-- Name: TABLE subledger_type; Type: COMMENT; Schema: kernel; Owner: -
--

COMMENT ON TABLE kernel.subledger_type IS 'Subledger kinds that must tie to a GL control account.';


--
-- Name: COLUMN subledger_type.allows_untagged; Type: COMMENT; Schema: kernel; Owner: -
--

COMMENT ON COLUMN kernel.subledger_type.allows_untagged IS 'True only for genuine BEARER instruments, where there is no party to record.';


--
-- Name: COLUMN subledger_type.uses_open_items; Type: COMMENT; Schema: kernel; Owner: -
--

COMMENT ON COLUMN kernel.subledger_type.uses_open_items IS 'True when this subledger''s detail lives in open_item; drives open_item_control_check scoping.';


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
-- Name: cam_pool; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.cam_pool (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    location_id uuid NOT NULL,
    pool_year smallint NOT NULL,
    period_start date NOT NULL,
    period_end date NOT NULL,
    admin_fee_rate kernel.percent_rate DEFAULT 0 NOT NULL,
    status text DEFAULT 'open'::text NOT NULL,
    currency kernel.currency_code DEFAULT 'USD'::bpchar NOT NULL,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    CONSTRAINT cam_pool_check CHECK ((period_end >= period_start)),
    CONSTRAINT cam_pool_status_check CHECK ((status = ANY (ARRAY['open'::text, 'reconciled'::text, 'closed'::text])))
);

ALTER TABLE ONLY tenant_demo.cam_pool FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE cam_pool; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.cam_pool IS 'Annual recoverable CAM cost pool for a location. Reconciled against estimates billed.';


--
-- Name: cam_pool_expense; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.cam_pool_expense (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    cam_pool_id uuid NOT NULL,
    expense_date date NOT NULL,
    category text NOT NULL,
    amount kernel.money_amount NOT NULL,
    currency kernel.currency_code DEFAULT 'USD'::bpchar NOT NULL,
    is_recoverable boolean DEFAULT true NOT NULL,
    exclusion_reason text,
    journal_entry_id uuid,
    description text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    CONSTRAINT cam_pool_expense_check CHECK ((is_recoverable OR (exclusion_reason IS NOT NULL)))
);

ALTER TABLE ONLY tenant_demo.cam_pool_expense FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE cam_pool_expense; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.cam_pool_expense IS 'Individual costs in a CAM pool. is_recoverable=false keeps non-recoverable spend visible but excluded.';


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
-- Name: commission_trueup; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.commission_trueup (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    agreement_id uuid NOT NULL,
    consignor_party_id uuid NOT NULL,
    period_start date NOT NULL,
    period_end date NOT NULL,
    gross_sales kernel.money_amount DEFAULT 0 NOT NULL,
    accrued_commission kernel.money_amount DEFAULT 0 NOT NULL,
    correct_commission kernel.money_amount DEFAULT 0 NOT NULL,
    adjustment_amount kernel.money_amount DEFAULT 0 NOT NULL,
    currency kernel.currency_code DEFAULT 'USD'::bpchar NOT NULL,
    effective_rate kernel.percent_rate,
    status text DEFAULT 'draft'::text NOT NULL,
    journal_entry_id uuid,
    note text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    CONSTRAINT commission_trueup_check CHECK ((period_end >= period_start)),
    CONSTRAINT commission_trueup_check1 CHECK (((adjustment_amount)::numeric = ((correct_commission)::numeric - (accrued_commission)::numeric))),
    CONSTRAINT commission_trueup_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'posted'::text, 'voided'::text])))
);

ALTER TABLE ONLY tenant_demo.commission_trueup FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE commission_trueup; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.commission_trueup IS 'Period adjustment reconciling sale-time commission accrual to the correct tiered rate (ADR-0037).';


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
    CONSTRAINT consignment_item_status_check CHECK ((status = ANY (ARRAY['received'::text, 'available'::text, 'reserved'::text, 'sold'::text, 'returned'::text, 'withdrawn'::text, 'lost'::text])))
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
-- Name: COLUMN fiscal_period.status; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON COLUMN tenant_demo.fiscal_period.status IS 'open = postings allowed; closed = soft lock (reopenable); locked = hard lock after year-end close.';


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
-- Name: inventory_item; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.inventory_item (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    sku text NOT NULL,
    description text NOT NULL,
    category text,
    supplier_party_id uuid,
    uom text DEFAULT 'each'::text NOT NULL,
    on_hand numeric(19,4) DEFAULT 0 NOT NULL,
    avg_cost kernel.money_amount DEFAULT 0 NOT NULL,
    currency kernel.currency_code DEFAULT 'USD'::bpchar NOT NULL,
    reorder_point numeric(19,4),
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    deleted_at timestamp with time zone,
    deleted_by uuid,
    CONSTRAINT inventory_item_avg_cost_check CHECK (((avg_cost)::numeric >= (0)::numeric)),
    CONSTRAINT inventory_item_on_hand_check CHECK ((on_hand >= (0)::numeric))
);

ALTER TABLE ONLY tenant_demo.inventory_item FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE inventory_item; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.inventory_item IS 'Owned-goods SKU with moving weighted-average cost (ADR-0031). Consigned goods are excluded.';


--
-- Name: inventory_movement; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.inventory_movement (
    id bigint NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    item_id uuid NOT NULL,
    movement_kind text NOT NULL,
    movement_date date DEFAULT CURRENT_DATE NOT NULL,
    quantity numeric(19,4) NOT NULL,
    unit_cost kernel.money_amount NOT NULL,
    extended_cost kernel.money_amount NOT NULL,
    currency kernel.currency_code DEFAULT 'USD'::bpchar NOT NULL,
    on_hand_after numeric(19,4) NOT NULL,
    avg_cost_after kernel.money_amount NOT NULL,
    source text DEFAULT 'manual'::text NOT NULL,
    source_ref text,
    sale_line_id uuid,
    journal_entry_id uuid,
    memo text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    CONSTRAINT inventory_movement_check CHECK (((extended_cost)::numeric = round((quantity * (unit_cost)::numeric), 4))),
    CONSTRAINT inventory_movement_movement_kind_check CHECK ((movement_kind = ANY (ARRAY['receipt'::text, 'issue'::text, 'adjustment'::text, 'return_to_supplier'::text, 'customer_return'::text]))),
    CONSTRAINT inventory_movement_quantity_check CHECK ((quantity <> (0)::numeric)),
    CONSTRAINT inventory_movement_unit_cost_check CHECK (((unit_cost)::numeric >= (0)::numeric))
);

ALTER TABLE ONLY tenant_demo.inventory_movement FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE inventory_movement; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.inventory_movement IS 'Append-only inventory ledger. Never edited; corrections are new movements.';


--
-- Name: inventory_movement_id_seq; Type: SEQUENCE; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.inventory_movement ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME tenant_demo.inventory_movement_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


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
-- Name: layaway; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.layaway (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    layaway_no bigint NOT NULL,
    customer_party_id uuid NOT NULL,
    opened_date date DEFAULT CURRENT_DATE NOT NULL,
    due_date date,
    goods_total kernel.money_amount DEFAULT 0 NOT NULL,
    tax_total kernel.money_amount DEFAULT 0 NOT NULL,
    total kernel.money_amount DEFAULT 0 NOT NULL,
    paid_total kernel.money_amount DEFAULT 0 NOT NULL,
    currency kernel.currency_code DEFAULT 'USD'::bpchar NOT NULL,
    cancellation_fee kernel.money_amount DEFAULT 0 NOT NULL,
    status text DEFAULT 'open'::text NOT NULL,
    sale_id uuid,
    closed_date date,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    CONSTRAINT layaway_cancellation_fee_check CHECK (((cancellation_fee)::numeric >= (0)::numeric)),
    CONSTRAINT layaway_check CHECK (((total)::numeric = ((goods_total)::numeric + (tax_total)::numeric))),
    CONSTRAINT layaway_check1 CHECK (((paid_total)::numeric <= (total)::numeric)),
    CONSTRAINT layaway_check2 CHECK (((status = 'open'::text) OR (closed_date IS NOT NULL))),
    CONSTRAINT layaway_check3 CHECK (((status <> 'completed'::text) OR (sale_id IS NOT NULL))),
    CONSTRAINT layaway_goods_total_check CHECK (((goods_total)::numeric >= (0)::numeric)),
    CONSTRAINT layaway_paid_total_check CHECK (((paid_total)::numeric >= (0)::numeric)),
    CONSTRAINT layaway_status_check CHECK ((status = ANY (ARRAY['open'::text, 'completed'::text, 'cancelled'::text, 'defaulted'::text]))),
    CONSTRAINT layaway_tax_total_check CHECK (((tax_total)::numeric >= (0)::numeric)),
    CONSTRAINT layaway_total_check CHECK (((total)::numeric >= (0)::numeric))
);

ALTER TABLE ONLY tenant_demo.layaway FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE layaway; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.layaway IS 'Customer layaway order. Deposits are a LIABILITY until pickup, never revenue (ADR-0036).';


--
-- Name: layaway_layaway_no_seq; Type: SEQUENCE; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.layaway ALTER COLUMN layaway_no ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME tenant_demo.layaway_layaway_no_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: layaway_line; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.layaway_line (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    layaway_id uuid NOT NULL,
    line_no integer NOT NULL,
    consignment_item_id uuid,
    inventory_item_id uuid,
    description text NOT NULL,
    quantity kernel.quantity DEFAULT 1 NOT NULL,
    unit_price kernel.money_amount NOT NULL,
    extended_price kernel.money_amount NOT NULL,
    currency kernel.currency_code DEFAULT 'USD'::bpchar NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    CONSTRAINT layaway_line_check CHECK (((extended_price)::numeric = ((quantity)::numeric * (unit_price)::numeric))),
    CONSTRAINT layaway_line_check1 CHECK (((consignment_item_id IS NOT NULL) <> (inventory_item_id IS NOT NULL))),
    CONSTRAINT layaway_line_extended_price_check CHECK (((extended_price)::numeric >= (0)::numeric)),
    CONSTRAINT layaway_line_quantity_check CHECK (((quantity)::numeric > (0)::numeric)),
    CONSTRAINT layaway_line_unit_price_check CHECK (((unit_price)::numeric >= (0)::numeric))
);

ALTER TABLE ONLY tenant_demo.layaway_line FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE layaway_line; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.layaway_line IS 'Goods reserved against a layaway. Reserved is not sold.';


--
-- Name: layaway_payment; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.layaway_payment (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    layaway_id uuid NOT NULL,
    payment_date date DEFAULT CURRENT_DATE NOT NULL,
    amount kernel.money_amount NOT NULL,
    currency kernel.currency_code DEFAULT 'USD'::bpchar NOT NULL,
    tender_type_code text,
    journal_entry_id uuid,
    idempotency_key text,
    note text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    CONSTRAINT layaway_payment_amount_check CHECK (((amount)::numeric <> (0)::numeric))
);

ALTER TABLE ONLY tenant_demo.layaway_payment FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE layaway_payment; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.layaway_payment IS 'Append-only staged payments against a layaway. Negative amounts are refunds.';


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
-- Name: lease_sales_report; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.lease_sales_report (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    lease_id uuid NOT NULL,
    period_start date NOT NULL,
    period_end date NOT NULL,
    reported_amount kernel.money_amount NOT NULL,
    pos_amount kernel.money_amount,
    currency kernel.currency_code DEFAULT 'USD'::bpchar NOT NULL,
    source text DEFAULT 'tenant_reported'::text NOT NULL,
    received_date date DEFAULT CURRENT_DATE NOT NULL,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    CONSTRAINT lease_sales_report_check CHECK ((period_end >= period_start)),
    CONSTRAINT lease_sales_report_reported_amount_check CHECK (((reported_amount)::numeric >= (0)::numeric)),
    CONSTRAINT lease_sales_report_source_check CHECK ((source = ANY (ARRAY['tenant_reported'::text, 'pos'::text, 'audited'::text])))
);

ALTER TABLE ONLY tenant_demo.lease_sales_report FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE lease_sales_report; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.lease_sales_report IS 'Sales reported by a lessee for a period. Drives percentage rent. pos_amount records the variance.';


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
-- Name: markdown_event; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.markdown_event (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    consignment_item_id uuid,
    inventory_item_id uuid,
    reason_code text NOT NULL,
    old_price kernel.money_amount NOT NULL,
    new_price kernel.money_amount NOT NULL,
    currency kernel.currency_code DEFAULT 'USD'::bpchar NOT NULL,
    absorbed_by text DEFAULT 'store'::text NOT NULL,
    share_store_rate kernel.percent_rate,
    effective_from date DEFAULT CURRENT_DATE NOT NULL,
    effective_thru date,
    approved_by uuid,
    note text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    CONSTRAINT markdown_event_absorbed_by_check CHECK ((absorbed_by = ANY (ARRAY['store'::text, 'consignor'::text, 'shared'::text]))),
    CONSTRAINT markdown_event_check CHECK (((consignment_item_id IS NOT NULL) <> (inventory_item_id IS NOT NULL))),
    CONSTRAINT markdown_event_check1 CHECK (((new_price)::numeric < (old_price)::numeric)),
    CONSTRAINT markdown_event_check2 CHECK ((((absorbed_by = 'shared'::text) AND (share_store_rate IS NOT NULL) AND ((share_store_rate)::numeric > (0)::numeric) AND ((share_store_rate)::numeric < (1)::numeric)) OR ((absorbed_by <> 'shared'::text) AND (share_store_rate IS NULL)))),
    CONSTRAINT markdown_event_check3 CHECK (((effective_thru IS NULL) OR (effective_thru >= effective_from))),
    CONSTRAINT markdown_event_new_price_check CHECK (((new_price)::numeric >= (0)::numeric)),
    CONSTRAINT markdown_event_old_price_check CHECK (((old_price)::numeric >= (0)::numeric))
);

ALTER TABLE ONLY tenant_demo.markdown_event FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE markdown_event; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.markdown_event IS 'Append-only record of deliberate price reductions, including who absorbs the cost (ADR-0036).';


--
-- Name: markdown_reason; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.markdown_reason (
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    description text,
    default_absorbed_by text DEFAULT 'store'::text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT markdown_reason_default_absorbed_by_check CHECK ((default_absorbed_by = ANY (ARRAY['store'::text, 'consignor'::text, 'shared'::text])))
);

ALTER TABLE ONLY tenant_demo.markdown_reason FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE markdown_reason; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.markdown_reason IS 'Why a price was reduced, and who absorbs it by default. Drives buying and supplier decisions.';


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
    item_kind text DEFAULT 'invoice'::text NOT NULL,
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
    CONSTRAINT open_item_item_kind_check CHECK ((item_kind = ANY (ARRAY['invoice'::text, 'credit_memo'::text]))),
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
-- Name: COLUMN open_item.item_kind; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON COLUMN tenant_demo.open_item.item_kind IS 'invoice = the party owes this; credit_memo = the direction is reversed. Amounts stay non-negative on both.';


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
    created_by uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
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
-- Name: payee_tax_profile; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.payee_tax_profile (
    party_id uuid NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    is_exempt boolean DEFAULT false NOT NULL,
    exempt_reason text,
    w9_received_date date,
    tin_type text,
    backup_withholding boolean DEFAULT false NOT NULL,
    backup_withholding_rate kernel.percent_rate,
    recipient_name text,
    recipient_address text,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    CONSTRAINT payee_tax_profile_check CHECK (((NOT is_exempt) OR (exempt_reason IS NOT NULL))),
    CONSTRAINT payee_tax_profile_check1 CHECK (((NOT backup_withholding) OR (backup_withholding_rate IS NOT NULL))),
    CONSTRAINT payee_tax_profile_tin_type_check CHECK ((tin_type = ANY (ARRAY['ssn'::text, 'ein'::text, 'itin'::text])))
);

ALTER TABLE ONLY tenant_demo.payee_tax_profile FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE payee_tax_profile; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.payee_tax_profile IS '1099 filing status per payee: TIN on file, W-9, exemption, backup withholding.';


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
    created_by uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
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
    inventory_item_id uuid,
    CONSTRAINT ck_sale_line_consignment_no_inventory CHECK (((line_kind <> 'consignment'::text) OR (inventory_item_id IS NULL))),
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
-- Name: COLUMN sale_line.inventory_item_id; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON COLUMN tenant_demo.sale_line.inventory_item_id IS 'Owned lines only. NULL = untracked (service/one-off). Consigned lines must leave this NULL (ADR-0031).';


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
-- Name: stored_value; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.stored_value (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    instrument_kind text NOT NULL,
    code text NOT NULL,
    party_id uuid,
    original_amount kernel.money_amount NOT NULL,
    balance kernel.money_amount NOT NULL,
    currency kernel.currency_code DEFAULT 'USD'::bpchar NOT NULL,
    issued_date date DEFAULT CURRENT_DATE NOT NULL,
    expires_date date,
    last_activity_at date DEFAULT CURRENT_DATE NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    origin text DEFAULT 'manual'::text NOT NULL,
    origin_ref text,
    journal_entry_id uuid,
    open_item_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid DEFAULT kernel.current_actor(),
    version integer DEFAULT 1 NOT NULL,
    deleted_at timestamp with time zone,
    deleted_by uuid,
    CONSTRAINT stored_value_balance_check CHECK (((balance)::numeric >= (0)::numeric)),
    CONSTRAINT stored_value_check CHECK (((balance)::numeric <= (original_amount)::numeric)),
    CONSTRAINT stored_value_check1 CHECK (((instrument_kind <> 'store_credit'::text) OR (party_id IS NOT NULL))),
    CONSTRAINT stored_value_check2 CHECK (((expires_date IS NULL) OR (expires_date >= issued_date))),
    CONSTRAINT stored_value_instrument_kind_check CHECK ((instrument_kind = ANY (ARRAY['gift_certificate'::text, 'store_credit'::text]))),
    CONSTRAINT stored_value_original_amount_check CHECK (((original_amount)::numeric > (0)::numeric)),
    CONSTRAINT stored_value_status_check CHECK ((status = ANY (ARRAY['active'::text, 'redeemed'::text, 'expired'::text, 'voided'::text, 'broken'::text])))
);

ALTER TABLE ONLY tenant_demo.stored_value FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE stored_value; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.stored_value IS 'Gift certificates and store credit. Issuance creates a liability, never revenue (ADR-0032).';


--
-- Name: stored_value_activity; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.stored_value_activity (
    id bigint NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    stored_value_id uuid NOT NULL,
    activity_kind text NOT NULL,
    activity_date date DEFAULT CURRENT_DATE NOT NULL,
    amount kernel.money_amount NOT NULL,
    balance_after kernel.money_amount NOT NULL,
    sale_id uuid,
    journal_entry_id uuid,
    memo text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    CONSTRAINT stored_value_activity_activity_kind_check CHECK ((activity_kind = ANY (ARRAY['issue'::text, 'redeem'::text, 'reload'::text, 'void'::text, 'expire'::text, 'breakage'::text]))),
    CONSTRAINT stored_value_activity_amount_check CHECK (((amount)::numeric <> (0)::numeric)),
    CONSTRAINT stored_value_activity_balance_after_check CHECK (((balance_after)::numeric >= (0)::numeric))
);

ALTER TABLE ONLY tenant_demo.stored_value_activity FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE stored_value_activity; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.stored_value_activity IS 'Append-only per-instrument history. Never edited.';


--
-- Name: stored_value_activity_id_seq; Type: SEQUENCE; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.stored_value_activity ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME tenant_demo.stored_value_activity_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: tax_form_threshold; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.tax_form_threshold (
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    form_code text NOT NULL,
    box_code text NOT NULL,
    tax_year smallint NOT NULL,
    threshold_amount kernel.money_amount NOT NULL,
    currency kernel.currency_code DEFAULT 'USD'::bpchar NOT NULL,
    note text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT tax_form_threshold_form_code_check CHECK ((form_code = ANY (ARRAY['1099-NEC'::text, '1099-MISC'::text]))),
    CONSTRAINT tax_form_threshold_tax_year_check CHECK (((tax_year >= 2000) AND (tax_year <= 2100))),
    CONSTRAINT tax_form_threshold_threshold_amount_check CHECK (((threshold_amount)::numeric >= (0)::numeric))
);

ALTER TABLE ONLY tenant_demo.tax_form_threshold FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE tax_form_threshold; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.tax_form_threshold IS 'Reportable minimum per form/box/tax year. Data, not a constant: thresholds are legislated and change.';


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
-- Name: tax_year_payment; Type: TABLE; Schema: tenant_demo; Owner: -
--

CREATE TABLE tenant_demo.tax_year_payment (
    id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid DEFAULT kernel.current_tenant() NOT NULL,
    party_id uuid NOT NULL,
    tax_year smallint NOT NULL,
    form_code text DEFAULT '1099-NEC'::text NOT NULL,
    box_code text DEFAULT 'nec'::text NOT NULL,
    payment_date date NOT NULL,
    amount kernel.money_amount NOT NULL,
    currency kernel.currency_code DEFAULT 'USD'::bpchar NOT NULL,
    withheld_amount kernel.money_amount DEFAULT 0 NOT NULL,
    source text NOT NULL,
    source_ref text,
    journal_entry_id uuid,
    idempotency_key text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT kernel.current_actor(),
    CONSTRAINT tax_year_payment_check CHECK ((tax_year = (EXTRACT(year FROM payment_date))::smallint)),
    CONSTRAINT tax_year_payment_form_code_check CHECK ((form_code = ANY (ARRAY['1099-NEC'::text, '1099-MISC'::text]))),
    CONSTRAINT tax_year_payment_withheld_amount_check CHECK (((withheld_amount)::numeric >= (0)::numeric))
);

ALTER TABLE ONLY tenant_demo.tax_year_payment FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE tax_year_payment; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.tax_year_payment IS 'Append-only cash-basis payment ledger feeding 1099 extracts. Negative amounts are corrections.';


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
    breakage_after_months smallint,
    CONSTRAINT tenant_config_fiscal_year_start_month_check CHECK (((fiscal_year_start_month >= 1) AND (fiscal_year_start_month <= 12)))
);

ALTER TABLE ONLY tenant_demo.tenant_config FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE tenant_config; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON TABLE tenant_demo.tenant_config IS 'One row per tenant. functional_currency is the ledger base currency.';


--
-- Name: COLUMN tenant_config.breakage_after_months; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON COLUMN tenant_demo.tenant_config.breakage_after_months IS 'Months of inactivity after which unredeemed stored value MAY be recognised as breakage income. NULL = never (default). Check state escheatment law before setting (ADR-0032).';


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
-- Name: v_1099_summary; Type: VIEW; Schema: tenant_demo; Owner: -
--

CREATE VIEW tenant_demo.v_1099_summary AS
 SELECT tax_year,
    form_code,
    count(DISTINCT party_id) AS payee_count,
    sum((amount)::numeric) AS total_paid,
    sum((withheld_amount)::numeric) AS total_withheld
   FROM tenant_demo.tax_year_payment
  WHERE (tenant_id = kernel.current_tenant())
  GROUP BY tax_year, form_code
  ORDER BY tax_year DESC, form_code;


--
-- Name: VIEW v_1099_summary; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON VIEW tenant_demo.v_1099_summary IS 'Per-year 1099 totals across all payees.';


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
    oi.item_kind,
    oi.original_amount,
    oi.open_amount,
    tenant_demo.open_item_signed(oi.item_kind, oi.open_amount) AS signed_amount,
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
            WHEN (days_outstanding <= 30) THEN (signed_amount)::numeric
            ELSE (0)::numeric
        END) AS bucket_0_30,
    sum(
        CASE
            WHEN ((days_outstanding >= 31) AND (days_outstanding <= 60)) THEN (signed_amount)::numeric
            ELSE (0)::numeric
        END) AS bucket_31_60,
    sum(
        CASE
            WHEN ((days_outstanding >= 61) AND (days_outstanding <= 90)) THEN (signed_amount)::numeric
            ELSE (0)::numeric
        END) AS bucket_61_90,
    sum(
        CASE
            WHEN (days_outstanding > 90) THEN (signed_amount)::numeric
            ELSE (0)::numeric
        END) AS bucket_90_plus,
    sum((signed_amount)::numeric) AS total_open
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
-- Name: v_commission_trueup_pending; Type: VIEW; Schema: tenant_demo; Owner: -
--

CREATE VIEW tenant_demo.v_commission_trueup_pending AS
 SELECT ca.id AS agreement_id,
    ca.agreement_no,
    p.display_name AS consignor_name,
    ca.settlement_frequency,
    count(cr.id) AS tier_count
   FROM ((tenant_demo.consignor_agreement ca
     JOIN tenant_demo.party p ON ((p.id = ca.consignor_party_id)))
     JOIN tenant_demo.commission_rule cr ON (((cr.agreement_id = ca.id) AND (cr.rule_type = 'tiered'::text))))
  WHERE ((ca.status = 'active'::text) AND (ca.deleted_at IS NULL))
  GROUP BY ca.id, ca.agreement_no, p.display_name, ca.settlement_frequency
  ORDER BY ca.agreement_no;


--
-- Name: VIEW v_commission_trueup_pending; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON VIEW tenant_demo.v_commission_trueup_pending IS 'Active agreements carrying tiered commission rules; these need periodic true-up.';


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
-- Name: v_layaway_aging; Type: VIEW; Schema: tenant_demo; Owner: -
--

CREATE VIEW tenant_demo.v_layaway_aging AS
 SELECT l.id,
    l.layaway_no,
    p.display_name AS customer_name,
    l.opened_date,
    l.due_date,
    l.total,
    l.paid_total,
    ((l.total)::numeric - (l.paid_total)::numeric) AS balance_due,
        CASE
            WHEN (l.due_date IS NULL) THEN NULL::integer
            ELSE (CURRENT_DATE - l.due_date)
        END AS days_overdue,
    l.status
   FROM (tenant_demo.layaway l
     JOIN tenant_demo.party p ON ((p.id = l.customer_party_id)))
  WHERE (l.status = 'open'::text)
  ORDER BY l.due_date, l.opened_date;


--
-- Name: VIEW v_layaway_aging; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON VIEW tenant_demo.v_layaway_aging IS 'Open layaways with balance due and days overdue.';


--
-- Name: v_lease_expiring; Type: VIEW; Schema: tenant_demo; Owner: -
--

CREATE VIEW tenant_demo.v_lease_expiring AS
 SELECT l.id AS lease_id,
    l.lease_no,
    l.lessee_party_id,
    p.display_name AS lessee_name,
    l.location_id,
    l.start_date,
    l.end_date,
    (l.end_date - CURRENT_DATE) AS days_remaining,
    l.status
   FROM (tenant_demo.lease l
     JOIN tenant_demo.party p ON ((p.id = l.lessee_party_id)))
  WHERE ((l.tenant_id = kernel.current_tenant()) AND (l.deleted_at IS NULL) AND (l.status = ANY (ARRAY['active'::text, 'draft'::text])) AND (l.end_date IS NOT NULL))
  ORDER BY l.end_date;


--
-- Name: VIEW v_lease_expiring; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON VIEW tenant_demo.v_lease_expiring IS 'Leases with an end date, nearest first. Renewal worklist.';


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
-- Name: v_sale_margin; Type: VIEW; Schema: tenant_demo; Owner: -
--

CREATE VIEW tenant_demo.v_sale_margin AS
 SELECT s.id AS sale_id,
    s.sale_no,
    s.sale_date,
    s.total,
    COALESCE(sum((sl.extended_price)::numeric) FILTER (WHERE (sl.line_kind = 'owned'::text)), (0)::numeric) AS owned_revenue,
    COALESCE(sum((sl.extended_price)::numeric) FILTER (WHERE (sl.line_kind = 'consignment'::text)), (0)::numeric) AS consignment_revenue,
    COALESCE(sum((sl.commission_amount)::numeric) FILTER (WHERE (sl.line_kind = 'consignment'::text)), (0)::numeric) AS commission_earned,
    COALESCE((- ( SELECT sum((m.extended_cost)::numeric) AS sum
           FROM (tenant_demo.inventory_movement m
             JOIN tenant_demo.sale_line x ON ((x.id = m.sale_line_id)))
          WHERE ((x.sale_id = s.id) AND (m.movement_kind = 'issue'::text)))), (0)::numeric) AS owned_cogs,
    ((COALESCE(sum((sl.extended_price)::numeric) FILTER (WHERE (sl.line_kind = 'owned'::text)), (0)::numeric) + (COALESCE((- ( SELECT sum((m.extended_cost)::numeric) AS sum
           FROM (tenant_demo.inventory_movement m
             JOIN tenant_demo.sale_line x ON ((x.id = m.sale_line_id)))
          WHERE ((x.sale_id = s.id) AND (m.movement_kind = 'issue'::text)))), (0)::numeric) * ('-1'::integer)::numeric)) + COALESCE(sum((sl.commission_amount)::numeric) FILTER (WHERE (sl.line_kind = 'consignment'::text)), (0)::numeric)) AS gross_margin
   FROM (tenant_demo.sale s
     LEFT JOIN tenant_demo.sale_line sl ON ((sl.sale_id = s.id)))
  GROUP BY s.id, s.sale_no, s.sale_date, s.total;


--
-- Name: VIEW v_sale_margin; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON VIEW tenant_demo.v_sale_margin IS 'Realtime per-sale margin: owned (price - COGS) plus consignment commission.';


--
-- Name: v_stored_value_outstanding; Type: VIEW; Schema: tenant_demo; Owner: -
--

CREATE VIEW tenant_demo.v_stored_value_outstanding AS
 SELECT sv.instrument_kind,
    sv.code,
    sv.party_id,
    p.display_name AS party_name,
    sv.original_amount,
    sv.balance,
    sv.issued_date,
    sv.expires_date,
    sv.last_activity_at,
    (CURRENT_DATE - sv.last_activity_at) AS days_inactive,
    sv.status
   FROM (tenant_demo.stored_value sv
     LEFT JOIN tenant_demo.party p ON ((p.id = sv.party_id)))
  WHERE ((sv.status = 'active'::text) AND ((sv.balance)::numeric > (0)::numeric) AND (sv.deleted_at IS NULL));


--
-- Name: VIEW v_stored_value_outstanding; Type: COMMENT; Schema: tenant_demo; Owner: -
--

COMMENT ON VIEW tenant_demo.v_stored_value_outstanding IS 'Outstanding stored-value liability with inactivity aging.';


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
-- Name: schema_migration schema_migration_pkey; Type: CONSTRAINT; Schema: kernel; Owner: -
--

ALTER TABLE ONLY kernel.schema_migration
    ADD CONSTRAINT schema_migration_pkey PRIMARY KEY (tenant_schema, version);


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
-- Name: cam_pool_expense cam_pool_expense_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.cam_pool_expense
    ADD CONSTRAINT cam_pool_expense_pkey PRIMARY KEY (id);


--
-- Name: cam_pool cam_pool_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.cam_pool
    ADD CONSTRAINT cam_pool_pkey PRIMARY KEY (id);


--
-- Name: cam_pool cam_pool_tenant_id_location_id_pool_year_key; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.cam_pool
    ADD CONSTRAINT cam_pool_tenant_id_location_id_pool_year_key UNIQUE (tenant_id, location_id, pool_year);


--
-- Name: commission_rule commission_rule_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.commission_rule
    ADD CONSTRAINT commission_rule_pkey PRIMARY KEY (id);


--
-- Name: commission_trueup commission_trueup_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.commission_trueup
    ADD CONSTRAINT commission_trueup_pkey PRIMARY KEY (id);


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
    ADD CONSTRAINT ex_commission_rule_no_overlap EXCLUDE USING gist (agreement_id WITH =, rule_type WITH =, COALESCE((breakpoint_amount)::numeric, ('-1'::integer)::numeric) WITH =, daterange(effective_from, effective_thru, '[]'::text) WITH &&);


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
-- Name: inventory_item inventory_item_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.inventory_item
    ADD CONSTRAINT inventory_item_pkey PRIMARY KEY (id);


--
-- Name: inventory_movement inventory_movement_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.inventory_movement
    ADD CONSTRAINT inventory_movement_pkey PRIMARY KEY (id);


--
-- Name: item_price_change item_price_change_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.item_price_change
    ADD CONSTRAINT item_price_change_pkey PRIMARY KEY (id);


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
-- Name: layaway_line layaway_line_layaway_id_line_no_key; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.layaway_line
    ADD CONSTRAINT layaway_line_layaway_id_line_no_key UNIQUE (layaway_id, line_no);


--
-- Name: layaway_line layaway_line_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.layaway_line
    ADD CONSTRAINT layaway_line_pkey PRIMARY KEY (id);


--
-- Name: layaway_payment layaway_payment_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.layaway_payment
    ADD CONSTRAINT layaway_payment_pkey PRIMARY KEY (id);


--
-- Name: layaway layaway_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.layaway
    ADD CONSTRAINT layaway_pkey PRIMARY KEY (id);


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
-- Name: lease_sales_report lease_sales_report_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.lease_sales_report
    ADD CONSTRAINT lease_sales_report_pkey PRIMARY KEY (id);


--
-- Name: lease_sales_report lease_sales_report_tenant_id_lease_id_period_start_period_e_key; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.lease_sales_report
    ADD CONSTRAINT lease_sales_report_tenant_id_lease_id_period_start_period_e_key UNIQUE (tenant_id, lease_id, period_start, period_end);


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
-- Name: markdown_event markdown_event_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.markdown_event
    ADD CONSTRAINT markdown_event_pkey PRIMARY KEY (id);


--
-- Name: markdown_reason markdown_reason_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.markdown_reason
    ADD CONSTRAINT markdown_reason_pkey PRIMARY KEY (tenant_id, code);


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
-- Name: payee_tax_profile payee_tax_profile_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.payee_tax_profile
    ADD CONSTRAINT payee_tax_profile_pkey PRIMARY KEY (party_id);


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
-- Name: stored_value_activity stored_value_activity_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.stored_value_activity
    ADD CONSTRAINT stored_value_activity_pkey PRIMARY KEY (id);


--
-- Name: stored_value stored_value_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.stored_value
    ADD CONSTRAINT stored_value_pkey PRIMARY KEY (id);


--
-- Name: tax_form_threshold tax_form_threshold_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.tax_form_threshold
    ADD CONSTRAINT tax_form_threshold_pkey PRIMARY KEY (tenant_id, form_code, box_code, tax_year);


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
-- Name: tax_year_payment tax_year_payment_pkey; Type: CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.tax_year_payment
    ADD CONSTRAINT tax_year_payment_pkey PRIMARY KEY (id);


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
-- Name: ix_cam_pool_expense_pool; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_cam_pool_expense_pool ON tenant_demo.cam_pool_expense USING btree (cam_pool_id);


--
-- Name: ix_commission_rule_agreement; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_commission_rule_agreement ON tenant_demo.commission_rule USING btree (agreement_id);


--
-- Name: ix_commission_trueup_party; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_commission_trueup_party ON tenant_demo.commission_trueup USING btree (consignor_party_id);


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
-- Name: ix_inventory_item_active; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_inventory_item_active ON tenant_demo.inventory_item USING btree (tenant_id, is_active) WHERE (deleted_at IS NULL);


--
-- Name: ix_inventory_movement_entry; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_inventory_movement_entry ON tenant_demo.inventory_movement USING btree (journal_entry_id);


--
-- Name: ix_inventory_movement_item; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_inventory_movement_item ON tenant_demo.inventory_movement USING btree (item_id, movement_date);


--
-- Name: ix_inventory_movement_saleline; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_inventory_movement_saleline ON tenant_demo.inventory_movement USING btree (sale_line_id);


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
-- Name: ix_layaway_customer; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_layaway_customer ON tenant_demo.layaway USING btree (customer_party_id);


--
-- Name: ix_layaway_line_layaway; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_layaway_line_layaway ON tenant_demo.layaway_line USING btree (layaway_id);


--
-- Name: ix_layaway_payment_layaway; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_layaway_payment_layaway ON tenant_demo.layaway_payment USING btree (layaway_id);


--
-- Name: ix_layaway_status; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_layaway_status ON tenant_demo.layaway USING btree (tenant_id, status);


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
-- Name: ix_lease_sales_report_lease; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_lease_sales_report_lease ON tenant_demo.lease_sales_report USING btree (lease_id, period_start);


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
-- Name: ix_markdown_event_citem; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_markdown_event_citem ON tenant_demo.markdown_event USING btree (consignment_item_id) WHERE (consignment_item_id IS NOT NULL);


--
-- Name: ix_markdown_event_effective; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_markdown_event_effective ON tenant_demo.markdown_event USING btree (tenant_id, effective_from);


--
-- Name: ix_markdown_event_iitem; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_markdown_event_iitem ON tenant_demo.markdown_event USING btree (inventory_item_id) WHERE (inventory_item_id IS NOT NULL);


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
-- Name: ix_sale_line_inventory; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_sale_line_inventory ON tenant_demo.sale_line USING btree (inventory_item_id);


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
-- Name: ix_stored_value_active; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_stored_value_active ON tenant_demo.stored_value USING btree (tenant_id, instrument_kind, status) WHERE ((status = 'active'::text) AND (deleted_at IS NULL));


--
-- Name: ix_stored_value_party; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_stored_value_party ON tenant_demo.stored_value USING btree (tenant_id, party_id) WHERE (deleted_at IS NULL);


--
-- Name: ix_sv_activity_instrument; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_sv_activity_instrument ON tenant_demo.stored_value_activity USING btree (stored_value_id, activity_date);


--
-- Name: ix_tax_year_payment_party_year; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_tax_year_payment_party_year ON tenant_demo.tax_year_payment USING btree (tenant_id, party_id, tax_year);


--
-- Name: ix_tax_year_payment_year; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_tax_year_payment_year ON tenant_demo.tax_year_payment USING btree (tenant_id, tax_year, form_code);


--
-- Name: ix_waitlist_open; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_waitlist_open ON tenant_demo.waitlist USING btree (tenant_id, requested_at) WHERE (status = 'waiting'::text);


--
-- Name: ix_waitlist_party; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE INDEX ix_waitlist_party ON tenant_demo.waitlist USING btree (party_id);


--
-- Name: ux_commission_trueup_period; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE UNIQUE INDEX ux_commission_trueup_period ON tenant_demo.commission_trueup USING btree (tenant_id, agreement_id, period_start, period_end) WHERE (status <> 'voided'::text);


--
-- Name: ux_consignment_item_sku; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE UNIQUE INDEX ux_consignment_item_sku ON tenant_demo.consignment_item USING btree (tenant_id, sku) WHERE ((sku IS NOT NULL) AND (deleted_at IS NULL));


--
-- Name: ux_inventory_item_sku; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE UNIQUE INDEX ux_inventory_item_sku ON tenant_demo.inventory_item USING btree (tenant_id, sku) WHERE (deleted_at IS NULL);


--
-- Name: ux_layaway_payment_idem; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE UNIQUE INDEX ux_layaway_payment_idem ON tenant_demo.layaway_payment USING btree (tenant_id, idempotency_key) WHERE (idempotency_key IS NOT NULL);


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
-- Name: ux_stored_value_code; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE UNIQUE INDEX ux_stored_value_code ON tenant_demo.stored_value USING btree (tenant_id, code) WHERE (deleted_at IS NULL);


--
-- Name: ux_tax_year_payment_idem; Type: INDEX; Schema: tenant_demo; Owner: -
--

CREATE UNIQUE INDEX ux_tax_year_payment_idem ON tenant_demo.tax_year_payment USING btree (tenant_id, idempotency_key) WHERE (idempotency_key IS NOT NULL);


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
-- Name: cam_pool trg_cam_pool_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_cam_pool_audit BEFORE UPDATE ON tenant_demo.cam_pool FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: commission_rule trg_commission_rule_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_commission_rule_audit BEFORE UPDATE ON tenant_demo.commission_rule FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: commission_trueup trg_commission_trueup_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_commission_trueup_audit BEFORE UPDATE ON tenant_demo.commission_trueup FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


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
-- Name: inventory_item trg_inventory_item_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_inventory_item_audit BEFORE UPDATE ON tenant_demo.inventory_item FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: inventory_movement trg_inventory_movement_immutable; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_inventory_movement_immutable BEFORE DELETE OR UPDATE ON tenant_demo.inventory_movement FOR EACH ROW EXECUTE FUNCTION tenant_demo.inventory_movement_immutable();


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
-- Name: journal_line trg_journal_line_control_tagged; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_journal_line_control_tagged BEFORE INSERT ON tenant_demo.journal_line FOR EACH ROW EXECUTE FUNCTION tenant_demo.assert_control_account_tagged();


--
-- Name: journal_line trg_journal_line_subledger_control; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_journal_line_subledger_control BEFORE INSERT ON tenant_demo.journal_line FOR EACH ROW EXECUTE FUNCTION tenant_demo.assert_subledger_control();


--
-- Name: layaway trg_layaway_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_layaway_audit BEFORE UPDATE ON tenant_demo.layaway FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: layaway_line trg_layaway_line_item_free; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_layaway_line_item_free BEFORE INSERT OR UPDATE ON tenant_demo.layaway_line FOR EACH ROW EXECUTE FUNCTION tenant_demo.assert_layaway_item_free();


--
-- Name: layaway_payment trg_layaway_payment_append_only; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_layaway_payment_append_only BEFORE DELETE OR UPDATE ON tenant_demo.layaway_payment FOR EACH ROW EXECUTE FUNCTION kernel.forbid_mutation();


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
-- Name: lease_sales_report trg_lease_sales_report_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_lease_sales_report_audit BEFORE UPDATE ON tenant_demo.lease_sales_report FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: lease_space trg_lease_space_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_lease_space_audit BEFORE UPDATE ON tenant_demo.lease_space FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: location trg_location_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_location_audit BEFORE UPDATE ON tenant_demo.location FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: markdown_event trg_markdown_event_append_only; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_markdown_event_append_only BEFORE DELETE OR UPDATE ON tenant_demo.markdown_event FOR EACH ROW EXECUTE FUNCTION kernel.forbid_mutation();


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
-- Name: payee_tax_profile trg_payee_tax_profile_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_payee_tax_profile_audit BEFORE UPDATE ON tenant_demo.payee_tax_profile FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


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
-- Name: stored_value trg_stored_value_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_stored_value_audit BEFORE UPDATE ON tenant_demo.stored_value FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: stored_value_activity trg_sv_activity_immutable; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_sv_activity_immutable BEFORE DELETE OR UPDATE ON tenant_demo.stored_value_activity FOR EACH ROW EXECUTE FUNCTION tenant_demo.stored_value_activity_immutable();


--
-- Name: tax_jurisdiction trg_tax_jurisdiction_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_tax_jurisdiction_audit BEFORE UPDATE ON tenant_demo.tax_jurisdiction FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: tax_rate trg_tax_rate_audit; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_tax_rate_audit BEFORE UPDATE ON tenant_demo.tax_rate FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();


--
-- Name: tax_year_payment trg_tax_year_payment_append_only; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE TRIGGER trg_tax_year_payment_append_only BEFORE DELETE OR UPDATE ON tenant_demo.tax_year_payment FOR EACH ROW EXECUTE FUNCTION kernel.forbid_mutation();


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
-- Name: payment_tender trg_vendor_draw_covered; Type: TRIGGER; Schema: tenant_demo; Owner: -
--

CREATE CONSTRAINT TRIGGER trg_vendor_draw_covered AFTER INSERT ON tenant_demo.payment_tender DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION tenant_demo.assert_vendor_draw_covered();


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
-- Name: cam_pool_expense cam_pool_expense_cam_pool_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.cam_pool_expense
    ADD CONSTRAINT cam_pool_expense_cam_pool_id_fkey FOREIGN KEY (cam_pool_id) REFERENCES tenant_demo.cam_pool(id) ON DELETE RESTRICT;


--
-- Name: cam_pool_expense cam_pool_expense_journal_entry_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.cam_pool_expense
    ADD CONSTRAINT cam_pool_expense_journal_entry_id_fkey FOREIGN KEY (journal_entry_id) REFERENCES tenant_demo.journal_entry(id) ON DELETE RESTRICT;


--
-- Name: cam_pool cam_pool_location_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.cam_pool
    ADD CONSTRAINT cam_pool_location_id_fkey FOREIGN KEY (location_id) REFERENCES tenant_demo.location(id) ON DELETE RESTRICT;


--
-- Name: commission_rule commission_rule_agreement_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.commission_rule
    ADD CONSTRAINT commission_rule_agreement_id_fkey FOREIGN KEY (agreement_id) REFERENCES tenant_demo.consignor_agreement(id) ON DELETE RESTRICT;


--
-- Name: commission_trueup commission_trueup_agreement_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.commission_trueup
    ADD CONSTRAINT commission_trueup_agreement_id_fkey FOREIGN KEY (agreement_id) REFERENCES tenant_demo.consignor_agreement(id) ON DELETE RESTRICT;


--
-- Name: commission_trueup commission_trueup_consignor_party_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.commission_trueup
    ADD CONSTRAINT commission_trueup_consignor_party_id_fkey FOREIGN KEY (consignor_party_id) REFERENCES tenant_demo.party(id) ON DELETE RESTRICT;


--
-- Name: commission_trueup commission_trueup_journal_entry_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.commission_trueup
    ADD CONSTRAINT commission_trueup_journal_entry_id_fkey FOREIGN KEY (journal_entry_id) REFERENCES tenant_demo.journal_entry(id) ON DELETE RESTRICT;


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
-- Name: inventory_item inventory_item_supplier_party_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.inventory_item
    ADD CONSTRAINT inventory_item_supplier_party_id_fkey FOREIGN KEY (supplier_party_id) REFERENCES tenant_demo.party(id) ON DELETE RESTRICT;


--
-- Name: inventory_movement inventory_movement_item_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.inventory_movement
    ADD CONSTRAINT inventory_movement_item_id_fkey FOREIGN KEY (item_id) REFERENCES tenant_demo.inventory_item(id) ON DELETE RESTRICT;


--
-- Name: inventory_movement inventory_movement_journal_entry_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.inventory_movement
    ADD CONSTRAINT inventory_movement_journal_entry_id_fkey FOREIGN KEY (journal_entry_id) REFERENCES tenant_demo.journal_entry(id) ON DELETE RESTRICT;


--
-- Name: inventory_movement inventory_movement_sale_line_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.inventory_movement
    ADD CONSTRAINT inventory_movement_sale_line_id_fkey FOREIGN KEY (sale_line_id) REFERENCES tenant_demo.sale_line(id) ON DELETE RESTRICT;


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
-- Name: layaway layaway_customer_party_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.layaway
    ADD CONSTRAINT layaway_customer_party_id_fkey FOREIGN KEY (customer_party_id) REFERENCES tenant_demo.party(id) ON DELETE RESTRICT;


--
-- Name: layaway_line layaway_line_consignment_item_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.layaway_line
    ADD CONSTRAINT layaway_line_consignment_item_id_fkey FOREIGN KEY (consignment_item_id) REFERENCES tenant_demo.consignment_item(id) ON DELETE RESTRICT;


--
-- Name: layaway_line layaway_line_inventory_item_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.layaway_line
    ADD CONSTRAINT layaway_line_inventory_item_id_fkey FOREIGN KEY (inventory_item_id) REFERENCES tenant_demo.inventory_item(id) ON DELETE RESTRICT;


--
-- Name: layaway_line layaway_line_layaway_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.layaway_line
    ADD CONSTRAINT layaway_line_layaway_id_fkey FOREIGN KEY (layaway_id) REFERENCES tenant_demo.layaway(id) ON DELETE CASCADE;


--
-- Name: layaway_payment layaway_payment_journal_entry_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.layaway_payment
    ADD CONSTRAINT layaway_payment_journal_entry_id_fkey FOREIGN KEY (journal_entry_id) REFERENCES tenant_demo.journal_entry(id) ON DELETE RESTRICT;


--
-- Name: layaway_payment layaway_payment_layaway_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.layaway_payment
    ADD CONSTRAINT layaway_payment_layaway_id_fkey FOREIGN KEY (layaway_id) REFERENCES tenant_demo.layaway(id) ON DELETE RESTRICT;


--
-- Name: layaway layaway_sale_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.layaway
    ADD CONSTRAINT layaway_sale_id_fkey FOREIGN KEY (sale_id) REFERENCES tenant_demo.sale(id) ON DELETE RESTRICT;


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
-- Name: lease_sales_report lease_sales_report_lease_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.lease_sales_report
    ADD CONSTRAINT lease_sales_report_lease_id_fkey FOREIGN KEY (lease_id) REFERENCES tenant_demo.lease(id) ON DELETE RESTRICT;


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
-- Name: markdown_event markdown_event_consignment_item_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.markdown_event
    ADD CONSTRAINT markdown_event_consignment_item_id_fkey FOREIGN KEY (consignment_item_id) REFERENCES tenant_demo.consignment_item(id) ON DELETE RESTRICT;


--
-- Name: markdown_event markdown_event_inventory_item_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.markdown_event
    ADD CONSTRAINT markdown_event_inventory_item_id_fkey FOREIGN KEY (inventory_item_id) REFERENCES tenant_demo.inventory_item(id) ON DELETE RESTRICT;


--
-- Name: markdown_event markdown_event_tenant_id_reason_code_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.markdown_event
    ADD CONSTRAINT markdown_event_tenant_id_reason_code_fkey FOREIGN KEY (tenant_id, reason_code) REFERENCES tenant_demo.markdown_reason(tenant_id, code);


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
-- Name: payee_tax_profile payee_tax_profile_party_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.payee_tax_profile
    ADD CONSTRAINT payee_tax_profile_party_id_fkey FOREIGN KEY (party_id) REFERENCES tenant_demo.party(id) ON DELETE RESTRICT;


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
-- Name: sale_line sale_line_inventory_item_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.sale_line
    ADD CONSTRAINT sale_line_inventory_item_id_fkey FOREIGN KEY (inventory_item_id) REFERENCES tenant_demo.inventory_item(id) ON DELETE RESTRICT;


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
-- Name: stored_value_activity stored_value_activity_journal_entry_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.stored_value_activity
    ADD CONSTRAINT stored_value_activity_journal_entry_id_fkey FOREIGN KEY (journal_entry_id) REFERENCES tenant_demo.journal_entry(id) ON DELETE RESTRICT;


--
-- Name: stored_value_activity stored_value_activity_sale_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.stored_value_activity
    ADD CONSTRAINT stored_value_activity_sale_id_fkey FOREIGN KEY (sale_id) REFERENCES tenant_demo.sale(id) ON DELETE RESTRICT;


--
-- Name: stored_value_activity stored_value_activity_stored_value_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.stored_value_activity
    ADD CONSTRAINT stored_value_activity_stored_value_id_fkey FOREIGN KEY (stored_value_id) REFERENCES tenant_demo.stored_value(id) ON DELETE RESTRICT;


--
-- Name: stored_value stored_value_journal_entry_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.stored_value
    ADD CONSTRAINT stored_value_journal_entry_id_fkey FOREIGN KEY (journal_entry_id) REFERENCES tenant_demo.journal_entry(id) ON DELETE RESTRICT;


--
-- Name: stored_value stored_value_open_item_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.stored_value
    ADD CONSTRAINT stored_value_open_item_id_fkey FOREIGN KEY (open_item_id) REFERENCES tenant_demo.open_item(id) ON DELETE RESTRICT;


--
-- Name: stored_value stored_value_party_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.stored_value
    ADD CONSTRAINT stored_value_party_id_fkey FOREIGN KEY (party_id) REFERENCES tenant_demo.party(id) ON DELETE RESTRICT;


--
-- Name: tax_rate tax_rate_jurisdiction_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.tax_rate
    ADD CONSTRAINT tax_rate_jurisdiction_id_fkey FOREIGN KEY (jurisdiction_id) REFERENCES tenant_demo.tax_jurisdiction(id) ON DELETE RESTRICT;


--
-- Name: tax_year_payment tax_year_payment_journal_entry_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.tax_year_payment
    ADD CONSTRAINT tax_year_payment_journal_entry_id_fkey FOREIGN KEY (journal_entry_id) REFERENCES tenant_demo.journal_entry(id) ON DELETE RESTRICT;


--
-- Name: tax_year_payment tax_year_payment_party_id_fkey; Type: FK CONSTRAINT; Schema: tenant_demo; Owner: -
--

ALTER TABLE ONLY tenant_demo.tax_year_payment
    ADD CONSTRAINT tax_year_payment_party_id_fkey FOREIGN KEY (party_id) REFERENCES tenant_demo.party(id) ON DELETE RESTRICT;


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
-- Name: cam_pool; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.cam_pool ENABLE ROW LEVEL SECURITY;

--
-- Name: cam_pool_expense; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.cam_pool_expense ENABLE ROW LEVEL SECURITY;

--
-- Name: commission_rule; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.commission_rule ENABLE ROW LEVEL SECURITY;

--
-- Name: commission_trueup; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.commission_trueup ENABLE ROW LEVEL SECURITY;

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
-- Name: inventory_item; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.inventory_item ENABLE ROW LEVEL SECURITY;

--
-- Name: inventory_movement; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.inventory_movement ENABLE ROW LEVEL SECURITY;

--
-- Name: item_price_change; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.item_price_change ENABLE ROW LEVEL SECURITY;

--
-- Name: layaway; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.layaway ENABLE ROW LEVEL SECURITY;

--
-- Name: layaway_line; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.layaway_line ENABLE ROW LEVEL SECURITY;

--
-- Name: layaway_payment; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.layaway_payment ENABLE ROW LEVEL SECURITY;

--
-- Name: lease; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.lease ENABLE ROW LEVEL SECURITY;

--
-- Name: lease_deposit; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.lease_deposit ENABLE ROW LEVEL SECURITY;

--
-- Name: lease_sales_report; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.lease_sales_report ENABLE ROW LEVEL SECURITY;

--
-- Name: lease_space; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.lease_space ENABLE ROW LEVEL SECURITY;

--
-- Name: location; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.location ENABLE ROW LEVEL SECURITY;

--
-- Name: markdown_event; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.markdown_event ENABLE ROW LEVEL SECURITY;

--
-- Name: markdown_reason; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.markdown_reason ENABLE ROW LEVEL SECURITY;

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
-- Name: payee_tax_profile; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.payee_tax_profile ENABLE ROW LEVEL SECURITY;

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
-- Name: stored_value; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.stored_value ENABLE ROW LEVEL SECURITY;

--
-- Name: stored_value_activity; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.stored_value_activity ENABLE ROW LEVEL SECURITY;

--
-- Name: tax_form_threshold; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.tax_form_threshold ENABLE ROW LEVEL SECURITY;

--
-- Name: tax_jurisdiction; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.tax_jurisdiction ENABLE ROW LEVEL SECURITY;

--
-- Name: tax_rate; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.tax_rate ENABLE ROW LEVEL SECURITY;

--
-- Name: tax_year_payment; Type: ROW SECURITY; Schema: tenant_demo; Owner: -
--

ALTER TABLE tenant_demo.tax_year_payment ENABLE ROW LEVEL SECURITY;

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
-- Name: cam_pool tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.cam_pool USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: cam_pool_expense tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.cam_pool_expense USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: commission_rule tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.commission_rule USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: commission_trueup tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.commission_trueup USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


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
-- Name: inventory_item tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.inventory_item USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: inventory_movement tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.inventory_movement USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: item_price_change tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.item_price_change USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: layaway tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.layaway USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: layaway_line tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.layaway_line USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: layaway_payment tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.layaway_payment USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: lease tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.lease USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: lease_deposit tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.lease_deposit USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: lease_sales_report tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.lease_sales_report USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: lease_space tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.lease_space USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: location tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.location USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: markdown_event tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.markdown_event USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: markdown_reason tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.markdown_reason USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


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
-- Name: payee_tax_profile tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.payee_tax_profile USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


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
-- Name: stored_value tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.stored_value USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: stored_value_activity tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.stored_value_activity USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: tax_form_threshold tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.tax_form_threshold USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: tax_jurisdiction tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.tax_jurisdiction USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: tax_rate tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.tax_rate USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


--
-- Name: tax_year_payment tenant_isolation; Type: POLICY; Schema: tenant_demo; Owner: -
--

CREATE POLICY tenant_isolation ON tenant_demo.tax_year_payment USING ((tenant_id = kernel.current_tenant())) WITH CHECK ((tenant_id = kernel.current_tenant()));


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
-- Name: TABLE schema_migration; Type: ACL; Schema: kernel; Owner: -
--

GRANT SELECT ON TABLE kernel.schema_migration TO ninja_app;
GRANT SELECT ON TABLE kernel.schema_migration TO ninja_migrator;


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
-- Name: TABLE cam_pool; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.cam_pool TO ninja_app;
GRANT ALL ON TABLE tenant_demo.cam_pool TO ninja_migrator;


--
-- Name: TABLE cam_pool_expense; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.cam_pool_expense TO ninja_app;
GRANT ALL ON TABLE tenant_demo.cam_pool_expense TO ninja_migrator;


--
-- Name: TABLE commission_rule; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.commission_rule TO ninja_app;
GRANT ALL ON TABLE tenant_demo.commission_rule TO ninja_migrator;


--
-- Name: TABLE commission_trueup; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.commission_trueup TO ninja_app;
GRANT ALL ON TABLE tenant_demo.commission_trueup TO ninja_migrator;


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
-- Name: TABLE inventory_item; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.inventory_item TO ninja_app;
GRANT ALL ON TABLE tenant_demo.inventory_item TO ninja_migrator;


--
-- Name: TABLE inventory_movement; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.inventory_movement TO ninja_app;
GRANT ALL ON TABLE tenant_demo.inventory_movement TO ninja_migrator;


--
-- Name: SEQUENCE inventory_movement_id_seq; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE tenant_demo.inventory_movement_id_seq TO ninja_app;
GRANT SELECT,USAGE ON SEQUENCE tenant_demo.inventory_movement_id_seq TO ninja_migrator;


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
-- Name: TABLE layaway; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.layaway TO ninja_app;
GRANT ALL ON TABLE tenant_demo.layaway TO ninja_migrator;


--
-- Name: SEQUENCE layaway_layaway_no_seq; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE tenant_demo.layaway_layaway_no_seq TO ninja_app;
GRANT SELECT,USAGE ON SEQUENCE tenant_demo.layaway_layaway_no_seq TO ninja_migrator;


--
-- Name: TABLE layaway_line; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.layaway_line TO ninja_app;
GRANT ALL ON TABLE tenant_demo.layaway_line TO ninja_migrator;


--
-- Name: TABLE layaway_payment; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.layaway_payment TO ninja_app;
GRANT ALL ON TABLE tenant_demo.layaway_payment TO ninja_migrator;


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
-- Name: TABLE lease_sales_report; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.lease_sales_report TO ninja_app;
GRANT ALL ON TABLE tenant_demo.lease_sales_report TO ninja_migrator;


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
-- Name: TABLE markdown_event; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.markdown_event TO ninja_app;
GRANT ALL ON TABLE tenant_demo.markdown_event TO ninja_migrator;


--
-- Name: TABLE markdown_reason; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.markdown_reason TO ninja_app;
GRANT ALL ON TABLE tenant_demo.markdown_reason TO ninja_migrator;


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
-- Name: TABLE payee_tax_profile; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.payee_tax_profile TO ninja_app;
GRANT ALL ON TABLE tenant_demo.payee_tax_profile TO ninja_migrator;


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
-- Name: TABLE stored_value; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.stored_value TO ninja_app;
GRANT ALL ON TABLE tenant_demo.stored_value TO ninja_migrator;


--
-- Name: TABLE stored_value_activity; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.stored_value_activity TO ninja_app;
GRANT ALL ON TABLE tenant_demo.stored_value_activity TO ninja_migrator;


--
-- Name: SEQUENCE stored_value_activity_id_seq; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE tenant_demo.stored_value_activity_id_seq TO ninja_app;
GRANT SELECT,USAGE ON SEQUENCE tenant_demo.stored_value_activity_id_seq TO ninja_migrator;


--
-- Name: TABLE tax_form_threshold; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.tax_form_threshold TO ninja_app;
GRANT ALL ON TABLE tenant_demo.tax_form_threshold TO ninja_migrator;


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
-- Name: TABLE tax_year_payment; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.tax_year_payment TO ninja_app;
GRANT ALL ON TABLE tenant_demo.tax_year_payment TO ninja_migrator;


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
-- Name: TABLE v_1099_summary; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.v_1099_summary TO ninja_app;
GRANT ALL ON TABLE tenant_demo.v_1099_summary TO ninja_migrator;


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
-- Name: TABLE v_commission_trueup_pending; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.v_commission_trueup_pending TO ninja_app;
GRANT ALL ON TABLE tenant_demo.v_commission_trueup_pending TO ninja_migrator;


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
-- Name: TABLE v_layaway_aging; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.v_layaway_aging TO ninja_app;
GRANT ALL ON TABLE tenant_demo.v_layaway_aging TO ninja_migrator;


--
-- Name: TABLE v_lease_expiring; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.v_lease_expiring TO ninja_app;
GRANT ALL ON TABLE tenant_demo.v_lease_expiring TO ninja_migrator;


--
-- Name: TABLE v_party_identifier_masked; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.v_party_identifier_masked TO ninja_app;
GRANT ALL ON TABLE tenant_demo.v_party_identifier_masked TO ninja_migrator;


--
-- Name: TABLE v_sale_margin; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.v_sale_margin TO ninja_app;
GRANT ALL ON TABLE tenant_demo.v_sale_margin TO ninja_migrator;


--
-- Name: TABLE v_stored_value_outstanding; Type: ACL; Schema: tenant_demo; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE tenant_demo.v_stored_value_outstanding TO ninja_app;
GRANT ALL ON TABLE tenant_demo.v_stored_value_outstanding TO ninja_migrator;


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

\unrestrict 3tOsByOaSrMH7TBJh8VKV52RlbIfhMNhB73alyxgu9RhhcPzBfmPBfjoTZCBghz

