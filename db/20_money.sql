-- ============================================================================
-- Ninja EMP — 20_money.sql  (TENANT-SCOPED)
-- Money & Currency: tenant configuration + exchange rates.
-- Conforms to docs/DATA_STANDARDS.md (audit block + optimistic locking).
-- Run with: SET search_path = <tenant_schema>, kernel;
-- ============================================================================
\set ON_ERROR_STOP on

-- ----------------------------------------------------------------------------
-- Tenant configuration. Exactly one row per tenant schema.
-- functional_currency is the base for all base_debit/base_credit ledger amounts.
-- ----------------------------------------------------------------------------
CREATE TABLE tenant_config (
  tenant_id              uuid PRIMARY KEY DEFAULT kernel.current_tenant(),
  legal_name             text NOT NULL,
  functional_currency    kernel.currency_code NOT NULL DEFAULT 'USD'
                           REFERENCES kernel.currency(code),
  fiscal_year_start_month smallint NOT NULL DEFAULT 1
                           CHECK (fiscal_year_start_month BETWEEN 1 AND 12),
  timezone               text NOT NULL DEFAULT 'UTC',
  created_at             timestamptz NOT NULL DEFAULT now(),
  created_by             uuid DEFAULT kernel.current_actor(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  updated_by             uuid DEFAULT kernel.current_actor(),
  version                integer NOT NULL DEFAULT 1
);
COMMENT ON TABLE tenant_config IS 'One row per tenant. functional_currency is the ledger base currency.';

CREATE TRIGGER trg_tenant_config_audit
  BEFORE UPDATE ON tenant_config
  FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();
CREATE TRIGGER trg_tenant_config_audit_row
  AFTER INSERT OR UPDATE OR DELETE ON tenant_config
  FOR EACH ROW EXECUTE FUNCTION kernel.audit_row();

-- ----------------------------------------------------------------------------
-- Exchange rates. Multi-currency-ready; USD base today.
-- Rate is "1 unit of from_currency = rate units of to_currency" as of as_of.
-- ----------------------------------------------------------------------------
CREATE TABLE exchange_rate (
  id            uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id     uuid NOT NULL DEFAULT kernel.current_tenant(),
  from_currency kernel.currency_code NOT NULL REFERENCES kernel.currency(code),
  to_currency   kernel.currency_code NOT NULL REFERENCES kernel.currency(code),
  rate          kernel.fx_rate NOT NULL,
  as_of         date NOT NULL,
  source        text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  created_by    uuid DEFAULT kernel.current_actor(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  updated_by    uuid DEFAULT kernel.current_actor(),
  version       integer NOT NULL DEFAULT 1,
  CHECK (from_currency <> to_currency),
  UNIQUE (tenant_id, from_currency, to_currency, as_of)
);
COMMENT ON TABLE exchange_rate IS 'Dated FX rates. Lookup = latest as_of <= target date.';

CREATE TRIGGER trg_exchange_rate_audit
  BEFORE UPDATE ON exchange_rate
  FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- Convenience: resolve the rate to convert an amount into the functional currency.
CREATE OR REPLACE FUNCTION fx_to_functional(
  p_from kernel.currency_code,
  p_as_of date
) RETURNS kernel.fx_rate
LANGUAGE plpgsql STABLE AS $$
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
COMMENT ON FUNCTION fx_to_functional IS 'Latest rate converting p_from into the tenant functional currency as of a date.';
