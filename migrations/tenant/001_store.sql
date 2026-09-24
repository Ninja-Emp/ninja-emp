-- Store baseline.
-- Squashed from the Nest tenant migrations through 066_intake_defaults_off.sql.
-- Unqualified names. The runner sets search_path to the store schema, then public.
-- Reference rows below are the empty mall (chart, House, settings, tax thresholds, Main).
-- Intake flags follow the column default from 066 (new mall, extras off).
-- A Nest chain that inserted settings before 066 leaves those flags true; that row is not copied.

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: nest_tenant; Type: SCHEMA; Schema: -; Owner: -
--



--
-- Name: emp_assert_assignment_no_overlap(); Type: FUNCTION; Schema: nest_tenant; Owner: -
--

CREATE FUNCTION emp_assert_assignment_no_overlap() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    conflicts integer;
    new_end date;
BEGIN
    new_end := COALESCE(NEW.ended_on, DATE '9999-12-31');
    SELECT COUNT(*) INTO conflicts
    FROM booth_assignments a
    WHERE a.booth_id = NEW.booth_id
      AND a.assignment_id <> NEW.assignment_id
      AND a.starts_on <= new_end
      AND COALESCE(a.ended_on, DATE '9999-12-31') >= NEW.starts_on;
    IF conflicts > 0 THEN
        RAISE EXCEPTION 'booth assignment overlaps'
            USING ERRCODE = '23P01';
    END IF;
    RETURN NEW;
END;
$$;


--
-- Name: emp_assert_journal_balanced(); Type: FUNCTION; Schema: nest_tenant; Owner: -
--

CREATE FUNCTION emp_assert_journal_balanced() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    sum_debit bigint;
    sum_credit bigint;
    line_count integer;
BEGIN
    SELECT COALESCE(SUM(debit_minor), 0), COALESCE(SUM(credit_minor), 0), COUNT(*)
    INTO sum_debit, sum_credit, line_count
    FROM journal_lines
    WHERE journal_id = NEW.journal_id;

    IF line_count < 2 THEN
        RAISE EXCEPTION 'journal must have at least two lines'
            USING ERRCODE = '23514';
    END IF;
    IF sum_debit <> sum_credit OR sum_debit <> NEW.total_debits_minor OR sum_credit <> NEW.total_credits_minor THEN
        RAISE EXCEPTION 'journal is not balanced'
            USING ERRCODE = '23514';
    END IF;
    RETURN NULL;
END;
$$;


--
-- Name: emp_assert_payout_journal(); Type: FUNCTION; Schema: nest_tenant; Owner: -
--

CREATE FUNCTION emp_assert_payout_journal() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    header record;
BEGIN
    SELECT source_type, source_reference, currency, total_debits_minor
      INTO header
      FROM journals
     WHERE journal_id = NEW.journal_id;
    IF header.source_type IS DISTINCT FROM 'holder_payout'
       OR header.source_reference IS DISTINCT FROM NEW.holder_payout_id::text
       OR header.currency IS DISTINCT FROM NEW.currency
       OR header.total_debits_minor IS DISTINCT FROM NEW.amount_minor THEN
        RAISE EXCEPTION 'payout journal does not match the payout'
            USING ERRCODE = '23514';
    END IF;
    RETURN NULL;
END;
$$;


--
-- Name: emp_assert_period_no_overlap(); Type: FUNCTION; Schema: nest_tenant; Owner: -
--

CREATE FUNCTION emp_assert_period_no_overlap() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    conflicts integer;
BEGIN
    SELECT COUNT(*) INTO conflicts
    FROM accounting_periods p
    WHERE p.book_id = NEW.book_id
      AND p.period_id <> NEW.period_id
      AND p.starts_on <= NEW.ends_on
      AND p.ends_on >= NEW.starts_on;
    IF conflicts > 0 THEN
        RAISE EXCEPTION 'accounting period overlaps'
            USING ERRCODE = '23P01';
    END IF;
    RETURN NEW;
END;
$$;


--
-- Name: emp_assert_rent_receipt_journal(); Type: FUNCTION; Schema: nest_tenant; Owner: -
--

CREATE FUNCTION emp_assert_rent_receipt_journal() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    header record;
BEGIN
    SELECT source_type, source_reference, currency, total_debits_minor
      INTO header
      FROM journals
     WHERE journal_id = NEW.journal_id;
    IF header.source_type IS DISTINCT FROM 'rent_receipt'
       OR header.source_reference IS DISTINCT FROM NEW.rent_receipt_id::text
       OR header.currency IS DISTINCT FROM NEW.currency
       OR header.total_debits_minor IS DISTINCT FROM NEW.amount_minor THEN
        RAISE EXCEPTION 'rent receipt journal does not match the receipt'
            USING ERRCODE = '23514';
    END IF;
    RETURN NULL;
END;
$$;


--
-- Name: emp_assert_return_journal(); Type: FUNCTION; Schema: nest_tenant; Owner: -
--

CREATE FUNCTION emp_assert_return_journal() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    header record;
BEGIN
    SELECT source_type, source_reference, currency, total_debits_minor
      INTO header
      FROM journals
     WHERE journal_id = NEW.journal_id;
    IF header.source_type IS DISTINCT FROM 'sale_return'
       OR header.source_reference IS DISTINCT FROM NEW.sale_return_id::text
       OR header.currency IS DISTINCT FROM NEW.currency
       OR header.total_debits_minor
            IS DISTINCT FROM NEW.amount_minor + GREATEST(NEW.cash_rounding_adjustment_minor, 0) THEN
        RAISE EXCEPTION 'return journal does not match the return'
            USING ERRCODE = '23514';
    END IF;
    RETURN NULL;
END;
$$;


--
-- Name: emp_assert_sale_journal(); Type: FUNCTION; Schema: nest_tenant; Owner: -
--

CREATE FUNCTION emp_assert_sale_journal() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    header record;
    tender_total bigint;
BEGIN
    SELECT source_type, source_reference, currency, total_debits_minor
      INTO header
      FROM journals
     WHERE journal_id = NEW.journal_id;
    IF header.source_type IS DISTINCT FROM 'sale'
       OR header.source_reference IS DISTINCT FROM NEW.sale_id::text
       OR header.currency IS DISTINCT FROM NEW.currency THEN
        RAISE EXCEPTION 'sale journal does not match the sale'
            USING ERRCODE = '23514';
    END IF;
    SELECT COALESCE(SUM(amount_minor), 0) INTO tender_total
      FROM sale_tenders
     WHERE sale_id = NEW.sale_id;
    IF tender_total + GREATEST(-NEW.cash_rounding_adjustment_minor, 0) <> header.total_debits_minor THEN
        RAISE EXCEPTION 'sale journal amount does not match tenders'
            USING ERRCODE = '23514';
    END IF;
    RETURN NULL;
END;
$$;


--
-- Name: emp_block_audit_mutation(); Type: FUNCTION; Schema: nest_tenant; Owner: -
--

CREATE FUNCTION emp_block_audit_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    RAISE EXCEPTION 'audit events are append-only'
        USING ERRCODE = '25006';
END;
$$;


--
-- Name: emp_block_cash_drop_mutation(); Type: FUNCTION; Schema: nest_tenant; Owner: -
--

CREATE FUNCTION emp_block_cash_drop_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    RAISE EXCEPTION 'cash drops are append-only'
        USING ERRCODE = '25006';
END;
$$;


--
-- Name: emp_block_ledger_mutation(); Type: FUNCTION; Schema: nest_tenant; Owner: -
--

CREATE FUNCTION emp_block_ledger_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    RAISE EXCEPTION 'ledger rows are append-only'
        USING ERRCODE = '25006';
END;
$$;


SET default_table_access_method = heap;

--
-- Name: accounting_periods; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE accounting_periods (
    period_id uuid DEFAULT uuidv7() NOT NULL,
    book_id uuid NOT NULL,
    starts_on date NOT NULL,
    ends_on date NOT NULL,
    status character varying(12) DEFAULT 'open'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT accounting_periods_range_chk CHECK ((ends_on >= starts_on)),
    CONSTRAINT accounting_periods_status_chk CHECK (((status)::text = ANY ((ARRAY['open'::character varying, 'soft_closed'::character varying, 'hard_closed'::character varying])::text[])))
);


--
-- Name: accounting_sequences; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE accounting_sequences (
    book_id uuid NOT NULL,
    scope character varying(64) NOT NULL,
    next_value bigint DEFAULT 1 NOT NULL,
    CONSTRAINT accounting_sequences_next_positive CHECK ((next_value >= 1))
);


--
-- Name: accounts; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE accounts (
    account_id uuid DEFAULT uuidv7() NOT NULL,
    code character varying(32) NOT NULL,
    name character varying(160) NOT NULL,
    account_type character varying(16) NOT NULL,
    normal_balance character varying(6) NOT NULL,
    is_postable boolean DEFAULT true NOT NULL,
    is_control boolean DEFAULT false NOT NULL,
    subledger_type character varying(32),
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT accounts_control_requires_subledger CHECK (((is_control = false) OR (subledger_type IS NOT NULL))),
    CONSTRAINT accounts_normal_balance_chk CHECK (((normal_balance)::text = ANY ((ARRAY['debit'::character varying, 'credit'::character varying])::text[]))),
    CONSTRAINT accounts_type_chk CHECK (((account_type)::text = ANY ((ARRAY['asset'::character varying, 'liability'::character varying, 'equity'::character varying, 'revenue'::character varying, 'expense'::character varying])::text[])))
);


--
-- Name: audit_events; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE audit_events (
    audit_event_id uuid DEFAULT uuidv7() NOT NULL,
    occurred_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    identity_id uuid,
    membership_id uuid,
    action character varying(64) NOT NULL,
    message text NOT NULL,
    resource_type character varying(64) NOT NULL,
    resource_id uuid NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT audit_events_actor_chk CHECK ((((identity_id IS NOT NULL) AND (membership_id IS NOT NULL)) OR ((identity_id IS NULL) AND (membership_id IS NULL))))
);


--
-- Name: booth_assignments; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE booth_assignments (
    assignment_id uuid DEFAULT uuidv7() NOT NULL,
    booth_id uuid NOT NULL,
    party_id uuid NOT NULL,
    starts_on date NOT NULL,
    ended_on date,
    rent_amount_minor bigint NOT NULL,
    currency character(3) NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT booth_assignments_currency_chk CHECK ((currency = ANY (ARRAY['USD'::bpchar, 'CAD'::bpchar, 'EUR'::bpchar]))),
    CONSTRAINT booth_assignments_range_chk CHECK (((ended_on IS NULL) OR (ended_on >= starts_on))),
    CONSTRAINT booth_assignments_rent_nonneg_chk CHECK ((rent_amount_minor >= 0))
);


--
-- Name: booth_map_layouts; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE booth_map_layouts (
    layout_id uuid DEFAULT uuidv7() NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    floors jsonb NOT NULL,
    CONSTRAINT booth_map_layouts_floors_chk CHECK (((jsonb_typeof(floors) = 'array'::text) AND (jsonb_array_length(floors) >= 1) AND (jsonb_array_length(floors) <= 20)))
);


--
-- Name: booths; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE booths (
    booth_id uuid DEFAULT uuidv7() NOT NULL,
    booth_code character varying(32) NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    size character varying(80),
    default_rent_minor bigint,
    default_rent_currency character(3),
    retired_at timestamp with time zone,
    CONSTRAINT booths_default_rent_chk CHECK ((((default_rent_minor IS NULL) AND (default_rent_currency IS NULL)) OR ((default_rent_minor IS NOT NULL) AND (default_rent_currency IS NOT NULL))))
);


--
-- Name: card_settlement_lines; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE card_settlement_lines (
    card_settlement_line_id uuid DEFAULT uuidv7() NOT NULL,
    card_settlement_id uuid NOT NULL,
    source_kind character varying(32) NOT NULL,
    source_id uuid NOT NULL,
    amount_minor bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT card_settlement_lines_amount_chk CHECK ((amount_minor > 0)),
    CONSTRAINT card_settlement_lines_kind_chk CHECK (((source_kind)::text = ANY ((ARRAY['sale_tender'::character varying, 'rent_receipt'::character varying, 'gift_certificate'::character varying, 'layaway_deposit'::character varying, 'store_credit'::character varying])::text[])))
);


--
-- Name: card_settlements; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE card_settlements (
    card_settlement_id uuid DEFAULT uuidv7() NOT NULL,
    kind character varying(16) NOT NULL,
    settled_on date NOT NULL,
    amount_minor bigint NOT NULL,
    fee_minor bigint DEFAULT 0 NOT NULL,
    currency character(3) NOT NULL,
    square_payout_id character varying(64),
    sale_id uuid,
    note character varying(255),
    journal_id uuid NOT NULL,
    status character varying(16) DEFAULT 'completed'::character varying NOT NULL,
    reversal_journal_id uuid,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT card_settlements_amount_chk CHECK (((amount_minor > 0) AND (fee_minor >= 0))),
    CONSTRAINT card_settlements_currency_chk CHECK ((currency = ANY (ARRAY['USD'::bpchar, 'CAD'::bpchar, 'EUR'::bpchar]))),
    CONSTRAINT card_settlements_kind_chk CHECK (((kind)::text = ANY ((ARRAY['square_payout'::character varying, 'manual'::character varying, 'processor_fee'::character varying, 'chargeback'::character varying])::text[]))),
    CONSTRAINT card_settlements_status_chk CHECK (((status)::text = ANY ((ARRAY['completed'::character varying, 'reversed'::character varying])::text[])))
);


--
-- Name: check_deposits; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE check_deposits (
    check_deposit_id uuid DEFAULT uuidv7() NOT NULL,
    deposited_on date NOT NULL,
    amount_minor bigint NOT NULL,
    currency character(3) NOT NULL,
    journal_id uuid NOT NULL,
    status character varying(16) NOT NULL,
    reversal_journal_id uuid,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT check_deposits_amount_positive_chk CHECK ((amount_minor > 0)),
    CONSTRAINT check_deposits_currency_chk CHECK ((currency = ANY (ARRAY['USD'::bpchar, 'CAD'::bpchar, 'EUR'::bpchar]))),
    CONSTRAINT check_deposits_status_chk CHECK (((status)::text = ANY ((ARRAY['completed'::character varying, 'reversed'::character varying])::text[]))),
    CONSTRAINT check_deposits_void_chk CHECK (((((status)::text = 'completed'::text) AND (reversal_journal_id IS NULL)) OR (((status)::text = 'reversed'::text) AND (reversal_journal_id IS NOT NULL))))
);


--
-- Name: customers; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE customers (
    customer_id uuid DEFAULT uuidv7() NOT NULL,
    display_name character varying(255) NOT NULL,
    tax_exempt boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT customers_name_len_chk CHECK ((char_length((display_name)::text) >= 2))
);


--
-- Name: gift_certificate_redemptions; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE gift_certificate_redemptions (
    redemption_id uuid DEFAULT uuidv7() NOT NULL,
    gift_certificate_id uuid NOT NULL,
    sale_id uuid NOT NULL,
    amount_minor bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT gift_certificate_redemptions_amount_positive_chk CHECK ((amount_minor > 0))
);


--
-- Name: gift_certificate_seq; Type: SEQUENCE; Schema: nest_tenant; Owner: -
--

CREATE SEQUENCE gift_certificate_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: gift_certificates; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE gift_certificates (
    gift_certificate_id uuid DEFAULT uuidv7() NOT NULL,
    certificate_no character varying(32) NOT NULL,
    issued_on date NOT NULL,
    face_amount_minor bigint NOT NULL,
    remaining_minor bigint NOT NULL,
    cash_amount_minor bigint NOT NULL,
    card_amount_minor bigint NOT NULL,
    check_amount_minor bigint NOT NULL,
    currency character(3) NOT NULL,
    status character varying(16) NOT NULL,
    journal_id uuid NOT NULL,
    reversal_journal_id uuid,
    register_id uuid,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT gift_certificates_currency_chk CHECK ((currency = ANY (ARRAY['USD'::bpchar, 'CAD'::bpchar, 'EUR'::bpchar]))),
    CONSTRAINT gift_certificates_face_positive_chk CHECK ((face_amount_minor > 0)),
    CONSTRAINT gift_certificates_remaining_chk CHECK (((remaining_minor >= 0) AND (remaining_minor <= face_amount_minor))),
    CONSTRAINT gift_certificates_status_chk CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'voided'::character varying])::text[]))),
    CONSTRAINT gift_certificates_tender_chk CHECK (((cash_amount_minor >= 0) AND (card_amount_minor >= 0) AND (check_amount_minor >= 0) AND (((cash_amount_minor + card_amount_minor) + check_amount_minor) = face_amount_minor))),
    CONSTRAINT gift_certificates_void_chk CHECK (((((status)::text = 'active'::text) AND (reversal_journal_id IS NULL)) OR (((status)::text = 'voided'::text) AND (reversal_journal_id IS NOT NULL))))
);


--
-- Name: holder_payouts; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE holder_payouts (
    holder_payout_id uuid DEFAULT uuidv7() NOT NULL,
    party_id uuid NOT NULL,
    paid_on date NOT NULL,
    amount_minor bigint NOT NULL,
    currency character(3) NOT NULL,
    journal_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    status character varying(16) DEFAULT 'completed'::character varying NOT NULL,
    reversal_journal_id uuid,
    payout_run_id uuid,
    method character varying(16) DEFAULT 'check'::character varying NOT NULL,
    register_id uuid,
    check_number character varying(32),
    CONSTRAINT holder_payouts_amount_positive_chk CHECK ((amount_minor > 0)),
    CONSTRAINT holder_payouts_cash_register_chk CHECK (((((method)::text = 'check'::text) AND (register_id IS NULL)) OR (((method)::text = 'cash'::text) AND (register_id IS NOT NULL)))),
    CONSTRAINT holder_payouts_currency_chk CHECK ((currency = ANY (ARRAY['USD'::bpchar, 'CAD'::bpchar, 'EUR'::bpchar]))),
    CONSTRAINT holder_payouts_method_chk CHECK (((method)::text = ANY ((ARRAY['check'::character varying, 'cash'::character varying, 'ach'::character varying])::text[]))),
    CONSTRAINT holder_payouts_status_chk CHECK (((status)::text = ANY ((ARRAY['completed'::character varying, 'reversed'::character varying])::text[]))),
    CONSTRAINT holder_payouts_void_requires_reversal CHECK (((((status)::text = 'completed'::text) AND (reversal_journal_id IS NULL)) OR (((status)::text = 'reversed'::text) AND (reversal_journal_id IS NOT NULL))))
);


--
-- Name: house_acquisition_items; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE house_acquisition_items (
    house_acquisition_id uuid NOT NULL,
    item_id uuid NOT NULL,
    qty integer NOT NULL,
    amount_minor bigint NOT NULL,
    prior_party_id uuid NOT NULL,
    CONSTRAINT house_acquisition_items_amount_nonneg_chk CHECK ((amount_minor >= 0)),
    CONSTRAINT house_acquisition_items_qty_positive_chk CHECK ((qty >= 1))
);


--
-- Name: house_acquisitions; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE house_acquisitions (
    house_acquisition_id uuid DEFAULT uuidv7() NOT NULL,
    from_party_id uuid NOT NULL,
    acquired_on date NOT NULL,
    amount_minor bigint NOT NULL,
    currency character(3) NOT NULL,
    journal_id uuid NOT NULL,
    status character varying(16) NOT NULL,
    reversal_journal_id uuid,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT house_acquisitions_amount_positive_chk CHECK ((amount_minor > 0)),
    CONSTRAINT house_acquisitions_currency_chk CHECK ((currency = ANY (ARRAY['USD'::bpchar, 'CAD'::bpchar, 'EUR'::bpchar]))),
    CONSTRAINT house_acquisitions_status_chk CHECK (((status)::text = ANY ((ARRAY['completed'::character varying, 'reversed'::character varying])::text[]))),
    CONSTRAINT house_acquisitions_void_chk CHECK (((((status)::text = 'completed'::text) AND (reversal_journal_id IS NULL)) OR (((status)::text = 'reversed'::text) AND (reversal_journal_id IS NOT NULL))))
);


--
-- Name: idempotency_keys; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE idempotency_keys (
    idempotency_key uuid NOT NULL,
    request_hash character(64) NOT NULL,
    redirect_path character varying(500) NOT NULL,
    response_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    completed boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: item_brands; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE item_brands (
    brand_id uuid DEFAULT uuidv7() NOT NULL,
    brand_name character varying(80) NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    retired_at timestamp with time zone
);


--
-- Name: item_categories; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE item_categories (
    category_id uuid DEFAULT uuidv7() NOT NULL,
    category_name character varying(80) NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    retired_at timestamp with time zone
);


--
-- Name: item_colors; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE item_colors (
    color_id uuid DEFAULT uuidv7() NOT NULL,
    color_name character varying(80) NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    retired_at timestamp with time zone
);


--
-- Name: item_departments; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE item_departments (
    department_id uuid DEFAULT uuidv7() NOT NULL,
    department_name character varying(80) NOT NULL,
    retired_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: item_photos; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE item_photos (
    item_id uuid NOT NULL,
    mime character varying(32) NOT NULL,
    bytes bytea NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT item_photos_bytes_chk CHECK (((octet_length(bytes) > 0) AND (octet_length(bytes) <= 512000))),
    CONSTRAINT item_photos_mime_chk CHECK (((mime)::text = ANY ((ARRAY['image/jpeg'::character varying, 'image/png'::character varying, 'image/webp'::character varying])::text[])))
);


--
-- Name: item_pulls; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE item_pulls (
    pull_id uuid DEFAULT uuidv7() NOT NULL,
    item_id uuid NOT NULL,
    qty integer NOT NULL,
    pulled_on date NOT NULL,
    reason character varying(32) NOT NULL,
    created_by_membership_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT item_pulls_qty_chk CHECK ((qty >= 1))
);


--
-- Name: item_qty_adjustments; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE item_qty_adjustments (
    adjustment_id uuid DEFAULT uuidv7() NOT NULL,
    item_id uuid NOT NULL,
    delta integer NOT NULL,
    reason character varying(16) NOT NULL,
    note character varying(255),
    created_by_membership_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT item_qty_adjustments_delta_chk CHECK ((delta <> 0)),
    CONSTRAINT item_qty_adjustments_reason_chk CHECK (((reason)::text = ANY ((ARRAY['count'::character varying, 'damage'::character varying, 'theft'::character varying, 'other'::character varying])::text[])))
);


--
-- Name: item_sizes; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE item_sizes (
    size_id uuid DEFAULT uuidv7() NOT NULL,
    size_name character varying(80) NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    retired_at timestamp with time zone
);


--
-- Name: items; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE items (
    item_id uuid DEFAULT uuidv7() NOT NULL,
    sku character varying(64) NOT NULL,
    item_name character varying(255) NOT NULL,
    party_id uuid NOT NULL,
    booth_id uuid,
    price_minor bigint NOT NULL,
    currency character(3) NOT NULL,
    qty_on_hand integer NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    category_id uuid,
    acquisition_minor bigint,
    brand_id uuid,
    color_id uuid,
    size_id uuid,
    item_notes character varying(500),
    received_on date NOT NULL,
    origin character varying(16) DEFAULT 'catalog'::character varying NOT NULL,
    expires_on date,
    commission_bps integer,
    cost_minor bigint,
    department_id uuid,
    CONSTRAINT items_acquisition_nonneg_chk CHECK (((acquisition_minor IS NULL) OR (acquisition_minor >= 0))),
    CONSTRAINT items_commission_bps_chk CHECK (((commission_bps IS NULL) OR ((commission_bps >= 0) AND (commission_bps <= 10000)))),
    CONSTRAINT items_cost_nonneg_chk CHECK (((cost_minor IS NULL) OR (cost_minor >= 0))),
    CONSTRAINT items_currency_chk CHECK ((currency = ANY (ARRAY['USD'::bpchar, 'CAD'::bpchar, 'EUR'::bpchar]))),
    CONSTRAINT items_origin_chk CHECK (((origin)::text = ANY ((ARRAY['catalog'::character varying, 'instant_add'::character varying])::text[]))),
    CONSTRAINT items_price_nonneg_chk CHECK ((price_minor >= 0)),
    CONSTRAINT items_qty_nonneg_chk CHECK ((qty_on_hand >= 0))
);


--
-- Name: journal_lines; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE journal_lines (
    journal_line_id uuid DEFAULT uuidv7() NOT NULL,
    journal_id uuid NOT NULL,
    line_no integer NOT NULL,
    account_id uuid NOT NULL,
    debit_minor bigint DEFAULT 0 NOT NULL,
    credit_minor bigint DEFAULT 0 NOT NULL,
    subledger_type character varying(32),
    subledger_ref uuid,
    memo character varying(255),
    CONSTRAINT journal_lines_nonneg_chk CHECK (((debit_minor >= 0) AND (credit_minor >= 0))),
    CONSTRAINT journal_lines_one_side_chk CHECK ((((debit_minor > 0) AND (credit_minor = 0)) OR ((credit_minor > 0) AND (debit_minor = 0))))
);


--
-- Name: journals; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE journals (
    journal_id uuid DEFAULT uuidv7() NOT NULL,
    book_id uuid NOT NULL,
    journal_no bigint NOT NULL,
    posting_key character varying(190) NOT NULL,
    posting_date date NOT NULL,
    occurred_at timestamp with time zone NOT NULL,
    posted_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    period_id uuid NOT NULL,
    currency character(3) NOT NULL,
    source_type character varying(48) NOT NULL,
    source_reference character varying(190),
    description character varying(255) NOT NULL,
    is_reversal boolean DEFAULT false NOT NULL,
    reverses_journal_id uuid,
    total_debits_minor bigint NOT NULL,
    total_credits_minor bigint NOT NULL,
    prev_hash character(64),
    entry_hash character(64) NOT NULL,
    hash_scheme smallint DEFAULT 1 NOT NULL,
    CONSTRAINT journals_balanced_chk CHECK ((total_debits_minor = total_credits_minor)),
    CONSTRAINT journals_currency_chk CHECK ((currency = ANY (ARRAY['USD'::bpchar, 'CAD'::bpchar, 'EUR'::bpchar]))),
    CONSTRAINT journals_hash_scheme_chk CHECK ((hash_scheme = ANY (ARRAY[1, 2]))),
    CONSTRAINT journals_no_positive_chk CHECK ((journal_no >= 1)),
    CONSTRAINT journals_reversal_requires_target CHECK (((is_reversal = false) OR (reverses_journal_id IS NOT NULL))),
    CONSTRAINT journals_totals_nonneg_chk CHECK ((total_debits_minor >= 0))
);


--
-- Name: layaway_deposits; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE layaway_deposits (
    layaway_deposit_id uuid DEFAULT uuidv7() NOT NULL,
    layaway_id uuid NOT NULL,
    received_on date NOT NULL,
    amount_minor bigint NOT NULL,
    cash_amount_minor bigint NOT NULL,
    card_amount_minor bigint NOT NULL,
    check_amount_minor bigint NOT NULL,
    gift_amount_minor bigint DEFAULT 0 NOT NULL,
    store_credit_amount_minor bigint DEFAULT 0 NOT NULL,
    currency character(3) NOT NULL,
    journal_id uuid NOT NULL,
    reversal_journal_id uuid,
    status character varying(16) DEFAULT 'completed'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    gift_certificate_id uuid,
    store_credit_id uuid,
    CONSTRAINT layaway_deposits_amount_positive_chk CHECK ((amount_minor > 0)),
    CONSTRAINT layaway_deposits_currency_chk CHECK ((currency = ANY (ARRAY['USD'::bpchar, 'CAD'::bpchar, 'EUR'::bpchar]))),
    CONSTRAINT layaway_deposits_gift_id_chk CHECK ((((gift_amount_minor = 0) AND (gift_certificate_id IS NULL)) OR ((gift_amount_minor > 0) AND (gift_certificate_id IS NOT NULL)))),
    CONSTRAINT layaway_deposits_status_chk CHECK (((status)::text = ANY ((ARRAY['completed'::character varying, 'reversed'::character varying])::text[]))),
    CONSTRAINT layaway_deposits_store_credit_id_chk CHECK ((((store_credit_amount_minor = 0) AND (store_credit_id IS NULL)) OR ((store_credit_amount_minor > 0) AND (store_credit_id IS NOT NULL)))),
    CONSTRAINT layaway_deposits_tender_chk CHECK (((cash_amount_minor >= 0) AND (card_amount_minor >= 0) AND (check_amount_minor >= 0) AND (gift_amount_minor >= 0) AND (store_credit_amount_minor >= 0) AND (((((cash_amount_minor + card_amount_minor) + check_amount_minor) + gift_amount_minor) + store_credit_amount_minor) = amount_minor)))
);


--
-- Name: layaway_lines; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE layaway_lines (
    layaway_line_id uuid DEFAULT uuidv7() NOT NULL,
    layaway_id uuid NOT NULL,
    item_id uuid NOT NULL,
    qty integer NOT NULL,
    unit_price_minor bigint NOT NULL,
    currency character(3) NOT NULL,
    CONSTRAINT layaway_lines_currency_chk CHECK ((currency = ANY (ARRAY['USD'::bpchar, 'CAD'::bpchar, 'EUR'::bpchar]))),
    CONSTRAINT layaway_lines_price_chk CHECK ((unit_price_minor >= 0)),
    CONSTRAINT layaway_lines_qty_chk CHECK ((qty > 0))
);


--
-- Name: layaways; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE layaways (
    layaway_id uuid DEFAULT uuidv7() NOT NULL,
    customer_id uuid NOT NULL,
    opened_on date NOT NULL,
    status character varying(16) NOT NULL,
    register_id uuid NOT NULL,
    sale_id uuid,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT layaways_status_chk CHECK (((status)::text = ANY ((ARRAY['open'::character varying, 'completed'::character varying, 'cancelled'::character varying])::text[])))
);


--
-- Name: ledger_books; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE ledger_books (
    book_id uuid DEFAULT uuidv7() NOT NULL,
    code character varying(32) NOT NULL,
    name character varying(120) NOT NULL,
    currency character(3) NOT NULL,
    is_default boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT ledger_books_currency_chk CHECK ((currency = ANY (ARRAY['USD'::bpchar, 'CAD'::bpchar, 'EUR'::bpchar])))
);


--
-- Name: mail_outbox; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE mail_outbox (
    mail_id uuid DEFAULT uuidv7() NOT NULL,
    kind character varying(32) NOT NULL,
    to_email character varying(320) NOT NULL,
    party_id uuid,
    subject character varying(200) NOT NULL,
    body_text text NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    status character varying(16) NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    last_error character varying(500),
    sent_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT mail_outbox_attempts_chk CHECK ((attempts >= 0)),
    CONSTRAINT mail_outbox_kind_chk CHECK (((kind)::text = ANY ((ARRAY['invite'::character varying, 'sale_ping'::character varying, 'weekly_vendor'::character varying, 'password_reset'::character varying, 'sale_receipt'::character varying])::text[]))),
    CONSTRAINT mail_outbox_sent_chk CHECK (((((status)::text = 'sent'::text) AND (sent_at IS NOT NULL)) OR (((status)::text <> 'sent'::text) AND (sent_at IS NULL)))),
    CONSTRAINT mail_outbox_status_chk CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'sent'::character varying, 'failed'::character varying])::text[])))
);


--
-- Name: markdown_policies; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE markdown_policies (
    policy_id uuid DEFAULT uuidv7() NOT NULL,
    policy_name character varying(80) NOT NULL,
    days_after_received integer NOT NULL,
    discount_bps integer NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    absorbed_by character varying(16) DEFAULT 'vendor'::character varying NOT NULL,
    reason character varying(32) DEFAULT 'other'::character varying NOT NULL,
    CONSTRAINT markdown_policies_absorbed_chk CHECK (((absorbed_by)::text = 'vendor'::text)),
    CONSTRAINT markdown_policies_bps_chk CHECK (((discount_bps >= 1) AND (discount_bps <= 10000))),
    CONSTRAINT markdown_policies_days_chk CHECK ((days_after_received >= 1)),
    CONSTRAINT markdown_policies_reason_chk CHECK (((reason)::text = ANY ((ARRAY['damage'::character varying, 'courtesy'::character varying, 'promo'::character varying, 'other'::character varying])::text[])))
);


--
-- Name: membership_staff_roles; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE membership_staff_roles (
    membership_id uuid NOT NULL,
    staff_role_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: open_ticket_lines; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE open_ticket_lines (
    ticket_line_id uuid DEFAULT uuidv7() NOT NULL,
    ticket_id uuid NOT NULL,
    item_id uuid,
    qty integer NOT NULL,
    unit_price_minor bigint NOT NULL,
    currency character(3) NOT NULL,
    line_discount_minor bigint DEFAULT 0 NOT NULL,
    line_discount_bps integer DEFAULT 0 NOT NULL,
    line_name character varying(255) NOT NULL,
    party_id uuid NOT NULL,
    booth_id uuid,
    CONSTRAINT open_ticket_lines_currency_chk CHECK ((currency = ANY (ARRAY['USD'::bpchar, 'CAD'::bpchar, 'EUR'::bpchar]))),
    CONSTRAINT open_ticket_lines_discount_bps_chk CHECK (((line_discount_bps >= 0) AND (line_discount_bps <= 10000))),
    CONSTRAINT open_ticket_lines_discount_nonneg_chk CHECK ((line_discount_minor >= 0)),
    CONSTRAINT open_ticket_lines_kind_chk CHECK (((item_id IS NOT NULL) OR ((item_id IS NULL) AND (btrim((line_name)::text) <> ''::text)))),
    CONSTRAINT open_ticket_lines_price_nonneg_chk CHECK ((unit_price_minor >= 0)),
    CONSTRAINT open_ticket_lines_qty_positive_chk CHECK ((qty >= 1))
);


--
-- Name: open_tickets; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE open_tickets (
    ticket_id uuid DEFAULT uuidv7() NOT NULL,
    register_id uuid NOT NULL,
    opened_by_membership_id uuid NOT NULL,
    status character varying(16) NOT NULL,
    expires_on date,
    completed_sale_id uuid,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    ticket_discount_minor bigint DEFAULT 0 NOT NULL,
    discount_reason character varying(16),
    customer_id uuid,
    tax_exempt boolean DEFAULT false NOT NULL,
    ticket_discount_bps integer DEFAULT 0 NOT NULL,
    hold_label character varying(80),
    CONSTRAINT open_tickets_discount_nonneg_chk CHECK ((ticket_discount_minor >= 0)),
    CONSTRAINT open_tickets_discount_reason_chk CHECK (((discount_reason IS NULL) OR ((discount_reason)::text = ANY ((ARRAY['damage'::character varying, 'courtesy'::character varying, 'promo'::character varying, 'other'::character varying])::text[])))),
    CONSTRAINT open_tickets_hold_expires_chk CHECK (((((status)::text = 'held'::text) AND (expires_on IS NOT NULL)) OR (((status)::text <> 'held'::text) AND (expires_on IS NULL)))),
    CONSTRAINT open_tickets_status_chk CHECK (((status)::text = ANY ((ARRAY['open'::character varying, 'held'::character varying, 'discarded'::character varying, 'completed'::character varying])::text[]))),
    CONSTRAINT open_tickets_ticket_discount_bps_chk CHECK (((ticket_discount_bps >= 0) AND (ticket_discount_bps <= 10000)))
);


--
-- Name: parties; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE parties (
    party_id uuid DEFAULT uuidv7() NOT NULL,
    display_name character varying(255) NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    commission_bps integer DEFAULT 0 NOT NULL,
    first_name character varying(100),
    last_name character varying(100),
    phone character varying(40),
    email character varying(320),
    kind character varying(16) DEFAULT 'vendor'::character varying NOT NULL,
    portal_enabled boolean DEFAULT true NOT NULL,
    custom_id character varying(100),
    payout_held boolean DEFAULT false NOT NULL,
    payout_hold_reason character varying(16),
    payout_payee_name character varying(200),
    pos_line_discount_bps integer DEFAULT 0 NOT NULL,
    address_line character varying(255),
    city character varying(80),
    region character varying(80),
    postal_code character varying(20),
    party_notes character varying(2000),
    agreement_starts_on date,
    agreement_ends_on date,
    tax_id character varying(40),
    linked_customer_id uuid,
    CONSTRAINT parties_commission_bps_chk CHECK (((commission_bps >= 0) AND (commission_bps <= 10000))),
    CONSTRAINT parties_custom_id_charset_chk CHECK (((custom_id IS NULL) OR ((custom_id)::text ~ '^[A-Za-z0-9-]+$'::text))),
    CONSTRAINT parties_house_custom_id_chk CHECK ((((kind)::text <> 'house'::text) OR (custom_id IS NULL))),
    CONSTRAINT parties_kind_chk CHECK (((kind)::text = ANY ((ARRAY['vendor'::character varying, 'house'::character varying])::text[]))),
    CONSTRAINT parties_payout_hold_chk CHECK ((((payout_held = false) AND (payout_hold_reason IS NULL)) OR ((payout_held = true) AND ((payout_hold_reason)::text = ANY ((ARRAY['deceased'::character varying, 'dispute'::character varying, 'exit'::character varying, 'other'::character varying])::text[]))))),
    CONSTRAINT parties_pos_line_discount_bps_chk CHECK (((pos_line_discount_bps >= 0) AND (pos_line_discount_bps <= 10000)))
);


--
-- Name: payable_rent_settlements; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE payable_rent_settlements (
    settlement_id uuid DEFAULT uuidv7() NOT NULL,
    party_id uuid NOT NULL,
    settled_on date NOT NULL,
    amount_minor bigint NOT NULL,
    currency character(3) NOT NULL,
    journal_id uuid NOT NULL,
    status character varying(16) DEFAULT 'completed'::character varying NOT NULL,
    reversal_journal_id uuid,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT payable_rent_settlements_amount_positive_chk CHECK ((amount_minor > 0)),
    CONSTRAINT payable_rent_settlements_currency_chk CHECK ((currency = ANY (ARRAY['USD'::bpchar, 'CAD'::bpchar, 'EUR'::bpchar]))),
    CONSTRAINT payable_rent_settlements_status_chk CHECK (((status)::text = ANY ((ARRAY['completed'::character varying, 'reversed'::character varying])::text[]))),
    CONSTRAINT payable_rent_settlements_void_requires_reversal CHECK (((((status)::text = 'completed'::text) AND (reversal_journal_id IS NULL)) OR (((status)::text = 'reversed'::text) AND (reversal_journal_id IS NOT NULL))))
);


--
-- Name: payout_run_envelopes; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE payout_run_envelopes (
    payout_run_envelope_id uuid DEFAULT uuidv7() NOT NULL,
    payout_run_id uuid NOT NULL,
    party_id uuid NOT NULL,
    holder_payout_id uuid,
    check_amount_minor bigint NOT NULL,
    currency character(3) NOT NULL,
    payload jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT payout_run_envelopes_amount_nonneg_chk CHECK ((check_amount_minor >= 0)),
    CONSTRAINT payout_run_envelopes_currency_chk CHECK ((currency = ANY (ARRAY['USD'::bpchar, 'CAD'::bpchar, 'EUR'::bpchar])))
);


--
-- Name: payout_runs; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE payout_runs (
    payout_run_id uuid DEFAULT uuidv7() NOT NULL,
    paid_on date NOT NULL,
    method character varying(16) NOT NULL,
    status character varying(16) NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT payout_runs_method_chk CHECK (((method)::text = ANY ((ARRAY['check'::character varying, 'cash'::character varying, 'ach'::character varying])::text[]))),
    CONSTRAINT payout_runs_status_chk CHECK (((status)::text = ANY ((ARRAY['completed'::character varying, 'reversed'::character varying])::text[])))
);


--
-- Name: processor_intents; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE processor_intents (
    intent_id uuid DEFAULT uuidv7() NOT NULL,
    kind character varying(16) NOT NULL,
    status character varying(16) NOT NULL,
    ticket_id uuid,
    party_id uuid,
    sale_id uuid,
    rent_receipt_id uuid,
    amount_minor bigint NOT NULL,
    currency character(3) NOT NULL,
    square_checkout_id character varying(64),
    square_payment_id character varying(64),
    posting_key character varying(80) NOT NULL,
    last_error character varying(500),
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    completed_at timestamp with time zone,
    tender_payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT processor_intents_amount_positive_chk CHECK ((amount_minor > 0)),
    CONSTRAINT processor_intents_currency_chk CHECK ((currency = ANY (ARRAY['USD'::bpchar, 'CAD'::bpchar, 'EUR'::bpchar]))),
    CONSTRAINT processor_intents_kind_chk CHECK (((kind)::text = ANY ((ARRAY['sale'::character varying, 'rent_receipt'::character varying])::text[]))),
    CONSTRAINT processor_intents_sale_kind_chk CHECK (((((kind)::text = 'sale'::text) AND (ticket_id IS NOT NULL) AND (party_id IS NULL)) OR (((kind)::text = 'rent_receipt'::text) AND (party_id IS NOT NULL) AND (ticket_id IS NULL)))),
    CONSTRAINT processor_intents_status_chk CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'completed'::character varying, 'canceled'::character varying, 'failed'::character varying])::text[])))
);


--
-- Name: processor_refunds; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE processor_refunds (
    processor_refund_id uuid DEFAULT uuidv7() NOT NULL,
    intent_id uuid NOT NULL,
    kind character varying(16) NOT NULL,
    sale_id uuid,
    sale_return_id uuid,
    rent_receipt_id uuid,
    amount_minor bigint NOT NULL,
    currency character(3) NOT NULL,
    status character varying(16) NOT NULL,
    square_refund_id character varying(64),
    idempotency_key character varying(190) NOT NULL,
    posting_key character varying(190) NOT NULL,
    last_error character varying(500),
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    completed_at timestamp with time zone,
    CONSTRAINT processor_refunds_amount_positive_chk CHECK ((amount_minor > 0)),
    CONSTRAINT processor_refunds_currency_chk CHECK ((currency = ANY (ARRAY['USD'::bpchar, 'CAD'::bpchar, 'EUR'::bpchar]))),
    CONSTRAINT processor_refunds_kind_chk CHECK (((kind)::text = ANY ((ARRAY['sale_void'::character varying, 'sale_return'::character varying, 'rent_reverse'::character varying])::text[]))),
    CONSTRAINT processor_refunds_kind_refs_chk CHECK (((((kind)::text = 'sale_void'::text) AND (sale_id IS NOT NULL) AND (sale_return_id IS NULL) AND (rent_receipt_id IS NULL)) OR (((kind)::text = 'sale_return'::text) AND (sale_id IS NOT NULL) AND (sale_return_id IS NOT NULL) AND (rent_receipt_id IS NULL)) OR (((kind)::text = 'rent_reverse'::text) AND (rent_receipt_id IS NOT NULL) AND (sale_id IS NULL) AND (sale_return_id IS NULL)))),
    CONSTRAINT processor_refunds_status_chk CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'completed'::character varying, 'failed'::character varying])::text[])))
);


--
-- Name: register_cash_drops; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE register_cash_drops (
    cash_drop_id uuid DEFAULT uuidv7() NOT NULL,
    register_session_id uuid NOT NULL,
    amount_minor bigint NOT NULL,
    currency character(3) NOT NULL,
    note character varying(255),
    dropped_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    dropped_by_membership_id uuid NOT NULL,
    CONSTRAINT register_cash_drops_amount_positive_chk CHECK ((amount_minor > 0)),
    CONSTRAINT register_cash_drops_currency_chk CHECK ((currency = ANY (ARRAY['USD'::bpchar, 'CAD'::bpchar, 'EUR'::bpchar])))
);


--
-- Name: register_sessions; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE register_sessions (
    register_session_id uuid DEFAULT uuidv7() NOT NULL,
    register_id uuid NOT NULL,
    opened_by_membership_id uuid NOT NULL,
    opened_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    opening_cash_minor bigint NOT NULL,
    currency character(3) NOT NULL,
    closed_at timestamp with time zone,
    closed_by_membership_id uuid,
    closing_cash_minor bigint,
    force_closed boolean DEFAULT false NOT NULL,
    closing_checks_minor bigint,
    opening_cash_counts jsonb,
    closing_cash_counts jsonb,
    owner_kind character varying(16) DEFAULT 'store'::character varying NOT NULL,
    owner_party_id uuid,
    CONSTRAINT register_sessions_close_chk CHECK ((((closed_at IS NULL) AND (closed_by_membership_id IS NULL) AND (closing_cash_minor IS NULL)) OR ((closed_at IS NOT NULL) AND (closed_by_membership_id IS NOT NULL) AND (closing_cash_minor IS NOT NULL)))),
    CONSTRAINT register_sessions_closing_checks_nonneg_chk CHECK (((closing_checks_minor IS NULL) OR (closing_checks_minor >= 0))),
    CONSTRAINT register_sessions_closing_nonneg_chk CHECK (((closing_cash_minor IS NULL) OR (closing_cash_minor >= 0))),
    CONSTRAINT register_sessions_currency_chk CHECK ((currency = ANY (ARRAY['USD'::bpchar, 'CAD'::bpchar, 'EUR'::bpchar]))),
    CONSTRAINT register_sessions_opening_nonneg_chk CHECK ((opening_cash_minor >= 0)),
    CONSTRAINT register_sessions_owner_chk CHECK ((((owner_kind)::text = 'store'::text) AND (owner_party_id IS NULL)))
);


--
-- Name: COLUMN register_sessions.owner_kind; Type: COMMENT; Schema: nest_tenant; Owner: -
--

COMMENT ON COLUMN register_sessions.owner_kind IS 'Store-owned till. A later migration MAY allow vendor-owned sessions with owner_party_id set.';


--
-- Name: registers; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE registers (
    register_id uuid DEFAULT uuidv7() NOT NULL,
    register_name character varying(100) NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    location_id uuid NOT NULL
);


--
-- Name: rent_charges; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE rent_charges (
    rent_charge_id uuid DEFAULT uuidv7() NOT NULL,
    assignment_id uuid NOT NULL,
    period_starts_on date NOT NULL,
    period_ends_on date NOT NULL,
    amount_minor bigint NOT NULL,
    currency character(3) NOT NULL,
    journal_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    status character varying(16) DEFAULT 'completed'::character varying NOT NULL,
    reversal_journal_id uuid,
    CONSTRAINT rent_charges_amount_positive_chk CHECK ((amount_minor > 0)),
    CONSTRAINT rent_charges_currency_chk CHECK ((currency = ANY (ARRAY['USD'::bpchar, 'CAD'::bpchar, 'EUR'::bpchar]))),
    CONSTRAINT rent_charges_range_chk CHECK ((period_ends_on >= period_starts_on)),
    CONSTRAINT rent_charges_status_chk CHECK (((status)::text = ANY ((ARRAY['completed'::character varying, 'reversed'::character varying])::text[]))),
    CONSTRAINT rent_charges_void_requires_reversal CHECK (((((status)::text = 'completed'::text) AND (reversal_journal_id IS NULL)) OR (((status)::text = 'reversed'::text) AND (reversal_journal_id IS NOT NULL))))
);


--
-- Name: rent_late_fees; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE rent_late_fees (
    rent_late_fee_id uuid DEFAULT uuidv7() NOT NULL,
    party_id uuid NOT NULL,
    period_starts_on date NOT NULL,
    period_ends_on date NOT NULL,
    assessed_on date NOT NULL,
    amount_minor bigint NOT NULL,
    currency character(3) NOT NULL,
    journal_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    status character varying(16) DEFAULT 'completed'::character varying NOT NULL,
    reversal_journal_id uuid,
    CONSTRAINT rent_late_fees_amount_positive_chk CHECK ((amount_minor > 0)),
    CONSTRAINT rent_late_fees_currency_chk CHECK ((currency = ANY (ARRAY['USD'::bpchar, 'CAD'::bpchar, 'EUR'::bpchar]))),
    CONSTRAINT rent_late_fees_range_chk CHECK ((period_ends_on >= period_starts_on)),
    CONSTRAINT rent_late_fees_status_chk CHECK (((status)::text = ANY ((ARRAY['completed'::character varying, 'reversed'::character varying])::text[]))),
    CONSTRAINT rent_late_fees_void_requires_reversal CHECK (((((status)::text = 'completed'::text) AND (reversal_journal_id IS NULL)) OR (((status)::text = 'reversed'::text) AND (reversal_journal_id IS NOT NULL))))
);


--
-- Name: rent_receipts; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE rent_receipts (
    rent_receipt_id uuid DEFAULT uuidv7() NOT NULL,
    party_id uuid NOT NULL,
    received_on date NOT NULL,
    amount_minor bigint NOT NULL,
    currency character(3) NOT NULL,
    journal_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    status character varying(16) DEFAULT 'completed'::character varying NOT NULL,
    reversal_journal_id uuid,
    register_session_id uuid,
    method character varying(16) DEFAULT 'cash'::character varying NOT NULL,
    card_ref character varying(64),
    card_last4 character(4),
    check_number character varying(32),
    deposited_id uuid,
    card_settlement_id uuid,
    CONSTRAINT rent_receipts_amount_positive_chk CHECK ((amount_minor > 0)),
    CONSTRAINT rent_receipts_card_last4_chk CHECK (((card_last4 IS NULL) OR (card_last4 ~ '^[0-9]{4}$'::text))),
    CONSTRAINT rent_receipts_currency_chk CHECK ((currency = ANY (ARRAY['USD'::bpchar, 'CAD'::bpchar, 'EUR'::bpchar]))),
    CONSTRAINT rent_receipts_method_chk CHECK (((method)::text = ANY ((ARRAY['cash'::character varying, 'card'::character varying, 'check'::character varying])::text[]))),
    CONSTRAINT rent_receipts_status_chk CHECK (((status)::text = ANY ((ARRAY['completed'::character varying, 'reversed'::character varying])::text[]))),
    CONSTRAINT rent_receipts_tender_fields_chk CHECK (((((method)::text = 'cash'::text) AND (card_ref IS NULL) AND (card_last4 IS NULL) AND (check_number IS NULL) AND (deposited_id IS NULL)) OR (((method)::text = 'card'::text) AND (check_number IS NULL) AND (deposited_id IS NULL)) OR (((method)::text = 'check'::text) AND (card_ref IS NULL) AND (card_last4 IS NULL) AND (check_number IS NOT NULL)))),
    CONSTRAINT rent_receipts_void_requires_reversal CHECK (((((status)::text = 'completed'::text) AND (reversal_journal_id IS NULL)) OR (((status)::text = 'reversed'::text) AND (reversal_journal_id IS NOT NULL))))
);


--
-- Name: sale_lines; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE sale_lines (
    sale_line_id uuid DEFAULT uuidv7() NOT NULL,
    sale_id uuid NOT NULL,
    item_id uuid,
    qty integer NOT NULL,
    unit_price_minor bigint NOT NULL,
    line_total_minor bigint NOT NULL,
    tax_minor bigint NOT NULL,
    commission_minor bigint NOT NULL,
    holder_minor bigint NOT NULL,
    line_discount_minor bigint DEFAULT 0 NOT NULL,
    ticket_discount_minor bigint DEFAULT 0 NOT NULL,
    line_discount_bps integer DEFAULT 0 NOT NULL,
    party_id uuid NOT NULL,
    reassigned_from_party_id uuid,
    reassigned_at timestamp with time zone,
    reassigned_by_membership_id uuid,
    line_name character varying(255) NOT NULL,
    booth_id uuid,
    cost_minor bigint DEFAULT 0 NOT NULL,
    CONSTRAINT sale_lines_amounts_nonneg_chk CHECK (((unit_price_minor >= 0) AND (line_total_minor >= 0) AND (tax_minor >= 0) AND (commission_minor >= 0) AND (holder_minor >= 0))),
    CONSTRAINT sale_lines_cost_nonneg_chk CHECK ((cost_minor >= 0)),
    CONSTRAINT sale_lines_discount_bps_chk CHECK (((line_discount_bps >= 0) AND (line_discount_bps <= 10000))),
    CONSTRAINT sale_lines_discount_nonneg_chk CHECK (((line_discount_minor >= 0) AND (ticket_discount_minor >= 0))),
    CONSTRAINT sale_lines_kind_chk CHECK (((item_id IS NOT NULL) OR ((item_id IS NULL) AND (btrim((line_name)::text) <> ''::text)))),
    CONSTRAINT sale_lines_qty_positive_chk CHECK ((qty >= 1))
);


--
-- Name: sale_return_lines; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE sale_return_lines (
    sale_return_line_id uuid DEFAULT uuidv7() NOT NULL,
    sale_return_id uuid NOT NULL,
    sale_line_id uuid NOT NULL,
    qty integer NOT NULL,
    line_total_minor bigint NOT NULL,
    tax_minor bigint NOT NULL,
    commission_minor bigint NOT NULL,
    holder_minor bigint NOT NULL,
    cost_minor bigint DEFAULT 0 NOT NULL,
    CONSTRAINT sale_return_lines_amounts_nonneg_chk CHECK (((line_total_minor >= 0) AND (tax_minor >= 0) AND (commission_minor >= 0) AND (holder_minor >= 0))),
    CONSTRAINT sale_return_lines_cost_nonneg_chk CHECK ((cost_minor >= 0)),
    CONSTRAINT sale_return_lines_qty_positive_chk CHECK ((qty >= 1))
);


--
-- Name: sale_returns; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE sale_returns (
    sale_return_id uuid DEFAULT uuidv7() NOT NULL,
    sale_id uuid NOT NULL,
    returned_on date NOT NULL,
    amount_minor bigint NOT NULL,
    currency character(3) NOT NULL,
    journal_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    cash_amount_minor bigint NOT NULL,
    card_amount_minor bigint NOT NULL,
    check_amount_minor bigint NOT NULL,
    gift_amount_minor bigint NOT NULL,
    vendor_purchase_amount_minor bigint DEFAULT 0 NOT NULL,
    store_credit_amount_minor bigint DEFAULT 0 NOT NULL,
    cash_rounding_adjustment_minor bigint DEFAULT 0 NOT NULL,
    CONSTRAINT sale_returns_amount_positive_chk CHECK ((amount_minor > 0)),
    CONSTRAINT sale_returns_currency_chk CHECK ((currency = ANY (ARRAY['USD'::bpchar, 'CAD'::bpchar, 'EUR'::bpchar]))),
    CONSTRAINT sale_returns_tender_chk CHECK (((cash_amount_minor >= 0) AND (card_amount_minor >= 0) AND (check_amount_minor >= 0) AND (gift_amount_minor >= 0) AND (vendor_purchase_amount_minor >= 0) AND (store_credit_amount_minor >= 0) AND (((((((cash_amount_minor + card_amount_minor) + check_amount_minor) + gift_amount_minor) + vendor_purchase_amount_minor) + store_credit_amount_minor) - cash_rounding_adjustment_minor) = amount_minor)))
);


--
-- Name: sale_tenders; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE sale_tenders (
    sale_tender_id uuid DEFAULT uuidv7() NOT NULL,
    sale_id uuid NOT NULL,
    method character varying(16) NOT NULL,
    amount_minor bigint NOT NULL,
    card_ref character varying(64),
    card_last4 character(4),
    check_number character varying(32),
    gift_certificate_id uuid,
    vendor_purchase_id uuid,
    deposited_id uuid,
    card_settlement_id uuid,
    store_credit_id uuid,
    CONSTRAINT sale_tenders_amount_positive_chk CHECK ((amount_minor > 0)),
    CONSTRAINT sale_tenders_card_last4_chk CHECK (((card_last4 IS NULL) OR (card_last4 ~ '^[0-9]{4}$'::text))),
    CONSTRAINT sale_tenders_fields_chk CHECK (((((method)::text = 'cash'::text) AND (card_ref IS NULL) AND (card_last4 IS NULL) AND (check_number IS NULL) AND (gift_certificate_id IS NULL) AND (vendor_purchase_id IS NULL)) OR (((method)::text = 'card'::text) AND (check_number IS NULL) AND (gift_certificate_id IS NULL) AND (vendor_purchase_id IS NULL)) OR (((method)::text = 'check'::text) AND (card_ref IS NULL) AND (card_last4 IS NULL) AND (gift_certificate_id IS NULL) AND (vendor_purchase_id IS NULL)) OR (((method)::text = 'gift'::text) AND (gift_certificate_id IS NOT NULL) AND (card_ref IS NULL) AND (card_last4 IS NULL) AND (check_number IS NULL) AND (vendor_purchase_id IS NULL)) OR (((method)::text = 'vendor_purchase'::text) AND (vendor_purchase_id IS NOT NULL) AND (card_ref IS NULL) AND (card_last4 IS NULL) AND (check_number IS NULL) AND (gift_certificate_id IS NULL)))),
    CONSTRAINT sale_tenders_method_chk CHECK (((method)::text = ANY ((ARRAY['cash'::character varying, 'card'::character varying, 'check'::character varying, 'gift'::character varying, 'vendor_purchase'::character varying, 'store_credit'::character varying])::text[])))
);


--
-- Name: sales; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE sales (
    sale_id uuid DEFAULT uuidv7() NOT NULL,
    register_id uuid NOT NULL,
    sold_on date NOT NULL,
    sold_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    currency character(3) NOT NULL,
    status character varying(16) NOT NULL,
    journal_id uuid NOT NULL,
    reversal_journal_id uuid,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    open_ticket_id uuid,
    ticket_discount_minor bigint DEFAULT 0 NOT NULL,
    discount_reason character varying(16),
    customer_id uuid,
    tax_exempt boolean DEFAULT false NOT NULL,
    ticket_discount_bps integer DEFAULT 0 NOT NULL,
    house_buy boolean DEFAULT false NOT NULL,
    change_minor bigint DEFAULT 0 NOT NULL,
    cash_rounding_adjustment_minor bigint DEFAULT 0 NOT NULL,
    checkout_kind character varying(16) DEFAULT 'central'::character varying NOT NULL,
    CONSTRAINT sales_change_nonneg_chk CHECK ((change_minor >= 0)),
    CONSTRAINT sales_checkout_kind_chk CHECK (((checkout_kind)::text = 'central'::text)),
    CONSTRAINT sales_currency_chk CHECK ((currency = ANY (ARRAY['USD'::bpchar, 'CAD'::bpchar, 'EUR'::bpchar]))),
    CONSTRAINT sales_discount_reason_chk CHECK (((discount_reason IS NULL) OR ((discount_reason)::text = ANY ((ARRAY['damage'::character varying, 'courtesy'::character varying, 'promo'::character varying, 'other'::character varying])::text[])))),
    CONSTRAINT sales_status_chk CHECK (((status)::text = ANY ((ARRAY['completed'::character varying, 'voided'::character varying])::text[]))),
    CONSTRAINT sales_ticket_discount_bps_chk CHECK (((ticket_discount_bps >= 0) AND (ticket_discount_bps <= 10000))),
    CONSTRAINT sales_ticket_discount_nonneg_chk CHECK ((ticket_discount_minor >= 0)),
    CONSTRAINT sales_void_requires_reversal CHECK (((((status)::text = 'completed'::text) AND (reversal_journal_id IS NULL)) OR (((status)::text = 'voided'::text) AND (reversal_journal_id IS NOT NULL))))
);


--
-- Name: COLUMN sales.checkout_kind; Type: COMMENT; Schema: nest_tenant; Owner: -
--

COMMENT ON COLUMN sales.checkout_kind IS 'Staff-operated central checkout. Widen the CHECK to add vendor-run later; do not add a second ledger.';


--
-- Name: scheduled_markdowns; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE scheduled_markdowns (
    markdown_id uuid DEFAULT uuidv7() NOT NULL,
    item_id uuid NOT NULL,
    takes_effect_on date NOT NULL,
    price_minor bigint NOT NULL,
    currency character(3) NOT NULL,
    status character varying(16) DEFAULT 'scheduled'::character varying NOT NULL,
    applied_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    absorbed_by character varying(16) DEFAULT 'vendor'::character varying NOT NULL,
    reason character varying(32) DEFAULT 'other'::character varying NOT NULL,
    CONSTRAINT scheduled_markdowns_absorbed_chk CHECK (((absorbed_by)::text = 'vendor'::text)),
    CONSTRAINT scheduled_markdowns_applied_chk CHECK (((((status)::text = 'applied'::text) AND (applied_at IS NOT NULL)) OR (((status)::text <> 'applied'::text) AND (applied_at IS NULL)))),
    CONSTRAINT scheduled_markdowns_currency_chk CHECK ((currency = ANY (ARRAY['USD'::bpchar, 'CAD'::bpchar, 'EUR'::bpchar]))),
    CONSTRAINT scheduled_markdowns_price_nonneg_chk CHECK ((price_minor >= 0)),
    CONSTRAINT scheduled_markdowns_reason_chk CHECK (((reason)::text = ANY ((ARRAY['damage'::character varying, 'courtesy'::character varying, 'promo'::character varying, 'other'::character varying])::text[]))),
    CONSTRAINT scheduled_markdowns_status_chk CHECK (((status)::text = ANY ((ARRAY['scheduled'::character varying, 'applied'::character varying, 'cancelled'::character varying])::text[])))
);


--
-- Name: COLUMN scheduled_markdowns.absorbed_by; Type: COMMENT; Schema: nest_tenant; Owner: -
--

COMMENT ON COLUMN scheduled_markdowns.absorbed_by IS 'Who takes the price cut. Vendor-only until named store-share sale math exists.';


--
-- Name: setup_step_progress; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE setup_step_progress (
    step_id character varying(64) NOT NULL,
    completed_at timestamp with time zone NOT NULL,
    source character varying(32) NOT NULL,
    CONSTRAINT setup_step_progress_source_check CHECK (((source)::text = ANY ((ARRAY['system'::character varying, 'owner'::character varying])::text[])))
);


--
-- Name: staff_roles; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE staff_roles (
    staff_role_id uuid DEFAULT uuidv7() NOT NULL,
    role_name character varying(80) NOT NULL,
    permissions text[] DEFAULT ARRAY[]::text[] NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: store_credit_redemptions; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE store_credit_redemptions (
    redemption_id uuid DEFAULT uuidv7() NOT NULL,
    store_credit_id uuid NOT NULL,
    sale_id uuid NOT NULL,
    amount_minor bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT store_credit_redemptions_amount_positive_chk CHECK ((amount_minor > 0))
);


--
-- Name: store_credit_seq; Type: SEQUENCE; Schema: nest_tenant; Owner: -
--

CREATE SEQUENCE store_credit_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: store_credits; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE store_credits (
    store_credit_id uuid DEFAULT uuidv7() NOT NULL,
    credit_no character varying(32) NOT NULL,
    customer_id uuid,
    issued_on date NOT NULL,
    face_amount_minor bigint NOT NULL,
    remaining_minor bigint NOT NULL,
    cash_amount_minor bigint NOT NULL,
    card_amount_minor bigint NOT NULL,
    check_amount_minor bigint NOT NULL,
    currency character(3) NOT NULL,
    status character varying(16) NOT NULL,
    journal_id uuid NOT NULL,
    reversal_journal_id uuid,
    register_id uuid,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT store_credits_currency_chk CHECK ((currency = ANY (ARRAY['USD'::bpchar, 'CAD'::bpchar, 'EUR'::bpchar]))),
    CONSTRAINT store_credits_face_positive_chk CHECK ((face_amount_minor > 0)),
    CONSTRAINT store_credits_remaining_chk CHECK (((remaining_minor >= 0) AND (remaining_minor <= face_amount_minor))),
    CONSTRAINT store_credits_status_chk CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'voided'::character varying])::text[]))),
    CONSTRAINT store_credits_tender_chk CHECK (((cash_amount_minor >= 0) AND (card_amount_minor >= 0) AND (check_amount_minor >= 0) AND (((cash_amount_minor + card_amount_minor) + check_amount_minor) = face_amount_minor))),
    CONSTRAINT store_credits_void_chk CHECK (((((status)::text = 'active'::text) AND (reversal_journal_id IS NULL)) OR (((status)::text = 'voided'::text) AND (reversal_journal_id IS NOT NULL))))
);


--
-- Name: store_locations; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE store_locations (
    location_id uuid DEFAULT uuidv7() NOT NULL,
    location_name character varying(80) NOT NULL,
    is_default boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: store_settings; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE store_settings (
    store_settings_id boolean DEFAULT true NOT NULL,
    rent_cycle_day integer DEFAULT 1 NOT NULL,
    cashier_may_discount boolean DEFAULT false NOT NULL,
    rent_period character varying(16) DEFAULT 'monthly'::character varying NOT NULL,
    vendor_portal_enabled boolean DEFAULT true NOT NULL,
    vendor_may_add_items boolean DEFAULT false NOT NULL,
    vendor_may_print_barcodes boolean DEFAULT false NOT NULL,
    vendor_sale_email boolean DEFAULT true NOT NULL,
    vendor_weekly_email boolean DEFAULT true NOT NULL,
    square_enabled boolean DEFAULT false NOT NULL,
    label_sheet_profile character varying(32) DEFAULT 'avery_8160'::character varying NOT NULL,
    label_copies_mode character varying(16) DEFAULT 'one'::character varying NOT NULL,
    late_fee_mode character varying(16) DEFAULT 'off'::character varying NOT NULL,
    late_fee_grace_days integer DEFAULT 0 NOT NULL,
    late_fee_amount_minor bigint,
    late_fee_second_after_days integer,
    late_fee_second_amount_minor bigint,
    check_print_enabled boolean DEFAULT false NOT NULL,
    check_print_layout character varying(8) DEFAULT '3_up'::character varying NOT NULL,
    check_print_next_number integer DEFAULT 1001 NOT NULL,
    check_print_offset_x_in numeric(8,4) DEFAULT 0 NOT NULL,
    check_print_offset_y_in numeric(8,4) DEFAULT 0 NOT NULL,
    return_days integer,
    print_receipt_on_checkout boolean DEFAULT true NOT NULL,
    printer_host character varying(255),
    printer_port integer DEFAULT 9100 NOT NULL,
    open_drawer_on_sale boolean DEFAULT false NOT NULL,
    sales_tax_e5 integer DEFAULT 0 NOT NULL,
    intake_show_category boolean DEFAULT false NOT NULL,
    intake_show_brand boolean DEFAULT false NOT NULL,
    intake_show_color boolean DEFAULT false NOT NULL,
    intake_show_size boolean DEFAULT false NOT NULL,
    intake_show_notes boolean DEFAULT false NOT NULL,
    legal_name character varying(255),
    company_address character varying(500),
    company_phone character varying(40),
    consignment_policy character varying(8000),
    label_printer_host character varying(253),
    label_printer_port integer DEFAULT 9100 NOT NULL,
    qz_enabled boolean DEFAULT false NOT NULL,
    webusb_drawer boolean DEFAULT false NOT NULL,
    layaway_enabled boolean DEFAULT false NOT NULL,
    pos_booth_tag_enabled boolean DEFAULT false NOT NULL,
    kiosk_hub_enabled boolean DEFAULT false NOT NULL,
    cash_rounding_increment smallint DEFAULT 1 NOT NULL,
    CONSTRAINT store_settings_cash_rounding_increment_chk CHECK ((cash_rounding_increment = ANY (ARRAY[1, 5, 10, 25]))),
    CONSTRAINT store_settings_check_print_layout_chk CHECK (((check_print_layout)::text = ANY ((ARRAY['3_up'::character varying, '1_up'::character varying])::text[]))),
    CONSTRAINT store_settings_check_print_next_chk CHECK ((check_print_next_number > 0)),
    CONSTRAINT store_settings_label_copies_mode_chk CHECK (((label_copies_mode)::text = ANY ((ARRAY['one'::character varying, 'on_hand'::character varying])::text[]))),
    CONSTRAINT store_settings_label_printer_port_chk CHECK (((label_printer_port >= 1) AND (label_printer_port <= 65535))),
    CONSTRAINT store_settings_label_sheet_profile_chk CHECK (((label_sheet_profile)::text = ANY ((ARRAY['avery_8160'::character varying, 'avery_94073'::character varying])::text[]))),
    CONSTRAINT store_settings_late_fee_amount_chk CHECK (((late_fee_amount_minor IS NULL) OR (late_fee_amount_minor > 0))),
    CONSTRAINT store_settings_late_fee_grace_chk CHECK (((late_fee_grace_days >= 0) AND (late_fee_grace_days <= 90))),
    CONSTRAINT store_settings_late_fee_mode_chk CHECK (((late_fee_mode)::text = ANY ((ARRAY['off'::character varying, 'flat'::character varying, 'tiered'::character varying])::text[]))),
    CONSTRAINT store_settings_late_fee_second_amount_chk CHECK (((late_fee_second_amount_minor IS NULL) OR (late_fee_second_amount_minor > 0))),
    CONSTRAINT store_settings_late_fee_second_days_chk CHECK (((late_fee_second_after_days IS NULL) OR ((late_fee_second_after_days > late_fee_grace_days) AND (late_fee_second_after_days <= 180)))),
    CONSTRAINT store_settings_printer_host_chk CHECK (((printer_host IS NULL) OR ((printer_host)::text ~ '^[A-Za-z0-9][A-Za-z0-9.-]{0,253}$'::text))),
    CONSTRAINT store_settings_printer_port_chk CHECK (((printer_port >= 1) AND (printer_port <= 65535))),
    CONSTRAINT store_settings_rent_day_chk CHECK (((rent_cycle_day >= 1) AND (rent_cycle_day <= 28))),
    CONSTRAINT store_settings_rent_period_chk CHECK (((rent_period)::text = ANY ((ARRAY['monthly'::character varying, 'weekly'::character varying, 'biweekly'::character varying])::text[]))),
    CONSTRAINT store_settings_return_days_chk CHECK (((return_days IS NULL) OR ((return_days >= 1) AND (return_days <= 365)))),
    CONSTRAINT store_settings_store_settings_id_check CHECK (store_settings_id),
    CONSTRAINT store_settings_tax_e5_chk CHECK (((sales_tax_e5 >= 0) AND (sales_tax_e5 <= 100000)))
);


--
-- Name: tax_form_thresholds; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE tax_form_thresholds (
    form_code character varying(16) NOT NULL,
    box_code character varying(8) NOT NULL,
    tax_year smallint NOT NULL,
    amount_minor bigint NOT NULL,
    currency character(3) NOT NULL,
    CONSTRAINT tax_form_thresholds_amount_chk CHECK ((amount_minor > 0)),
    CONSTRAINT tax_form_thresholds_form_chk CHECK ((((form_code)::text = '1099-NEC'::text) AND ((box_code)::text = '1'::text)))
);


--
-- Name: tax_year_payments; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE tax_year_payments (
    tax_year_payment_id uuid DEFAULT uuidv7() NOT NULL,
    party_id uuid NOT NULL,
    tax_year smallint NOT NULL,
    payment_date date NOT NULL,
    amount_minor bigint NOT NULL,
    currency character(3) NOT NULL,
    form_code character varying(16) DEFAULT '1099-NEC'::character varying NOT NULL,
    source_type character varying(32) NOT NULL,
    source_id uuid NOT NULL,
    kind character varying(16) NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT tax_year_payments_amount_chk CHECK (((((kind)::text = 'payment'::text) AND (amount_minor > 0)) OR (((kind)::text = 'reversal'::text) AND (amount_minor < 0)))),
    CONSTRAINT tax_year_payments_form_chk CHECK (((form_code)::text = '1099-NEC'::text)),
    CONSTRAINT tax_year_payments_kind_chk CHECK (((kind)::text = ANY ((ARRAY['payment'::character varying, 'reversal'::character varying])::text[]))),
    CONSTRAINT tax_year_payments_source_chk CHECK (((source_type)::text = 'holder_payout'::text)),
    CONSTRAINT tax_year_payments_year_chk CHECK ((tax_year = (EXTRACT(year FROM payment_date))::smallint))
);


--
-- Name: TABLE tax_year_payments; Type: COMMENT; Schema: nest_tenant; Owner: -
--

COMMENT ON TABLE tax_year_payments IS 'Cash that moved to a vendor, dated to the original payout day. Reversal nets the same tax year. Not a journal.';


--
-- Name: vendor_clawback_applies; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE vendor_clawback_applies (
    vendor_clawback_apply_id uuid DEFAULT uuidv7() NOT NULL,
    party_id uuid NOT NULL,
    holder_payout_id uuid,
    applied_on date NOT NULL,
    amount_minor bigint NOT NULL,
    currency character(3) NOT NULL,
    journal_id uuid NOT NULL,
    status character varying(16) NOT NULL,
    reversal_journal_id uuid,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT vendor_clawback_applies_amount_positive_chk CHECK ((amount_minor > 0)),
    CONSTRAINT vendor_clawback_applies_currency_chk CHECK ((currency = ANY (ARRAY['USD'::bpchar, 'CAD'::bpchar, 'EUR'::bpchar]))),
    CONSTRAINT vendor_clawback_applies_status_chk CHECK (((status)::text = ANY ((ARRAY['completed'::character varying, 'reversed'::character varying])::text[]))),
    CONSTRAINT vendor_clawback_applies_void_chk CHECK (((((status)::text = 'completed'::text) AND (reversal_journal_id IS NULL)) OR (((status)::text = 'reversed'::text) AND (reversal_journal_id IS NOT NULL))))
);


--
-- Name: vendor_clawbacks; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE vendor_clawbacks (
    vendor_clawback_id uuid DEFAULT uuidv7() NOT NULL,
    party_id uuid NOT NULL,
    clawed_on date NOT NULL,
    amount_minor bigint NOT NULL,
    currency character(3) NOT NULL,
    source_type character varying(16) NOT NULL,
    source_id uuid NOT NULL,
    journal_id uuid NOT NULL,
    status character varying(16) NOT NULL,
    reversal_journal_id uuid,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT vendor_clawbacks_amount_positive_chk CHECK ((amount_minor > 0)),
    CONSTRAINT vendor_clawbacks_currency_chk CHECK ((currency = ANY (ARRAY['USD'::bpchar, 'CAD'::bpchar, 'EUR'::bpchar]))),
    CONSTRAINT vendor_clawbacks_source_chk CHECK (((source_type)::text = ANY ((ARRAY['sale_return'::character varying, 'sale_void'::character varying, 'reassign'::character varying])::text[]))),
    CONSTRAINT vendor_clawbacks_status_chk CHECK (((status)::text = ANY ((ARRAY['completed'::character varying, 'reversed'::character varying])::text[]))),
    CONSTRAINT vendor_clawbacks_void_chk CHECK (((((status)::text = 'completed'::text) AND (reversal_journal_id IS NULL)) OR (((status)::text = 'reversed'::text) AND (reversal_journal_id IS NOT NULL))))
);


--
-- Name: vendor_purchases; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE vendor_purchases (
    vendor_purchase_id uuid DEFAULT uuidv7() NOT NULL,
    party_id uuid NOT NULL,
    sale_id uuid NOT NULL,
    amount_minor bigint NOT NULL,
    currency character(3) NOT NULL,
    status character varying(16) NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT vendor_purchases_amount_positive_chk CHECK ((amount_minor > 0)),
    CONSTRAINT vendor_purchases_currency_chk CHECK ((currency = ANY (ARRAY['USD'::bpchar, 'CAD'::bpchar, 'EUR'::bpchar]))),
    CONSTRAINT vendor_purchases_status_chk CHECK (((status)::text = ANY ((ARRAY['completed'::character varying, 'reversed'::character varying])::text[])))
);


--
-- Name: vendor_unclaimed; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE vendor_unclaimed (
    vendor_unclaimed_id uuid DEFAULT uuidv7() NOT NULL,
    party_id uuid NOT NULL,
    moved_on date NOT NULL,
    amount_minor bigint NOT NULL,
    currency character(3) NOT NULL,
    journal_id uuid NOT NULL,
    status character varying(16) NOT NULL,
    reversal_journal_id uuid,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT vendor_unclaimed_amount_positive_chk CHECK ((amount_minor > 0)),
    CONSTRAINT vendor_unclaimed_currency_chk CHECK ((currency = ANY (ARRAY['USD'::bpchar, 'CAD'::bpchar, 'EUR'::bpchar]))),
    CONSTRAINT vendor_unclaimed_status_chk CHECK (((status)::text = ANY ((ARRAY['completed'::character varying, 'reversed'::character varying])::text[]))),
    CONSTRAINT vendor_unclaimed_void_chk CHECK (((((status)::text = 'completed'::text) AND (reversal_journal_id IS NULL)) OR (((status)::text = 'reversed'::text) AND (reversal_journal_id IS NOT NULL))))
);


--
-- Name: vendor_writeoffs; Type: TABLE; Schema: nest_tenant; Owner: -
--

CREATE TABLE vendor_writeoffs (
    vendor_writeoff_id uuid DEFAULT uuidv7() NOT NULL,
    party_id uuid NOT NULL,
    written_on date NOT NULL,
    amount_minor bigint NOT NULL,
    currency character(3) NOT NULL,
    bucket character varying(8) NOT NULL,
    reason character varying(255) NOT NULL,
    journal_id uuid NOT NULL,
    status character varying(16) NOT NULL,
    reversal_journal_id uuid,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT vendor_writeoffs_amount_positive_chk CHECK ((amount_minor > 0)),
    CONSTRAINT vendor_writeoffs_bucket_chk CHECK (((bucket)::text = ANY ((ARRAY['1310'::character varying, '1300'::character varying])::text[]))),
    CONSTRAINT vendor_writeoffs_currency_chk CHECK ((currency = ANY (ARRAY['USD'::bpchar, 'CAD'::bpchar, 'EUR'::bpchar]))),
    CONSTRAINT vendor_writeoffs_status_chk CHECK (((status)::text = ANY ((ARRAY['completed'::character varying, 'reversed'::character varying])::text[]))),
    CONSTRAINT vendor_writeoffs_void_chk CHECK (((((status)::text = 'completed'::text) AND (reversal_journal_id IS NULL)) OR (((status)::text = 'reversed'::text) AND (reversal_journal_id IS NOT NULL))))
);


--
-- Name: accounting_periods accounting_periods_book_start_key; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY accounting_periods
    ADD CONSTRAINT accounting_periods_book_start_key UNIQUE (book_id, starts_on);


--
-- Name: accounting_periods accounting_periods_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY accounting_periods
    ADD CONSTRAINT accounting_periods_pkey PRIMARY KEY (period_id);


--
-- Name: accounting_sequences accounting_sequences_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY accounting_sequences
    ADD CONSTRAINT accounting_sequences_pkey PRIMARY KEY (book_id, scope);


--
-- Name: accounts accounts_code_key; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY accounts
    ADD CONSTRAINT accounts_code_key UNIQUE (code);


--
-- Name: accounts accounts_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY accounts
    ADD CONSTRAINT accounts_pkey PRIMARY KEY (account_id);


--
-- Name: audit_events audit_events_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY audit_events
    ADD CONSTRAINT audit_events_pkey PRIMARY KEY (audit_event_id);


--
-- Name: booth_assignments booth_assignments_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY booth_assignments
    ADD CONSTRAINT booth_assignments_pkey PRIMARY KEY (assignment_id);


--
-- Name: booth_map_layouts booth_map_layouts_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY booth_map_layouts
    ADD CONSTRAINT booth_map_layouts_pkey PRIMARY KEY (layout_id);


--
-- Name: booths booths_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY booths
    ADD CONSTRAINT booths_pkey PRIMARY KEY (booth_id);


--
-- Name: card_settlement_lines card_settlement_lines_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY card_settlement_lines
    ADD CONSTRAINT card_settlement_lines_pkey PRIMARY KEY (card_settlement_line_id);


--
-- Name: card_settlements card_settlements_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY card_settlements
    ADD CONSTRAINT card_settlements_pkey PRIMARY KEY (card_settlement_id);


--
-- Name: check_deposits check_deposits_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY check_deposits
    ADD CONSTRAINT check_deposits_pkey PRIMARY KEY (check_deposit_id);


--
-- Name: customers customers_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY customers
    ADD CONSTRAINT customers_pkey PRIMARY KEY (customer_id);


--
-- Name: gift_certificate_redemptions gift_certificate_redemptions_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY gift_certificate_redemptions
    ADD CONSTRAINT gift_certificate_redemptions_pkey PRIMARY KEY (redemption_id);


--
-- Name: gift_certificates gift_certificates_no_key; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY gift_certificates
    ADD CONSTRAINT gift_certificates_no_key UNIQUE (certificate_no);


--
-- Name: gift_certificates gift_certificates_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY gift_certificates
    ADD CONSTRAINT gift_certificates_pkey PRIMARY KEY (gift_certificate_id);


--
-- Name: holder_payouts holder_payouts_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY holder_payouts
    ADD CONSTRAINT holder_payouts_pkey PRIMARY KEY (holder_payout_id);


--
-- Name: house_acquisition_items house_acquisition_items_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY house_acquisition_items
    ADD CONSTRAINT house_acquisition_items_pkey PRIMARY KEY (house_acquisition_id, item_id);


--
-- Name: house_acquisitions house_acquisitions_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY house_acquisitions
    ADD CONSTRAINT house_acquisitions_pkey PRIMARY KEY (house_acquisition_id);


--
-- Name: idempotency_keys idempotency_keys_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY idempotency_keys
    ADD CONSTRAINT idempotency_keys_pkey PRIMARY KEY (idempotency_key);


--
-- Name: item_brands item_brands_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY item_brands
    ADD CONSTRAINT item_brands_pkey PRIMARY KEY (brand_id);


--
-- Name: item_categories item_categories_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY item_categories
    ADD CONSTRAINT item_categories_pkey PRIMARY KEY (category_id);


--
-- Name: item_colors item_colors_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY item_colors
    ADD CONSTRAINT item_colors_pkey PRIMARY KEY (color_id);


--
-- Name: item_departments item_departments_name_key; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY item_departments
    ADD CONSTRAINT item_departments_name_key UNIQUE (department_name);


--
-- Name: item_departments item_departments_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY item_departments
    ADD CONSTRAINT item_departments_pkey PRIMARY KEY (department_id);


--
-- Name: item_photos item_photos_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY item_photos
    ADD CONSTRAINT item_photos_pkey PRIMARY KEY (item_id);


--
-- Name: item_pulls item_pulls_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY item_pulls
    ADD CONSTRAINT item_pulls_pkey PRIMARY KEY (pull_id);


--
-- Name: item_qty_adjustments item_qty_adjustments_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY item_qty_adjustments
    ADD CONSTRAINT item_qty_adjustments_pkey PRIMARY KEY (adjustment_id);


--
-- Name: item_sizes item_sizes_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY item_sizes
    ADD CONSTRAINT item_sizes_pkey PRIMARY KEY (size_id);


--
-- Name: items items_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY items
    ADD CONSTRAINT items_pkey PRIMARY KEY (item_id);


--
-- Name: journal_lines journal_lines_line_key; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY journal_lines
    ADD CONSTRAINT journal_lines_line_key UNIQUE (journal_id, line_no);


--
-- Name: journal_lines journal_lines_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY journal_lines
    ADD CONSTRAINT journal_lines_pkey PRIMARY KEY (journal_line_id);


--
-- Name: journals journals_book_no_key; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY journals
    ADD CONSTRAINT journals_book_no_key UNIQUE (book_id, journal_no);


--
-- Name: journals journals_entry_hash_key; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY journals
    ADD CONSTRAINT journals_entry_hash_key UNIQUE (book_id, entry_hash);


--
-- Name: journals journals_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY journals
    ADD CONSTRAINT journals_pkey PRIMARY KEY (journal_id);


--
-- Name: journals journals_posting_key_key; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY journals
    ADD CONSTRAINT journals_posting_key_key UNIQUE (book_id, posting_key);


--
-- Name: layaway_deposits layaway_deposits_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY layaway_deposits
    ADD CONSTRAINT layaway_deposits_pkey PRIMARY KEY (layaway_deposit_id);


--
-- Name: layaway_lines layaway_lines_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY layaway_lines
    ADD CONSTRAINT layaway_lines_pkey PRIMARY KEY (layaway_line_id);


--
-- Name: layaways layaways_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY layaways
    ADD CONSTRAINT layaways_pkey PRIMARY KEY (layaway_id);


--
-- Name: ledger_books ledger_books_code_key; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY ledger_books
    ADD CONSTRAINT ledger_books_code_key UNIQUE (code);


--
-- Name: ledger_books ledger_books_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY ledger_books
    ADD CONSTRAINT ledger_books_pkey PRIMARY KEY (book_id);


--
-- Name: mail_outbox mail_outbox_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY mail_outbox
    ADD CONSTRAINT mail_outbox_pkey PRIMARY KEY (mail_id);


--
-- Name: markdown_policies markdown_policies_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY markdown_policies
    ADD CONSTRAINT markdown_policies_pkey PRIMARY KEY (policy_id);


--
-- Name: membership_staff_roles membership_staff_roles_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY membership_staff_roles
    ADD CONSTRAINT membership_staff_roles_pkey PRIMARY KEY (membership_id);


--
-- Name: open_ticket_lines open_ticket_lines_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY open_ticket_lines
    ADD CONSTRAINT open_ticket_lines_pkey PRIMARY KEY (ticket_line_id);


--
-- Name: open_tickets open_tickets_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY open_tickets
    ADD CONSTRAINT open_tickets_pkey PRIMARY KEY (ticket_id);


--
-- Name: parties parties_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY parties
    ADD CONSTRAINT parties_pkey PRIMARY KEY (party_id);


--
-- Name: payable_rent_settlements payable_rent_settlements_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY payable_rent_settlements
    ADD CONSTRAINT payable_rent_settlements_pkey PRIMARY KEY (settlement_id);


--
-- Name: payout_run_envelopes payout_run_envelopes_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY payout_run_envelopes
    ADD CONSTRAINT payout_run_envelopes_pkey PRIMARY KEY (payout_run_envelope_id);


--
-- Name: payout_run_envelopes payout_run_envelopes_run_party_key; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY payout_run_envelopes
    ADD CONSTRAINT payout_run_envelopes_run_party_key UNIQUE (payout_run_id, party_id);


--
-- Name: payout_runs payout_runs_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY payout_runs
    ADD CONSTRAINT payout_runs_pkey PRIMARY KEY (payout_run_id);


--
-- Name: processor_intents processor_intents_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY processor_intents
    ADD CONSTRAINT processor_intents_pkey PRIMARY KEY (intent_id);


--
-- Name: processor_intents processor_intents_posting_key_uidx; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY processor_intents
    ADD CONSTRAINT processor_intents_posting_key_uidx UNIQUE (posting_key);


--
-- Name: processor_refunds processor_refunds_idempotency_uidx; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY processor_refunds
    ADD CONSTRAINT processor_refunds_idempotency_uidx UNIQUE (idempotency_key);


--
-- Name: processor_refunds processor_refunds_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY processor_refunds
    ADD CONSTRAINT processor_refunds_pkey PRIMARY KEY (processor_refund_id);


--
-- Name: processor_refunds processor_refunds_posting_key_uidx; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY processor_refunds
    ADD CONSTRAINT processor_refunds_posting_key_uidx UNIQUE (posting_key);


--
-- Name: register_cash_drops register_cash_drops_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY register_cash_drops
    ADD CONSTRAINT register_cash_drops_pkey PRIMARY KEY (cash_drop_id);


--
-- Name: register_sessions register_sessions_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY register_sessions
    ADD CONSTRAINT register_sessions_pkey PRIMARY KEY (register_session_id);


--
-- Name: registers registers_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY registers
    ADD CONSTRAINT registers_pkey PRIMARY KEY (register_id);


--
-- Name: rent_charges rent_charges_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY rent_charges
    ADD CONSTRAINT rent_charges_pkey PRIMARY KEY (rent_charge_id);


--
-- Name: rent_late_fees rent_late_fees_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY rent_late_fees
    ADD CONSTRAINT rent_late_fees_pkey PRIMARY KEY (rent_late_fee_id);


--
-- Name: rent_receipts rent_receipts_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY rent_receipts
    ADD CONSTRAINT rent_receipts_pkey PRIMARY KEY (rent_receipt_id);


--
-- Name: sale_lines sale_lines_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY sale_lines
    ADD CONSTRAINT sale_lines_pkey PRIMARY KEY (sale_line_id);


--
-- Name: sale_return_lines sale_return_lines_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY sale_return_lines
    ADD CONSTRAINT sale_return_lines_pkey PRIMARY KEY (sale_return_line_id);


--
-- Name: sale_return_lines sale_return_lines_return_line_key; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY sale_return_lines
    ADD CONSTRAINT sale_return_lines_return_line_key UNIQUE (sale_return_id, sale_line_id);


--
-- Name: sale_returns sale_returns_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY sale_returns
    ADD CONSTRAINT sale_returns_pkey PRIMARY KEY (sale_return_id);


--
-- Name: sale_tenders sale_tenders_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY sale_tenders
    ADD CONSTRAINT sale_tenders_pkey PRIMARY KEY (sale_tender_id);


--
-- Name: sales sales_open_ticket_id_key; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY sales
    ADD CONSTRAINT sales_open_ticket_id_key UNIQUE (open_ticket_id);


--
-- Name: sales sales_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY sales
    ADD CONSTRAINT sales_pkey PRIMARY KEY (sale_id);


--
-- Name: scheduled_markdowns scheduled_markdowns_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY scheduled_markdowns
    ADD CONSTRAINT scheduled_markdowns_pkey PRIMARY KEY (markdown_id);


--
-- Name: setup_step_progress setup_step_progress_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY setup_step_progress
    ADD CONSTRAINT setup_step_progress_pkey PRIMARY KEY (step_id);


--
-- Name: staff_roles staff_roles_name_key; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY staff_roles
    ADD CONSTRAINT staff_roles_name_key UNIQUE (role_name);


--
-- Name: staff_roles staff_roles_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY staff_roles
    ADD CONSTRAINT staff_roles_pkey PRIMARY KEY (staff_role_id);


--
-- Name: store_credit_redemptions store_credit_redemptions_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY store_credit_redemptions
    ADD CONSTRAINT store_credit_redemptions_pkey PRIMARY KEY (redemption_id);


--
-- Name: store_credits store_credits_no_key; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY store_credits
    ADD CONSTRAINT store_credits_no_key UNIQUE (credit_no);


--
-- Name: store_credits store_credits_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY store_credits
    ADD CONSTRAINT store_credits_pkey PRIMARY KEY (store_credit_id);


--
-- Name: store_locations store_locations_name_key; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY store_locations
    ADD CONSTRAINT store_locations_name_key UNIQUE (location_name);


--
-- Name: store_locations store_locations_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY store_locations
    ADD CONSTRAINT store_locations_pkey PRIMARY KEY (location_id);


--
-- Name: store_settings store_settings_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY store_settings
    ADD CONSTRAINT store_settings_pkey PRIMARY KEY (store_settings_id);


--
-- Name: tax_form_thresholds tax_form_thresholds_pk; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY tax_form_thresholds
    ADD CONSTRAINT tax_form_thresholds_pk PRIMARY KEY (form_code, box_code, tax_year, currency);


--
-- Name: tax_year_payments tax_year_payments_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY tax_year_payments
    ADD CONSTRAINT tax_year_payments_pkey PRIMARY KEY (tax_year_payment_id);


--
-- Name: tax_year_payments tax_year_payments_source_kind_key; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY tax_year_payments
    ADD CONSTRAINT tax_year_payments_source_kind_key UNIQUE (source_type, source_id, kind);


--
-- Name: vendor_clawback_applies vendor_clawback_applies_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY vendor_clawback_applies
    ADD CONSTRAINT vendor_clawback_applies_pkey PRIMARY KEY (vendor_clawback_apply_id);


--
-- Name: vendor_clawbacks vendor_clawbacks_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY vendor_clawbacks
    ADD CONSTRAINT vendor_clawbacks_pkey PRIMARY KEY (vendor_clawback_id);


--
-- Name: vendor_purchases vendor_purchases_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY vendor_purchases
    ADD CONSTRAINT vendor_purchases_pkey PRIMARY KEY (vendor_purchase_id);


--
-- Name: vendor_unclaimed vendor_unclaimed_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY vendor_unclaimed
    ADD CONSTRAINT vendor_unclaimed_pkey PRIMARY KEY (vendor_unclaimed_id);


--
-- Name: vendor_writeoffs vendor_writeoffs_pkey; Type: CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY vendor_writeoffs
    ADD CONSTRAINT vendor_writeoffs_pkey PRIMARY KEY (vendor_writeoff_id);


--
-- Name: audit_events_action_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX audit_events_action_idx ON audit_events USING btree (action);


--
-- Name: audit_events_identity_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX audit_events_identity_idx ON audit_events USING btree (identity_id);


--
-- Name: audit_events_occurred_at_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX audit_events_occurred_at_idx ON audit_events USING btree (occurred_at DESC);


--
-- Name: booth_assignments_booth_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX booth_assignments_booth_idx ON booth_assignments USING btree (booth_id, starts_on);


--
-- Name: booth_assignments_party_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX booth_assignments_party_idx ON booth_assignments USING btree (party_id);


--
-- Name: booth_map_layouts_singleton; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE UNIQUE INDEX booth_map_layouts_singleton ON booth_map_layouts USING btree ((true));


--
-- Name: booths_code_lower_key; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE UNIQUE INDEX booths_code_lower_key ON booths USING btree (lower(btrim((booth_code)::text)));


--
-- Name: card_settlement_lines_settlement_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX card_settlement_lines_settlement_idx ON card_settlement_lines USING btree (card_settlement_id);


--
-- Name: card_settlement_lines_source_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX card_settlement_lines_source_idx ON card_settlement_lines USING btree (source_kind, source_id);


--
-- Name: card_settlements_settled_on_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX card_settlements_settled_on_idx ON card_settlements USING btree (settled_on DESC);


--
-- Name: customers_display_name_key; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE UNIQUE INDEX customers_display_name_key ON customers USING btree (lower((display_name)::text));


--
-- Name: gift_certificate_redemptions_sale_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX gift_certificate_redemptions_sale_idx ON gift_certificate_redemptions USING btree (sale_id);


--
-- Name: holder_payouts_check_number_key; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE UNIQUE INDEX holder_payouts_check_number_key ON holder_payouts USING btree (check_number) WHERE (check_number IS NOT NULL);


--
-- Name: holder_payouts_party_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX holder_payouts_party_idx ON holder_payouts USING btree (party_id, paid_on);


--
-- Name: item_brands_name_lower_key; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE UNIQUE INDEX item_brands_name_lower_key ON item_brands USING btree (lower(btrim((brand_name)::text)));


--
-- Name: item_categories_name_lower_key; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE UNIQUE INDEX item_categories_name_lower_key ON item_categories USING btree (lower(btrim((category_name)::text)));


--
-- Name: item_colors_name_lower_key; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE UNIQUE INDEX item_colors_name_lower_key ON item_colors USING btree (lower(btrim((color_name)::text)));


--
-- Name: item_departments_name_lower_key; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE UNIQUE INDEX item_departments_name_lower_key ON item_departments USING btree (lower(btrim((department_name)::text)));


--
-- Name: item_pulls_item_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX item_pulls_item_idx ON item_pulls USING btree (item_id, pulled_on);


--
-- Name: item_qty_adjustments_item_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX item_qty_adjustments_item_idx ON item_qty_adjustments USING btree (item_id, created_at);


--
-- Name: item_sizes_name_lower_key; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE UNIQUE INDEX item_sizes_name_lower_key ON item_sizes USING btree (lower(btrim((size_name)::text)));


--
-- Name: items_booth_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX items_booth_idx ON items USING btree (booth_id);


--
-- Name: items_brand_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX items_brand_idx ON items USING btree (brand_id);


--
-- Name: items_category_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX items_category_idx ON items USING btree (category_id);


--
-- Name: items_color_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX items_color_idx ON items USING btree (color_id);


--
-- Name: items_party_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX items_party_idx ON items USING btree (party_id);


--
-- Name: items_received_on_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX items_received_on_idx ON items USING btree (received_on);


--
-- Name: items_size_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX items_size_idx ON items USING btree (size_id);


--
-- Name: items_sku_lower_key; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE UNIQUE INDEX items_sku_lower_key ON items USING btree (lower(btrim((sku)::text)));


--
-- Name: journal_lines_account_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX journal_lines_account_idx ON journal_lines USING btree (account_id);


--
-- Name: journal_lines_journal_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX journal_lines_journal_idx ON journal_lines USING btree (journal_id);


--
-- Name: journal_lines_subledger_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX journal_lines_subledger_idx ON journal_lines USING btree (subledger_type, subledger_ref) WHERE (subledger_type IS NOT NULL);


--
-- Name: journals_book_posting_date_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX journals_book_posting_date_idx ON journals USING btree (book_id, posting_date);


--
-- Name: journals_genesis_key; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE UNIQUE INDEX journals_genesis_key ON journals USING btree (book_id) WHERE (prev_hash IS NULL);


--
-- Name: journals_prev_hash_key; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE UNIQUE INDEX journals_prev_hash_key ON journals USING btree (book_id, prev_hash) WHERE (prev_hash IS NOT NULL);


--
-- Name: ledger_books_single_default; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE UNIQUE INDEX ledger_books_single_default ON ledger_books USING btree (is_default) WHERE (is_default = true);


--
-- Name: mail_outbox_pending_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX mail_outbox_pending_idx ON mail_outbox USING btree (status, created_at) WHERE ((status)::text = 'pending'::text);


--
-- Name: markdown_policies_days_key; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE UNIQUE INDEX markdown_policies_days_key ON markdown_policies USING btree (days_after_received);


--
-- Name: markdown_policies_name_lower_key; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE UNIQUE INDEX markdown_policies_name_lower_key ON markdown_policies USING btree (lower(btrim((policy_name)::text)));


--
-- Name: open_ticket_lines_item_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX open_ticket_lines_item_idx ON open_ticket_lines USING btree (item_id);


--
-- Name: open_ticket_lines_item_key; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE UNIQUE INDEX open_ticket_lines_item_key ON open_ticket_lines USING btree (ticket_id, item_id) WHERE (item_id IS NOT NULL);


--
-- Name: open_tickets_status_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX open_tickets_status_idx ON open_tickets USING btree (status);


--
-- Name: parties_display_name_lower_key; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE UNIQUE INDEX parties_display_name_lower_key ON parties USING btree (lower(btrim((display_name)::text)));


--
-- Name: parties_one_house_key; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE UNIQUE INDEX parties_one_house_key ON parties USING btree ((true)) WHERE ((kind)::text = 'house'::text);


--
-- Name: parties_vendor_custom_id_lower_key; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE UNIQUE INDEX parties_vendor_custom_id_lower_key ON parties USING btree (lower((custom_id)::text)) WHERE (((kind)::text = 'vendor'::text) AND (custom_id IS NOT NULL));


--
-- Name: payable_rent_settlements_party_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX payable_rent_settlements_party_idx ON payable_rent_settlements USING btree (party_id, settled_on);


--
-- Name: payout_run_envelopes_run_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX payout_run_envelopes_run_idx ON payout_run_envelopes USING btree (payout_run_id);


--
-- Name: processor_intents_checkout_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX processor_intents_checkout_idx ON processor_intents USING btree (square_checkout_id) WHERE (square_checkout_id IS NOT NULL);


--
-- Name: processor_refunds_intent_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX processor_refunds_intent_idx ON processor_refunds USING btree (intent_id);


--
-- Name: processor_refunds_rent_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX processor_refunds_rent_idx ON processor_refunds USING btree (rent_receipt_id) WHERE (rent_receipt_id IS NOT NULL);


--
-- Name: processor_refunds_sale_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX processor_refunds_sale_idx ON processor_refunds USING btree (sale_id) WHERE (sale_id IS NOT NULL);


--
-- Name: register_cash_drops_session_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX register_cash_drops_session_idx ON register_cash_drops USING btree (register_session_id);


--
-- Name: register_sessions_one_open_key; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE UNIQUE INDEX register_sessions_one_open_key ON register_sessions USING btree (register_id) WHERE (closed_at IS NULL);


--
-- Name: register_sessions_register_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX register_sessions_register_idx ON register_sessions USING btree (register_id, opened_at DESC);


--
-- Name: registers_name_lower_key; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE UNIQUE INDEX registers_name_lower_key ON registers USING btree (lower(btrim((register_name)::text)));


--
-- Name: rent_charges_assignment_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX rent_charges_assignment_idx ON rent_charges USING btree (assignment_id);


--
-- Name: rent_charges_assignment_period_completed_key; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE UNIQUE INDEX rent_charges_assignment_period_completed_key ON rent_charges USING btree (assignment_id, period_starts_on) WHERE ((status)::text = 'completed'::text);


--
-- Name: rent_late_fees_party_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX rent_late_fees_party_idx ON rent_late_fees USING btree (party_id);


--
-- Name: rent_late_fees_party_period_completed_key; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE UNIQUE INDEX rent_late_fees_party_period_completed_key ON rent_late_fees USING btree (party_id, period_starts_on) WHERE ((status)::text = 'completed'::text);


--
-- Name: rent_receipts_party_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX rent_receipts_party_idx ON rent_receipts USING btree (party_id, received_on);


--
-- Name: rent_receipts_register_session_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX rent_receipts_register_session_idx ON rent_receipts USING btree (register_session_id, created_at);


--
-- Name: rent_receipts_undeposited_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX rent_receipts_undeposited_idx ON rent_receipts USING btree (method) WHERE (((method)::text = 'check'::text) AND (deposited_id IS NULL) AND ((status)::text = 'completed'::text));


--
-- Name: sale_lines_party_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX sale_lines_party_idx ON sale_lines USING btree (party_id);


--
-- Name: sale_lines_sale_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX sale_lines_sale_idx ON sale_lines USING btree (sale_id);


--
-- Name: sale_return_lines_line_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX sale_return_lines_line_idx ON sale_return_lines USING btree (sale_line_id);


--
-- Name: sale_returns_sale_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX sale_returns_sale_idx ON sale_returns USING btree (sale_id);


--
-- Name: sale_tenders_sale_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX sale_tenders_sale_idx ON sale_tenders USING btree (sale_id);


--
-- Name: sales_sold_on_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX sales_sold_on_idx ON sales USING btree (sold_on);


--
-- Name: scheduled_markdowns_due_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX scheduled_markdowns_due_idx ON scheduled_markdowns USING btree (takes_effect_on) WHERE ((status)::text = 'scheduled'::text);


--
-- Name: scheduled_markdowns_item_date_scheduled_key; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE UNIQUE INDEX scheduled_markdowns_item_date_scheduled_key ON scheduled_markdowns USING btree (item_id, takes_effect_on) WHERE ((status)::text = 'scheduled'::text);


--
-- Name: store_locations_one_default_key; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE UNIQUE INDEX store_locations_one_default_key ON store_locations USING btree ((true)) WHERE is_default;


--
-- Name: tax_year_payments_party_year_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX tax_year_payments_party_year_idx ON tax_year_payments USING btree (party_id, tax_year);


--
-- Name: vendor_clawback_applies_party_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX vendor_clawback_applies_party_idx ON vendor_clawback_applies USING btree (party_id);


--
-- Name: vendor_clawbacks_party_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX vendor_clawbacks_party_idx ON vendor_clawbacks USING btree (party_id);


--
-- Name: vendor_purchases_sale_key; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE UNIQUE INDEX vendor_purchases_sale_key ON vendor_purchases USING btree (sale_id);


--
-- Name: vendor_unclaimed_party_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX vendor_unclaimed_party_idx ON vendor_unclaimed USING btree (party_id);


--
-- Name: vendor_writeoffs_party_idx; Type: INDEX; Schema: nest_tenant; Owner: -
--

CREATE INDEX vendor_writeoffs_party_idx ON vendor_writeoffs USING btree (party_id);


--
-- Name: accounting_periods accounting_periods_no_overlap; Type: TRIGGER; Schema: nest_tenant; Owner: -
--

CREATE TRIGGER accounting_periods_no_overlap BEFORE INSERT OR UPDATE ON accounting_periods FOR EACH ROW EXECUTE FUNCTION emp_assert_period_no_overlap();


--
-- Name: audit_events audit_events_append_only; Type: TRIGGER; Schema: nest_tenant; Owner: -
--

CREATE TRIGGER audit_events_append_only BEFORE DELETE OR UPDATE ON audit_events FOR EACH ROW EXECUTE FUNCTION emp_block_audit_mutation();


--
-- Name: booth_assignments booth_assignments_no_overlap; Type: TRIGGER; Schema: nest_tenant; Owner: -
--

CREATE TRIGGER booth_assignments_no_overlap BEFORE INSERT OR UPDATE ON booth_assignments FOR EACH ROW EXECUTE FUNCTION emp_assert_assignment_no_overlap();


--
-- Name: holder_payouts holder_payouts_journal_match; Type: TRIGGER; Schema: nest_tenant; Owner: -
--

CREATE CONSTRAINT TRIGGER holder_payouts_journal_match AFTER INSERT ON holder_payouts DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION emp_assert_payout_journal();


--
-- Name: journal_lines journal_lines_append_only; Type: TRIGGER; Schema: nest_tenant; Owner: -
--

CREATE TRIGGER journal_lines_append_only BEFORE DELETE OR UPDATE ON journal_lines FOR EACH ROW EXECUTE FUNCTION emp_block_ledger_mutation();


--
-- Name: journals journals_append_only; Type: TRIGGER; Schema: nest_tenant; Owner: -
--

CREATE TRIGGER journals_append_only BEFORE DELETE OR UPDATE ON journals FOR EACH ROW EXECUTE FUNCTION emp_block_ledger_mutation();


--
-- Name: journals journals_balanced; Type: TRIGGER; Schema: nest_tenant; Owner: -
--

CREATE CONSTRAINT TRIGGER journals_balanced AFTER INSERT ON journals DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION emp_assert_journal_balanced();


--
-- Name: register_cash_drops register_cash_drops_append_only; Type: TRIGGER; Schema: nest_tenant; Owner: -
--

CREATE TRIGGER register_cash_drops_append_only BEFORE DELETE OR UPDATE ON register_cash_drops FOR EACH ROW EXECUTE FUNCTION emp_block_cash_drop_mutation();


--
-- Name: rent_receipts rent_receipts_journal_match; Type: TRIGGER; Schema: nest_tenant; Owner: -
--

CREATE CONSTRAINT TRIGGER rent_receipts_journal_match AFTER INSERT ON rent_receipts DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION emp_assert_rent_receipt_journal();


--
-- Name: sale_returns sale_returns_journal_match; Type: TRIGGER; Schema: nest_tenant; Owner: -
--

CREATE CONSTRAINT TRIGGER sale_returns_journal_match AFTER INSERT ON sale_returns DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION emp_assert_return_journal();


--
-- Name: sales sales_journal_match; Type: TRIGGER; Schema: nest_tenant; Owner: -
--

CREATE CONSTRAINT TRIGGER sales_journal_match AFTER INSERT ON sales DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION emp_assert_sale_journal();


--
-- Name: accounting_periods accounting_periods_book_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY accounting_periods
    ADD CONSTRAINT accounting_periods_book_id_fkey FOREIGN KEY (book_id) REFERENCES ledger_books(book_id);


--
-- Name: accounting_sequences accounting_sequences_book_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY accounting_sequences
    ADD CONSTRAINT accounting_sequences_book_id_fkey FOREIGN KEY (book_id) REFERENCES ledger_books(book_id);


--
-- Name: booth_assignments booth_assignments_booth_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY booth_assignments
    ADD CONSTRAINT booth_assignments_booth_id_fkey FOREIGN KEY (booth_id) REFERENCES booths(booth_id) ON DELETE RESTRICT;


--
-- Name: booth_assignments booth_assignments_party_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY booth_assignments
    ADD CONSTRAINT booth_assignments_party_id_fkey FOREIGN KEY (party_id) REFERENCES parties(party_id) ON DELETE RESTRICT;


--
-- Name: card_settlement_lines card_settlement_lines_card_settlement_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY card_settlement_lines
    ADD CONSTRAINT card_settlement_lines_card_settlement_id_fkey FOREIGN KEY (card_settlement_id) REFERENCES card_settlements(card_settlement_id) ON DELETE RESTRICT;


--
-- Name: card_settlements card_settlements_journal_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY card_settlements
    ADD CONSTRAINT card_settlements_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES journals(journal_id);


--
-- Name: card_settlements card_settlements_reversal_journal_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY card_settlements
    ADD CONSTRAINT card_settlements_reversal_journal_id_fkey FOREIGN KEY (reversal_journal_id) REFERENCES journals(journal_id);


--
-- Name: check_deposits check_deposits_journal_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY check_deposits
    ADD CONSTRAINT check_deposits_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES journals(journal_id);


--
-- Name: check_deposits check_deposits_reversal_journal_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY check_deposits
    ADD CONSTRAINT check_deposits_reversal_journal_id_fkey FOREIGN KEY (reversal_journal_id) REFERENCES journals(journal_id);


--
-- Name: gift_certificate_redemptions gift_certificate_redemptions_gift_certificate_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY gift_certificate_redemptions
    ADD CONSTRAINT gift_certificate_redemptions_gift_certificate_id_fkey FOREIGN KEY (gift_certificate_id) REFERENCES gift_certificates(gift_certificate_id) ON DELETE RESTRICT;


--
-- Name: gift_certificate_redemptions gift_certificate_redemptions_sale_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY gift_certificate_redemptions
    ADD CONSTRAINT gift_certificate_redemptions_sale_id_fkey FOREIGN KEY (sale_id) REFERENCES sales(sale_id) ON DELETE RESTRICT;


--
-- Name: gift_certificates gift_certificates_journal_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY gift_certificates
    ADD CONSTRAINT gift_certificates_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES journals(journal_id);


--
-- Name: gift_certificates gift_certificates_register_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY gift_certificates
    ADD CONSTRAINT gift_certificates_register_id_fkey FOREIGN KEY (register_id) REFERENCES registers(register_id) ON DELETE RESTRICT;


--
-- Name: gift_certificates gift_certificates_reversal_journal_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY gift_certificates
    ADD CONSTRAINT gift_certificates_reversal_journal_id_fkey FOREIGN KEY (reversal_journal_id) REFERENCES journals(journal_id);


--
-- Name: holder_payouts holder_payouts_journal_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY holder_payouts
    ADD CONSTRAINT holder_payouts_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES journals(journal_id);


--
-- Name: holder_payouts holder_payouts_party_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY holder_payouts
    ADD CONSTRAINT holder_payouts_party_id_fkey FOREIGN KEY (party_id) REFERENCES parties(party_id) ON DELETE RESTRICT;


--
-- Name: holder_payouts holder_payouts_payout_run_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY holder_payouts
    ADD CONSTRAINT holder_payouts_payout_run_id_fkey FOREIGN KEY (payout_run_id) REFERENCES payout_runs(payout_run_id) ON DELETE RESTRICT;


--
-- Name: holder_payouts holder_payouts_register_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY holder_payouts
    ADD CONSTRAINT holder_payouts_register_id_fkey FOREIGN KEY (register_id) REFERENCES registers(register_id) ON DELETE RESTRICT;


--
-- Name: holder_payouts holder_payouts_reversal_journal_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY holder_payouts
    ADD CONSTRAINT holder_payouts_reversal_journal_id_fkey FOREIGN KEY (reversal_journal_id) REFERENCES journals(journal_id);


--
-- Name: house_acquisition_items house_acquisition_items_house_acquisition_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY house_acquisition_items
    ADD CONSTRAINT house_acquisition_items_house_acquisition_id_fkey FOREIGN KEY (house_acquisition_id) REFERENCES house_acquisitions(house_acquisition_id) ON DELETE RESTRICT;


--
-- Name: house_acquisition_items house_acquisition_items_item_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY house_acquisition_items
    ADD CONSTRAINT house_acquisition_items_item_id_fkey FOREIGN KEY (item_id) REFERENCES items(item_id) ON DELETE RESTRICT;


--
-- Name: house_acquisition_items house_acquisition_items_prior_party_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY house_acquisition_items
    ADD CONSTRAINT house_acquisition_items_prior_party_id_fkey FOREIGN KEY (prior_party_id) REFERENCES parties(party_id) ON DELETE RESTRICT;


--
-- Name: house_acquisitions house_acquisitions_from_party_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY house_acquisitions
    ADD CONSTRAINT house_acquisitions_from_party_id_fkey FOREIGN KEY (from_party_id) REFERENCES parties(party_id) ON DELETE RESTRICT;


--
-- Name: house_acquisitions house_acquisitions_journal_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY house_acquisitions
    ADD CONSTRAINT house_acquisitions_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES journals(journal_id);


--
-- Name: house_acquisitions house_acquisitions_reversal_journal_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY house_acquisitions
    ADD CONSTRAINT house_acquisitions_reversal_journal_id_fkey FOREIGN KEY (reversal_journal_id) REFERENCES journals(journal_id);


--
-- Name: item_photos item_photos_item_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY item_photos
    ADD CONSTRAINT item_photos_item_id_fkey FOREIGN KEY (item_id) REFERENCES items(item_id) ON DELETE RESTRICT;


--
-- Name: item_pulls item_pulls_item_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY item_pulls
    ADD CONSTRAINT item_pulls_item_id_fkey FOREIGN KEY (item_id) REFERENCES items(item_id) ON DELETE RESTRICT;


--
-- Name: item_qty_adjustments item_qty_adjustments_item_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY item_qty_adjustments
    ADD CONSTRAINT item_qty_adjustments_item_id_fkey FOREIGN KEY (item_id) REFERENCES items(item_id) ON DELETE RESTRICT;


--
-- Name: items items_booth_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY items
    ADD CONSTRAINT items_booth_id_fkey FOREIGN KEY (booth_id) REFERENCES booths(booth_id) ON DELETE RESTRICT;


--
-- Name: items items_brand_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY items
    ADD CONSTRAINT items_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES item_brands(brand_id) ON DELETE RESTRICT;


--
-- Name: items items_category_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY items
    ADD CONSTRAINT items_category_id_fkey FOREIGN KEY (category_id) REFERENCES item_categories(category_id) ON DELETE RESTRICT;


--
-- Name: items items_color_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY items
    ADD CONSTRAINT items_color_id_fkey FOREIGN KEY (color_id) REFERENCES item_colors(color_id) ON DELETE RESTRICT;


--
-- Name: items items_department_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY items
    ADD CONSTRAINT items_department_id_fkey FOREIGN KEY (department_id) REFERENCES item_departments(department_id) ON DELETE RESTRICT;


--
-- Name: items items_party_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY items
    ADD CONSTRAINT items_party_id_fkey FOREIGN KEY (party_id) REFERENCES parties(party_id) ON DELETE RESTRICT;


--
-- Name: items items_size_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY items
    ADD CONSTRAINT items_size_id_fkey FOREIGN KEY (size_id) REFERENCES item_sizes(size_id) ON DELETE RESTRICT;


--
-- Name: journal_lines journal_lines_account_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY journal_lines
    ADD CONSTRAINT journal_lines_account_id_fkey FOREIGN KEY (account_id) REFERENCES accounts(account_id);


--
-- Name: journal_lines journal_lines_journal_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY journal_lines
    ADD CONSTRAINT journal_lines_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES journals(journal_id);


--
-- Name: journals journals_book_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY journals
    ADD CONSTRAINT journals_book_id_fkey FOREIGN KEY (book_id) REFERENCES ledger_books(book_id);


--
-- Name: journals journals_period_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY journals
    ADD CONSTRAINT journals_period_id_fkey FOREIGN KEY (period_id) REFERENCES accounting_periods(period_id);


--
-- Name: journals journals_reverses_journal_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY journals
    ADD CONSTRAINT journals_reverses_journal_id_fkey FOREIGN KEY (reverses_journal_id) REFERENCES journals(journal_id);


--
-- Name: layaway_deposits layaway_deposits_gift_certificate_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY layaway_deposits
    ADD CONSTRAINT layaway_deposits_gift_certificate_id_fkey FOREIGN KEY (gift_certificate_id) REFERENCES gift_certificates(gift_certificate_id);


--
-- Name: layaway_deposits layaway_deposits_journal_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY layaway_deposits
    ADD CONSTRAINT layaway_deposits_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES journals(journal_id);


--
-- Name: layaway_deposits layaway_deposits_layaway_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY layaway_deposits
    ADD CONSTRAINT layaway_deposits_layaway_id_fkey FOREIGN KEY (layaway_id) REFERENCES layaways(layaway_id) ON DELETE RESTRICT;


--
-- Name: layaway_deposits layaway_deposits_reversal_journal_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY layaway_deposits
    ADD CONSTRAINT layaway_deposits_reversal_journal_id_fkey FOREIGN KEY (reversal_journal_id) REFERENCES journals(journal_id);


--
-- Name: layaway_deposits layaway_deposits_store_credit_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY layaway_deposits
    ADD CONSTRAINT layaway_deposits_store_credit_id_fkey FOREIGN KEY (store_credit_id) REFERENCES store_credits(store_credit_id);


--
-- Name: layaway_lines layaway_lines_item_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY layaway_lines
    ADD CONSTRAINT layaway_lines_item_id_fkey FOREIGN KEY (item_id) REFERENCES items(item_id) ON DELETE RESTRICT;


--
-- Name: layaway_lines layaway_lines_layaway_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY layaway_lines
    ADD CONSTRAINT layaway_lines_layaway_id_fkey FOREIGN KEY (layaway_id) REFERENCES layaways(layaway_id) ON DELETE RESTRICT;


--
-- Name: layaways layaways_customer_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY layaways
    ADD CONSTRAINT layaways_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES customers(customer_id) ON DELETE RESTRICT;


--
-- Name: layaways layaways_register_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY layaways
    ADD CONSTRAINT layaways_register_id_fkey FOREIGN KEY (register_id) REFERENCES registers(register_id) ON DELETE RESTRICT;


--
-- Name: layaways layaways_sale_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY layaways
    ADD CONSTRAINT layaways_sale_id_fkey FOREIGN KEY (sale_id) REFERENCES sales(sale_id) ON DELETE RESTRICT;


--
-- Name: mail_outbox mail_outbox_party_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY mail_outbox
    ADD CONSTRAINT mail_outbox_party_id_fkey FOREIGN KEY (party_id) REFERENCES parties(party_id) ON DELETE RESTRICT;


--
-- Name: membership_staff_roles membership_staff_roles_staff_role_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY membership_staff_roles
    ADD CONSTRAINT membership_staff_roles_staff_role_id_fkey FOREIGN KEY (staff_role_id) REFERENCES staff_roles(staff_role_id) ON DELETE RESTRICT;


--
-- Name: open_ticket_lines open_ticket_lines_booth_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY open_ticket_lines
    ADD CONSTRAINT open_ticket_lines_booth_id_fkey FOREIGN KEY (booth_id) REFERENCES booths(booth_id) ON DELETE RESTRICT;


--
-- Name: open_ticket_lines open_ticket_lines_item_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY open_ticket_lines
    ADD CONSTRAINT open_ticket_lines_item_id_fkey FOREIGN KEY (item_id) REFERENCES items(item_id) ON DELETE RESTRICT;


--
-- Name: open_ticket_lines open_ticket_lines_party_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY open_ticket_lines
    ADD CONSTRAINT open_ticket_lines_party_id_fkey FOREIGN KEY (party_id) REFERENCES parties(party_id) ON DELETE RESTRICT;


--
-- Name: open_ticket_lines open_ticket_lines_ticket_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY open_ticket_lines
    ADD CONSTRAINT open_ticket_lines_ticket_id_fkey FOREIGN KEY (ticket_id) REFERENCES open_tickets(ticket_id) ON DELETE CASCADE;


--
-- Name: open_tickets open_tickets_customer_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY open_tickets
    ADD CONSTRAINT open_tickets_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES customers(customer_id) ON DELETE RESTRICT;


--
-- Name: open_tickets open_tickets_register_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY open_tickets
    ADD CONSTRAINT open_tickets_register_id_fkey FOREIGN KEY (register_id) REFERENCES registers(register_id) ON DELETE RESTRICT;


--
-- Name: parties parties_linked_customer_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY parties
    ADD CONSTRAINT parties_linked_customer_id_fkey FOREIGN KEY (linked_customer_id) REFERENCES customers(customer_id) ON DELETE RESTRICT;


--
-- Name: payable_rent_settlements payable_rent_settlements_journal_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY payable_rent_settlements
    ADD CONSTRAINT payable_rent_settlements_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES journals(journal_id);


--
-- Name: payable_rent_settlements payable_rent_settlements_party_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY payable_rent_settlements
    ADD CONSTRAINT payable_rent_settlements_party_id_fkey FOREIGN KEY (party_id) REFERENCES parties(party_id) ON DELETE RESTRICT;


--
-- Name: payable_rent_settlements payable_rent_settlements_reversal_journal_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY payable_rent_settlements
    ADD CONSTRAINT payable_rent_settlements_reversal_journal_id_fkey FOREIGN KEY (reversal_journal_id) REFERENCES journals(journal_id);


--
-- Name: payout_run_envelopes payout_run_envelopes_holder_payout_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY payout_run_envelopes
    ADD CONSTRAINT payout_run_envelopes_holder_payout_id_fkey FOREIGN KEY (holder_payout_id) REFERENCES holder_payouts(holder_payout_id) ON DELETE RESTRICT;


--
-- Name: payout_run_envelopes payout_run_envelopes_party_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY payout_run_envelopes
    ADD CONSTRAINT payout_run_envelopes_party_id_fkey FOREIGN KEY (party_id) REFERENCES parties(party_id) ON DELETE RESTRICT;


--
-- Name: payout_run_envelopes payout_run_envelopes_payout_run_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY payout_run_envelopes
    ADD CONSTRAINT payout_run_envelopes_payout_run_id_fkey FOREIGN KEY (payout_run_id) REFERENCES payout_runs(payout_run_id) ON DELETE RESTRICT;


--
-- Name: processor_intents processor_intents_party_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY processor_intents
    ADD CONSTRAINT processor_intents_party_id_fkey FOREIGN KEY (party_id) REFERENCES parties(party_id) ON DELETE RESTRICT;


--
-- Name: processor_intents processor_intents_rent_receipt_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY processor_intents
    ADD CONSTRAINT processor_intents_rent_receipt_id_fkey FOREIGN KEY (rent_receipt_id) REFERENCES rent_receipts(rent_receipt_id) ON DELETE RESTRICT;


--
-- Name: processor_intents processor_intents_sale_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY processor_intents
    ADD CONSTRAINT processor_intents_sale_id_fkey FOREIGN KEY (sale_id) REFERENCES sales(sale_id) ON DELETE RESTRICT;


--
-- Name: processor_intents processor_intents_ticket_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY processor_intents
    ADD CONSTRAINT processor_intents_ticket_id_fkey FOREIGN KEY (ticket_id) REFERENCES open_tickets(ticket_id) ON DELETE RESTRICT;


--
-- Name: processor_refunds processor_refunds_intent_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY processor_refunds
    ADD CONSTRAINT processor_refunds_intent_id_fkey FOREIGN KEY (intent_id) REFERENCES processor_intents(intent_id) ON DELETE RESTRICT;


--
-- Name: processor_refunds processor_refunds_rent_receipt_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY processor_refunds
    ADD CONSTRAINT processor_refunds_rent_receipt_id_fkey FOREIGN KEY (rent_receipt_id) REFERENCES rent_receipts(rent_receipt_id) ON DELETE RESTRICT;


--
-- Name: processor_refunds processor_refunds_sale_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY processor_refunds
    ADD CONSTRAINT processor_refunds_sale_id_fkey FOREIGN KEY (sale_id) REFERENCES sales(sale_id) ON DELETE RESTRICT;


--
-- Name: register_cash_drops register_cash_drops_register_session_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY register_cash_drops
    ADD CONSTRAINT register_cash_drops_register_session_id_fkey FOREIGN KEY (register_session_id) REFERENCES register_sessions(register_session_id) ON DELETE RESTRICT;


--
-- Name: register_sessions register_sessions_owner_party_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY register_sessions
    ADD CONSTRAINT register_sessions_owner_party_id_fkey FOREIGN KEY (owner_party_id) REFERENCES parties(party_id);


--
-- Name: register_sessions register_sessions_register_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY register_sessions
    ADD CONSTRAINT register_sessions_register_id_fkey FOREIGN KEY (register_id) REFERENCES registers(register_id) ON DELETE RESTRICT;


--
-- Name: registers registers_location_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY registers
    ADD CONSTRAINT registers_location_id_fkey FOREIGN KEY (location_id) REFERENCES store_locations(location_id) ON DELETE RESTRICT;


--
-- Name: rent_charges rent_charges_assignment_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY rent_charges
    ADD CONSTRAINT rent_charges_assignment_id_fkey FOREIGN KEY (assignment_id) REFERENCES booth_assignments(assignment_id) ON DELETE RESTRICT;


--
-- Name: rent_charges rent_charges_journal_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY rent_charges
    ADD CONSTRAINT rent_charges_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES journals(journal_id);


--
-- Name: rent_charges rent_charges_reversal_journal_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY rent_charges
    ADD CONSTRAINT rent_charges_reversal_journal_id_fkey FOREIGN KEY (reversal_journal_id) REFERENCES journals(journal_id);


--
-- Name: rent_late_fees rent_late_fees_journal_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY rent_late_fees
    ADD CONSTRAINT rent_late_fees_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES journals(journal_id);


--
-- Name: rent_late_fees rent_late_fees_party_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY rent_late_fees
    ADD CONSTRAINT rent_late_fees_party_id_fkey FOREIGN KEY (party_id) REFERENCES parties(party_id) ON DELETE RESTRICT;


--
-- Name: rent_late_fees rent_late_fees_reversal_journal_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY rent_late_fees
    ADD CONSTRAINT rent_late_fees_reversal_journal_id_fkey FOREIGN KEY (reversal_journal_id) REFERENCES journals(journal_id);


--
-- Name: rent_receipts rent_receipts_card_settlement_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY rent_receipts
    ADD CONSTRAINT rent_receipts_card_settlement_id_fkey FOREIGN KEY (card_settlement_id) REFERENCES card_settlements(card_settlement_id);


--
-- Name: rent_receipts rent_receipts_deposited_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY rent_receipts
    ADD CONSTRAINT rent_receipts_deposited_id_fkey FOREIGN KEY (deposited_id) REFERENCES check_deposits(check_deposit_id);


--
-- Name: rent_receipts rent_receipts_journal_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY rent_receipts
    ADD CONSTRAINT rent_receipts_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES journals(journal_id);


--
-- Name: rent_receipts rent_receipts_party_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY rent_receipts
    ADD CONSTRAINT rent_receipts_party_id_fkey FOREIGN KEY (party_id) REFERENCES parties(party_id) ON DELETE RESTRICT;


--
-- Name: rent_receipts rent_receipts_register_session_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY rent_receipts
    ADD CONSTRAINT rent_receipts_register_session_id_fkey FOREIGN KEY (register_session_id) REFERENCES register_sessions(register_session_id);


--
-- Name: rent_receipts rent_receipts_reversal_journal_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY rent_receipts
    ADD CONSTRAINT rent_receipts_reversal_journal_id_fkey FOREIGN KEY (reversal_journal_id) REFERENCES journals(journal_id);


--
-- Name: sale_lines sale_lines_booth_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY sale_lines
    ADD CONSTRAINT sale_lines_booth_id_fkey FOREIGN KEY (booth_id) REFERENCES booths(booth_id) ON DELETE RESTRICT;


--
-- Name: sale_lines sale_lines_item_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY sale_lines
    ADD CONSTRAINT sale_lines_item_id_fkey FOREIGN KEY (item_id) REFERENCES items(item_id) ON DELETE RESTRICT;


--
-- Name: sale_lines sale_lines_party_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY sale_lines
    ADD CONSTRAINT sale_lines_party_id_fkey FOREIGN KEY (party_id) REFERENCES parties(party_id) ON DELETE RESTRICT;


--
-- Name: sale_lines sale_lines_reassigned_from_party_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY sale_lines
    ADD CONSTRAINT sale_lines_reassigned_from_party_id_fkey FOREIGN KEY (reassigned_from_party_id) REFERENCES parties(party_id) ON DELETE RESTRICT;


--
-- Name: sale_lines sale_lines_sale_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY sale_lines
    ADD CONSTRAINT sale_lines_sale_id_fkey FOREIGN KEY (sale_id) REFERENCES sales(sale_id) ON DELETE RESTRICT;


--
-- Name: sale_return_lines sale_return_lines_sale_line_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY sale_return_lines
    ADD CONSTRAINT sale_return_lines_sale_line_id_fkey FOREIGN KEY (sale_line_id) REFERENCES sale_lines(sale_line_id) ON DELETE RESTRICT;


--
-- Name: sale_return_lines sale_return_lines_sale_return_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY sale_return_lines
    ADD CONSTRAINT sale_return_lines_sale_return_id_fkey FOREIGN KEY (sale_return_id) REFERENCES sale_returns(sale_return_id) ON DELETE RESTRICT;


--
-- Name: sale_returns sale_returns_journal_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY sale_returns
    ADD CONSTRAINT sale_returns_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES journals(journal_id);


--
-- Name: sale_returns sale_returns_sale_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY sale_returns
    ADD CONSTRAINT sale_returns_sale_id_fkey FOREIGN KEY (sale_id) REFERENCES sales(sale_id) ON DELETE RESTRICT;


--
-- Name: sale_tenders sale_tenders_card_settlement_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY sale_tenders
    ADD CONSTRAINT sale_tenders_card_settlement_id_fkey FOREIGN KEY (card_settlement_id) REFERENCES card_settlements(card_settlement_id);


--
-- Name: sale_tenders sale_tenders_deposited_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY sale_tenders
    ADD CONSTRAINT sale_tenders_deposited_id_fkey FOREIGN KEY (deposited_id) REFERENCES check_deposits(check_deposit_id) ON DELETE RESTRICT;


--
-- Name: sale_tenders sale_tenders_gift_certificate_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY sale_tenders
    ADD CONSTRAINT sale_tenders_gift_certificate_id_fkey FOREIGN KEY (gift_certificate_id) REFERENCES gift_certificates(gift_certificate_id) ON DELETE RESTRICT;


--
-- Name: sale_tenders sale_tenders_sale_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY sale_tenders
    ADD CONSTRAINT sale_tenders_sale_id_fkey FOREIGN KEY (sale_id) REFERENCES sales(sale_id) ON DELETE RESTRICT;


--
-- Name: sale_tenders sale_tenders_store_credit_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY sale_tenders
    ADD CONSTRAINT sale_tenders_store_credit_id_fkey FOREIGN KEY (store_credit_id) REFERENCES store_credits(store_credit_id) ON DELETE RESTRICT;


--
-- Name: sale_tenders sale_tenders_vendor_purchase_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY sale_tenders
    ADD CONSTRAINT sale_tenders_vendor_purchase_id_fkey FOREIGN KEY (vendor_purchase_id) REFERENCES vendor_purchases(vendor_purchase_id) ON DELETE RESTRICT;


--
-- Name: sales sales_customer_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY sales
    ADD CONSTRAINT sales_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES customers(customer_id) ON DELETE RESTRICT;


--
-- Name: sales sales_journal_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY sales
    ADD CONSTRAINT sales_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES journals(journal_id);


--
-- Name: sales sales_open_ticket_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY sales
    ADD CONSTRAINT sales_open_ticket_id_fkey FOREIGN KEY (open_ticket_id) REFERENCES open_tickets(ticket_id);


--
-- Name: sales sales_register_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY sales
    ADD CONSTRAINT sales_register_id_fkey FOREIGN KEY (register_id) REFERENCES registers(register_id) ON DELETE RESTRICT;


--
-- Name: sales sales_reversal_journal_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY sales
    ADD CONSTRAINT sales_reversal_journal_id_fkey FOREIGN KEY (reversal_journal_id) REFERENCES journals(journal_id);


--
-- Name: scheduled_markdowns scheduled_markdowns_item_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY scheduled_markdowns
    ADD CONSTRAINT scheduled_markdowns_item_id_fkey FOREIGN KEY (item_id) REFERENCES items(item_id) ON DELETE RESTRICT;


--
-- Name: store_credit_redemptions store_credit_redemptions_sale_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY store_credit_redemptions
    ADD CONSTRAINT store_credit_redemptions_sale_id_fkey FOREIGN KEY (sale_id) REFERENCES sales(sale_id) ON DELETE RESTRICT;


--
-- Name: store_credit_redemptions store_credit_redemptions_store_credit_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY store_credit_redemptions
    ADD CONSTRAINT store_credit_redemptions_store_credit_id_fkey FOREIGN KEY (store_credit_id) REFERENCES store_credits(store_credit_id) ON DELETE RESTRICT;


--
-- Name: store_credits store_credits_customer_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY store_credits
    ADD CONSTRAINT store_credits_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES customers(customer_id) ON DELETE RESTRICT;


--
-- Name: store_credits store_credits_journal_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY store_credits
    ADD CONSTRAINT store_credits_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES journals(journal_id);


--
-- Name: store_credits store_credits_register_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY store_credits
    ADD CONSTRAINT store_credits_register_id_fkey FOREIGN KEY (register_id) REFERENCES registers(register_id) ON DELETE RESTRICT;


--
-- Name: store_credits store_credits_reversal_journal_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY store_credits
    ADD CONSTRAINT store_credits_reversal_journal_id_fkey FOREIGN KEY (reversal_journal_id) REFERENCES journals(journal_id);


--
-- Name: tax_year_payments tax_year_payments_party_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY tax_year_payments
    ADD CONSTRAINT tax_year_payments_party_id_fkey FOREIGN KEY (party_id) REFERENCES parties(party_id);


--
-- Name: vendor_clawback_applies vendor_clawback_applies_holder_payout_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY vendor_clawback_applies
    ADD CONSTRAINT vendor_clawback_applies_holder_payout_id_fkey FOREIGN KEY (holder_payout_id) REFERENCES holder_payouts(holder_payout_id) ON DELETE RESTRICT;


--
-- Name: vendor_clawback_applies vendor_clawback_applies_journal_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY vendor_clawback_applies
    ADD CONSTRAINT vendor_clawback_applies_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES journals(journal_id);


--
-- Name: vendor_clawback_applies vendor_clawback_applies_party_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY vendor_clawback_applies
    ADD CONSTRAINT vendor_clawback_applies_party_id_fkey FOREIGN KEY (party_id) REFERENCES parties(party_id) ON DELETE RESTRICT;


--
-- Name: vendor_clawback_applies vendor_clawback_applies_reversal_journal_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY vendor_clawback_applies
    ADD CONSTRAINT vendor_clawback_applies_reversal_journal_id_fkey FOREIGN KEY (reversal_journal_id) REFERENCES journals(journal_id);


--
-- Name: vendor_clawbacks vendor_clawbacks_journal_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY vendor_clawbacks
    ADD CONSTRAINT vendor_clawbacks_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES journals(journal_id);


--
-- Name: vendor_clawbacks vendor_clawbacks_party_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY vendor_clawbacks
    ADD CONSTRAINT vendor_clawbacks_party_id_fkey FOREIGN KEY (party_id) REFERENCES parties(party_id) ON DELETE RESTRICT;


--
-- Name: vendor_clawbacks vendor_clawbacks_reversal_journal_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY vendor_clawbacks
    ADD CONSTRAINT vendor_clawbacks_reversal_journal_id_fkey FOREIGN KEY (reversal_journal_id) REFERENCES journals(journal_id);


--
-- Name: vendor_purchases vendor_purchases_party_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY vendor_purchases
    ADD CONSTRAINT vendor_purchases_party_id_fkey FOREIGN KEY (party_id) REFERENCES parties(party_id) ON DELETE RESTRICT;


--
-- Name: vendor_purchases vendor_purchases_sale_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY vendor_purchases
    ADD CONSTRAINT vendor_purchases_sale_id_fkey FOREIGN KEY (sale_id) REFERENCES sales(sale_id) ON DELETE RESTRICT;


--
-- Name: vendor_unclaimed vendor_unclaimed_journal_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY vendor_unclaimed
    ADD CONSTRAINT vendor_unclaimed_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES journals(journal_id);


--
-- Name: vendor_unclaimed vendor_unclaimed_party_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY vendor_unclaimed
    ADD CONSTRAINT vendor_unclaimed_party_id_fkey FOREIGN KEY (party_id) REFERENCES parties(party_id) ON DELETE RESTRICT;


--
-- Name: vendor_unclaimed vendor_unclaimed_reversal_journal_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY vendor_unclaimed
    ADD CONSTRAINT vendor_unclaimed_reversal_journal_id_fkey FOREIGN KEY (reversal_journal_id) REFERENCES journals(journal_id);


--
-- Name: vendor_writeoffs vendor_writeoffs_journal_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY vendor_writeoffs
    ADD CONSTRAINT vendor_writeoffs_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES journals(journal_id);


--
-- Name: vendor_writeoffs vendor_writeoffs_party_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY vendor_writeoffs
    ADD CONSTRAINT vendor_writeoffs_party_id_fkey FOREIGN KEY (party_id) REFERENCES parties(party_id) ON DELETE RESTRICT;


--
-- Name: vendor_writeoffs vendor_writeoffs_reversal_journal_id_fkey; Type: FK CONSTRAINT; Schema: nest_tenant; Owner: -
--

ALTER TABLE ONLY vendor_writeoffs
    ADD CONSTRAINT vendor_writeoffs_reversal_journal_id_fkey FOREIGN KEY (reversal_journal_id) REFERENCES journals(journal_id);


--
-- PostgreSQL database dump complete
--


INSERT INTO accounts (code, name, account_type, normal_balance, is_postable, is_control, subledger_type) VALUES
    ('1000', 'Cash in drawer', 'asset', 'debit', true, false, NULL),
    ('1010', 'Bank', 'asset', 'debit', true, false, NULL),
    ('1015', 'Cash in safe', 'asset', 'debit', true, false, NULL),
    ('1100', 'Undeposited checks', 'asset', 'debit', true, false, NULL),
    ('1200', 'Card clearing', 'asset', 'debit', true, false, NULL),
    ('1300', 'Rent receivable', 'asset', 'debit', true, true, 'party'),
    ('1310', 'Vendor receivable', 'asset', 'debit', true, true, 'party'),
    ('1400', 'House inventory', 'asset', 'debit', true, false, NULL),
    ('2000', 'Holder payable', 'liability', 'credit', true, true, 'party'),
    ('2100', 'Sales tax payable', 'liability', 'credit', true, true, 'tax'),
    ('2200', 'Gift certificate liability', 'liability', 'credit', true, false, NULL),
    ('2210', 'Layaway deposits', 'liability', 'credit', true, false, NULL),
    ('2220', 'Store credit liability', 'liability', 'credit', true, false, NULL),
    ('2300', 'Unclaimed vendor payable', 'liability', 'credit', true, true, 'party'),
    ('3000', 'Owner capital', 'equity', 'credit', true, false, NULL),
    ('3900', 'Retained earnings', 'equity', 'credit', true, false, NULL),
    ('4000', 'Commission income', 'revenue', 'credit', true, false, NULL),
    ('4100', 'Booth rent income', 'revenue', 'credit', true, false, NULL),
    ('4200', 'Late fee income', 'revenue', 'credit', true, false, NULL),
    ('4300', 'Store merchandise income', 'revenue', 'credit', true, false, NULL),
    ('5100', 'House cost of sales', 'expense', 'debit', true, false, NULL),
    ('6150', 'Cash over/short', 'expense', 'debit', true, false, NULL),
    ('6160', 'Uncollectible vendor balances', 'expense', 'debit', true, false, NULL),
    ('6170', 'Processor fees', 'expense', 'debit', true, false, NULL),
    ('6180', 'Card chargebacks', 'expense', 'debit', true, false, NULL);

INSERT INTO parties (display_name, first_name, last_name, commission_bps, kind, portal_enabled)
VALUES ('House', NULL, NULL, 0, 'house', false);

INSERT INTO store_settings DEFAULT VALUES;

INSERT INTO store_locations (location_name, is_default) VALUES ('Main', true);

INSERT INTO tax_form_thresholds (form_code, box_code, tax_year, amount_minor, currency)
SELECT '1099-NEC', '1', y.year, 60000, c.currency
FROM generate_series(2020, 2025) AS y (year)
CROSS JOIN (VALUES ('USD'), ('CAD'), ('EUR')) AS c (currency);

INSERT INTO tax_form_thresholds (form_code, box_code, tax_year, amount_minor, currency)
SELECT '1099-NEC', '1', 2026, 200000, c.currency
FROM (VALUES ('USD'), ('CAD'), ('EUR')) AS c (currency);
