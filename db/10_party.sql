-- ============================================================================
-- Ninja EMP — 10_party.sql  (TENANT-SCOPED)
-- Party Model Architecture (Silverston): Party / PartyRole / PartyRelationship /
-- PartyContactMechanism, with Person & Organization subtypes.
-- Conforms to docs/DATA_STANDARDS.md: audit block + optimistic locking on every
-- mutable table; soft delete on master data; RESTRICT on financial/master FKs
-- (ADR-0016); PII encrypted at rest + masked (ADR-0018).
-- Run with: SET search_path = <tenant_schema>, kernel;
-- ============================================================================
\set ON_ERROR_STOP on

-- ----------------------------------------------------------------------------
-- Party — the supertype. Every actor (person or org) is a Party.
-- The store owner is a Party too (role flagged is_house), so settlement can
-- route to owner's equity/draw instead of a third-party payable.
-- ----------------------------------------------------------------------------
CREATE TABLE party (
  id           uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id    uuid NOT NULL DEFAULT kernel.current_tenant(),
  party_type   text NOT NULL CHECK (party_type IN ('person','organization')),
  display_name text NOT NULL,
  is_active    boolean NOT NULL DEFAULT true,
  -- audit block (DATA_STANDARDS §2)
  created_at   timestamptz NOT NULL DEFAULT now(),
  created_by   uuid DEFAULT kernel.current_actor(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  updated_by   uuid DEFAULT kernel.current_actor(),
  version      integer NOT NULL DEFAULT 1,
  -- soft delete (DATA_STANDARDS §3)
  deleted_at   timestamptz,
  deleted_by   uuid
);
COMMENT ON TABLE party IS 'Party supertype. Person or Organization. Store owner is a Party with an is_house role.';

CREATE INDEX ix_party_active ON party(tenant_id) WHERE deleted_at IS NULL;

CREATE TRIGGER trg_party_audit
  BEFORE UPDATE ON party
  FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();
CREATE TRIGGER trg_party_audit_row
  AFTER INSERT OR UPDATE OR DELETE ON party
  FOR EACH ROW EXECUTE FUNCTION kernel.audit_row();

-- ----------------------------------------------------------------------------
-- Subtypes. A trigger enforces that the subtype matches party.party_type.
-- Pure child detail: CASCADE from party is allowed (ADR-0016) because the party
-- itself is soft-deleted and never hard-deleted while it has history.
-- ----------------------------------------------------------------------------
CREATE TABLE person (
  party_id      uuid PRIMARY KEY REFERENCES party(id) ON DELETE CASCADE,
  given_name    text,
  middle_name   text,
  family_name   text,
  name_prefix   text,
  name_suffix   text,
  date_of_birth date,          -- pii_sensitive (ADR-0018)
  gender        text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  version       integer NOT NULL DEFAULT 1
);

CREATE TABLE organization (
  party_id       uuid PRIMARY KEY REFERENCES party(id) ON DELETE CASCADE,
  legal_name     text NOT NULL,
  trading_name   text,
  entity_type    text,          -- llc | corp | sole_prop | partnership | nonprofit
  incorporation_date date,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  version        integer NOT NULL DEFAULT 1
);

CREATE OR REPLACE FUNCTION assert_party_subtype() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_type text;
BEGIN
  SELECT party_type INTO v_type FROM party WHERE id = NEW.party_id;
  IF v_type IS NULL THEN
    RAISE EXCEPTION 'party % does not exist', NEW.party_id USING ERRCODE='23503';
  END IF;
  IF v_type <> TG_ARGV[0] THEN
    RAISE EXCEPTION 'party % is %, but % subtype requires %',
      NEW.party_id, v_type, TG_TABLE_NAME, TG_ARGV[0] USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END; $$;

CREATE TRIGGER trg_person_subtype
  BEFORE INSERT OR UPDATE ON person
  FOR EACH ROW EXECUTE FUNCTION assert_party_subtype('person');
CREATE TRIGGER trg_person_audit
  BEFORE UPDATE ON person
  FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

CREATE TRIGGER trg_organization_subtype
  BEFORE INSERT OR UPDATE ON organization
  FOR EACH ROW EXECUTE FUNCTION assert_party_subtype('organization');
CREATE TRIGGER trg_organization_audit
  BEFORE UPDATE ON organization
  FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- ----------------------------------------------------------------------------
-- PartyRole — what a Party is *doing*. is_house marks the store owner's own role.
-- One active (thru_date IS NULL) role per (party, role_type).
-- RESTRICT: a party with roles cannot be hard-deleted (ADR-0016).
-- ----------------------------------------------------------------------------
CREATE TABLE party_role (
  id             uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id      uuid NOT NULL DEFAULT kernel.current_tenant(),
  party_id       uuid NOT NULL REFERENCES party(id) ON DELETE RESTRICT,
  role_type_code text NOT NULL REFERENCES kernel.party_role_type(code),
  is_house       boolean NOT NULL DEFAULT false,
  from_date      date NOT NULL DEFAULT current_date,
  thru_date      date,
  created_at     timestamptz NOT NULL DEFAULT now(),
  created_by     uuid DEFAULT kernel.current_actor(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  updated_by     uuid DEFAULT kernel.current_actor(),
  version        integer NOT NULL DEFAULT 1,
  CHECK (thru_date IS NULL OR thru_date >= from_date)
);
COMMENT ON TABLE party_role IS 'Roles a party plays. is_house=true routes settlement to owner equity/draw.';

CREATE UNIQUE INDEX ux_party_role_active
  ON party_role (party_id, role_type_code)
  WHERE thru_date IS NULL;
CREATE INDEX ix_party_role_party ON party_role(party_id);

CREATE TRIGGER trg_party_role_audit
  BEFORE UPDATE ON party_role
  FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- ----------------------------------------------------------------------------
-- PartyRelationship — directed, typed, time-bounded links between parties.
-- RESTRICT: relationships are part of the party's history (ADR-0016).
-- ----------------------------------------------------------------------------
CREATE TABLE party_relationship (
  id                     uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id              uuid NOT NULL DEFAULT kernel.current_tenant(),
  from_party_id          uuid NOT NULL REFERENCES party(id) ON DELETE RESTRICT,
  to_party_id            uuid NOT NULL REFERENCES party(id) ON DELETE RESTRICT,
  relationship_type_code text NOT NULL REFERENCES kernel.party_relationship_type(code),
  from_date              date NOT NULL DEFAULT current_date,
  thru_date              date,
  created_at             timestamptz NOT NULL DEFAULT now(),
  created_by             uuid DEFAULT kernel.current_actor(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  updated_by             uuid DEFAULT kernel.current_actor(),
  version                integer NOT NULL DEFAULT 1,
  CHECK (from_party_id <> to_party_id),
  CHECK (thru_date IS NULL OR thru_date >= from_date)
);
CREATE INDEX ix_party_relationship_from ON party_relationship(from_party_id);
CREATE INDEX ix_party_relationship_to ON party_relationship(to_party_id);

CREATE TRIGGER trg_party_relationship_audit
  BEFORE UPDATE ON party_relationship
  FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- ----------------------------------------------------------------------------
-- PartyContactMechanism — email/phone/web/etc. (non-postal). Child detail.
-- ----------------------------------------------------------------------------
CREATE TABLE party_contact_mechanism (
  id                  uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id           uuid NOT NULL DEFAULT kernel.current_tenant(),
  party_id            uuid NOT NULL REFERENCES party(id) ON DELETE CASCADE,
  mechanism_type_code text NOT NULL REFERENCES kernel.contact_mechanism_type(code),
  value               text NOT NULL,          -- pii (email/phone)
  is_primary          boolean NOT NULL DEFAULT false,
  valid_from          date,
  valid_thru          date,
  created_at          timestamptz NOT NULL DEFAULT now(),
  created_by          uuid DEFAULT kernel.current_actor(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  updated_by          uuid DEFAULT kernel.current_actor(),
  version             integer NOT NULL DEFAULT 1
);
CREATE INDEX ix_party_contact_party ON party_contact_mechanism(party_id);

CREATE TRIGGER trg_party_contact_audit
  BEFORE UPDATE ON party_contact_mechanism
  FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- ----------------------------------------------------------------------------
-- PostalAddress — structured mailing address (a contact mechanism subtype).
-- ----------------------------------------------------------------------------
CREATE TABLE postal_address (
  id           uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id    uuid NOT NULL DEFAULT kernel.current_tenant(),
  party_id     uuid NOT NULL REFERENCES party(id) ON DELETE CASCADE,
  label        text,                 -- billing | shipping | home | work
  line1        text,
  line2        text,
  city         text,
  region       text,
  postal_code  text,
  country_code char(2),
  is_primary   boolean NOT NULL DEFAULT false,
  created_at   timestamptz NOT NULL DEFAULT now(),
  created_by   uuid DEFAULT kernel.current_actor(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  updated_by   uuid DEFAULT kernel.current_actor(),
  version      integer NOT NULL DEFAULT 1
);
CREATE INDEX ix_postal_address_party ON postal_address(party_id);

CREATE TRIGGER trg_postal_address_audit
  BEFORE UPDATE ON postal_address
  FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- ----------------------------------------------------------------------------
-- PartyIdentifier — external identifiers (tax id, vendor number, DUNS...).
-- PII-SENSITIVE values are ENCRYPTED AT REST (ADR-0018). Uniqueness is enforced
-- on a deterministic SHA-256 hash (ciphertext is non-deterministic). The raw
-- value is never stored in clear text; it is exposed only via a masked view.
-- RESTRICT: identifiers are compliance-relevant history (ADR-0016).
-- ----------------------------------------------------------------------------
CREATE TABLE party_identifier (
  id                  uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id           uuid NOT NULL DEFAULT kernel.current_tenant(),
  party_id            uuid NOT NULL REFERENCES party(id) ON DELETE RESTRICT,
  identifier_type     text NOT NULL REFERENCES kernel.identifier_type(code),
  identifier_value_enc bytea NOT NULL,        -- pgp_sym_encrypt(value, app.pii_key)
  identifier_hash     text NOT NULL,          -- sha256(value) for uniqueness
  issuing_authority   text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  created_by          uuid DEFAULT kernel.current_actor(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  updated_by          uuid DEFAULT kernel.current_actor(),
  version             integer NOT NULL DEFAULT 1,
  deleted_at          timestamptz,
  deleted_by          uuid
);
COMMENT ON TABLE party_identifier IS 'External identifiers. Values encrypted at rest (ADR-0018); uniqueness via sha256 hash.';
CREATE INDEX ix_party_identifier_party ON party_identifier(party_id);
CREATE UNIQUE INDEX ux_party_identifier_active
  ON party_identifier (tenant_id, identifier_type, identifier_hash)
  WHERE deleted_at IS NULL;

CREATE TRIGGER trg_party_identifier_audit
  BEFORE UPDATE ON party_identifier
  FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- Helper: set (upsert) an identifier, encrypting the value with app.pii_key.
CREATE OR REPLACE FUNCTION set_party_identifier(
  p_party_id  uuid,
  p_type      text,
  p_value     text,
  p_authority text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_key  text := current_setting('app.pii_key', true);
  v_hash text;
  v_id   uuid;
BEGIN
  IF v_key IS NULL OR v_key = '' THEN
    RAISE EXCEPTION 'app.pii_key is not set; cannot store PII (ADR-0018)' USING ERRCODE='28000';
  END IF;
  v_hash := encode(digest(p_value, 'sha256'), 'hex');
  SELECT id INTO v_id FROM party_identifier
    WHERE tenant_id = kernel.current_tenant() AND identifier_type = p_type
      AND identifier_hash = v_hash AND deleted_at IS NULL;
  IF v_id IS NOT NULL THEN
    UPDATE party_identifier
       SET identifier_value_enc = pgp_sym_encrypt(p_value, v_key),
           issuing_authority = p_authority
     WHERE id = v_id;
    RETURN v_id;
  END IF;
  INSERT INTO party_identifier (party_id, identifier_type, identifier_value_enc, identifier_hash, issuing_authority)
  VALUES (p_party_id, p_type, pgp_sym_encrypt(p_value, v_key), v_hash, p_authority)
  RETURNING id INTO v_id;
  RETURN v_id;
END; $$;
COMMENT ON FUNCTION set_party_identifier IS 'Encrypts and stores a party identifier; uniqueness via sha256. Requires app.pii_key.';

-- Masked view: decrypts and masks, exposing only the last 4 characters.
CREATE OR REPLACE VIEW v_party_identifier_masked AS
  SELECT id, tenant_id, party_id, identifier_type,
         kernel.mask_tail(pgp_sym_decrypt(identifier_value_enc, current_setting('app.pii_key', true)), 4)
           AS identifier_masked,
         issuing_authority, created_at
    FROM party_identifier
   WHERE deleted_at IS NULL;
COMMENT ON VIEW v_party_identifier_masked IS 'PII-safe view of party identifiers (masked). Requires app.pii_key to decrypt.';
