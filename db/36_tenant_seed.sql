-- ============================================================================
-- Ninja EMP — 36_tenant_seed.sql  (TENANT-SCOPED)
-- Fiscal calendar generation. ADR-0014 makes the fiscal calendar a hard
-- dependency of posting, so tenant provisioning MUST generate the current and
-- next fiscal year of periods. Idempotent.
-- Run with: SET search_path = <tenant_schema>, kernel;
-- ============================================================================
\set ON_ERROR_STOP on

-- Generate 12 monthly periods for a fiscal year, honoring the tenant's
-- fiscal_year_start_month. Idempotent (ON CONFLICT DO NOTHING).
CREATE OR REPLACE FUNCTION generate_fiscal_year(p_year int) RETURNS int
LANGUAGE plpgsql AS $$
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
COMMENT ON FUNCTION generate_fiscal_year IS 'Creates 12 monthly fiscal periods for a year (idempotent). ADR-0014 provisioning requirement.';

-- Convenience: ensure the current and next fiscal year exist.
CREATE OR REPLACE FUNCTION ensure_fiscal_calendar() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM generate_fiscal_year(EXTRACT(year FROM current_date)::int);
  PERFORM generate_fiscal_year(EXTRACT(year FROM current_date)::int + 1);
END; $$;
COMMENT ON FUNCTION ensure_fiscal_calendar IS 'Generates current + next fiscal year of periods (ADR-0014).';
