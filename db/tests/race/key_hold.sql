-- Race 4 (key), session A — posts with the shared idempotency key, holding the
-- posting counter (and the unique (tenant_id, idempotency_key) index entry), then
-- rolls back.
BEGIN;
SELECT post_journal_entry(
  '2091-07-01', 'race key A', 'race', 'race-key-a', 'race:key',
  jsonb_build_array(
    jsonb_build_object('account_id','01900000-0000-7000-8000-00000000f010','debit',100,'currency','USD','fx_rate',1),
    jsonb_build_object('account_id','01900000-0000-7000-8000-00000000f012','credit',100,'currency','USD','fx_rate',1)
  )
);
SELECT pg_sleep(6);
ROLLBACK;
