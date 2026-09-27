-- Race 2 (period), session A — closes the 2091 period, holding its row lock for
-- the sleep, then rolls back. Session B's posting must block on the period row
-- (the period-open trigger takes it FOR UPDATE).
BEGIN;
UPDATE fiscal_period SET status = 'closed' WHERE id = '01900000-0000-7000-8000-00000000f021';
SELECT pg_sleep(6);
ROLLBACK;
