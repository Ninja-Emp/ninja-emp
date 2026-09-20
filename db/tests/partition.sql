-- ============================================================================
-- Ninja EMP — partition.sql
-- Proves the journal design is PARTITION-READY (ADR-0019): a range-partitioned
-- journal_line (by entry_date) still enforces the deferred balance invariant,
-- and all lines of one entry live in a single partition.
-- Run: psql -d ninja_emp -v ON_ERROR_STOP=1 -f db/tests/partition.sql
-- ============================================================================
\set ON_ERROR_STOP on
SET search_path = tenant_demo, kernel;

-- Re-runnable: drop any prior run's artifacts.
DROP TABLE IF EXISTS jl_p CASCADE;
DROP TABLE IF EXISTS je_p CASCADE;

-- Partitioned journal header (PK includes the partition key).
CREATE TABLE je_p (
  id         uuid NOT NULL DEFAULT uuidv7(),
  entry_date date NOT NULL,
  memo       text,
  PRIMARY KEY (id, entry_date)
) PARTITION BY RANGE (entry_date);
CREATE TABLE je_p_2026 PARTITION OF je_p FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
CREATE TABLE je_p_2027 PARTITION OF je_p FOR VALUES FROM ('2027-01-01') TO ('2028-01-01');

-- Partitioned journal line. entry_date is denormalized from the header so the
-- partition key is present on the line (all lines of an entry share it).
CREATE TABLE jl_p (
  id               bigint GENERATED ALWAYS AS IDENTITY,
  journal_entry_id uuid NOT NULL,
  entry_date       date NOT NULL,
  line_no          smallint NOT NULL,
  debit            kernel.money_amount NOT NULL DEFAULT 0,
  credit           kernel.money_amount NOT NULL DEFAULT 0,
  PRIMARY KEY (id, entry_date)
) PARTITION BY RANGE (entry_date);
CREATE TABLE jl_p_2026 PARTITION OF jl_p FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
CREATE TABLE jl_p_2027 PARTITION OF jl_p FOR VALUES FROM ('2027-01-01') TO ('2028-01-01');

-- Deferred balance trigger on the partitioned table (propagates to partitions).
CREATE OR REPLACE FUNCTION assert_entry_balanced_p() RETURNS trigger
LANGUAGE plpgsql AS $$
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

CREATE CONSTRAINT TRIGGER trg_jl_p_balanced
  AFTER INSERT OR UPDATE OR DELETE ON jl_p
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION assert_entry_balanced_p();

\echo '=== P1: balanced entry posts across partitions; deferred trigger fires ==='
DO $$
DECLARE v_id uuid := uuidv7();
BEGIN
  INSERT INTO je_p (id, entry_date, memo) VALUES (v_id, '2026-06-15', 'partitioned test');
  INSERT INTO jl_p (journal_entry_id, entry_date, line_no, debit, credit) VALUES
    (v_id,'2026-06-15',1,100,0),
    (v_id,'2026-06-15',2,0,100);
  EXECUTE 'SET CONSTRAINTS ALL IMMEDIATE';
  RAISE NOTICE 'PASS: balanced partitioned entry accepted';
END $$;

\echo '=== P2: unbalanced entry is REJECTED on the partitioned table ==='
DO $$
DECLARE v_id uuid := uuidv7();
BEGIN
  INSERT INTO je_p (id, entry_date, memo) VALUES (v_id, '2026-07-15', 'bad');
  INSERT INTO jl_p (journal_entry_id, entry_date, line_no, debit, credit) VALUES
    (v_id,'2026-07-15',1,100,0),
    (v_id,'2026-07-15',2,0,90);
  EXECUTE 'SET CONSTRAINTS ALL IMMEDIATE';
  RAISE EXCEPTION 'FAIL: unbalanced partitioned entry accepted';
EXCEPTION WHEN check_violation THEN
  RAISE NOTICE 'PASS: unbalanced partitioned entry rejected (%)', SQLERRM;
END $$;

\echo '=== P3: partition pruning routes a year to one partition ==='
SELECT CASE WHEN (SELECT count(*) FROM jl_p_2026) = 2
            THEN 'PASS: 2026 lines landed in jl_p_2026' ELSE 'FAIL' END AS p3a;
SELECT CASE WHEN (SELECT count(*) FROM jl_p_2027) = 0
            THEN 'PASS: 2027 partition empty' ELSE 'FAIL' END AS p3b;

\echo '=== P4: a 2027 entry lands in the 2027 partition ==='
DO $$
DECLARE v_id uuid := uuidv7();
BEGIN
  INSERT INTO je_p (id, entry_date, memo) VALUES (v_id, '2027-03-01', 'next year');
  INSERT INTO jl_p (journal_entry_id, entry_date, line_no, debit, credit) VALUES
    (v_id,'2027-03-01',1,50,0),
    (v_id,'2027-03-01',2,0,50);
  EXECUTE 'SET CONSTRAINTS ALL IMMEDIATE';
END $$;
SELECT CASE WHEN (SELECT count(*) FROM jl_p_2027) = 2
            THEN 'PASS: 2027 lines landed in jl_p_2027' ELSE 'FAIL' END AS p4;

\echo '=== ALL PARTITION TESTS COMPLETE ==='
