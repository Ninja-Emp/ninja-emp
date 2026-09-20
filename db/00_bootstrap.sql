-- ============================================================================
-- Ninja EMP — 00_bootstrap.sql  (CONTROL PLANE — its own database)
-- ADR-0008: the control plane lives in a SEPARATE database (ninja_control),
-- not alongside tenant schemas. Smaller blast radius for restores/migrations.
-- Run against the control database only.
-- ============================================================================
\set ON_ERROR_STOP on

CREATE SCHEMA IF NOT EXISTS control;
COMMENT ON SCHEMA control IS 'Control plane: tenant registry and routing metadata. Separate database (ADR-0008).';

CREATE TABLE control.tenant (
  id            uuid PRIMARY KEY DEFAULT uuidv7(),
  slug          text NOT NULL UNIQUE,
  schema_name   text NOT NULL UNIQUE,
  legal_name    text NOT NULL,
  status        text NOT NULL DEFAULT 'active' CHECK (status IN ('active','suspended','archived')),
  pool_group    text NOT NULL DEFAULT 'default',   -- PgBouncer pool routing
  created_at    timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE control.tenant IS 'Tenant registry. schema_name is the per-tenant schema; pool_group routes PgBouncer.';

-- Register a tenant (schema creation + DDL is done by the migration runner).
CREATE OR REPLACE FUNCTION control.register_tenant(
  p_slug text, p_legal_name text, p_schema_name text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_id uuid; v_schema text;
BEGIN
  v_schema := COALESCE(p_schema_name, 'tenant_' || replace(p_slug, '-', '_'));
  INSERT INTO control.tenant (slug, schema_name, legal_name)
  VALUES (p_slug, v_schema, p_legal_name)
  RETURNING id INTO v_id;
  RETURN v_id;
END; $$;
COMMENT ON FUNCTION control.register_tenant IS 'Registers a tenant; the migration runner then creates and migrates its schema.';
