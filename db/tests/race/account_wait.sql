-- Race 3 (account), session B — posts a line to the account session A is
-- changing. The header takes the counter and period first, so this proves the
-- kernel's whole lock order (counter -> period -> account) serialises cleanly.
BEGIN;
SELECT post_journal_entry(
  '2091-06-01', 'race account B', 'race', 'race-account-b', 'race:account:b',
  jsonb_build_array(
    jsonb_build_object('account_id','01900000-0000-7000-8000-00000000f010','debit',100,'currency','USD','fx_rate',1),
    jsonb_build_object('account_id','01900000-0000-7000-8000-00000000f012','credit',100,'currency','USD','fx_rate',1)
  )
);
SELECT 'RACE_B_OK';
ROLLBACK;
