--
-- PostgreSQL database dump
--

\restrict AdP2RpejVotpzl9h08e0IoEUFvtJeUlsmuCgzEWD0mpCCDanw60lEd1Unh4Pgkf

-- Dumped from database version 18.6 (Debian 18.6-1.pgdg12+2)
-- Dumped by pg_dump version 18.6 (Debian 18.6-1.pgdg12+2)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Data for Name: account_type; Type: TABLE DATA; Schema: kernel; Owner: -
--

INSERT INTO kernel.account_type (code, name, normal_balance, statement, sort_order) VALUES ('asset', 'Asset', 'D', 'balance_sheet', 10);
INSERT INTO kernel.account_type (code, name, normal_balance, statement, sort_order) VALUES ('liability', 'Liability', 'C', 'balance_sheet', 20);
INSERT INTO kernel.account_type (code, name, normal_balance, statement, sort_order) VALUES ('equity', 'Equity', 'C', 'balance_sheet', 30);
INSERT INTO kernel.account_type (code, name, normal_balance, statement, sort_order) VALUES ('revenue', 'Revenue', 'C', 'income_statement', 40);
INSERT INTO kernel.account_type (code, name, normal_balance, statement, sort_order) VALUES ('expense', 'Expense', 'D', 'income_statement', 50);


--
-- Data for Name: contact_mechanism_type; Type: TABLE DATA; Schema: kernel; Owner: -
--

INSERT INTO kernel.contact_mechanism_type (code, name) VALUES ('email', 'Email');
INSERT INTO kernel.contact_mechanism_type (code, name) VALUES ('phone', 'Phone');
INSERT INTO kernel.contact_mechanism_type (code, name) VALUES ('mobile', 'Mobile');
INSERT INTO kernel.contact_mechanism_type (code, name) VALUES ('web', 'Website');
INSERT INTO kernel.contact_mechanism_type (code, name) VALUES ('fax', 'Fax');
INSERT INTO kernel.contact_mechanism_type (code, name) VALUES ('social', 'Social');


--
-- Data for Name: currency; Type: TABLE DATA; Schema: kernel; Owner: -
--

INSERT INTO kernel.currency (code, numeric_code, name, minor_unit, symbol, is_active) VALUES ('USD', 840, 'US Dollar', 2, '$', true);
INSERT INTO kernel.currency (code, numeric_code, name, minor_unit, symbol, is_active) VALUES ('EUR', 978, 'Euro', 2, '€', true);
INSERT INTO kernel.currency (code, numeric_code, name, minor_unit, symbol, is_active) VALUES ('GBP', 826, 'Pound Sterling', 2, '£', true);
INSERT INTO kernel.currency (code, numeric_code, name, minor_unit, symbol, is_active) VALUES ('CAD', 124, 'Canadian Dollar', 2, 'C$', true);
INSERT INTO kernel.currency (code, numeric_code, name, minor_unit, symbol, is_active) VALUES ('MXN', 484, 'Mexican Peso', 2, 'MX$', true);
INSERT INTO kernel.currency (code, numeric_code, name, minor_unit, symbol, is_active) VALUES ('JPY', 392, 'Japanese Yen', 0, '¥', true);
INSERT INTO kernel.currency (code, numeric_code, name, minor_unit, symbol, is_active) VALUES ('AUD', 36, 'Australian Dollar', 2, 'A$', true);


--
-- Data for Name: data_classification; Type: TABLE DATA; Schema: kernel; Owner: -
--

INSERT INTO kernel.data_classification (schema_name, table_name, column_name, class, note) VALUES ('*', 'party_identifier', 'identifier_value', 'pii_sensitive', 'Encrypted at rest; masked in views (ADR-0018).');
INSERT INTO kernel.data_classification (schema_name, table_name, column_name, class, note) VALUES ('*', 'person', 'date_of_birth', 'pii_sensitive', 'Encrypted/masked; never exposed raw.');
INSERT INTO kernel.data_classification (schema_name, table_name, column_name, class, note) VALUES ('*', 'person', 'given_name', 'pii', NULL);
INSERT INTO kernel.data_classification (schema_name, table_name, column_name, class, note) VALUES ('*', 'person', 'family_name', 'pii', NULL);
INSERT INTO kernel.data_classification (schema_name, table_name, column_name, class, note) VALUES ('*', 'party_contact_mechanism', 'value', 'pii', 'Email/phone are personal data.');
INSERT INTO kernel.data_classification (schema_name, table_name, column_name, class, note) VALUES ('*', 'postal_address', 'line1', 'pii', NULL);
INSERT INTO kernel.data_classification (schema_name, table_name, column_name, class, note) VALUES ('*', 'postal_address', 'line2', 'pii', NULL);
INSERT INTO kernel.data_classification (schema_name, table_name, column_name, class, note) VALUES ('*', 'postal_address', 'postal_code', 'pii', NULL);
INSERT INTO kernel.data_classification (schema_name, table_name, column_name, class, note) VALUES ('*', 'journal_entry', 'memo', 'confidential', NULL);
INSERT INTO kernel.data_classification (schema_name, table_name, column_name, class, note) VALUES ('*', 'journal_line', 'memo', 'confidential', NULL);
INSERT INTO kernel.data_classification (schema_name, table_name, column_name, class, note) VALUES ('*', 'lease', '*', 'confidential', 'Contract terms.');


--
-- Data for Name: identifier_type; Type: TABLE DATA; Schema: kernel; Owner: -
--

INSERT INTO kernel.identifier_type (code, name, is_pii, is_sensitive) VALUES ('tax_id', 'Tax Identifier', true, true);
INSERT INTO kernel.identifier_type (code, name, is_pii, is_sensitive) VALUES ('ein', 'Employer ID Number', true, true);
INSERT INTO kernel.identifier_type (code, name, is_pii, is_sensitive) VALUES ('ssn', 'Social Security No.', true, true);
INSERT INTO kernel.identifier_type (code, name, is_pii, is_sensitive) VALUES ('duns', 'DUNS Number', false, false);
INSERT INTO kernel.identifier_type (code, name, is_pii, is_sensitive) VALUES ('vendor_no', 'Vendor Number', false, false);
INSERT INTO kernel.identifier_type (code, name, is_pii, is_sensitive) VALUES ('customer_no', 'Customer Number', false, false);
INSERT INTO kernel.identifier_type (code, name, is_pii, is_sensitive) VALUES ('license_no', 'Business License No.', false, false);


--
-- Data for Name: migration; Type: TABLE DATA; Schema: kernel; Owner: -
--



--
-- Data for Name: party_relationship_type; Type: TABLE DATA; Schema: kernel; Owner: -
--

INSERT INTO kernel.party_relationship_type (code, name, description) VALUES ('vendor_of', 'Vendor of', 'from_party supplies to_party.');
INSERT INTO kernel.party_relationship_type (code, name, description) VALUES ('employee_of', 'Employee of', 'from_party is employed by to_party.');
INSERT INTO kernel.party_relationship_type (code, name, description) VALUES ('contact_for', 'Contact for', 'from_party is a contact for to_party.');
INSERT INTO kernel.party_relationship_type (code, name, description) VALUES ('guarantor_of', 'Guarantor of', 'from_party guarantees to_party obligations.');
INSERT INTO kernel.party_relationship_type (code, name, description) VALUES ('parent_of', 'Parent of', 'Corporate hierarchy.');


--
-- Data for Name: party_role_type; Type: TABLE DATA; Schema: kernel; Owner: -
--

INSERT INTO kernel.party_role_type (code, name, description) VALUES ('customer', 'Customer', 'Buys goods/services.');
INSERT INTO kernel.party_role_type (code, name, description) VALUES ('vendor', 'Vendor', 'Sells goods to the store or rents a booth.');
INSERT INTO kernel.party_role_type (code, name, description) VALUES ('consignor', 'Consignor', 'Places goods on consignment.');
INSERT INTO kernel.party_role_type (code, name, description) VALUES ('supplier', 'Supplier', 'Supplies goods/services to the store.');
INSERT INTO kernel.party_role_type (code, name, description) VALUES ('employee', 'Employee', 'Works for the store.');
INSERT INTO kernel.party_role_type (code, name, description) VALUES ('landlord', 'Landlord', 'Lessor of space (the mall itself, in vendor-run model).');
INSERT INTO kernel.party_role_type (code, name, description) VALUES ('buyer', 'Buyer', 'Store acting as purchaser of vendor/consignor goods.');
INSERT INTO kernel.party_role_type (code, name, description) VALUES ('contact', 'Contact', 'Generic contact person.');
INSERT INTO kernel.party_role_type (code, name, description) VALUES ('lessee', 'Lessee', 'Holds a lease for mall space.');


--
-- Data for Name: posting_role; Type: TABLE DATA; Schema: kernel; Owner: -
--

INSERT INTO kernel.posting_role (code, name, description) VALUES ('cash', 'Cash', 'Cash / bank account.');
INSERT INTO kernel.posting_role (code, name, description) VALUES ('ar_control', 'AR Control', 'Accounts receivable control account.');
INSERT INTO kernel.posting_role (code, name, description) VALUES ('ap_control', 'AP Control', 'Accounts payable control account.');
INSERT INTO kernel.posting_role (code, name, description) VALUES ('vendor_payable_control', 'Vendor Payable Control', 'Vendor/consignor payable control account.');
INSERT INTO kernel.posting_role (code, name, description) VALUES ('customer_credit_control', 'Customer Credit Control', 'Customer store-credit liability control.');
INSERT INTO kernel.posting_role (code, name, description) VALUES ('gift_certificate_control', 'Gift Certificate Control', 'Gift certificate liability control.');
INSERT INTO kernel.posting_role (code, name, description) VALUES ('security_deposit_control', 'Security Deposit Control', 'Refundable deposit liability control.');
INSERT INTO kernel.posting_role (code, name, description) VALUES ('rent_revenue', 'Rent Revenue', 'Rental income.');
INSERT INTO kernel.posting_role (code, name, description) VALUES ('cam_revenue', 'CAM Revenue', 'Common-area-maintenance income.');
INSERT INTO kernel.posting_role (code, name, description) VALUES ('percentage_rent_revenue', 'Percentage Rent Revenue', 'Percentage rent income.');
INSERT INTO kernel.posting_role (code, name, description) VALUES ('other_income', 'Other Income', 'Miscellaneous income.');
INSERT INTO kernel.posting_role (code, name, description) VALUES ('bad_debt_expense', 'Bad Debt Expense', 'Write-off of uncollectible receivables.');
INSERT INTO kernel.posting_role (code, name, description) VALUES ('sales_revenue', 'Sales Revenue', 'Merchandise sales revenue.');
INSERT INTO kernel.posting_role (code, name, description) VALUES ('cogs', 'Cost of Goods Sold', 'Cost of goods sold.');
INSERT INTO kernel.posting_role (code, name, description) VALUES ('inventory', 'Inventory', 'Inventory asset.');
INSERT INTO kernel.posting_role (code, name, description) VALUES ('owner_equity', 'Owner Equity', 'Owner equity / draw.');
INSERT INTO kernel.posting_role (code, name, description) VALUES ('consignor_payable_control', 'Consignor Payable Control', 'Net proceeds owed to consignors (control).');
INSERT INTO kernel.posting_role (code, name, description) VALUES ('commission_revenue', 'Commission Revenue', 'Commission earned on consignment sales.');
INSERT INTO kernel.posting_role (code, name, description) VALUES ('consignment_cogs', 'Consignment COGS', 'Cost of consigned goods sold (amount due to consignor).');


--
-- Data for Name: rent_component_type; Type: TABLE DATA; Schema: kernel; Owner: -
--

INSERT INTO kernel.rent_component_type (code, name, is_variable, description) VALUES ('base_rent', 'Base Rent', false, 'Fixed periodic rent.');
INSERT INTO kernel.rent_component_type (code, name, is_variable, description) VALUES ('cam', 'CAM', false, 'Common area maintenance.');
INSERT INTO kernel.rent_component_type (code, name, is_variable, description) VALUES ('percentage_rent', 'Percentage Rent', true, 'Rent as a % of sales over a breakpoint.');
INSERT INTO kernel.rent_component_type (code, name, is_variable, description) VALUES ('utilities', 'Utilities', false, 'Utility pass-through.');
INSERT INTO kernel.rent_component_type (code, name, is_variable, description) VALUES ('marketing', 'Marketing Fee', false, 'Marketing/promotion fee.');
INSERT INTO kernel.rent_component_type (code, name, is_variable, description) VALUES ('insurance', 'Insurance', false, 'Insurance pass-through.');
INSERT INTO kernel.rent_component_type (code, name, is_variable, description) VALUES ('fixed_fee', 'Fixed Fee', false, 'Any other fixed periodic fee.');


--
-- Data for Name: space_type; Type: TABLE DATA; Schema: kernel; Owner: -
--

INSERT INTO kernel.space_type (code, name, description) VALUES ('kiosk', 'Kiosk', 'Small freestanding unit.');
INSERT INTO kernel.space_type (code, name, description) VALUES ('booth', 'Booth', 'Open booth in a hall.');
INSERT INTO kernel.space_type (code, name, description) VALUES ('inline', 'Inline', 'Standard inline storefront.');
INSERT INTO kernel.space_type (code, name, description) VALUES ('endcap', 'End Cap', 'End-of-aisle display.');
INSERT INTO kernel.space_type (code, name, description) VALUES ('cart', 'Cart', 'Mobile cart.');
INSERT INTO kernel.space_type (code, name, description) VALUES ('office', 'Office', 'Back-office / service space.');
INSERT INTO kernel.space_type (code, name, description) VALUES ('storage', 'Storage', 'Storage unit.');
INSERT INTO kernel.space_type (code, name, description) VALUES ('popup', 'Pop-up', 'Short-term pop-up space.');


--
-- Data for Name: subledger_type; Type: TABLE DATA; Schema: kernel; Owner: -
--

INSERT INTO kernel.subledger_type (code, name, description) VALUES ('ar', 'Accounts Receivable', 'Money owed TO the store by customers.');
INSERT INTO kernel.subledger_type (code, name, description) VALUES ('ap', 'Accounts Payable', 'Money the store owes suppliers.');
INSERT INTO kernel.subledger_type (code, name, description) VALUES ('vendor_payable', 'Vendor Payable', 'Net settlement owed to vendors/consignors.');
INSERT INTO kernel.subledger_type (code, name, description) VALUES ('customer_credit', 'Customer Store Credit', 'Refund liability owed to a customer.');
INSERT INTO kernel.subledger_type (code, name, description) VALUES ('gift_certificate', 'Gift Certificate', 'Outstanding gift certificate liability.');
INSERT INTO kernel.subledger_type (code, name, description) VALUES ('security_deposit', 'Security Deposit', 'Refundable deposit held for a lessee.');
INSERT INTO kernel.subledger_type (code, name, description) VALUES ('consignor_payable', 'Consignor Payable', 'Net proceeds owed to a consignor after commission.');


--
-- Data for Name: account; Type: TABLE DATA; Schema: tenant_demo; Owner: -
--

INSERT INTO tenant_demo.account (id, tenant_id, code, name, account_type_code, parent_id, is_control, control_subledger_type_code, currency, is_active, created_at, created_by, updated_at, updated_by, version, deleted_at, deleted_by) VALUES ('01a0c0f3-4566-7542-aff3-be7dde1661ed', '11111111-1111-7111-8111-111111111111', '1000', 'Cash on Hand', 'asset', NULL, false, NULL, NULL, true, '2026-09-20 22:32:43.621482+00', NULL, '2026-09-20 22:32:43.621482+00', NULL, 1, NULL, NULL);
INSERT INTO tenant_demo.account (id, tenant_id, code, name, account_type_code, parent_id, is_control, control_subledger_type_code, currency, is_active, created_at, created_by, updated_at, updated_by, version, deleted_at, deleted_by) VALUES ('01a0c0f3-4566-7acf-bafe-18a3bd355d37', '11111111-1111-7111-8111-111111111111', '1010', 'Bank', 'asset', NULL, false, NULL, NULL, true, '2026-09-20 22:32:43.621482+00', NULL, '2026-09-20 22:32:43.621482+00', NULL, 1, NULL, NULL);
INSERT INTO tenant_demo.account (id, tenant_id, code, name, account_type_code, parent_id, is_control, control_subledger_type_code, currency, is_active, created_at, created_by, updated_at, updated_by, version, deleted_at, deleted_by) VALUES ('01a0c0f3-4566-7b28-8a05-ddbdf7828464', '11111111-1111-7111-8111-111111111111', '1100', 'Accounts Receivable', 'asset', NULL, true, 'ar', NULL, true, '2026-09-20 22:32:43.621482+00', NULL, '2026-09-20 22:32:43.621482+00', NULL, 1, NULL, NULL);
INSERT INTO tenant_demo.account (id, tenant_id, code, name, account_type_code, parent_id, is_control, control_subledger_type_code, currency, is_active, created_at, created_by, updated_at, updated_by, version, deleted_at, deleted_by) VALUES ('01a0c0f3-4566-7b57-ae3d-e6a9f13ca896', '11111111-1111-7111-8111-111111111111', '1200', 'Inventory', 'asset', NULL, false, NULL, NULL, true, '2026-09-20 22:32:43.621482+00', NULL, '2026-09-20 22:32:43.621482+00', NULL, 1, NULL, NULL);
INSERT INTO tenant_demo.account (id, tenant_id, code, name, account_type_code, parent_id, is_control, control_subledger_type_code, currency, is_active, created_at, created_by, updated_at, updated_by, version, deleted_at, deleted_by) VALUES ('01a0c0f3-4566-7b86-8460-1536f37aaec6', '11111111-1111-7111-8111-111111111111', '1300', 'Prepaid Expenses', 'asset', NULL, false, NULL, NULL, true, '2026-09-20 22:32:43.621482+00', NULL, '2026-09-20 22:32:43.621482+00', NULL, 1, NULL, NULL);
INSERT INTO tenant_demo.account (id, tenant_id, code, name, account_type_code, parent_id, is_control, control_subledger_type_code, currency, is_active, created_at, created_by, updated_at, updated_by, version, deleted_at, deleted_by) VALUES ('01a0c0f3-4566-7ba7-ae08-b53147b0fc43', '11111111-1111-7111-8111-111111111111', '1500', 'Leasehold Improvements', 'asset', NULL, false, NULL, NULL, true, '2026-09-20 22:32:43.621482+00', NULL, '2026-09-20 22:32:43.621482+00', NULL, 1, NULL, NULL);
INSERT INTO tenant_demo.account (id, tenant_id, code, name, account_type_code, parent_id, is_control, control_subledger_type_code, currency, is_active, created_at, created_by, updated_at, updated_by, version, deleted_at, deleted_by) VALUES ('01a0c0f3-4566-7bc0-94a8-4551823f36ef', '11111111-1111-7111-8111-111111111111', '2000', 'Accounts Payable', 'liability', NULL, true, 'ap', NULL, true, '2026-09-20 22:32:43.621482+00', NULL, '2026-09-20 22:32:43.621482+00', NULL, 1, NULL, NULL);
INSERT INTO tenant_demo.account (id, tenant_id, code, name, account_type_code, parent_id, is_control, control_subledger_type_code, currency, is_active, created_at, created_by, updated_at, updated_by, version, deleted_at, deleted_by) VALUES ('01a0c0f3-4566-7bdb-908e-d423fb29783b', '11111111-1111-7111-8111-111111111111', '2100', 'Vendor Payable', 'liability', NULL, true, 'vendor_payable', NULL, true, '2026-09-20 22:32:43.621482+00', NULL, '2026-09-20 22:32:43.621482+00', NULL, 1, NULL, NULL);
INSERT INTO tenant_demo.account (id, tenant_id, code, name, account_type_code, parent_id, is_control, control_subledger_type_code, currency, is_active, created_at, created_by, updated_at, updated_by, version, deleted_at, deleted_by) VALUES ('01a0c0f3-4566-7c0b-9142-7a81c9520c3b', '11111111-1111-7111-8111-111111111111', '2200', 'Customer Store Credit', 'liability', NULL, true, 'customer_credit', NULL, true, '2026-09-20 22:32:43.621482+00', NULL, '2026-09-20 22:32:43.621482+00', NULL, 1, NULL, NULL);
INSERT INTO tenant_demo.account (id, tenant_id, code, name, account_type_code, parent_id, is_control, control_subledger_type_code, currency, is_active, created_at, created_by, updated_at, updated_by, version, deleted_at, deleted_by) VALUES ('01a0c0f3-4566-7c29-bacf-ff14d2f602e2', '11111111-1111-7111-8111-111111111111', '2300', 'Gift Certificates', 'liability', NULL, true, 'gift_certificate', NULL, true, '2026-09-20 22:32:43.621482+00', NULL, '2026-09-20 22:32:43.621482+00', NULL, 1, NULL, NULL);
INSERT INTO tenant_demo.account (id, tenant_id, code, name, account_type_code, parent_id, is_control, control_subledger_type_code, currency, is_active, created_at, created_by, updated_at, updated_by, version, deleted_at, deleted_by) VALUES ('01a0c0f3-4566-7c43-9fbd-e6b03a615952', '11111111-1111-7111-8111-111111111111', '2400', 'Security Deposits Held', 'liability', NULL, true, 'security_deposit', NULL, true, '2026-09-20 22:32:43.621482+00', NULL, '2026-09-20 22:32:43.621482+00', NULL, 1, NULL, NULL);
INSERT INTO tenant_demo.account (id, tenant_id, code, name, account_type_code, parent_id, is_control, control_subledger_type_code, currency, is_active, created_at, created_by, updated_at, updated_by, version, deleted_at, deleted_by) VALUES ('01a0c0f3-4566-7c61-bc56-d6362a12ec0b', '11111111-1111-7111-8111-111111111111', '2500', 'Sales Tax Payable', 'liability', NULL, false, NULL, NULL, true, '2026-09-20 22:32:43.621482+00', NULL, '2026-09-20 22:32:43.621482+00', NULL, 1, NULL, NULL);
INSERT INTO tenant_demo.account (id, tenant_id, code, name, account_type_code, parent_id, is_control, control_subledger_type_code, currency, is_active, created_at, created_by, updated_at, updated_by, version, deleted_at, deleted_by) VALUES ('01a0c0f3-4566-7c7c-bd96-92c0b4d6800c', '11111111-1111-7111-8111-111111111111', '3000', 'Owner Equity', 'equity', NULL, false, NULL, NULL, true, '2026-09-20 22:32:43.621482+00', NULL, '2026-09-20 22:32:43.621482+00', NULL, 1, NULL, NULL);
INSERT INTO tenant_demo.account (id, tenant_id, code, name, account_type_code, parent_id, is_control, control_subledger_type_code, currency, is_active, created_at, created_by, updated_at, updated_by, version, deleted_at, deleted_by) VALUES ('01a0c0f3-4566-7cb2-843b-efe614ca307e', '11111111-1111-7111-8111-111111111111', '3100', 'Owner Draw', 'equity', NULL, false, NULL, NULL, true, '2026-09-20 22:32:43.621482+00', NULL, '2026-09-20 22:32:43.621482+00', NULL, 1, NULL, NULL);
INSERT INTO tenant_demo.account (id, tenant_id, code, name, account_type_code, parent_id, is_control, control_subledger_type_code, currency, is_active, created_at, created_by, updated_at, updated_by, version, deleted_at, deleted_by) VALUES ('01a0c0f3-4566-7cd3-9e8e-e3ea52f226f1', '11111111-1111-7111-8111-111111111111', '4000', 'Sales Revenue', 'revenue', NULL, false, NULL, NULL, true, '2026-09-20 22:32:43.621482+00', NULL, '2026-09-20 22:32:43.621482+00', NULL, 1, NULL, NULL);
INSERT INTO tenant_demo.account (id, tenant_id, code, name, account_type_code, parent_id, is_control, control_subledger_type_code, currency, is_active, created_at, created_by, updated_at, updated_by, version, deleted_at, deleted_by) VALUES ('01a0c0f3-4566-7cf0-89a0-014e57b9ef8c', '11111111-1111-7111-8111-111111111111', '4100', 'Rent Revenue', 'revenue', NULL, false, NULL, NULL, true, '2026-09-20 22:32:43.621482+00', NULL, '2026-09-20 22:32:43.621482+00', NULL, 1, NULL, NULL);
INSERT INTO tenant_demo.account (id, tenant_id, code, name, account_type_code, parent_id, is_control, control_subledger_type_code, currency, is_active, created_at, created_by, updated_at, updated_by, version, deleted_at, deleted_by) VALUES ('01a0c0f3-4566-7d0f-a646-3d98290e5061', '11111111-1111-7111-8111-111111111111', '4110', 'CAM Revenue', 'revenue', NULL, false, NULL, NULL, true, '2026-09-20 22:32:43.621482+00', NULL, '2026-09-20 22:32:43.621482+00', NULL, 1, NULL, NULL);
INSERT INTO tenant_demo.account (id, tenant_id, code, name, account_type_code, parent_id, is_control, control_subledger_type_code, currency, is_active, created_at, created_by, updated_at, updated_by, version, deleted_at, deleted_by) VALUES ('01a0c0f3-4566-7d35-981c-addd13e27090', '11111111-1111-7111-8111-111111111111', '4120', 'Percentage Rent Revenue', 'revenue', NULL, false, NULL, NULL, true, '2026-09-20 22:32:43.621482+00', NULL, '2026-09-20 22:32:43.621482+00', NULL, 1, NULL, NULL);
INSERT INTO tenant_demo.account (id, tenant_id, code, name, account_type_code, parent_id, is_control, control_subledger_type_code, currency, is_active, created_at, created_by, updated_at, updated_by, version, deleted_at, deleted_by) VALUES ('01a0c0f3-4566-7d4f-a1c4-e1cf486c2a16', '11111111-1111-7111-8111-111111111111', '4900', 'Other Income', 'revenue', NULL, false, NULL, NULL, true, '2026-09-20 22:32:43.621482+00', NULL, '2026-09-20 22:32:43.621482+00', NULL, 1, NULL, NULL);
INSERT INTO tenant_demo.account (id, tenant_id, code, name, account_type_code, parent_id, is_control, control_subledger_type_code, currency, is_active, created_at, created_by, updated_at, updated_by, version, deleted_at, deleted_by) VALUES ('01a0c0f3-4566-7d68-b7f7-4bbf1a190e86', '11111111-1111-7111-8111-111111111111', '5000', 'Cost of Goods Sold', 'expense', NULL, false, NULL, NULL, true, '2026-09-20 22:32:43.621482+00', NULL, '2026-09-20 22:32:43.621482+00', NULL, 1, NULL, NULL);
INSERT INTO tenant_demo.account (id, tenant_id, code, name, account_type_code, parent_id, is_control, control_subledger_type_code, currency, is_active, created_at, created_by, updated_at, updated_by, version, deleted_at, deleted_by) VALUES ('01a0c0f3-4566-7d86-9ede-2e2d665c5122', '11111111-1111-7111-8111-111111111111', '6000', 'Bad Debt Expense', 'expense', NULL, false, NULL, NULL, true, '2026-09-20 22:32:43.621482+00', NULL, '2026-09-20 22:32:43.621482+00', NULL, 1, NULL, NULL);
INSERT INTO tenant_demo.account (id, tenant_id, code, name, account_type_code, parent_id, is_control, control_subledger_type_code, currency, is_active, created_at, created_by, updated_at, updated_by, version, deleted_at, deleted_by) VALUES ('01a0c0f3-4566-7da1-a410-6857a1c58103', '11111111-1111-7111-8111-111111111111', '6100', 'Rent Expense', 'expense', NULL, false, NULL, NULL, true, '2026-09-20 22:32:43.621482+00', NULL, '2026-09-20 22:32:43.621482+00', NULL, 1, NULL, NULL);
INSERT INTO tenant_demo.account (id, tenant_id, code, name, account_type_code, parent_id, is_control, control_subledger_type_code, currency, is_active, created_at, created_by, updated_at, updated_by, version, deleted_at, deleted_by) VALUES ('01a0c0f3-4566-7dc0-950d-a14ba76163a5', '11111111-1111-7111-8111-111111111111', '6200', 'Utilities Expense', 'expense', NULL, false, NULL, NULL, true, '2026-09-20 22:32:43.621482+00', NULL, '2026-09-20 22:32:43.621482+00', NULL, 1, NULL, NULL);
INSERT INTO tenant_demo.account (id, tenant_id, code, name, account_type_code, parent_id, is_control, control_subledger_type_code, currency, is_active, created_at, created_by, updated_at, updated_by, version, deleted_at, deleted_by) VALUES ('01a0c0f3-4566-7ded-8274-92af1e21bfc9', '11111111-1111-7111-8111-111111111111', '6300', 'Marketing Expense', 'expense', NULL, false, NULL, NULL, true, '2026-09-20 22:32:43.621482+00', NULL, '2026-09-20 22:32:43.621482+00', NULL, 1, NULL, NULL);
INSERT INTO tenant_demo.account (id, tenant_id, code, name, account_type_code, parent_id, is_control, control_subledger_type_code, currency, is_active, created_at, created_by, updated_at, updated_by, version, deleted_at, deleted_by) VALUES ('01a0c0f3-4566-7e0b-9716-3a385542fb84', '11111111-1111-7111-8111-111111111111', '6400', 'Insurance Expense', 'expense', NULL, false, NULL, NULL, true, '2026-09-20 22:32:43.621482+00', NULL, '2026-09-20 22:32:43.621482+00', NULL, 1, NULL, NULL);
INSERT INTO tenant_demo.account (id, tenant_id, code, name, account_type_code, parent_id, is_control, control_subledger_type_code, currency, is_active, created_at, created_by, updated_at, updated_by, version, deleted_at, deleted_by) VALUES ('01a0c0f3-4566-7e24-81d3-a429fda00dad', '11111111-1111-7111-8111-111111111111', '6900', 'General & Administrative', 'expense', NULL, false, NULL, NULL, true, '2026-09-20 22:32:43.621482+00', NULL, '2026-09-20 22:32:43.621482+00', NULL, 1, NULL, NULL);
INSERT INTO tenant_demo.account (id, tenant_id, code, name, account_type_code, parent_id, is_control, control_subledger_type_code, currency, is_active, created_at, created_by, updated_at, updated_by, version, deleted_at, deleted_by) VALUES ('01a0c0f3-458f-7af2-ab08-4566aab15eb1', '11111111-1111-7111-8111-111111111111', '2110', 'Consignor Payable', 'liability', NULL, true, 'consignor_payable', NULL, true, '2026-09-20 22:32:43.66283+00', NULL, '2026-09-20 22:32:43.66283+00', NULL, 1, NULL, NULL);
INSERT INTO tenant_demo.account (id, tenant_id, code, name, account_type_code, parent_id, is_control, control_subledger_type_code, currency, is_active, created_at, created_by, updated_at, updated_by, version, deleted_at, deleted_by) VALUES ('01a0c0f3-458f-7da6-a5e1-25c90623329c', '11111111-1111-7111-8111-111111111111', '4200', 'Commission Revenue', 'revenue', NULL, false, NULL, NULL, true, '2026-09-20 22:32:43.66283+00', NULL, '2026-09-20 22:32:43.66283+00', NULL, 1, NULL, NULL);
INSERT INTO tenant_demo.account (id, tenant_id, code, name, account_type_code, parent_id, is_control, control_subledger_type_code, currency, is_active, created_at, created_by, updated_at, updated_by, version, deleted_at, deleted_by) VALUES ('01a0c0f3-458f-7df0-ae3b-b1a5ea0aff8f', '11111111-1111-7111-8111-111111111111', '5100', 'Consignment COGS', 'expense', NULL, false, NULL, NULL, true, '2026-09-20 22:32:43.66283+00', NULL, '2026-09-20 22:32:43.66283+00', NULL, 1, NULL, NULL);


--
-- Data for Name: audit_log; Type: TABLE DATA; Schema: tenant_demo; Owner: -
--

INSERT INTO tenant_demo.audit_log (id, tenant_id, table_schema, table_name, row_id, op, actor_id, before_data, after_data, occurred_at) OVERRIDING SYSTEM VALUE VALUES (1, '11111111-1111-7111-8111-111111111111', 'tenant_demo', 'tenant_config', NULL, 'INSERT', NULL, NULL, '{"version": 1, "timezone": "UTC", "tenant_id": "11111111-1111-7111-8111-111111111111", "created_at": "2026-09-20T22:32:43.584799+00:00", "created_by": null, "legal_name": "Demo Mall LLC", "updated_at": "2026-09-20T22:32:43.584799+00:00", "updated_by": null, "functional_currency": "USD", "fiscal_year_start_month": 1}', '2026-09-20 22:32:43.584799+00');
INSERT INTO tenant_demo.audit_log (id, tenant_id, table_schema, table_name, row_id, op, actor_id, before_data, after_data, occurred_at) OVERRIDING SYSTEM VALUE VALUES (2, '11111111-1111-7111-8111-111111111111', 'tenant_demo', 'account', '01a0c0f3-4566-7542-aff3-be7dde1661ed', 'INSERT', NULL, NULL, '{"id": "01a0c0f3-4566-7542-aff3-be7dde1661ed", "code": "1000", "name": "Cash on Hand", "version": 1, "currency": null, "is_active": true, "parent_id": null, "tenant_id": "11111111-1111-7111-8111-111111111111", "created_at": "2026-09-20T22:32:43.621482+00:00", "created_by": null, "deleted_at": null, "deleted_by": null, "is_control": false, "updated_at": "2026-09-20T22:32:43.621482+00:00", "updated_by": null, "account_type_code": "asset", "control_subledger_type_code": null}', '2026-09-20 22:32:43.621482+00');
INSERT INTO tenant_demo.audit_log (id, tenant_id, table_schema, table_name, row_id, op, actor_id, before_data, after_data, occurred_at) OVERRIDING SYSTEM VALUE VALUES (3, '11111111-1111-7111-8111-111111111111', 'tenant_demo', 'account', '01a0c0f3-4566-7acf-bafe-18a3bd355d37', 'INSERT', NULL, NULL, '{"id": "01a0c0f3-4566-7acf-bafe-18a3bd355d37", "code": "1010", "name": "Bank", "version": 1, "currency": null, "is_active": true, "parent_id": null, "tenant_id": "11111111-1111-7111-8111-111111111111", "created_at": "2026-09-20T22:32:43.621482+00:00", "created_by": null, "deleted_at": null, "deleted_by": null, "is_control": false, "updated_at": "2026-09-20T22:32:43.621482+00:00", "updated_by": null, "account_type_code": "asset", "control_subledger_type_code": null}', '2026-09-20 22:32:43.621482+00');
INSERT INTO tenant_demo.audit_log (id, tenant_id, table_schema, table_name, row_id, op, actor_id, before_data, after_data, occurred_at) OVERRIDING SYSTEM VALUE VALUES (4, '11111111-1111-7111-8111-111111111111', 'tenant_demo', 'account', '01a0c0f3-4566-7b28-8a05-ddbdf7828464', 'INSERT', NULL, NULL, '{"id": "01a0c0f3-4566-7b28-8a05-ddbdf7828464", "code": "1100", "name": "Accounts Receivable", "version": 1, "currency": null, "is_active": true, "parent_id": null, "tenant_id": "11111111-1111-7111-8111-111111111111", "created_at": "2026-09-20T22:32:43.621482+00:00", "created_by": null, "deleted_at": null, "deleted_by": null, "is_control": true, "updated_at": "2026-09-20T22:32:43.621482+00:00", "updated_by": null, "account_type_code": "asset", "control_subledger_type_code": "ar"}', '2026-09-20 22:32:43.621482+00');
INSERT INTO tenant_demo.audit_log (id, tenant_id, table_schema, table_name, row_id, op, actor_id, before_data, after_data, occurred_at) OVERRIDING SYSTEM VALUE VALUES (5, '11111111-1111-7111-8111-111111111111', 'tenant_demo', 'account', '01a0c0f3-4566-7b57-ae3d-e6a9f13ca896', 'INSERT', NULL, NULL, '{"id": "01a0c0f3-4566-7b57-ae3d-e6a9f13ca896", "code": "1200", "name": "Inventory", "version": 1, "currency": null, "is_active": true, "parent_id": null, "tenant_id": "11111111-1111-7111-8111-111111111111", "created_at": "2026-09-20T22:32:43.621482+00:00", "created_by": null, "deleted_at": null, "deleted_by": null, "is_control": false, "updated_at": "2026-09-20T22:32:43.621482+00:00", "updated_by": null, "account_type_code": "asset", "control_subledger_type_code": null}', '2026-09-20 22:32:43.621482+00');
INSERT INTO tenant_demo.audit_log (id, tenant_id, table_schema, table_name, row_id, op, actor_id, before_data, after_data, occurred_at) OVERRIDING SYSTEM VALUE VALUES (6, '11111111-1111-7111-8111-111111111111', 'tenant_demo', 'account', '01a0c0f3-4566-7b86-8460-1536f37aaec6', 'INSERT', NULL, NULL, '{"id": "01a0c0f3-4566-7b86-8460-1536f37aaec6", "code": "1300", "name": "Prepaid Expenses", "version": 1, "currency": null, "is_active": true, "parent_id": null, "tenant_id": "11111111-1111-7111-8111-111111111111", "created_at": "2026-09-20T22:32:43.621482+00:00", "created_by": null, "deleted_at": null, "deleted_by": null, "is_control": false, "updated_at": "2026-09-20T22:32:43.621482+00:00", "updated_by": null, "account_type_code": "asset", "control_subledger_type_code": null}', '2026-09-20 22:32:43.621482+00');
INSERT INTO tenant_demo.audit_log (id, tenant_id, table_schema, table_name, row_id, op, actor_id, before_data, after_data, occurred_at) OVERRIDING SYSTEM VALUE VALUES (7, '11111111-1111-7111-8111-111111111111', 'tenant_demo', 'account', '01a0c0f3-4566-7ba7-ae08-b53147b0fc43', 'INSERT', NULL, NULL, '{"id": "01a0c0f3-4566-7ba7-ae08-b53147b0fc43", "code": "1500", "name": "Leasehold Improvements", "version": 1, "currency": null, "is_active": true, "parent_id": null, "tenant_id": "11111111-1111-7111-8111-111111111111", "created_at": "2026-09-20T22:32:43.621482+00:00", "created_by": null, "deleted_at": null, "deleted_by": null, "is_control": false, "updated_at": "2026-09-20T22:32:43.621482+00:00", "updated_by": null, "account_type_code": "asset", "control_subledger_type_code": null}', '2026-09-20 22:32:43.621482+00');
INSERT INTO tenant_demo.audit_log (id, tenant_id, table_schema, table_name, row_id, op, actor_id, before_data, after_data, occurred_at) OVERRIDING SYSTEM VALUE VALUES (8, '11111111-1111-7111-8111-111111111111', 'tenant_demo', 'account', '01a0c0f3-4566-7bc0-94a8-4551823f36ef', 'INSERT', NULL, NULL, '{"id": "01a0c0f3-4566-7bc0-94a8-4551823f36ef", "code": "2000", "name": "Accounts Payable", "version": 1, "currency": null, "is_active": true, "parent_id": null, "tenant_id": "11111111-1111-7111-8111-111111111111", "created_at": "2026-09-20T22:32:43.621482+00:00", "created_by": null, "deleted_at": null, "deleted_by": null, "is_control": true, "updated_at": "2026-09-20T22:32:43.621482+00:00", "updated_by": null, "account_type_code": "liability", "control_subledger_type_code": "ap"}', '2026-09-20 22:32:43.621482+00');
INSERT INTO tenant_demo.audit_log (id, tenant_id, table_schema, table_name, row_id, op, actor_id, before_data, after_data, occurred_at) OVERRIDING SYSTEM VALUE VALUES (9, '11111111-1111-7111-8111-111111111111', 'tenant_demo', 'account', '01a0c0f3-4566-7bdb-908e-d423fb29783b', 'INSERT', NULL, NULL, '{"id": "01a0c0f3-4566-7bdb-908e-d423fb29783b", "code": "2100", "name": "Vendor Payable", "version": 1, "currency": null, "is_active": true, "parent_id": null, "tenant_id": "11111111-1111-7111-8111-111111111111", "created_at": "2026-09-20T22:32:43.621482+00:00", "created_by": null, "deleted_at": null, "deleted_by": null, "is_control": true, "updated_at": "2026-09-20T22:32:43.621482+00:00", "updated_by": null, "account_type_code": "liability", "control_subledger_type_code": "vendor_payable"}', '2026-09-20 22:32:43.621482+00');
INSERT INTO tenant_demo.audit_log (id, tenant_id, table_schema, table_name, row_id, op, actor_id, before_data, after_data, occurred_at) OVERRIDING SYSTEM VALUE VALUES (10, '11111111-1111-7111-8111-111111111111', 'tenant_demo', 'account', '01a0c0f3-4566-7c0b-9142-7a81c9520c3b', 'INSERT', NULL, NULL, '{"id": "01a0c0f3-4566-7c0b-9142-7a81c9520c3b", "code": "2200", "name": "Customer Store Credit", "version": 1, "currency": null, "is_active": true, "parent_id": null, "tenant_id": "11111111-1111-7111-8111-111111111111", "created_at": "2026-09-20T22:32:43.621482+00:00", "created_by": null, "deleted_at": null, "deleted_by": null, "is_control": true, "updated_at": "2026-09-20T22:32:43.621482+00:00", "updated_by": null, "account_type_code": "liability", "control_subledger_type_code": "customer_credit"}', '2026-09-20 22:32:43.621482+00');
INSERT INTO tenant_demo.audit_log (id, tenant_id, table_schema, table_name, row_id, op, actor_id, before_data, after_data, occurred_at) OVERRIDING SYSTEM VALUE VALUES (11, '11111111-1111-7111-8111-111111111111', 'tenant_demo', 'account', '01a0c0f3-4566-7c29-bacf-ff14d2f602e2', 'INSERT', NULL, NULL, '{"id": "01a0c0f3-4566-7c29-bacf-ff14d2f602e2", "code": "2300", "name": "Gift Certificates", "version": 1, "currency": null, "is_active": true, "parent_id": null, "tenant_id": "11111111-1111-7111-8111-111111111111", "created_at": "2026-09-20T22:32:43.621482+00:00", "created_by": null, "deleted_at": null, "deleted_by": null, "is_control": true, "updated_at": "2026-09-20T22:32:43.621482+00:00", "updated_by": null, "account_type_code": "liability", "control_subledger_type_code": "gift_certificate"}', '2026-09-20 22:32:43.621482+00');
INSERT INTO tenant_demo.audit_log (id, tenant_id, table_schema, table_name, row_id, op, actor_id, before_data, after_data, occurred_at) OVERRIDING SYSTEM VALUE VALUES (12, '11111111-1111-7111-8111-111111111111', 'tenant_demo', 'account', '01a0c0f3-4566-7c43-9fbd-e6b03a615952', 'INSERT', NULL, NULL, '{"id": "01a0c0f3-4566-7c43-9fbd-e6b03a615952", "code": "2400", "name": "Security Deposits Held", "version": 1, "currency": null, "is_active": true, "parent_id": null, "tenant_id": "11111111-1111-7111-8111-111111111111", "created_at": "2026-09-20T22:32:43.621482+00:00", "created_by": null, "deleted_at": null, "deleted_by": null, "is_control": true, "updated_at": "2026-09-20T22:32:43.621482+00:00", "updated_by": null, "account_type_code": "liability", "control_subledger_type_code": "security_deposit"}', '2026-09-20 22:32:43.621482+00');
INSERT INTO tenant_demo.audit_log (id, tenant_id, table_schema, table_name, row_id, op, actor_id, before_data, after_data, occurred_at) OVERRIDING SYSTEM VALUE VALUES (13, '11111111-1111-7111-8111-111111111111', 'tenant_demo', 'account', '01a0c0f3-4566-7c61-bc56-d6362a12ec0b', 'INSERT', NULL, NULL, '{"id": "01a0c0f3-4566-7c61-bc56-d6362a12ec0b", "code": "2500", "name": "Sales Tax Payable", "version": 1, "currency": null, "is_active": true, "parent_id": null, "tenant_id": "11111111-1111-7111-8111-111111111111", "created_at": "2026-09-20T22:32:43.621482+00:00", "created_by": null, "deleted_at": null, "deleted_by": null, "is_control": false, "updated_at": "2026-09-20T22:32:43.621482+00:00", "updated_by": null, "account_type_code": "liability", "control_subledger_type_code": null}', '2026-09-20 22:32:43.621482+00');
INSERT INTO tenant_demo.audit_log (id, tenant_id, table_schema, table_name, row_id, op, actor_id, before_data, after_data, occurred_at) OVERRIDING SYSTEM VALUE VALUES (14, '11111111-1111-7111-8111-111111111111', 'tenant_demo', 'account', '01a0c0f3-4566-7c7c-bd96-92c0b4d6800c', 'INSERT', NULL, NULL, '{"id": "01a0c0f3-4566-7c7c-bd96-92c0b4d6800c", "code": "3000", "name": "Owner Equity", "version": 1, "currency": null, "is_active": true, "parent_id": null, "tenant_id": "11111111-1111-7111-8111-111111111111", "created_at": "2026-09-20T22:32:43.621482+00:00", "created_by": null, "deleted_at": null, "deleted_by": null, "is_control": false, "updated_at": "2026-09-20T22:32:43.621482+00:00", "updated_by": null, "account_type_code": "equity", "control_subledger_type_code": null}', '2026-09-20 22:32:43.621482+00');
INSERT INTO tenant_demo.audit_log (id, tenant_id, table_schema, table_name, row_id, op, actor_id, before_data, after_data, occurred_at) OVERRIDING SYSTEM VALUE VALUES (15, '11111111-1111-7111-8111-111111111111', 'tenant_demo', 'account', '01a0c0f3-4566-7cb2-843b-efe614ca307e', 'INSERT', NULL, NULL, '{"id": "01a0c0f3-4566-7cb2-843b-efe614ca307e", "code": "3100", "name": "Owner Draw", "version": 1, "currency": null, "is_active": true, "parent_id": null, "tenant_id": "11111111-1111-7111-8111-111111111111", "created_at": "2026-09-20T22:32:43.621482+00:00", "created_by": null, "deleted_at": null, "deleted_by": null, "is_control": false, "updated_at": "2026-09-20T22:32:43.621482+00:00", "updated_by": null, "account_type_code": "equity", "control_subledger_type_code": null}', '2026-09-20 22:32:43.621482+00');
INSERT INTO tenant_demo.audit_log (id, tenant_id, table_schema, table_name, row_id, op, actor_id, before_data, after_data, occurred_at) OVERRIDING SYSTEM VALUE VALUES (16, '11111111-1111-7111-8111-111111111111', 'tenant_demo', 'account', '01a0c0f3-4566-7cd3-9e8e-e3ea52f226f1', 'INSERT', NULL, NULL, '{"id": "01a0c0f3-4566-7cd3-9e8e-e3ea52f226f1", "code": "4000", "name": "Sales Revenue", "version": 1, "currency": null, "is_active": true, "parent_id": null, "tenant_id": "11111111-1111-7111-8111-111111111111", "created_at": "2026-09-20T22:32:43.621482+00:00", "created_by": null, "deleted_at": null, "deleted_by": null, "is_control": false, "updated_at": "2026-09-20T22:32:43.621482+00:00", "updated_by": null, "account_type_code": "revenue", "control_subledger_type_code": null}', '2026-09-20 22:32:43.621482+00');
INSERT INTO tenant_demo.audit_log (id, tenant_id, table_schema, table_name, row_id, op, actor_id, before_data, after_data, occurred_at) OVERRIDING SYSTEM VALUE VALUES (17, '11111111-1111-7111-8111-111111111111', 'tenant_demo', 'account', '01a0c0f3-4566-7cf0-89a0-014e57b9ef8c', 'INSERT', NULL, NULL, '{"id": "01a0c0f3-4566-7cf0-89a0-014e57b9ef8c", "code": "4100", "name": "Rent Revenue", "version": 1, "currency": null, "is_active": true, "parent_id": null, "tenant_id": "11111111-1111-7111-8111-111111111111", "created_at": "2026-09-20T22:32:43.621482+00:00", "created_by": null, "deleted_at": null, "deleted_by": null, "is_control": false, "updated_at": "2026-09-20T22:32:43.621482+00:00", "updated_by": null, "account_type_code": "revenue", "control_subledger_type_code": null}', '2026-09-20 22:32:43.621482+00');
INSERT INTO tenant_demo.audit_log (id, tenant_id, table_schema, table_name, row_id, op, actor_id, before_data, after_data, occurred_at) OVERRIDING SYSTEM VALUE VALUES (18, '11111111-1111-7111-8111-111111111111', 'tenant_demo', 'account', '01a0c0f3-4566-7d0f-a646-3d98290e5061', 'INSERT', NULL, NULL, '{"id": "01a0c0f3-4566-7d0f-a646-3d98290e5061", "code": "4110", "name": "CAM Revenue", "version": 1, "currency": null, "is_active": true, "parent_id": null, "tenant_id": "11111111-1111-7111-8111-111111111111", "created_at": "2026-09-20T22:32:43.621482+00:00", "created_by": null, "deleted_at": null, "deleted_by": null, "is_control": false, "updated_at": "2026-09-20T22:32:43.621482+00:00", "updated_by": null, "account_type_code": "revenue", "control_subledger_type_code": null}', '2026-09-20 22:32:43.621482+00');
INSERT INTO tenant_demo.audit_log (id, tenant_id, table_schema, table_name, row_id, op, actor_id, before_data, after_data, occurred_at) OVERRIDING SYSTEM VALUE VALUES (19, '11111111-1111-7111-8111-111111111111', 'tenant_demo', 'account', '01a0c0f3-4566-7d35-981c-addd13e27090', 'INSERT', NULL, NULL, '{"id": "01a0c0f3-4566-7d35-981c-addd13e27090", "code": "4120", "name": "Percentage Rent Revenue", "version": 1, "currency": null, "is_active": true, "parent_id": null, "tenant_id": "11111111-1111-7111-8111-111111111111", "created_at": "2026-09-20T22:32:43.621482+00:00", "created_by": null, "deleted_at": null, "deleted_by": null, "is_control": false, "updated_at": "2026-09-20T22:32:43.621482+00:00", "updated_by": null, "account_type_code": "revenue", "control_subledger_type_code": null}', '2026-09-20 22:32:43.621482+00');
INSERT INTO tenant_demo.audit_log (id, tenant_id, table_schema, table_name, row_id, op, actor_id, before_data, after_data, occurred_at) OVERRIDING SYSTEM VALUE VALUES (20, '11111111-1111-7111-8111-111111111111', 'tenant_demo', 'account', '01a0c0f3-4566-7d4f-a1c4-e1cf486c2a16', 'INSERT', NULL, NULL, '{"id": "01a0c0f3-4566-7d4f-a1c4-e1cf486c2a16", "code": "4900", "name": "Other Income", "version": 1, "currency": null, "is_active": true, "parent_id": null, "tenant_id": "11111111-1111-7111-8111-111111111111", "created_at": "2026-09-20T22:32:43.621482+00:00", "created_by": null, "deleted_at": null, "deleted_by": null, "is_control": false, "updated_at": "2026-09-20T22:32:43.621482+00:00", "updated_by": null, "account_type_code": "revenue", "control_subledger_type_code": null}', '2026-09-20 22:32:43.621482+00');
INSERT INTO tenant_demo.audit_log (id, tenant_id, table_schema, table_name, row_id, op, actor_id, before_data, after_data, occurred_at) OVERRIDING SYSTEM VALUE VALUES (21, '11111111-1111-7111-8111-111111111111', 'tenant_demo', 'account', '01a0c0f3-4566-7d68-b7f7-4bbf1a190e86', 'INSERT', NULL, NULL, '{"id": "01a0c0f3-4566-7d68-b7f7-4bbf1a190e86", "code": "5000", "name": "Cost of Goods Sold", "version": 1, "currency": null, "is_active": true, "parent_id": null, "tenant_id": "11111111-1111-7111-8111-111111111111", "created_at": "2026-09-20T22:32:43.621482+00:00", "created_by": null, "deleted_at": null, "deleted_by": null, "is_control": false, "updated_at": "2026-09-20T22:32:43.621482+00:00", "updated_by": null, "account_type_code": "expense", "control_subledger_type_code": null}', '2026-09-20 22:32:43.621482+00');
INSERT INTO tenant_demo.audit_log (id, tenant_id, table_schema, table_name, row_id, op, actor_id, before_data, after_data, occurred_at) OVERRIDING SYSTEM VALUE VALUES (22, '11111111-1111-7111-8111-111111111111', 'tenant_demo', 'account', '01a0c0f3-4566-7d86-9ede-2e2d665c5122', 'INSERT', NULL, NULL, '{"id": "01a0c0f3-4566-7d86-9ede-2e2d665c5122", "code": "6000", "name": "Bad Debt Expense", "version": 1, "currency": null, "is_active": true, "parent_id": null, "tenant_id": "11111111-1111-7111-8111-111111111111", "created_at": "2026-09-20T22:32:43.621482+00:00", "created_by": null, "deleted_at": null, "deleted_by": null, "is_control": false, "updated_at": "2026-09-20T22:32:43.621482+00:00", "updated_by": null, "account_type_code": "expense", "control_subledger_type_code": null}', '2026-09-20 22:32:43.621482+00');
INSERT INTO tenant_demo.audit_log (id, tenant_id, table_schema, table_name, row_id, op, actor_id, before_data, after_data, occurred_at) OVERRIDING SYSTEM VALUE VALUES (23, '11111111-1111-7111-8111-111111111111', 'tenant_demo', 'account', '01a0c0f3-4566-7da1-a410-6857a1c58103', 'INSERT', NULL, NULL, '{"id": "01a0c0f3-4566-7da1-a410-6857a1c58103", "code": "6100", "name": "Rent Expense", "version": 1, "currency": null, "is_active": true, "parent_id": null, "tenant_id": "11111111-1111-7111-8111-111111111111", "created_at": "2026-09-20T22:32:43.621482+00:00", "created_by": null, "deleted_at": null, "deleted_by": null, "is_control": false, "updated_at": "2026-09-20T22:32:43.621482+00:00", "updated_by": null, "account_type_code": "expense", "control_subledger_type_code": null}', '2026-09-20 22:32:43.621482+00');
INSERT INTO tenant_demo.audit_log (id, tenant_id, table_schema, table_name, row_id, op, actor_id, before_data, after_data, occurred_at) OVERRIDING SYSTEM VALUE VALUES (24, '11111111-1111-7111-8111-111111111111', 'tenant_demo', 'account', '01a0c0f3-4566-7dc0-950d-a14ba76163a5', 'INSERT', NULL, NULL, '{"id": "01a0c0f3-4566-7dc0-950d-a14ba76163a5", "code": "6200", "name": "Utilities Expense", "version": 1, "currency": null, "is_active": true, "parent_id": null, "tenant_id": "11111111-1111-7111-8111-111111111111", "created_at": "2026-09-20T22:32:43.621482+00:00", "created_by": null, "deleted_at": null, "deleted_by": null, "is_control": false, "updated_at": "2026-09-20T22:32:43.621482+00:00", "updated_by": null, "account_type_code": "expense", "control_subledger_type_code": null}', '2026-09-20 22:32:43.621482+00');
INSERT INTO tenant_demo.audit_log (id, tenant_id, table_schema, table_name, row_id, op, actor_id, before_data, after_data, occurred_at) OVERRIDING SYSTEM VALUE VALUES (25, '11111111-1111-7111-8111-111111111111', 'tenant_demo', 'account', '01a0c0f3-4566-7ded-8274-92af1e21bfc9', 'INSERT', NULL, NULL, '{"id": "01a0c0f3-4566-7ded-8274-92af1e21bfc9", "code": "6300", "name": "Marketing Expense", "version": 1, "currency": null, "is_active": true, "parent_id": null, "tenant_id": "11111111-1111-7111-8111-111111111111", "created_at": "2026-09-20T22:32:43.621482+00:00", "created_by": null, "deleted_at": null, "deleted_by": null, "is_control": false, "updated_at": "2026-09-20T22:32:43.621482+00:00", "updated_by": null, "account_type_code": "expense", "control_subledger_type_code": null}', '2026-09-20 22:32:43.621482+00');
INSERT INTO tenant_demo.audit_log (id, tenant_id, table_schema, table_name, row_id, op, actor_id, before_data, after_data, occurred_at) OVERRIDING SYSTEM VALUE VALUES (26, '11111111-1111-7111-8111-111111111111', 'tenant_demo', 'account', '01a0c0f3-4566-7e0b-9716-3a385542fb84', 'INSERT', NULL, NULL, '{"id": "01a0c0f3-4566-7e0b-9716-3a385542fb84", "code": "6400", "name": "Insurance Expense", "version": 1, "currency": null, "is_active": true, "parent_id": null, "tenant_id": "11111111-1111-7111-8111-111111111111", "created_at": "2026-09-20T22:32:43.621482+00:00", "created_by": null, "deleted_at": null, "deleted_by": null, "is_control": false, "updated_at": "2026-09-20T22:32:43.621482+00:00", "updated_by": null, "account_type_code": "expense", "control_subledger_type_code": null}', '2026-09-20 22:32:43.621482+00');
INSERT INTO tenant_demo.audit_log (id, tenant_id, table_schema, table_name, row_id, op, actor_id, before_data, after_data, occurred_at) OVERRIDING SYSTEM VALUE VALUES (27, '11111111-1111-7111-8111-111111111111', 'tenant_demo', 'account', '01a0c0f3-4566-7e24-81d3-a429fda00dad', 'INSERT', NULL, NULL, '{"id": "01a0c0f3-4566-7e24-81d3-a429fda00dad", "code": "6900", "name": "General & Administrative", "version": 1, "currency": null, "is_active": true, "parent_id": null, "tenant_id": "11111111-1111-7111-8111-111111111111", "created_at": "2026-09-20T22:32:43.621482+00:00", "created_by": null, "deleted_at": null, "deleted_by": null, "is_control": false, "updated_at": "2026-09-20T22:32:43.621482+00:00", "updated_by": null, "account_type_code": "expense", "control_subledger_type_code": null}', '2026-09-20 22:32:43.621482+00');
INSERT INTO tenant_demo.audit_log (id, tenant_id, table_schema, table_name, row_id, op, actor_id, before_data, after_data, occurred_at) OVERRIDING SYSTEM VALUE VALUES (28, '11111111-1111-7111-8111-111111111111', 'tenant_demo', 'account', '01a0c0f3-458f-7af2-ab08-4566aab15eb1', 'INSERT', NULL, NULL, '{"id": "01a0c0f3-458f-7af2-ab08-4566aab15eb1", "code": "2110", "name": "Consignor Payable", "version": 1, "currency": null, "is_active": true, "parent_id": null, "tenant_id": "11111111-1111-7111-8111-111111111111", "created_at": "2026-09-20T22:32:43.66283+00:00", "created_by": null, "deleted_at": null, "deleted_by": null, "is_control": true, "updated_at": "2026-09-20T22:32:43.66283+00:00", "updated_by": null, "account_type_code": "liability", "control_subledger_type_code": "consignor_payable"}', '2026-09-20 22:32:43.66283+00');
INSERT INTO tenant_demo.audit_log (id, tenant_id, table_schema, table_name, row_id, op, actor_id, before_data, after_data, occurred_at) OVERRIDING SYSTEM VALUE VALUES (29, '11111111-1111-7111-8111-111111111111', 'tenant_demo', 'account', '01a0c0f3-458f-7da6-a5e1-25c90623329c', 'INSERT', NULL, NULL, '{"id": "01a0c0f3-458f-7da6-a5e1-25c90623329c", "code": "4200", "name": "Commission Revenue", "version": 1, "currency": null, "is_active": true, "parent_id": null, "tenant_id": "11111111-1111-7111-8111-111111111111", "created_at": "2026-09-20T22:32:43.66283+00:00", "created_by": null, "deleted_at": null, "deleted_by": null, "is_control": false, "updated_at": "2026-09-20T22:32:43.66283+00:00", "updated_by": null, "account_type_code": "revenue", "control_subledger_type_code": null}', '2026-09-20 22:32:43.66283+00');
INSERT INTO tenant_demo.audit_log (id, tenant_id, table_schema, table_name, row_id, op, actor_id, before_data, after_data, occurred_at) OVERRIDING SYSTEM VALUE VALUES (30, '11111111-1111-7111-8111-111111111111', 'tenant_demo', 'account', '01a0c0f3-458f-7df0-ae3b-b1a5ea0aff8f', 'INSERT', NULL, NULL, '{"id": "01a0c0f3-458f-7df0-ae3b-b1a5ea0aff8f", "code": "5100", "name": "Consignment COGS", "version": 1, "currency": null, "is_active": true, "parent_id": null, "tenant_id": "11111111-1111-7111-8111-111111111111", "created_at": "2026-09-20T22:32:43.66283+00:00", "created_by": null, "deleted_at": null, "deleted_by": null, "is_control": false, "updated_at": "2026-09-20T22:32:43.66283+00:00", "updated_by": null, "account_type_code": "expense", "control_subledger_type_code": null}', '2026-09-20 22:32:43.66283+00');


--
-- Data for Name: party; Type: TABLE DATA; Schema: tenant_demo; Owner: -
--



--
-- Data for Name: consignor_agreement; Type: TABLE DATA; Schema: tenant_demo; Owner: -
--



--
-- Data for Name: commission_rule; Type: TABLE DATA; Schema: tenant_demo; Owner: -
--



--
-- Data for Name: consignment_item; Type: TABLE DATA; Schema: tenant_demo; Owner: -
--



--
-- Data for Name: journal_entry; Type: TABLE DATA; Schema: tenant_demo; Owner: -
--



--
-- Data for Name: consignment_sale; Type: TABLE DATA; Schema: tenant_demo; Owner: -
--



--
-- Data for Name: consignment_sale_line; Type: TABLE DATA; Schema: tenant_demo; Owner: -
--



--
-- Data for Name: consignor_settlement; Type: TABLE DATA; Schema: tenant_demo; Owner: -
--



--
-- Data for Name: consignor_payout; Type: TABLE DATA; Schema: tenant_demo; Owner: -
--



--
-- Data for Name: location; Type: TABLE DATA; Schema: tenant_demo; Owner: -
--



--
-- Data for Name: lease; Type: TABLE DATA; Schema: tenant_demo; Owner: -
--



--
-- Data for Name: delinquency; Type: TABLE DATA; Schema: tenant_demo; Owner: -
--



--
-- Data for Name: exchange_rate; Type: TABLE DATA; Schema: tenant_demo; Owner: -
--



--
-- Data for Name: fiscal_period; Type: TABLE DATA; Schema: tenant_demo; Owner: -
--

INSERT INTO tenant_demo.fiscal_period (id, tenant_id, fiscal_year, period_no, start_date, end_date, status, closed_at, closed_by, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-45e8-76ea-a543-3264bbdcde58', '11111111-1111-7111-8111-111111111111', 2026, 1, '2026-01-01', '2026-01-31', 'open', NULL, NULL, '2026-09-20 22:32:43.750203+00', NULL, '2026-09-20 22:32:43.750203+00', NULL, 1);
INSERT INTO tenant_demo.fiscal_period (id, tenant_id, fiscal_year, period_no, start_date, end_date, status, closed_at, closed_by, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-45e8-7d3d-9280-b509d4f3f627', '11111111-1111-7111-8111-111111111111', 2026, 2, '2026-02-01', '2026-02-28', 'open', NULL, NULL, '2026-09-20 22:32:43.750203+00', NULL, '2026-09-20 22:32:43.750203+00', NULL, 1);
INSERT INTO tenant_demo.fiscal_period (id, tenant_id, fiscal_year, period_no, start_date, end_date, status, closed_at, closed_by, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-45e8-7e6f-be82-c10c24cdaf2a', '11111111-1111-7111-8111-111111111111', 2026, 3, '2026-03-01', '2026-03-31', 'open', NULL, NULL, '2026-09-20 22:32:43.750203+00', NULL, '2026-09-20 22:32:43.750203+00', NULL, 1);
INSERT INTO tenant_demo.fiscal_period (id, tenant_id, fiscal_year, period_no, start_date, end_date, status, closed_at, closed_by, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-45e8-7f53-bdb9-71b26e944bef', '11111111-1111-7111-8111-111111111111', 2026, 4, '2026-04-01', '2026-04-30', 'open', NULL, NULL, '2026-09-20 22:32:43.750203+00', NULL, '2026-09-20 22:32:43.750203+00', NULL, 1);
INSERT INTO tenant_demo.fiscal_period (id, tenant_id, fiscal_year, period_no, start_date, end_date, status, closed_at, closed_by, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-45e9-702e-abb0-06db0150f72d', '11111111-1111-7111-8111-111111111111', 2026, 5, '2026-05-01', '2026-05-31', 'open', NULL, NULL, '2026-09-20 22:32:43.750203+00', NULL, '2026-09-20 22:32:43.750203+00', NULL, 1);
INSERT INTO tenant_demo.fiscal_period (id, tenant_id, fiscal_year, period_no, start_date, end_date, status, closed_at, closed_by, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-45e9-70f8-b3ec-4aeb999d7c4a', '11111111-1111-7111-8111-111111111111', 2026, 6, '2026-06-01', '2026-06-30', 'open', NULL, NULL, '2026-09-20 22:32:43.750203+00', NULL, '2026-09-20 22:32:43.750203+00', NULL, 1);
INSERT INTO tenant_demo.fiscal_period (id, tenant_id, fiscal_year, period_no, start_date, end_date, status, closed_at, closed_by, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-45e9-7156-ba05-6382c0f277db', '11111111-1111-7111-8111-111111111111', 2026, 7, '2026-07-01', '2026-07-31', 'open', NULL, NULL, '2026-09-20 22:32:43.750203+00', NULL, '2026-09-20 22:32:43.750203+00', NULL, 1);
INSERT INTO tenant_demo.fiscal_period (id, tenant_id, fiscal_year, period_no, start_date, end_date, status, closed_at, closed_by, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-45e9-71d0-a868-70c9ca1fb81d', '11111111-1111-7111-8111-111111111111', 2026, 8, '2026-08-01', '2026-08-31', 'open', NULL, NULL, '2026-09-20 22:32:43.750203+00', NULL, '2026-09-20 22:32:43.750203+00', NULL, 1);
INSERT INTO tenant_demo.fiscal_period (id, tenant_id, fiscal_year, period_no, start_date, end_date, status, closed_at, closed_by, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-45e9-7225-afe3-0a0daf5cbef6', '11111111-1111-7111-8111-111111111111', 2026, 9, '2026-09-01', '2026-09-30', 'open', NULL, NULL, '2026-09-20 22:32:43.750203+00', NULL, '2026-09-20 22:32:43.750203+00', NULL, 1);
INSERT INTO tenant_demo.fiscal_period (id, tenant_id, fiscal_year, period_no, start_date, end_date, status, closed_at, closed_by, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-45e9-7288-b872-793e47934ee4', '11111111-1111-7111-8111-111111111111', 2026, 10, '2026-10-01', '2026-10-31', 'open', NULL, NULL, '2026-09-20 22:32:43.750203+00', NULL, '2026-09-20 22:32:43.750203+00', NULL, 1);
INSERT INTO tenant_demo.fiscal_period (id, tenant_id, fiscal_year, period_no, start_date, end_date, status, closed_at, closed_by, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-45e9-72d9-b690-d177fd39036e', '11111111-1111-7111-8111-111111111111', 2026, 11, '2026-11-01', '2026-11-30', 'open', NULL, NULL, '2026-09-20 22:32:43.750203+00', NULL, '2026-09-20 22:32:43.750203+00', NULL, 1);
INSERT INTO tenant_demo.fiscal_period (id, tenant_id, fiscal_year, period_no, start_date, end_date, status, closed_at, closed_by, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-45e9-7328-ac6c-e2ff08dfa7cc', '11111111-1111-7111-8111-111111111111', 2026, 12, '2026-12-01', '2026-12-31', 'open', NULL, NULL, '2026-09-20 22:32:43.750203+00', NULL, '2026-09-20 22:32:43.750203+00', NULL, 1);
INSERT INTO tenant_demo.fiscal_period (id, tenant_id, fiscal_year, period_no, start_date, end_date, status, closed_at, closed_by, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-45e9-7444-9432-527548b57831', '11111111-1111-7111-8111-111111111111', 2027, 1, '2027-01-01', '2027-01-31', 'open', NULL, NULL, '2026-09-20 22:32:43.750203+00', NULL, '2026-09-20 22:32:43.750203+00', NULL, 1);
INSERT INTO tenant_demo.fiscal_period (id, tenant_id, fiscal_year, period_no, start_date, end_date, status, closed_at, closed_by, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-45e9-74a0-a29f-4979b1bcdda1', '11111111-1111-7111-8111-111111111111', 2027, 2, '2027-02-01', '2027-02-28', 'open', NULL, NULL, '2026-09-20 22:32:43.750203+00', NULL, '2026-09-20 22:32:43.750203+00', NULL, 1);
INSERT INTO tenant_demo.fiscal_period (id, tenant_id, fiscal_year, period_no, start_date, end_date, status, closed_at, closed_by, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-45e9-74f2-a335-5a61ee6f01d7', '11111111-1111-7111-8111-111111111111', 2027, 3, '2027-03-01', '2027-03-31', 'open', NULL, NULL, '2026-09-20 22:32:43.750203+00', NULL, '2026-09-20 22:32:43.750203+00', NULL, 1);
INSERT INTO tenant_demo.fiscal_period (id, tenant_id, fiscal_year, period_no, start_date, end_date, status, closed_at, closed_by, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-45e9-7544-b2cb-f49ab2b2432f', '11111111-1111-7111-8111-111111111111', 2027, 4, '2027-04-01', '2027-04-30', 'open', NULL, NULL, '2026-09-20 22:32:43.750203+00', NULL, '2026-09-20 22:32:43.750203+00', NULL, 1);
INSERT INTO tenant_demo.fiscal_period (id, tenant_id, fiscal_year, period_no, start_date, end_date, status, closed_at, closed_by, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-45e9-7594-983b-b6f18c00d615', '11111111-1111-7111-8111-111111111111', 2027, 5, '2027-05-01', '2027-05-31', 'open', NULL, NULL, '2026-09-20 22:32:43.750203+00', NULL, '2026-09-20 22:32:43.750203+00', NULL, 1);
INSERT INTO tenant_demo.fiscal_period (id, tenant_id, fiscal_year, period_no, start_date, end_date, status, closed_at, closed_by, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-45e9-75e1-9f92-ff0ffc80a007', '11111111-1111-7111-8111-111111111111', 2027, 6, '2027-06-01', '2027-06-30', 'open', NULL, NULL, '2026-09-20 22:32:43.750203+00', NULL, '2026-09-20 22:32:43.750203+00', NULL, 1);
INSERT INTO tenant_demo.fiscal_period (id, tenant_id, fiscal_year, period_no, start_date, end_date, status, closed_at, closed_by, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-45e9-7630-8a30-e4882860ae11', '11111111-1111-7111-8111-111111111111', 2027, 7, '2027-07-01', '2027-07-31', 'open', NULL, NULL, '2026-09-20 22:32:43.750203+00', NULL, '2026-09-20 22:32:43.750203+00', NULL, 1);
INSERT INTO tenant_demo.fiscal_period (id, tenant_id, fiscal_year, period_no, start_date, end_date, status, closed_at, closed_by, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-45e9-7681-b295-84cdf4b29a22', '11111111-1111-7111-8111-111111111111', 2027, 8, '2027-08-01', '2027-08-31', 'open', NULL, NULL, '2026-09-20 22:32:43.750203+00', NULL, '2026-09-20 22:32:43.750203+00', NULL, 1);
INSERT INTO tenant_demo.fiscal_period (id, tenant_id, fiscal_year, period_no, start_date, end_date, status, closed_at, closed_by, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-45e9-76d0-bf31-de0594592d6a', '11111111-1111-7111-8111-111111111111', 2027, 9, '2027-09-01', '2027-09-30', 'open', NULL, NULL, '2026-09-20 22:32:43.750203+00', NULL, '2026-09-20 22:32:43.750203+00', NULL, 1);
INSERT INTO tenant_demo.fiscal_period (id, tenant_id, fiscal_year, period_no, start_date, end_date, status, closed_at, closed_by, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-45e9-771f-94d1-20f5bf76f425', '11111111-1111-7111-8111-111111111111', 2027, 10, '2027-10-01', '2027-10-31', 'open', NULL, NULL, '2026-09-20 22:32:43.750203+00', NULL, '2026-09-20 22:32:43.750203+00', NULL, 1);
INSERT INTO tenant_demo.fiscal_period (id, tenant_id, fiscal_year, period_no, start_date, end_date, status, closed_at, closed_by, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-45e9-776c-947d-2ce0821a8b3d', '11111111-1111-7111-8111-111111111111', 2027, 11, '2027-11-01', '2027-11-30', 'open', NULL, NULL, '2026-09-20 22:32:43.750203+00', NULL, '2026-09-20 22:32:43.750203+00', NULL, 1);
INSERT INTO tenant_demo.fiscal_period (id, tenant_id, fiscal_year, period_no, start_date, end_date, status, closed_at, closed_by, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-45e9-77bb-b542-ca55838c9034', '11111111-1111-7111-8111-111111111111', 2027, 12, '2027-12-01', '2027-12-31', 'open', NULL, NULL, '2026-09-20 22:32:43.750203+00', NULL, '2026-09-20 22:32:43.750203+00', NULL, 1);


--
-- Data for Name: floor; Type: TABLE DATA; Schema: tenant_demo; Owner: -
--



--
-- Data for Name: item_price_change; Type: TABLE DATA; Schema: tenant_demo; Owner: -
--



--
-- Data for Name: journal_line; Type: TABLE DATA; Schema: tenant_demo; Owner: -
--



--
-- Data for Name: lease_deposit; Type: TABLE DATA; Schema: tenant_demo; Owner: -
--



--
-- Data for Name: space; Type: TABLE DATA; Schema: tenant_demo; Owner: -
--



--
-- Data for Name: lease_space; Type: TABLE DATA; Schema: tenant_demo; Owner: -
--



--
-- Data for Name: open_item; Type: TABLE DATA; Schema: tenant_demo; Owner: -
--



--
-- Data for Name: organization; Type: TABLE DATA; Schema: tenant_demo; Owner: -
--



--
-- Data for Name: party_contact_mechanism; Type: TABLE DATA; Schema: tenant_demo; Owner: -
--



--
-- Data for Name: party_identifier; Type: TABLE DATA; Schema: tenant_demo; Owner: -
--



--
-- Data for Name: party_relationship; Type: TABLE DATA; Schema: tenant_demo; Owner: -
--



--
-- Data for Name: party_role; Type: TABLE DATA; Schema: tenant_demo; Owner: -
--



--
-- Data for Name: payment_application; Type: TABLE DATA; Schema: tenant_demo; Owner: -
--



--
-- Data for Name: person; Type: TABLE DATA; Schema: tenant_demo; Owner: -
--



--
-- Data for Name: postal_address; Type: TABLE DATA; Schema: tenant_demo; Owner: -
--



--
-- Data for Name: posting_map; Type: TABLE DATA; Schema: tenant_demo; Owner: -
--

INSERT INTO tenant_demo.posting_map (id, tenant_id, role_code, account_id, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-456a-7bf5-9d5d-0d86d249745a', '11111111-1111-7111-8111-111111111111', 'cash', '01a0c0f3-4566-7542-aff3-be7dde1661ed', '2026-09-20 22:32:43.626241+00', NULL, '2026-09-20 22:32:43.626241+00', NULL, 1);
INSERT INTO tenant_demo.posting_map (id, tenant_id, role_code, account_id, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-456a-7e8f-8136-78485179914c', '11111111-1111-7111-8111-111111111111', 'ar_control', '01a0c0f3-4566-7b28-8a05-ddbdf7828464', '2026-09-20 22:32:43.626241+00', NULL, '2026-09-20 22:32:43.626241+00', NULL, 1);
INSERT INTO tenant_demo.posting_map (id, tenant_id, role_code, account_id, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-456a-7ec2-8898-d6bb2139c97d', '11111111-1111-7111-8111-111111111111', 'inventory', '01a0c0f3-4566-7b57-ae3d-e6a9f13ca896', '2026-09-20 22:32:43.626241+00', NULL, '2026-09-20 22:32:43.626241+00', NULL, 1);
INSERT INTO tenant_demo.posting_map (id, tenant_id, role_code, account_id, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-456a-7edb-ae42-1a7f7cdf8204', '11111111-1111-7111-8111-111111111111', 'ap_control', '01a0c0f3-4566-7bc0-94a8-4551823f36ef', '2026-09-20 22:32:43.626241+00', NULL, '2026-09-20 22:32:43.626241+00', NULL, 1);
INSERT INTO tenant_demo.posting_map (id, tenant_id, role_code, account_id, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-456a-7ef1-ac0c-0f9b363afae6', '11111111-1111-7111-8111-111111111111', 'vendor_payable_control', '01a0c0f3-4566-7bdb-908e-d423fb29783b', '2026-09-20 22:32:43.626241+00', NULL, '2026-09-20 22:32:43.626241+00', NULL, 1);
INSERT INTO tenant_demo.posting_map (id, tenant_id, role_code, account_id, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-456a-7f06-ac38-1e0877b6a616', '11111111-1111-7111-8111-111111111111', 'customer_credit_control', '01a0c0f3-4566-7c0b-9142-7a81c9520c3b', '2026-09-20 22:32:43.626241+00', NULL, '2026-09-20 22:32:43.626241+00', NULL, 1);
INSERT INTO tenant_demo.posting_map (id, tenant_id, role_code, account_id, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-456a-7f1b-9c90-d6a95571fa8a', '11111111-1111-7111-8111-111111111111', 'gift_certificate_control', '01a0c0f3-4566-7c29-bacf-ff14d2f602e2', '2026-09-20 22:32:43.626241+00', NULL, '2026-09-20 22:32:43.626241+00', NULL, 1);
INSERT INTO tenant_demo.posting_map (id, tenant_id, role_code, account_id, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-456a-7f2f-9daa-0019cef07d46', '11111111-1111-7111-8111-111111111111', 'security_deposit_control', '01a0c0f3-4566-7c43-9fbd-e6b03a615952', '2026-09-20 22:32:43.626241+00', NULL, '2026-09-20 22:32:43.626241+00', NULL, 1);
INSERT INTO tenant_demo.posting_map (id, tenant_id, role_code, account_id, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-456a-7f45-aabc-ddbf878f95ac', '11111111-1111-7111-8111-111111111111', 'owner_equity', '01a0c0f3-4566-7c7c-bd96-92c0b4d6800c', '2026-09-20 22:32:43.626241+00', NULL, '2026-09-20 22:32:43.626241+00', NULL, 1);
INSERT INTO tenant_demo.posting_map (id, tenant_id, role_code, account_id, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-456a-7f5f-b0af-e8a25db3a6e2', '11111111-1111-7111-8111-111111111111', 'sales_revenue', '01a0c0f3-4566-7cd3-9e8e-e3ea52f226f1', '2026-09-20 22:32:43.626241+00', NULL, '2026-09-20 22:32:43.626241+00', NULL, 1);
INSERT INTO tenant_demo.posting_map (id, tenant_id, role_code, account_id, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-456a-7f77-be58-a5232ca016ed', '11111111-1111-7111-8111-111111111111', 'rent_revenue', '01a0c0f3-4566-7cf0-89a0-014e57b9ef8c', '2026-09-20 22:32:43.626241+00', NULL, '2026-09-20 22:32:43.626241+00', NULL, 1);
INSERT INTO tenant_demo.posting_map (id, tenant_id, role_code, account_id, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-456a-7f98-9bf7-19740582a259', '11111111-1111-7111-8111-111111111111', 'cam_revenue', '01a0c0f3-4566-7d0f-a646-3d98290e5061', '2026-09-20 22:32:43.626241+00', NULL, '2026-09-20 22:32:43.626241+00', NULL, 1);
INSERT INTO tenant_demo.posting_map (id, tenant_id, role_code, account_id, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-456a-7faf-b637-7a76e0d06ee6', '11111111-1111-7111-8111-111111111111', 'percentage_rent_revenue', '01a0c0f3-4566-7d35-981c-addd13e27090', '2026-09-20 22:32:43.626241+00', NULL, '2026-09-20 22:32:43.626241+00', NULL, 1);
INSERT INTO tenant_demo.posting_map (id, tenant_id, role_code, account_id, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-456a-7fc4-9194-73fd744fa842', '11111111-1111-7111-8111-111111111111', 'other_income', '01a0c0f3-4566-7d4f-a1c4-e1cf486c2a16', '2026-09-20 22:32:43.626241+00', NULL, '2026-09-20 22:32:43.626241+00', NULL, 1);
INSERT INTO tenant_demo.posting_map (id, tenant_id, role_code, account_id, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-456a-7fd9-9d83-5dfd1cf1896c', '11111111-1111-7111-8111-111111111111', 'cogs', '01a0c0f3-4566-7d68-b7f7-4bbf1a190e86', '2026-09-20 22:32:43.626241+00', NULL, '2026-09-20 22:32:43.626241+00', NULL, 1);
INSERT INTO tenant_demo.posting_map (id, tenant_id, role_code, account_id, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-456a-7fef-ab28-79d042e4812a', '11111111-1111-7111-8111-111111111111', 'bad_debt_expense', '01a0c0f3-4566-7d86-9ede-2e2d665c5122', '2026-09-20 22:32:43.626241+00', NULL, '2026-09-20 22:32:43.626241+00', NULL, 1);
INSERT INTO tenant_demo.posting_map (id, tenant_id, role_code, account_id, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-4592-7b52-9694-6f2bc341a026', '11111111-1111-7111-8111-111111111111', 'consignor_payable_control', '01a0c0f3-458f-7af2-ab08-4566aab15eb1', '2026-09-20 22:32:43.66614+00', NULL, '2026-09-20 22:32:43.66614+00', NULL, 1);
INSERT INTO tenant_demo.posting_map (id, tenant_id, role_code, account_id, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-4592-7cda-8c2c-7e7cc6a90cd2', '11111111-1111-7111-8111-111111111111', 'commission_revenue', '01a0c0f3-458f-7da6-a5e1-25c90623329c', '2026-09-20 22:32:43.66614+00', NULL, '2026-09-20 22:32:43.66614+00', NULL, 1);
INSERT INTO tenant_demo.posting_map (id, tenant_id, role_code, account_id, created_at, created_by, updated_at, updated_by, version) VALUES ('01a0c0f3-4592-7d38-b65a-5292af975cd5', '11111111-1111-7111-8111-111111111111', 'consignment_cogs', '01a0c0f3-458f-7df0-ae3b-b1a5ea0aff8f', '2026-09-20 22:32:43.66614+00', NULL, '2026-09-20 22:32:43.66614+00', NULL, 1);


--
-- Data for Name: rent_component; Type: TABLE DATA; Schema: tenant_demo; Owner: -
--



--
-- Data for Name: settlement_line; Type: TABLE DATA; Schema: tenant_demo; Owner: -
--



--
-- Data for Name: space_attribute; Type: TABLE DATA; Schema: tenant_demo; Owner: -
--



--
-- Data for Name: tenant_config; Type: TABLE DATA; Schema: tenant_demo; Owner: -
--

INSERT INTO tenant_demo.tenant_config (tenant_id, legal_name, functional_currency, fiscal_year_start_month, timezone, created_at, created_by, updated_at, updated_by, version) VALUES ('11111111-1111-7111-8111-111111111111', 'Demo Mall LLC', 'USD', 1, 'UTC', '2026-09-20 22:32:43.584799+00', NULL, '2026-09-20 22:32:43.584799+00', NULL, 1);


--
-- Data for Name: waitlist; Type: TABLE DATA; Schema: tenant_demo; Owner: -
--



--
-- Name: audit_log_id_seq; Type: SEQUENCE SET; Schema: tenant_demo; Owner: -
--

SELECT pg_catalog.setval('tenant_demo.audit_log_id_seq', 30, true);


--
-- Name: consignment_item_item_no_seq; Type: SEQUENCE SET; Schema: tenant_demo; Owner: -
--

SELECT pg_catalog.setval('tenant_demo.consignment_item_item_no_seq', 1, false);


--
-- Name: consignment_sale_sale_no_seq; Type: SEQUENCE SET; Schema: tenant_demo; Owner: -
--

SELECT pg_catalog.setval('tenant_demo.consignment_sale_sale_no_seq', 1, false);


--
-- Name: consignor_agreement_agreement_no_seq; Type: SEQUENCE SET; Schema: tenant_demo; Owner: -
--

SELECT pg_catalog.setval('tenant_demo.consignor_agreement_agreement_no_seq', 1, false);


--
-- Name: consignor_settlement_settlement_no_seq; Type: SEQUENCE SET; Schema: tenant_demo; Owner: -
--

SELECT pg_catalog.setval('tenant_demo.consignor_settlement_settlement_no_seq', 1, false);


--
-- Name: journal_entry_entry_no_seq; Type: SEQUENCE SET; Schema: tenant_demo; Owner: -
--

SELECT pg_catalog.setval('tenant_demo.journal_entry_entry_no_seq', 1, false);


--
-- Name: journal_line_id_seq; Type: SEQUENCE SET; Schema: tenant_demo; Owner: -
--

SELECT pg_catalog.setval('tenant_demo.journal_line_id_seq', 1, false);


--
-- Name: lease_lease_no_seq; Type: SEQUENCE SET; Schema: tenant_demo; Owner: -
--

SELECT pg_catalog.setval('tenant_demo.lease_lease_no_seq', 1, false);


--
-- PostgreSQL database dump complete
--

\unrestrict AdP2RpejVotpzl9h08e0IoEUFvtJeUlsmuCgzEWD0mpCCDanw60lEd1Unh4Pgkf

