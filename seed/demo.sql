-- Demo Mall. One Saturday, journals included, fixed ids.
-- Logins: owner@demo.test and cashier@demo.test. Password: practice.
-- Rent stays on 1300. The only 2000 to 1300 journal is the named apply.
-- The bowl return puts the unpaid holder remainder on 1310. Payable stays at zero, not negative.
-- The check pays leftover payable. It does not mash rent into the payout.

INSERT INTO public.identities (identity_id, email, password_hash) VALUES
    ('018f0000-0000-7000-8000-000000000002', 'owner@demo.test', '$argon2id$v=19$m=19456,t=2,p=1$aTBZeDlPYkRGWmg4bDMueA$BJG4P3/qzDT1rByhbuhHQwEhRbpRu0sAe6/VwGuS/Xs'),
    ('018f0000-0000-7000-8000-000000000003', 'cashier@demo.test', '$argon2id$v=19$m=19456,t=2,p=1$TVVWaWdRV3hsbjl1ZGdybQ$hgkV2ooe5Kk9RScqoWZDtfrI+uvOheZbyg891oKvMco')
ON CONFLICT (email) DO NOTHING;

INSERT INTO public.tenants (
    tenant_id, slug, store_name, status, use_case, functional_currency, timezone, demo_seeded
) VALUES (
    '018f0000-0000-7000-8000-000000000001', 'demo', 'Demo Mall', 'demo', 'vendor_mall', 'USD', 'America/Chicago', true
) ON CONFLICT (slug) DO NOTHING;

INSERT INTO public.tenant_memberships (tenant_membership_id, tenant_id, identity_id, role) VALUES
    ('018f0000-0000-7000-8000-000000000004', '018f0000-0000-7000-8000-000000000001', '018f0000-0000-7000-8000-000000000002', 'owner'),
    ('018f0000-0000-7000-8000-000000000005', '018f0000-0000-7000-8000-000000000001', '018f0000-0000-7000-8000-000000000003', 'cashier')
ON CONFLICT (tenant_id, identity_id) DO NOTHING;

INSERT INTO public.tenant_billing (tenant_id, plan_code, status) VALUES
    ('018f0000-0000-7000-8000-000000000001', 'practice', 'trial')
ON CONFLICT (tenant_id) DO NOTHING;

INSERT INTO ledger_books (book_id, code, name, currency, is_default) VALUES
    ('018f0000-0000-7000-8000-000000000010', 'PRIMARY', 'Primary book', 'USD', true);

INSERT INTO accounting_periods (period_id, book_id, starts_on, ends_on, status) VALUES
    ('018f0000-0000-7000-8000-000000000011', '018f0000-0000-7000-8000-000000000010', '2026-09-01', '2026-09-30', 'open');

INSERT INTO accounting_sequences (book_id, scope, next_value) VALUES
    ('018f0000-0000-7000-8000-000000000010', 'journal', 11);

INSERT INTO parties (party_id, display_name, first_name, last_name, commission_bps, kind, portal_enabled) VALUES
    ('018f0000-0000-7000-8000-000000000020', 'Pat Practice', 'Pat', 'Practice', 4000, 'vendor', true);

INSERT INTO booths (booth_id, booth_code, size, default_rent_minor, default_rent_currency) VALUES
    ('018f0000-0000-7000-8000-000000000021', 'A12', '10x10', 8000, 'USD');

INSERT INTO booth_assignments (assignment_id, booth_id, party_id, starts_on, rent_amount_minor, currency) VALUES
    ('018f0000-0000-7000-8000-000000000022', '018f0000-0000-7000-8000-000000000021', '018f0000-0000-7000-8000-000000000020', '2026-09-01', 8000, 'USD');

INSERT INTO registers (register_id, register_name, location_id) VALUES
    ('018f0000-0000-7000-8000-000000000030', 'Front', (SELECT location_id FROM store_locations WHERE location_name = 'Main'));

INSERT INTO items (item_id, sku, item_name, party_id, booth_id, price_minor, currency, qty_on_hand, received_on, origin) VALUES
    ('018f0000-0000-7000-8000-000000000040', 'MUG-1', 'Practice mug', '018f0000-0000-7000-8000-000000000020', '018f0000-0000-7000-8000-000000000021', 1000, 'USD', 1, '2026-09-01', 'catalog'),
    ('018f0000-0000-7000-8000-000000000041', 'LAMP-1', 'Practice lamp', '018f0000-0000-7000-8000-000000000020', '018f0000-0000-7000-8000-000000000021', 10000, 'USD', 0, '2026-09-01', 'catalog'),
    ('018f0000-0000-7000-8000-000000000042', 'BOWL-1', 'Practice bowl', '018f0000-0000-7000-8000-000000000020', '018f0000-0000-7000-8000-000000000021', 1000, 'USD', 1, '2026-09-01', 'catalog');

INSERT INTO register_sessions (
    register_session_id, register_id, opened_by_membership_id, opened_at, opening_cash_minor, currency,
    closed_at, closed_by_membership_id, closing_cash_minor, closing_checks_minor, force_closed
) VALUES (
    '018f0000-0000-7000-8000-000000000031', '018f0000-0000-7000-8000-000000000030', '018f0000-0000-7000-8000-000000000004', '2026-09-12T13:30:00.000Z', 0, 'USD',
    '2026-09-12T16:00:00.000Z', '018f0000-0000-7000-8000-000000000004', 12000, 0, false
);
INSERT INTO journals (
    journal_id, book_id, journal_no, posting_key, posting_date, occurred_at, period_id, currency,
    source_type, source_reference, description, is_reversal, reverses_journal_id,
    total_debits_minor, total_credits_minor, prev_hash, entry_hash, hash_scheme
) VALUES
('018f0000-0000-7000-8000-000000000101', '018f0000-0000-7000-8000-000000000010', 1, 'je:owner-capital:opening', '2026-09-12', '2026-09-12T12:00:00.000Z', '018f0000-0000-7000-8000-000000000011', 'USD', 'owner_capital', NULL, 'Owner capital', false, NULL, 50000, 50000, NULL, '09fc82a2ef8c5f56dcdb86ff8f66a1cc6b1e795cefb2547f52831329040e8af4', 2),
('018f0000-0000-7000-8000-000000000102', '018f0000-0000-7000-8000-000000000010', 2, 'je:rent-charge:018f0000-0000-7000-8000-000000000022:2026-09-01', '2026-09-01', '2026-09-12T13:00:00.000Z', '018f0000-0000-7000-8000-000000000011', 'USD', 'rent_charge', '018f0000-0000-7000-8000-000000000022', 'Booth rent 2026-09-01', false, NULL, 8000, 8000, '09fc82a2ef8c5f56dcdb86ff8f66a1cc6b1e795cefb2547f52831329040e8af4', '8464cb6fe9a8f0143cc6c4d81ba375d7f3fbd42649c0793ed4aeb62772444590', 2),
('018f0000-0000-7000-8000-000000000103', '018f0000-0000-7000-8000-000000000010', 3, 'je:sale:018f0000-0000-7000-8000-000000000201', '2026-09-12', '2026-09-12T14:00:00.000Z', '018f0000-0000-7000-8000-000000000011', 'USD', 'sale', '018f0000-0000-7000-8000-000000000201', 'Sale', false, NULL, 1000, 1000, '8464cb6fe9a8f0143cc6c4d81ba375d7f3fbd42649c0793ed4aeb62772444590', '2732e06509682a313fae8f9ca8f197e6e8380908371760464283a818b8a8b6e0', 2),
('018f0000-0000-7000-8000-000000000104', '018f0000-0000-7000-8000-000000000010', 4, 'je:sale-void:018f0000-0000-7000-8000-000000000201', '2026-09-12', '2026-09-12T14:05:00.000Z', '018f0000-0000-7000-8000-000000000011', 'USD', 'sale', '018f0000-0000-7000-8000-000000000201', 'Reversal: Sale', true, '018f0000-0000-7000-8000-000000000103', 1000, 1000, '2732e06509682a313fae8f9ca8f197e6e8380908371760464283a818b8a8b6e0', 'eecaf3d362b9ffb8a63b301b4a03215f584f918f30f11cb0ae28ea7a67c2f848', 2),
('018f0000-0000-7000-8000-000000000105', '018f0000-0000-7000-8000-000000000010', 5, 'je:sale:018f0000-0000-7000-8000-000000000202', '2026-09-12', '2026-09-12T14:10:00.000Z', '018f0000-0000-7000-8000-000000000011', 'USD', 'sale', '018f0000-0000-7000-8000-000000000202', 'Sale', false, NULL, 10000, 10000, 'eecaf3d362b9ffb8a63b301b4a03215f584f918f30f11cb0ae28ea7a67c2f848', '3390dbbc4b2f42ffffd6ca63f3a500b006a967bbaea118e96ae3fde811518efd', 2),
('018f0000-0000-7000-8000-000000000106', '018f0000-0000-7000-8000-000000000010', 6, 'je:sale:018f0000-0000-7000-8000-000000000203', '2026-09-12', '2026-09-12T14:20:00.000Z', '018f0000-0000-7000-8000-000000000011', 'USD', 'sale', '018f0000-0000-7000-8000-000000000203', 'Sale', false, NULL, 1000, 1000, '3390dbbc4b2f42ffffd6ca63f3a500b006a967bbaea118e96ae3fde811518efd', '41416c78c505b60b87ec170b9f9261c3c9bab74dffcf9607cb35a528b114f70c', 2),
('018f0000-0000-7000-8000-000000000107', '018f0000-0000-7000-8000-000000000010', 7, 'je:payable-rent-settlement:018f0000-0000-7000-8000-000000000603', '2026-09-12', '2026-09-12T15:00:00.000Z', '018f0000-0000-7000-8000-000000000011', 'USD', 'payable_rent_settlement', '018f0000-0000-7000-8000-000000000603', 'Apply payable to rent', false, NULL, 5000, 5000, '41416c78c505b60b87ec170b9f9261c3c9bab74dffcf9607cb35a528b114f70c', '990d2bbc9a4f0ebc9b0b9f00901ab7ffc7fcecf3397f8cc60e644a6e36b54fef', 2),
('018f0000-0000-7000-8000-000000000108', '018f0000-0000-7000-8000-000000000010', 8, 'je:rent-receipt:018f0000-0000-7000-8000-000000000602', '2026-09-12', '2026-09-12T15:10:00.000Z', '018f0000-0000-7000-8000-000000000011', 'USD', 'rent_receipt', '018f0000-0000-7000-8000-000000000602', 'Booth rent payment', false, NULL, 2000, 2000, '990d2bbc9a4f0ebc9b0b9f00901ab7ffc7fcecf3397f8cc60e644a6e36b54fef', '8bb8dfecafbbf0934bd7bc80fec2e0d9ca9627e0f7a44583a1644ea2970e8921', 2),
('018f0000-0000-7000-8000-000000000109', '018f0000-0000-7000-8000-000000000010', 9, 'je:payout:018f0000-0000-7000-8000-000000000604', '2026-09-12', '2026-09-12T15:20:00.000Z', '018f0000-0000-7000-8000-000000000011', 'USD', 'holder_payout', '018f0000-0000-7000-8000-000000000604', 'Holder payout (check)', false, NULL, 1200, 1200, '8bb8dfecafbbf0934bd7bc80fec2e0d9ca9627e0f7a44583a1644ea2970e8921', '25860942b5cdbd09a868a0c11b3206f2b1acbe48f8abcd52ce6cfab6467d3be3', 2),
('018f0000-0000-7000-8000-000000000110', '018f0000-0000-7000-8000-000000000010', 10, 'je:sale-return:018f0000-0000-7000-8000-000000000501', '2026-09-12', '2026-09-12T15:30:00.000Z', '018f0000-0000-7000-8000-000000000011', 'USD', 'sale_return', '018f0000-0000-7000-8000-000000000501', 'Sale return', false, NULL, 1000, 1000, '25860942b5cdbd09a868a0c11b3206f2b1acbe48f8abcd52ce6cfab6467d3be3', 'ce70eac67339fc1818aeaa29eb65756b9dba9bcc9ad2e19446567ec1ec4fa0d2', 2);

INSERT INTO journal_lines (journal_id, line_no, account_id, debit_minor, credit_minor, subledger_type, subledger_ref) VALUES
('018f0000-0000-7000-8000-000000000101', 1, (SELECT account_id FROM accounts WHERE code = '1010'), 50000, 0, NULL, NULL),
('018f0000-0000-7000-8000-000000000101', 2, (SELECT account_id FROM accounts WHERE code = '3000'), 0, 50000, NULL, NULL),
('018f0000-0000-7000-8000-000000000102', 1, (SELECT account_id FROM accounts WHERE code = '1300'), 8000, 0, 'party', '018f0000-0000-7000-8000-000000000020'),
('018f0000-0000-7000-8000-000000000102', 2, (SELECT account_id FROM accounts WHERE code = '4100'), 0, 8000, NULL, NULL),
('018f0000-0000-7000-8000-000000000103', 1, (SELECT account_id FROM accounts WHERE code = '1000'), 1000, 0, NULL, NULL),
('018f0000-0000-7000-8000-000000000103', 2, (SELECT account_id FROM accounts WHERE code = '4000'), 0, 400, NULL, NULL),
('018f0000-0000-7000-8000-000000000103', 3, (SELECT account_id FROM accounts WHERE code = '2000'), 0, 600, 'party', '018f0000-0000-7000-8000-000000000020'),
('018f0000-0000-7000-8000-000000000104', 1, (SELECT account_id FROM accounts WHERE code = '1000'), 0, 1000, NULL, NULL),
('018f0000-0000-7000-8000-000000000104', 2, (SELECT account_id FROM accounts WHERE code = '4000'), 400, 0, NULL, NULL),
('018f0000-0000-7000-8000-000000000104', 3, (SELECT account_id FROM accounts WHERE code = '2000'), 600, 0, 'party', '018f0000-0000-7000-8000-000000000020'),
('018f0000-0000-7000-8000-000000000105', 1, (SELECT account_id FROM accounts WHERE code = '1000'), 10000, 0, NULL, NULL),
('018f0000-0000-7000-8000-000000000105', 2, (SELECT account_id FROM accounts WHERE code = '4000'), 0, 4000, NULL, NULL),
('018f0000-0000-7000-8000-000000000105', 3, (SELECT account_id FROM accounts WHERE code = '2000'), 0, 6000, 'party', '018f0000-0000-7000-8000-000000000020'),
('018f0000-0000-7000-8000-000000000106', 1, (SELECT account_id FROM accounts WHERE code = '1000'), 1000, 0, NULL, NULL),
('018f0000-0000-7000-8000-000000000106', 2, (SELECT account_id FROM accounts WHERE code = '4000'), 0, 400, NULL, NULL),
('018f0000-0000-7000-8000-000000000106', 3, (SELECT account_id FROM accounts WHERE code = '2000'), 0, 600, 'party', '018f0000-0000-7000-8000-000000000020'),
('018f0000-0000-7000-8000-000000000107', 1, (SELECT account_id FROM accounts WHERE code = '2000'), 5000, 0, 'party', '018f0000-0000-7000-8000-000000000020'),
('018f0000-0000-7000-8000-000000000107', 2, (SELECT account_id FROM accounts WHERE code = '1300'), 0, 5000, 'party', '018f0000-0000-7000-8000-000000000020'),
('018f0000-0000-7000-8000-000000000108', 1, (SELECT account_id FROM accounts WHERE code = '1000'), 2000, 0, NULL, NULL),
('018f0000-0000-7000-8000-000000000108', 2, (SELECT account_id FROM accounts WHERE code = '1300'), 0, 2000, 'party', '018f0000-0000-7000-8000-000000000020'),
('018f0000-0000-7000-8000-000000000109', 1, (SELECT account_id FROM accounts WHERE code = '2000'), 1200, 0, 'party', '018f0000-0000-7000-8000-000000000020'),
('018f0000-0000-7000-8000-000000000109', 2, (SELECT account_id FROM accounts WHERE code = '1010'), 0, 1200, NULL, NULL),
('018f0000-0000-7000-8000-000000000110', 1, (SELECT account_id FROM accounts WHERE code = '2000'), 400, 0, 'party', '018f0000-0000-7000-8000-000000000020'),
('018f0000-0000-7000-8000-000000000110', 2, (SELECT account_id FROM accounts WHERE code = '1310'), 200, 0, 'party', '018f0000-0000-7000-8000-000000000020'),
('018f0000-0000-7000-8000-000000000110', 3, (SELECT account_id FROM accounts WHERE code = '4000'), 400, 0, NULL, NULL),
('018f0000-0000-7000-8000-000000000110', 4, (SELECT account_id FROM accounts WHERE code = '1000'), 0, 1000, NULL, NULL);

INSERT INTO sales (
    sale_id, register_id, sold_on, sold_at, currency, status, journal_id, reversal_journal_id,
    tax_exempt, ticket_discount_minor, ticket_discount_bps, house_buy, change_minor,
    cash_rounding_adjustment_minor, checkout_kind
) VALUES
    ('018f0000-0000-7000-8000-000000000201', '018f0000-0000-7000-8000-000000000030', '2026-09-12', '2026-09-12T14:00:00.000Z', 'USD', 'voided', '018f0000-0000-7000-8000-000000000103', '018f0000-0000-7000-8000-000000000104', false, 0, 0, false, 0, 0, 'central'),
    ('018f0000-0000-7000-8000-000000000202', '018f0000-0000-7000-8000-000000000030', '2026-09-12', '2026-09-12T14:10:00.000Z', 'USD', 'completed', '018f0000-0000-7000-8000-000000000105', NULL, false, 0, 0, false, 0, 0, 'central'),
    ('018f0000-0000-7000-8000-000000000203', '018f0000-0000-7000-8000-000000000030', '2026-09-12', '2026-09-12T14:20:00.000Z', 'USD', 'completed', '018f0000-0000-7000-8000-000000000106', NULL, false, 0, 0, false, 0, 0, 'central');

INSERT INTO sale_lines (
    sale_line_id, sale_id, item_id, party_id, qty, unit_price_minor, line_total_minor, tax_minor,
    commission_minor, holder_minor, line_name, booth_id, cost_minor
) VALUES
    ('018f0000-0000-7000-8000-000000000301', '018f0000-0000-7000-8000-000000000201', '018f0000-0000-7000-8000-000000000040', '018f0000-0000-7000-8000-000000000020', 1, 1000, 1000, 0, 400, 600, 'Practice mug', '018f0000-0000-7000-8000-000000000021', 0),
    ('018f0000-0000-7000-8000-000000000302', '018f0000-0000-7000-8000-000000000202', '018f0000-0000-7000-8000-000000000041', '018f0000-0000-7000-8000-000000000020', 1, 10000, 10000, 0, 4000, 6000, 'Practice lamp', '018f0000-0000-7000-8000-000000000021', 0),
    ('018f0000-0000-7000-8000-000000000303', '018f0000-0000-7000-8000-000000000203', '018f0000-0000-7000-8000-000000000042', '018f0000-0000-7000-8000-000000000020', 1, 1000, 1000, 0, 400, 600, 'Practice bowl', '018f0000-0000-7000-8000-000000000021', 0);

INSERT INTO sale_tenders (sale_tender_id, sale_id, method, amount_minor) VALUES
    ('018f0000-0000-7000-8000-000000000401', '018f0000-0000-7000-8000-000000000201', 'cash', 1000),
    ('018f0000-0000-7000-8000-000000000402', '018f0000-0000-7000-8000-000000000202', 'cash', 10000),
    ('018f0000-0000-7000-8000-000000000403', '018f0000-0000-7000-8000-000000000203', 'cash', 1000);

INSERT INTO sale_returns (
    sale_return_id, sale_id, returned_on, amount_minor, currency, journal_id,
    cash_amount_minor, card_amount_minor, check_amount_minor, gift_amount_minor,
    vendor_purchase_amount_minor, store_credit_amount_minor, cash_rounding_adjustment_minor
) VALUES (
    '018f0000-0000-7000-8000-000000000501', '018f0000-0000-7000-8000-000000000203', '2026-09-12', 1000, 'USD', '018f0000-0000-7000-8000-000000000110',
    1000, 0, 0, 0, 0, 0, 0
);

INSERT INTO sale_return_lines (
    sale_return_line_id, sale_return_id, sale_line_id, qty, line_total_minor, tax_minor, commission_minor, holder_minor, cost_minor
) VALUES (
    '018f0000-0000-7000-8000-000000000502', '018f0000-0000-7000-8000-000000000501', '018f0000-0000-7000-8000-000000000303', 1, 1000, 0, 400, 600, 0
);

INSERT INTO vendor_clawbacks (
    vendor_clawback_id, party_id, clawed_on, amount_minor, currency, source_type, source_id, journal_id, status
) VALUES (
    '018f0000-0000-7000-8000-000000000503', '018f0000-0000-7000-8000-000000000020', '2026-09-12', 200, 'USD', 'sale_return', '018f0000-0000-7000-8000-000000000501', '018f0000-0000-7000-8000-000000000110', 'completed'
);

INSERT INTO rent_charges (
    rent_charge_id, assignment_id, period_starts_on, period_ends_on, amount_minor, currency, journal_id, status
) VALUES (
    '018f0000-0000-7000-8000-000000000601', '018f0000-0000-7000-8000-000000000022', '2026-09-01', '2026-09-30', 8000, 'USD', '018f0000-0000-7000-8000-000000000102', 'completed'
);

INSERT INTO payable_rent_settlements (
    settlement_id, party_id, settled_on, amount_minor, currency, journal_id, status
) VALUES (
    '018f0000-0000-7000-8000-000000000603', '018f0000-0000-7000-8000-000000000020', '2026-09-12', 5000, 'USD', '018f0000-0000-7000-8000-000000000107', 'completed'
);

INSERT INTO rent_receipts (
    rent_receipt_id, party_id, register_session_id, received_on, amount_minor, currency, journal_id, method, status
) VALUES (
    '018f0000-0000-7000-8000-000000000602', '018f0000-0000-7000-8000-000000000020', '018f0000-0000-7000-8000-000000000031', '2026-09-12', 2000, 'USD', '018f0000-0000-7000-8000-000000000108', 'cash', 'completed'
);

INSERT INTO payout_runs (payout_run_id, paid_on, method, status) VALUES
    ('018f0000-0000-7000-8000-000000000605', '2026-09-12', 'check', 'completed');

INSERT INTO holder_payouts (
    holder_payout_id, party_id, paid_on, amount_minor, currency, journal_id, status, payout_run_id, method, check_number
) VALUES (
    '018f0000-0000-7000-8000-000000000604', '018f0000-0000-7000-8000-000000000020', '2026-09-12', 1200, 'USD', '018f0000-0000-7000-8000-000000000109', 'completed', '018f0000-0000-7000-8000-000000000605', 'check', '1001'
);

INSERT INTO payout_run_envelopes (
    payout_run_envelope_id, payout_run_id, party_id, holder_payout_id, check_amount_minor, currency, payload
) VALUES (
    '018f0000-0000-7000-8000-000000000606', '018f0000-0000-7000-8000-000000000605', '018f0000-0000-7000-8000-000000000020', '018f0000-0000-7000-8000-000000000604', 1200, 'USD',
    '{"payee":"Pat Practice","checkNumber":"1001"}'::jsonb
);

INSERT INTO tax_year_payments (
    party_id, tax_year, payment_date, amount_minor, currency, form_code, source_type, source_id, kind
) VALUES (
    '018f0000-0000-7000-8000-000000000020', 2026, '2026-09-12', 1200, 'USD', '1099-NEC', 'holder_payout', '018f0000-0000-7000-8000-000000000604', 'payment'
);

UPDATE store_settings SET check_print_next_number = 1002 WHERE store_settings_id = true;

INSERT INTO audit_events (occurred_at, identity_id, membership_id, action, message, resource_type, resource_id) VALUES
    ('2026-09-12T13:30:00.000Z', '018f0000-0000-7000-8000-000000000002', '018f0000-0000-7000-8000-000000000004', 'register_open', 'Opened the register', 'register_session', '018f0000-0000-7000-8000-000000000031'),
    ('2026-09-12T13:00:00.000Z', '018f0000-0000-7000-8000-000000000002', '018f0000-0000-7000-8000-000000000004', 'rent_charge', 'Posted booth rent', 'rent_charge', '018f0000-0000-7000-8000-000000000601'),
    ('2026-09-12T14:00:00.000Z', '018f0000-0000-7000-8000-000000000002', '018f0000-0000-7000-8000-000000000004', 'sale', 'Completed a sale', 'sale', '018f0000-0000-7000-8000-000000000201'),
    ('2026-09-12T14:05:00.000Z', '018f0000-0000-7000-8000-000000000002', '018f0000-0000-7000-8000-000000000004', 'sale_void', 'Voided a sale', 'sale', '018f0000-0000-7000-8000-000000000201'),
    ('2026-09-12T14:10:00.000Z', '018f0000-0000-7000-8000-000000000002', '018f0000-0000-7000-8000-000000000004', 'sale', 'Completed a sale', 'sale', '018f0000-0000-7000-8000-000000000202'),
    ('2026-09-12T14:20:00.000Z', '018f0000-0000-7000-8000-000000000002', '018f0000-0000-7000-8000-000000000004', 'sale', 'Completed a sale', 'sale', '018f0000-0000-7000-8000-000000000203'),
    ('2026-09-12T15:00:00.000Z', '018f0000-0000-7000-8000-000000000002', '018f0000-0000-7000-8000-000000000004', 'payable_rent_settlement', 'Applied payable to rent', 'payable_rent_settlement', '018f0000-0000-7000-8000-000000000603'),
    ('2026-09-12T15:10:00.000Z', '018f0000-0000-7000-8000-000000000002', '018f0000-0000-7000-8000-000000000004', 'rent_receipt', 'Recorded a rent payment', 'rent_receipt', '018f0000-0000-7000-8000-000000000602'),
    ('2026-09-12T15:20:00.000Z', '018f0000-0000-7000-8000-000000000002', '018f0000-0000-7000-8000-000000000004', 'holder_payout', 'Paid a vendor by check', 'holder_payout', '018f0000-0000-7000-8000-000000000604'),
    ('2026-09-12T15:30:00.000Z', '018f0000-0000-7000-8000-000000000002', '018f0000-0000-7000-8000-000000000004', 'sale_return', 'Returned a sale', 'sale_return', '018f0000-0000-7000-8000-000000000501'),
    ('2026-09-12T16:00:00.000Z', '018f0000-0000-7000-8000-000000000002', '018f0000-0000-7000-8000-000000000004', 'register_close', 'Closed the register', 'register_session', '018f0000-0000-7000-8000-000000000031');
