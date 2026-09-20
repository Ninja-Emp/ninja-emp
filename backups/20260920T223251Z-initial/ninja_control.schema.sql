--
-- PostgreSQL database dump
--

\restrict weghLCEfFCc8PV364gX7aSIDXhuNTL51Iu0h4fA8hvLpix2L7MSEYbpf2DJfKsm

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
-- Name: control; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA control;


--
-- Name: SCHEMA control; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA control IS 'Control plane: tenant registry and routing metadata. Separate database (ADR-0008).';


--
-- Name: register_tenant(text, text, text); Type: FUNCTION; Schema: control; Owner: -
--

CREATE FUNCTION control.register_tenant(p_slug text, p_legal_name text, p_schema_name text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE v_id uuid; v_schema text;
BEGIN
  v_schema := COALESCE(p_schema_name, 'tenant_' || replace(p_slug, '-', '_'));
  INSERT INTO control.tenant (slug, schema_name, legal_name)
  VALUES (p_slug, v_schema, p_legal_name)
  RETURNING id INTO v_id;
  RETURN v_id;
END; $$;


--
-- Name: FUNCTION register_tenant(p_slug text, p_legal_name text, p_schema_name text); Type: COMMENT; Schema: control; Owner: -
--

COMMENT ON FUNCTION control.register_tenant(p_slug text, p_legal_name text, p_schema_name text) IS 'Registers a tenant; the migration runner then creates and migrates its schema.';


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: tenant; Type: TABLE; Schema: control; Owner: -
--

CREATE TABLE control.tenant (
    id uuid DEFAULT uuidv7() NOT NULL,
    slug text NOT NULL,
    schema_name text NOT NULL,
    legal_name text NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    pool_group text DEFAULT 'default'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT tenant_status_check CHECK ((status = ANY (ARRAY['active'::text, 'suspended'::text, 'archived'::text])))
);


--
-- Name: TABLE tenant; Type: COMMENT; Schema: control; Owner: -
--

COMMENT ON TABLE control.tenant IS 'Tenant registry. schema_name is the per-tenant schema; pool_group routes PgBouncer.';


--
-- Name: tenant tenant_pkey; Type: CONSTRAINT; Schema: control; Owner: -
--

ALTER TABLE ONLY control.tenant
    ADD CONSTRAINT tenant_pkey PRIMARY KEY (id);


--
-- Name: tenant tenant_schema_name_key; Type: CONSTRAINT; Schema: control; Owner: -
--

ALTER TABLE ONLY control.tenant
    ADD CONSTRAINT tenant_schema_name_key UNIQUE (schema_name);


--
-- Name: tenant tenant_slug_key; Type: CONSTRAINT; Schema: control; Owner: -
--

ALTER TABLE ONLY control.tenant
    ADD CONSTRAINT tenant_slug_key UNIQUE (slug);


--
-- PostgreSQL database dump complete
--

\unrestrict weghLCEfFCc8PV364gX7aSIDXhuNTL51Iu0h4fA8hvLpix2L7MSEYbpf2DJfKsm

