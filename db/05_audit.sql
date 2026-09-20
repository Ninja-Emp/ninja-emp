-- ============================================================================
-- Ninja EMP — 05_audit.sql  (TENANT-SCOPED)
-- Append-only row-history log (ADR-0017). Written by kernel.audit_row() triggers
-- attached to high-value tables. Never updated or deleted.
-- Run with: SET search_path = <tenant_schema>, kernel;
-- ============================================================================
\set ON_ERROR_STOP on

CREATE TABLE audit_log (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id    uuid NOT NULL DEFAULT kernel.current_tenant(),
  table_schema text NOT NULL,
  table_name   text NOT NULL,
  row_id       text,
  op           text NOT NULL CHECK (op IN ('INSERT','UPDATE','DELETE')),
  actor_id     uuid,
  before_data  jsonb,
  after_data   jsonb,
  occurred_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE audit_log IS 'Append-only row history for high-value tables (ADR-0017). before/after JSON snapshots.';

CREATE INDEX ix_audit_log_row ON audit_log(table_name, row_id);
CREATE INDEX ix_audit_log_time ON audit_log(occurred_at);

-- Append-only: block UPDATE/DELETE (kernel.forbid_mutation).
CREATE TRIGGER trg_audit_log_append_only
  BEFORE UPDATE OR DELETE ON audit_log
  FOR EACH ROW EXECUTE FUNCTION kernel.forbid_mutation();
