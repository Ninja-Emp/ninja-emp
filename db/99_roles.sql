-- ============================================================================
-- Ninja EMP — 99_roles.sql  (CLUSTER-LEVEL, run once against any database)
-- Two application roles (ADR-0007):
--   ninja_app      — DML only; RLS applies (no BYPASSRLS).
--   ninja_migrator — DDL + maintenance; BYPASSRLS so FORCE RLS does not hide
--                    rows from migrations/backfills (the classic footgun).
-- Kernel/tenant grants are applied per-database by provision.sh.
-- ============================================================================
\set ON_ERROR_STOP on

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ninja_app') THEN
    CREATE ROLE ninja_app LOGIN PASSWORD 'change_me_in_prod';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ninja_migrator') THEN
    CREATE ROLE ninja_migrator LOGIN PASSWORD 'change_me_in_prod' BYPASSRLS;
  END IF;
END $$;

-- ninja_app must NOT bypass RLS.
ALTER ROLE ninja_app NOBYPASSRLS;
-- ninja_migrator must bypass RLS (FORCE RLS otherwise hides all rows from it).
ALTER ROLE ninja_migrator BYPASSRLS;
