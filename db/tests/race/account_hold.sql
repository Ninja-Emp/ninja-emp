-- Race 3 (account), session A — changes an account's type, holding its row lock
-- for the sleep, then rolls back. Session B's posting must block on the account
-- row (the account-lock trigger takes it FOR UPDATE).
BEGIN;
UPDATE account SET account_type_code = 'expense' WHERE id = '01900000-0000-7000-8000-00000000f010';
SELECT pg_sleep(6);
ROLLBACK;
