-- Public registry baseline.
-- Squashed from the Nest shared migrations through 011_saas_doors.sql.
-- No store rows. schema_migrations is the runner ledger.

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--



--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--



SET default_table_access_method = heap;

--
-- Name: error_alert_dispatches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.error_alert_dispatches (
    rule_id uuid NOT NULL,
    issue_id uuid NOT NULL,
    sent_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: error_alert_rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.error_alert_rules (
    rule_id uuid DEFAULT uuidv7() NOT NULL,
    enabled boolean DEFAULT false NOT NULL,
    to_emails character varying(320)[] DEFAULT (ARRAY[]::character varying[])::character varying(320)[] NOT NULL,
    on_new_issue boolean DEFAULT true NOT NULL,
    on_regression boolean DEFAULT true NOT NULL,
    on_spike boolean DEFAULT false NOT NULL,
    spike_count integer DEFAULT 50 NOT NULL,
    spike_window_minutes integer DEFAULT 60 NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT error_alert_rules_spike_count_chk CHECK (((spike_count >= 1) AND (spike_count <= 10000))),
    CONSTRAINT error_alert_rules_spike_window_chk CHECK (((spike_window_minutes >= 1) AND (spike_window_minutes <= 10080)))
);


--
-- Name: error_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.error_events (
    event_id uuid DEFAULT uuidv7() NOT NULL,
    issue_id uuid NOT NULL,
    request_id uuid NOT NULL,
    occurred_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    tenant_id uuid,
    store_name character varying(255),
    store_slug character varying(63),
    identity_id uuid,
    identity_email character varying(320),
    identity_role character varying(16),
    platform_user_id uuid,
    platform_email character varying(320),
    path character varying(200) NOT NULL,
    method character varying(16) NOT NULL,
    http_status integer,
    code character varying(64) NOT NULL,
    message character varying(500) NOT NULL,
    digest character varying(64),
    user_agent character varying(300),
    emp_env character varying(16) NOT NULL,
    store_status character varying(16),
    release character varying(64) DEFAULT ''::character varying NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT error_events_emp_env_chk CHECK (((emp_env)::text = ANY ((ARRAY['local'::character varying, 'test'::character varying, 'production'::character varying])::text[]))),
    CONSTRAINT error_events_store_status_chk CHECK (((store_status IS NULL) OR ((store_status)::text = ANY ((ARRAY['demo'::character varying, 'live'::character varying, 'suspended'::character varying])::text[]))))
);


--
-- Name: error_issues; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.error_issues (
    issue_id uuid DEFAULT uuidv7() NOT NULL,
    fingerprint character(64) NOT NULL,
    title character varying(500) NOT NULL,
    culprit character varying(200) NOT NULL,
    level character varying(16) NOT NULL,
    kind character varying(32) NOT NULL,
    service character varying(16) NOT NULL,
    status character varying(16) NOT NULL,
    event_count integer DEFAULT 1 NOT NULL,
    first_seen_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    last_seen_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    last_tenant_id uuid,
    last_identity_id uuid,
    last_identity_email character varying(320),
    last_platform_user_id uuid,
    last_platform_email character varying(320),
    release character varying(64) DEFAULT ''::character varying NOT NULL,
    CONSTRAINT error_issues_event_count_chk CHECK ((event_count >= 0)),
    CONSTRAINT error_issues_kind_chk CHECK (((kind)::text = ANY ((ARRAY['unhandled_api'::character varying, 'emp_5xx'::character varying, 'client_web'::character varying, 'client_admin'::character varying, 'next_web'::character varying, 'next_admin'::character varying, 'scheduler'::character varying, 'mail'::character varying, 'square'::character varying, 'print'::character varying])::text[]))),
    CONSTRAINT error_issues_level_chk CHECK (((level)::text = ANY ((ARRAY['error'::character varying, 'warning'::character varying])::text[]))),
    CONSTRAINT error_issues_service_chk CHECK (((service)::text = ANY ((ARRAY['api'::character varying, 'web'::character varying, 'admin'::character varying])::text[]))),
    CONSTRAINT error_issues_status_chk CHECK (((status)::text = ANY ((ARRAY['unresolved'::character varying, 'resolved'::character varying, 'ignored'::character varying])::text[])))
);


--
-- Name: identities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.identities (
    identity_id uuid DEFAULT uuidv7() NOT NULL,
    email character varying(320) NOT NULL,
    password_hash character varying(255) NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    disabled_at timestamp with time zone
);


--
-- Name: identity_password_resets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.identity_password_resets (
    password_reset_id uuid DEFAULT uuidv7() NOT NULL,
    identity_id uuid NOT NULL,
    token_hash character(64) NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    consumed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: owner_login_handoffs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.owner_login_handoffs (
    owner_login_handoff_id uuid DEFAULT uuidv7() NOT NULL,
    token_hash character(64) NOT NULL,
    tenant_id uuid NOT NULL,
    tenant_membership_id uuid NOT NULL,
    platform_user_id uuid NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    consumed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: platform_audit_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.platform_audit_events (
    platform_audit_event_id uuid DEFAULT uuidv7() NOT NULL,
    platform_user_id uuid,
    action character varying(64) NOT NULL,
    message character varying(500) NOT NULL,
    resource_type character varying(32) NOT NULL,
    resource_id uuid NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    occurred_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT platform_audit_events_action_chk CHECK (((char_length(btrim((action)::text)) >= 1) AND (char_length((action)::text) <= 64))),
    CONSTRAINT platform_audit_events_message_chk CHECK ((char_length(btrim((message)::text)) >= 1))
);


--
-- Name: platform_invoices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.platform_invoices (
    invoice_id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid NOT NULL,
    issued_on date NOT NULL,
    amount_minor bigint NOT NULL,
    currency character(3) NOT NULL,
    status character varying(16) NOT NULL,
    paid_on date,
    memo character varying(255),
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT platform_invoices_amount_positive_chk CHECK ((amount_minor > 0)),
    CONSTRAINT platform_invoices_currency_chk CHECK ((currency = ANY (ARRAY['USD'::bpchar, 'CAD'::bpchar, 'EUR'::bpchar]))),
    CONSTRAINT platform_invoices_paid_chk CHECK (((((status)::text = 'paid'::text) AND (paid_on IS NOT NULL)) OR (((status)::text <> 'paid'::text) AND (paid_on IS NULL)))),
    CONSTRAINT platform_invoices_status_chk CHECK (((status)::text = ANY ((ARRAY['open'::character varying, 'paid'::character varying, 'voided'::character varying])::text[])))
);


--
-- Name: platform_mail_outbox; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.platform_mail_outbox (
    mail_id uuid DEFAULT uuidv7() NOT NULL,
    kind character varying(32) NOT NULL,
    to_email character varying(320) NOT NULL,
    subject character varying(200) NOT NULL,
    body_text text NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    status character varying(16) NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    last_error character varying(500),
    sent_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT platform_mail_outbox_attempts_chk CHECK ((attempts >= 0)),
    CONSTRAINT platform_mail_outbox_kind_chk CHECK (((kind)::text = 'error_alert'::text)),
    CONSTRAINT platform_mail_outbox_sent_chk CHECK (((((status)::text = 'sent'::text) AND (sent_at IS NOT NULL)) OR (((status)::text <> 'sent'::text) AND (sent_at IS NULL)))),
    CONSTRAINT platform_mail_outbox_status_chk CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'sent'::character varying, 'failed'::character varying])::text[])))
);


--
-- Name: platform_mfa_challenges; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.platform_mfa_challenges (
    challenge_id uuid DEFAULT uuidv7() NOT NULL,
    platform_user_id uuid NOT NULL,
    token_hash character(64) NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: platform_password_resets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.platform_password_resets (
    platform_password_reset_id uuid DEFAULT uuidv7() NOT NULL,
    platform_user_id uuid NOT NULL,
    token_hash character(64) NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    consumed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: platform_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.platform_sessions (
    platform_session_id uuid DEFAULT uuidv7() NOT NULL,
    platform_user_id uuid NOT NULL,
    token_hash character(64) NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    last_seen_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: platform_users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.platform_users (
    platform_user_id uuid DEFAULT uuidv7() NOT NULL,
    email character varying(320) NOT NULL,
    password_hash character varying(255) NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    totp_secret character varying(64),
    totp_enabled boolean DEFAULT false NOT NULL,
    totp_confirmed_at timestamp with time zone,
    CONSTRAINT platform_users_totp_chk CHECK ((((totp_enabled = false) AND (totp_confirmed_at IS NULL)) OR ((totp_enabled = true) AND (totp_secret IS NOT NULL) AND (totp_confirmed_at IS NOT NULL))))
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    migration_key text NOT NULL,
    applied_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checksum character(64) NOT NULL
);


--
-- Name: square_oauth_states; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.square_oauth_states (
    state_id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid NOT NULL,
    nonce_hash character(64) NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: tenant_billing; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_billing (
    tenant_id uuid NOT NULL,
    plan_code character varying(32) DEFAULT 'practice'::character varying NOT NULL,
    status character varying(16) DEFAULT 'trial'::character varying NOT NULL,
    current_period_end date,
    notes character varying(255),
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT tenant_billing_plan_chk CHECK (((plan_code)::text = ANY ((ARRAY['practice'::character varying, 'standard'::character varying, 'paused'::character varying])::text[]))),
    CONSTRAINT tenant_billing_status_chk CHECK (((status)::text = ANY ((ARRAY['trial'::character varying, 'active'::character varying, 'past_due'::character varying, 'canceled'::character varying])::text[])))
);


--
-- Name: tenant_invites; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_invites (
    invite_id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid NOT NULL,
    email character varying(320) NOT NULL,
    role character varying(16) NOT NULL,
    party_id uuid,
    token_hash character(64) NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    accepted_at timestamp with time zone,
    created_by_membership_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT tenant_invites_role_check CHECK (((role)::text = ANY ((ARRAY['manager'::character varying, 'cashier'::character varying, 'vendor'::character varying])::text[]))),
    CONSTRAINT tenant_invites_vendor_party_chk CHECK (((((role)::text = 'vendor'::text) AND (party_id IS NOT NULL)) OR (((role)::text <> 'vendor'::text) AND (party_id IS NULL))))
);


--
-- Name: tenant_memberships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_memberships (
    tenant_membership_id uuid DEFAULT uuidv7() NOT NULL,
    tenant_id uuid NOT NULL,
    identity_id uuid NOT NULL,
    role character varying(16) NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    disabled_at timestamp with time zone,
    party_id uuid,
    CONSTRAINT tenant_memberships_role_check CHECK (((role)::text = ANY ((ARRAY['owner'::character varying, 'manager'::character varying, 'cashier'::character varying, 'vendor'::character varying])::text[]))),
    CONSTRAINT tenant_memberships_vendor_party_chk CHECK (((((role)::text = 'vendor'::text) AND (party_id IS NOT NULL)) OR (((role)::text <> 'vendor'::text) AND (party_id IS NULL))))
);


--
-- Name: tenant_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_sessions (
    tenant_session_id uuid DEFAULT uuidv7() NOT NULL,
    tenant_membership_id uuid NOT NULL,
    token_hash character(64) NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    last_seen_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    support_login boolean DEFAULT false NOT NULL
);


--
-- Name: tenant_square_oauth; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_square_oauth (
    tenant_id uuid NOT NULL,
    merchant_id character varying(64) NOT NULL,
    location_id character varying(64) NOT NULL,
    access_token_cipher text NOT NULL,
    refresh_token_cipher text,
    expires_at timestamp with time zone,
    connected_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: tenants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenants (
    tenant_id uuid DEFAULT uuidv7() NOT NULL,
    slug character varying(63) NOT NULL,
    store_name character varying(255) NOT NULL,
    status character varying(16) NOT NULL,
    use_case character varying(32) NOT NULL,
    functional_currency character(3) NOT NULL,
    timezone character varying(64) NOT NULL,
    demo_seeded boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    schema_name character varying(80) GENERATED ALWAYS AS (('tenant_'::text || replace((tenant_id)::text, '-'::text, '_'::text))) STORED,
    resume_status character varying(16),
    square_location_id character varying(64),
    CONSTRAINT tenants_currency_check CHECK ((functional_currency = ANY (ARRAY['USD'::bpchar, 'CAD'::bpchar, 'EUR'::bpchar]))),
    CONSTRAINT tenants_resume_status_chk CHECK (((((status)::text = 'suspended'::text) AND ((resume_status)::text = ANY ((ARRAY['demo'::character varying, 'live'::character varying])::text[]))) OR (((status)::text <> 'suspended'::text) AND (resume_status IS NULL)))),
    CONSTRAINT tenants_schema_name_shape_check CHECK (((schema_name)::text ~ '^tenant_[0-9a-f]{8}_[0-9a-f]{4}_[0-9a-f]{4}_[0-9a-f]{4}_[0-9a-f]{12}$'::text)),
    CONSTRAINT tenants_status_check CHECK (((status)::text = ANY ((ARRAY['demo'::character varying, 'live'::character varying, 'suspended'::character varying])::text[]))),
    CONSTRAINT tenants_use_case_check CHECK (((use_case)::text = ANY ((ARRAY['vendor_mall'::character varying, 'consignment'::character varying])::text[])))
);


--
-- Name: error_alert_dispatches error_alert_dispatches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.error_alert_dispatches
    ADD CONSTRAINT error_alert_dispatches_pkey PRIMARY KEY (rule_id, issue_id);


--
-- Name: error_alert_rules error_alert_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.error_alert_rules
    ADD CONSTRAINT error_alert_rules_pkey PRIMARY KEY (rule_id);


--
-- Name: error_events error_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.error_events
    ADD CONSTRAINT error_events_pkey PRIMARY KEY (event_id);


--
-- Name: error_issues error_issues_fingerprint_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.error_issues
    ADD CONSTRAINT error_issues_fingerprint_key UNIQUE (fingerprint);


--
-- Name: error_issues error_issues_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.error_issues
    ADD CONSTRAINT error_issues_pkey PRIMARY KEY (issue_id);


--
-- Name: identities identities_email_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identities
    ADD CONSTRAINT identities_email_key UNIQUE (email);


--
-- Name: identities identities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identities
    ADD CONSTRAINT identities_pkey PRIMARY KEY (identity_id);


--
-- Name: identity_password_resets identity_password_resets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_password_resets
    ADD CONSTRAINT identity_password_resets_pkey PRIMARY KEY (password_reset_id);


--
-- Name: identity_password_resets identity_password_resets_token_hash_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_password_resets
    ADD CONSTRAINT identity_password_resets_token_hash_key UNIQUE (token_hash);


--
-- Name: owner_login_handoffs owner_login_handoffs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.owner_login_handoffs
    ADD CONSTRAINT owner_login_handoffs_pkey PRIMARY KEY (owner_login_handoff_id);


--
-- Name: owner_login_handoffs owner_login_handoffs_token_hash_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.owner_login_handoffs
    ADD CONSTRAINT owner_login_handoffs_token_hash_key UNIQUE (token_hash);


--
-- Name: platform_audit_events platform_audit_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_audit_events
    ADD CONSTRAINT platform_audit_events_pkey PRIMARY KEY (platform_audit_event_id);


--
-- Name: platform_invoices platform_invoices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_invoices
    ADD CONSTRAINT platform_invoices_pkey PRIMARY KEY (invoice_id);


--
-- Name: platform_mail_outbox platform_mail_outbox_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_mail_outbox
    ADD CONSTRAINT platform_mail_outbox_pkey PRIMARY KEY (mail_id);


--
-- Name: platform_mfa_challenges platform_mfa_challenges_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_mfa_challenges
    ADD CONSTRAINT platform_mfa_challenges_pkey PRIMARY KEY (challenge_id);


--
-- Name: platform_mfa_challenges platform_mfa_challenges_token_hash_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_mfa_challenges
    ADD CONSTRAINT platform_mfa_challenges_token_hash_key UNIQUE (token_hash);


--
-- Name: platform_password_resets platform_password_resets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_password_resets
    ADD CONSTRAINT platform_password_resets_pkey PRIMARY KEY (platform_password_reset_id);


--
-- Name: platform_password_resets platform_password_resets_token_hash_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_password_resets
    ADD CONSTRAINT platform_password_resets_token_hash_key UNIQUE (token_hash);


--
-- Name: platform_sessions platform_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_sessions
    ADD CONSTRAINT platform_sessions_pkey PRIMARY KEY (platform_session_id);


--
-- Name: platform_sessions platform_sessions_token_hash_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_sessions
    ADD CONSTRAINT platform_sessions_token_hash_key UNIQUE (token_hash);


--
-- Name: platform_users platform_users_email_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_users
    ADD CONSTRAINT platform_users_email_key UNIQUE (email);


--
-- Name: platform_users platform_users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_users
    ADD CONSTRAINT platform_users_pkey PRIMARY KEY (platform_user_id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (migration_key);


--
-- Name: square_oauth_states square_oauth_states_nonce_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.square_oauth_states
    ADD CONSTRAINT square_oauth_states_nonce_key UNIQUE (nonce_hash);


--
-- Name: square_oauth_states square_oauth_states_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.square_oauth_states
    ADD CONSTRAINT square_oauth_states_pkey PRIMARY KEY (state_id);


--
-- Name: tenant_billing tenant_billing_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_billing
    ADD CONSTRAINT tenant_billing_pkey PRIMARY KEY (tenant_id);


--
-- Name: tenant_invites tenant_invites_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_invites
    ADD CONSTRAINT tenant_invites_pkey PRIMARY KEY (invite_id);


--
-- Name: tenant_invites tenant_invites_token_hash_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_invites
    ADD CONSTRAINT tenant_invites_token_hash_key UNIQUE (token_hash);


--
-- Name: tenant_memberships tenant_memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_memberships
    ADD CONSTRAINT tenant_memberships_pkey PRIMARY KEY (tenant_membership_id);


--
-- Name: tenant_memberships tenant_memberships_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_memberships
    ADD CONSTRAINT tenant_memberships_unique UNIQUE (tenant_id, identity_id);


--
-- Name: tenant_sessions tenant_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_sessions
    ADD CONSTRAINT tenant_sessions_pkey PRIMARY KEY (tenant_session_id);


--
-- Name: tenant_sessions tenant_sessions_token_hash_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_sessions
    ADD CONSTRAINT tenant_sessions_token_hash_key UNIQUE (token_hash);


--
-- Name: tenant_square_oauth tenant_square_oauth_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_square_oauth
    ADD CONSTRAINT tenant_square_oauth_pkey PRIMARY KEY (tenant_id);


--
-- Name: tenants tenants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenants
    ADD CONSTRAINT tenants_pkey PRIMARY KEY (tenant_id);


--
-- Name: tenants tenants_schema_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenants
    ADD CONSTRAINT tenants_schema_name_key UNIQUE (schema_name);


--
-- Name: tenants tenants_slug_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenants
    ADD CONSTRAINT tenants_slug_key UNIQUE (slug);


--
-- Name: error_events_issue_seen_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX error_events_issue_seen_idx ON public.error_events USING btree (issue_id, occurred_at DESC);


--
-- Name: error_events_occurred_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX error_events_occurred_idx ON public.error_events USING btree (occurred_at);


--
-- Name: error_events_request_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX error_events_request_idx ON public.error_events USING btree (request_id);


--
-- Name: error_events_tenant_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX error_events_tenant_idx ON public.error_events USING btree (tenant_id);


--
-- Name: error_issues_status_seen_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX error_issues_status_seen_idx ON public.error_issues USING btree (status, last_seen_at DESC);


--
-- Name: identity_password_resets_expires_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX identity_password_resets_expires_idx ON public.identity_password_resets USING btree (expires_at);


--
-- Name: identity_password_resets_identity_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX identity_password_resets_identity_idx ON public.identity_password_resets USING btree (identity_id, created_at DESC);


--
-- Name: owner_login_handoffs_expires_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX owner_login_handoffs_expires_idx ON public.owner_login_handoffs USING btree (expires_at);


--
-- Name: platform_audit_events_actor_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX platform_audit_events_actor_idx ON public.platform_audit_events USING btree (platform_user_id, occurred_at DESC);


--
-- Name: platform_audit_events_occurred_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX platform_audit_events_occurred_at_idx ON public.platform_audit_events USING btree (occurred_at DESC);


--
-- Name: platform_invoices_tenant_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX platform_invoices_tenant_idx ON public.platform_invoices USING btree (tenant_id, issued_on);


--
-- Name: platform_mail_outbox_pending_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX platform_mail_outbox_pending_idx ON public.platform_mail_outbox USING btree (status, created_at) WHERE ((status)::text = 'pending'::text);


--
-- Name: platform_mfa_challenges_expires_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX platform_mfa_challenges_expires_idx ON public.platform_mfa_challenges USING btree (expires_at);


--
-- Name: platform_password_resets_expires_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX platform_password_resets_expires_idx ON public.platform_password_resets USING btree (expires_at);


--
-- Name: platform_password_resets_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX platform_password_resets_user_idx ON public.platform_password_resets USING btree (platform_user_id, created_at DESC);


--
-- Name: platform_sessions_expires_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX platform_sessions_expires_idx ON public.platform_sessions USING btree (expires_at);


--
-- Name: tenant_invites_expires_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tenant_invites_expires_idx ON public.tenant_invites USING btree (expires_at);


--
-- Name: tenant_invites_tenant_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tenant_invites_tenant_idx ON public.tenant_invites USING btree (tenant_id, email);


--
-- Name: tenant_memberships_identity_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tenant_memberships_identity_idx ON public.tenant_memberships USING btree (identity_id);


--
-- Name: tenant_memberships_vendor_party_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX tenant_memberships_vendor_party_key ON public.tenant_memberships USING btree (tenant_id, party_id) WHERE (((role)::text = 'vendor'::text) AND (party_id IS NOT NULL));


--
-- Name: tenant_sessions_expires_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tenant_sessions_expires_idx ON public.tenant_sessions USING btree (expires_at);


--
-- Name: tenant_sessions_membership_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tenant_sessions_membership_idx ON public.tenant_sessions USING btree (tenant_membership_id);


--
-- Name: tenant_square_oauth_location_uidx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX tenant_square_oauth_location_uidx ON public.tenant_square_oauth USING btree (location_id);


--
-- Name: tenants_square_location_uidx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX tenants_square_location_uidx ON public.tenants USING btree (square_location_id) WHERE (square_location_id IS NOT NULL);


--
-- Name: tenants_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tenants_status_idx ON public.tenants USING btree (status);


--
-- Name: error_alert_dispatches error_alert_dispatches_issue_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.error_alert_dispatches
    ADD CONSTRAINT error_alert_dispatches_issue_id_fkey FOREIGN KEY (issue_id) REFERENCES public.error_issues(issue_id) ON DELETE CASCADE;


--
-- Name: error_alert_dispatches error_alert_dispatches_rule_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.error_alert_dispatches
    ADD CONSTRAINT error_alert_dispatches_rule_id_fkey FOREIGN KEY (rule_id) REFERENCES public.error_alert_rules(rule_id) ON DELETE CASCADE;


--
-- Name: error_events error_events_issue_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.error_events
    ADD CONSTRAINT error_events_issue_id_fkey FOREIGN KEY (issue_id) REFERENCES public.error_issues(issue_id) ON DELETE CASCADE;


--
-- Name: error_events error_events_platform_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.error_events
    ADD CONSTRAINT error_events_platform_user_id_fkey FOREIGN KEY (platform_user_id) REFERENCES public.platform_users(platform_user_id) ON DELETE SET NULL;


--
-- Name: error_events error_events_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.error_events
    ADD CONSTRAINT error_events_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(tenant_id) ON DELETE SET NULL;


--
-- Name: error_issues error_issues_last_platform_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.error_issues
    ADD CONSTRAINT error_issues_last_platform_user_id_fkey FOREIGN KEY (last_platform_user_id) REFERENCES public.platform_users(platform_user_id) ON DELETE SET NULL;


--
-- Name: error_issues error_issues_last_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.error_issues
    ADD CONSTRAINT error_issues_last_tenant_id_fkey FOREIGN KEY (last_tenant_id) REFERENCES public.tenants(tenant_id) ON DELETE SET NULL;


--
-- Name: identity_password_resets identity_password_resets_identity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.identity_password_resets
    ADD CONSTRAINT identity_password_resets_identity_id_fkey FOREIGN KEY (identity_id) REFERENCES public.identities(identity_id) ON DELETE RESTRICT;


--
-- Name: owner_login_handoffs owner_login_handoffs_platform_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.owner_login_handoffs
    ADD CONSTRAINT owner_login_handoffs_platform_user_id_fkey FOREIGN KEY (platform_user_id) REFERENCES public.platform_users(platform_user_id) ON DELETE RESTRICT;


--
-- Name: owner_login_handoffs owner_login_handoffs_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.owner_login_handoffs
    ADD CONSTRAINT owner_login_handoffs_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(tenant_id) ON DELETE RESTRICT;


--
-- Name: owner_login_handoffs owner_login_handoffs_tenant_membership_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.owner_login_handoffs
    ADD CONSTRAINT owner_login_handoffs_tenant_membership_id_fkey FOREIGN KEY (tenant_membership_id) REFERENCES public.tenant_memberships(tenant_membership_id) ON DELETE RESTRICT;


--
-- Name: platform_audit_events platform_audit_events_platform_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_audit_events
    ADD CONSTRAINT platform_audit_events_platform_user_id_fkey FOREIGN KEY (platform_user_id) REFERENCES public.platform_users(platform_user_id) ON DELETE RESTRICT;


--
-- Name: platform_invoices platform_invoices_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_invoices
    ADD CONSTRAINT platform_invoices_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(tenant_id) ON DELETE RESTRICT;


--
-- Name: platform_mfa_challenges platform_mfa_challenges_platform_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_mfa_challenges
    ADD CONSTRAINT platform_mfa_challenges_platform_user_id_fkey FOREIGN KEY (platform_user_id) REFERENCES public.platform_users(platform_user_id) ON DELETE CASCADE;


--
-- Name: platform_password_resets platform_password_resets_platform_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_password_resets
    ADD CONSTRAINT platform_password_resets_platform_user_id_fkey FOREIGN KEY (platform_user_id) REFERENCES public.platform_users(platform_user_id) ON DELETE RESTRICT;


--
-- Name: platform_sessions platform_sessions_platform_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_sessions
    ADD CONSTRAINT platform_sessions_platform_user_id_fkey FOREIGN KEY (platform_user_id) REFERENCES public.platform_users(platform_user_id) ON DELETE CASCADE;


--
-- Name: square_oauth_states square_oauth_states_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.square_oauth_states
    ADD CONSTRAINT square_oauth_states_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(tenant_id) ON DELETE CASCADE;


--
-- Name: tenant_billing tenant_billing_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_billing
    ADD CONSTRAINT tenant_billing_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(tenant_id) ON DELETE RESTRICT;


--
-- Name: tenant_invites tenant_invites_created_by_membership_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_invites
    ADD CONSTRAINT tenant_invites_created_by_membership_id_fkey FOREIGN KEY (created_by_membership_id) REFERENCES public.tenant_memberships(tenant_membership_id) ON DELETE RESTRICT;


--
-- Name: tenant_invites tenant_invites_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_invites
    ADD CONSTRAINT tenant_invites_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(tenant_id) ON DELETE RESTRICT;


--
-- Name: tenant_memberships tenant_memberships_identity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_memberships
    ADD CONSTRAINT tenant_memberships_identity_id_fkey FOREIGN KEY (identity_id) REFERENCES public.identities(identity_id) ON DELETE RESTRICT;


--
-- Name: tenant_memberships tenant_memberships_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_memberships
    ADD CONSTRAINT tenant_memberships_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(tenant_id) ON DELETE RESTRICT;


--
-- Name: tenant_sessions tenant_sessions_tenant_membership_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_sessions
    ADD CONSTRAINT tenant_sessions_tenant_membership_id_fkey FOREIGN KEY (tenant_membership_id) REFERENCES public.tenant_memberships(tenant_membership_id) ON DELETE CASCADE;


--
-- Name: tenant_square_oauth tenant_square_oauth_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_square_oauth
    ADD CONSTRAINT tenant_square_oauth_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(tenant_id) ON DELETE RESTRICT;


--
-- PostgreSQL database dump complete
--
