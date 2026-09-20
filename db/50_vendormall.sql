-- ============================================================================
-- Ninja EMP — 50_vendormall.sql  (TENANT-SCOPED)
-- Vendor Mall domain (SRS Part 3): physical locations, floors, rentable spaces,
-- space attributes, waitlist, leases, lease-space allocation, rent components,
-- security deposits, and delinquency tracking.
-- Conforms to docs/DATA_STANDARDS.md: audit block + optimistic locking on every
-- mutable table; soft delete on master data; RESTRICT on financial/master FKs
-- (ADR-0016); extensible enums via kernel lookup tables.
-- Run with: SET search_path = <tenant_schema>, kernel;
-- ============================================================================
\set ON_ERROR_STOP on

-- ----------------------------------------------------------------------------
-- Location — a physical mall property/site.
-- ----------------------------------------------------------------------------
CREATE TABLE location (
  id           uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id    uuid NOT NULL DEFAULT kernel.current_tenant(),
  code         text NOT NULL,
  name         text NOT NULL,
  timezone     text NOT NULL DEFAULT 'UTC',
  address_line1 text,
  address_line2 text,
  city         text,
  region       text,
  postal_code  text,
  country_code char(2),
  is_active    boolean NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now(),
  created_by   uuid DEFAULT kernel.current_actor(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  updated_by   uuid DEFAULT kernel.current_actor(),
  version      integer NOT NULL DEFAULT 1,
  deleted_at   timestamptz,
  deleted_by   uuid,
  UNIQUE (tenant_id, code)
);
COMMENT ON TABLE location IS 'A physical mall property/site. Master data (soft-deleted).';

CREATE INDEX ix_location_active ON location(tenant_id) WHERE deleted_at IS NULL;
CREATE TRIGGER trg_location_audit
  BEFORE UPDATE ON location FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- ----------------------------------------------------------------------------
-- Floor — a level within a location.
-- ----------------------------------------------------------------------------
CREATE TABLE floor (
  id          uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id   uuid NOT NULL DEFAULT kernel.current_tenant(),
  location_id uuid NOT NULL REFERENCES location(id) ON DELETE RESTRICT,
  code        text NOT NULL,
  name        text NOT NULL,
  level_no    smallint NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now(),
  created_by  uuid DEFAULT kernel.current_actor(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  uuid DEFAULT kernel.current_actor(),
  version     integer NOT NULL DEFAULT 1,
  deleted_at  timestamptz,
  deleted_by  uuid,
  UNIQUE (tenant_id, location_id, code)
);
COMMENT ON TABLE floor IS 'A level within a location. Master data (soft-deleted).';

CREATE INDEX ix_floor_location ON floor(location_id);
CREATE TRIGGER trg_floor_audit
  BEFORE UPDATE ON floor FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- ----------------------------------------------------------------------------
-- Space — a rentable unit (kiosk, booth, inline, ...). Master data.
-- ----------------------------------------------------------------------------
CREATE TABLE space (
  id              uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id       uuid NOT NULL DEFAULT kernel.current_tenant(),
  floor_id        uuid NOT NULL REFERENCES floor(id) ON DELETE RESTRICT,
  code            text NOT NULL,
  name            text,
  space_type_code text NOT NULL REFERENCES kernel.space_type(code),
  area_sqft       numeric(12,2) CHECK (area_sqft IS NULL OR area_sqft >= 0),
  status          text NOT NULL DEFAULT 'available'
                    CHECK (status IN ('available','reserved','leased','maintenance','inactive')),
  is_active       boolean NOT NULL DEFAULT true,
  created_at      timestamptz NOT NULL DEFAULT now(),
  created_by      uuid DEFAULT kernel.current_actor(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  updated_by      uuid DEFAULT kernel.current_actor(),
  version         integer NOT NULL DEFAULT 1,
  deleted_at      timestamptz,
  deleted_by      uuid,
  UNIQUE (tenant_id, code)
);
COMMENT ON TABLE space IS 'A rentable unit. status tracks availability. Master data (soft-deleted).';

CREATE INDEX ix_space_floor ON space(floor_id);
CREATE INDEX ix_space_status ON space(tenant_id, status) WHERE deleted_at IS NULL;
CREATE TRIGGER trg_space_audit
  BEFORE UPDATE ON space FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- ----------------------------------------------------------------------------
-- SpaceAttribute — key/value attributes of a space (child detail, CASCADE).
-- ----------------------------------------------------------------------------
CREATE TABLE space_attribute (
  id         uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id  uuid NOT NULL DEFAULT kernel.current_tenant(),
  space_id   uuid NOT NULL REFERENCES space(id) ON DELETE CASCADE,
  attr_key   text NOT NULL,
  attr_value text,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid DEFAULT kernel.current_actor(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid DEFAULT kernel.current_actor(),
  version    integer NOT NULL DEFAULT 1,
  UNIQUE (space_id, attr_key)
);
CREATE INDEX ix_space_attribute_space ON space_attribute(space_id);
CREATE TRIGGER trg_space_attribute_audit
  BEFORE UPDATE ON space_attribute FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- ----------------------------------------------------------------------------
-- Waitlist — parties waiting for a space (optionally of a type/location).
-- ----------------------------------------------------------------------------
CREATE TABLE waitlist (
  id                   uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id            uuid NOT NULL DEFAULT kernel.current_tenant(),
  party_id             uuid NOT NULL REFERENCES party(id) ON DELETE RESTRICT,
  space_type_code      text REFERENCES kernel.space_type(code),
  preferred_location_id uuid REFERENCES location(id) ON DELETE RESTRICT,
  requested_at         timestamptz NOT NULL DEFAULT now(),
  status               text NOT NULL DEFAULT 'waiting'
                         CHECK (status IN ('waiting','offered','converted','expired','cancelled')),
  notes                text,
  created_at           timestamptz NOT NULL DEFAULT now(),
  created_by           uuid DEFAULT kernel.current_actor(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  updated_by           uuid DEFAULT kernel.current_actor(),
  version              integer NOT NULL DEFAULT 1
);
COMMENT ON TABLE waitlist IS 'Parties waiting for space. status drives the queue.';

CREATE INDEX ix_waitlist_party ON waitlist(party_id);
CREATE INDEX ix_waitlist_open ON waitlist(tenant_id, requested_at) WHERE status = 'waiting';
CREATE TRIGGER trg_waitlist_audit
  BEFORE UPDATE ON waitlist FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- ----------------------------------------------------------------------------
-- Lease — a contract between a lessee party and the mall for one or more spaces.
-- Master data (soft-deleted). lease_no is human-readable (identity).
-- ----------------------------------------------------------------------------
CREATE TABLE lease (
  id              uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id       uuid NOT NULL DEFAULT kernel.current_tenant(),
  lease_no        bigint GENERATED ALWAYS AS IDENTITY,
  lessee_party_id uuid NOT NULL REFERENCES party(id) ON DELETE RESTRICT,
  location_id     uuid NOT NULL REFERENCES location(id) ON DELETE RESTRICT,
  status          text NOT NULL DEFAULT 'draft'
                    CHECK (status IN ('draft','active','expired','terminated')),
  start_date      date NOT NULL,
  end_date        date,
  signed_date     date,
  billing_day     smallint NOT NULL DEFAULT 1 CHECK (billing_day BETWEEN 1 AND 28),
  notes           text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  created_by      uuid DEFAULT kernel.current_actor(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  updated_by      uuid DEFAULT kernel.current_actor(),
  version         integer NOT NULL DEFAULT 1,
  deleted_at      timestamptz,
  deleted_by      uuid,
  CHECK (end_date IS NULL OR end_date >= start_date),
  UNIQUE (tenant_id, lease_no)
);
COMMENT ON TABLE lease IS 'Lease contract. lessee_party_id is the tenant of the space. Master data (soft-deleted).';

CREATE INDEX ix_lease_lessee ON lease(lessee_party_id);
CREATE INDEX ix_lease_location ON lease(location_id);
CREATE INDEX ix_lease_active ON lease(tenant_id, status) WHERE deleted_at IS NULL;
CREATE TRIGGER trg_lease_audit
  BEFORE UPDATE ON lease FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();
CREATE TRIGGER trg_lease_audit_row
  AFTER INSERT OR UPDATE OR DELETE ON lease FOR EACH ROW EXECUTE FUNCTION kernel.audit_row();

-- ----------------------------------------------------------------------------
-- LeaseSpace — allocation of one or more spaces to a lease (time-bounded).
-- ----------------------------------------------------------------------------
CREATE TABLE lease_space (
  id                  uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id           uuid NOT NULL DEFAULT kernel.current_tenant(),
  lease_id            uuid NOT NULL REFERENCES lease(id) ON DELETE RESTRICT,
  space_id            uuid NOT NULL REFERENCES space(id) ON DELETE RESTRICT,
  allocated_area_sqft numeric(12,2) CHECK (allocated_area_sqft IS NULL OR allocated_area_sqft >= 0),
  from_date           date NOT NULL DEFAULT current_date,
  thru_date           date,
  created_at          timestamptz NOT NULL DEFAULT now(),
  created_by          uuid DEFAULT kernel.current_actor(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  updated_by          uuid DEFAULT kernel.current_actor(),
  version             integer NOT NULL DEFAULT 1,
  CHECK (thru_date IS NULL OR thru_date >= from_date)
);
COMMENT ON TABLE lease_space IS 'Time-bounded allocation of spaces to a lease.';

CREATE INDEX ix_lease_space_lease ON lease_space(lease_id);
CREATE INDEX ix_lease_space_space ON lease_space(space_id);
-- A space may be actively leased by at most one lease at a time.
CREATE UNIQUE INDEX ux_lease_space_active
  ON lease_space (space_id) WHERE thru_date IS NULL;
CREATE TRIGGER trg_lease_space_audit
  BEFORE UPDATE ON lease_space FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- ----------------------------------------------------------------------------
-- RentComponent — the periodic charges that make up a lease's billing.
-- base_rent/CAM/etc. carry a fixed amount; percentage_rent carries a rate.
-- ----------------------------------------------------------------------------
CREATE TABLE rent_component (
  id                  uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id           uuid NOT NULL DEFAULT kernel.current_tenant(),
  lease_id            uuid NOT NULL REFERENCES lease(id) ON DELETE RESTRICT,
  component_type_code text NOT NULL REFERENCES kernel.rent_component_type(code),
  amount              kernel.money_amount NOT NULL DEFAULT 0,
  currency            kernel.currency_code NOT NULL DEFAULT 'USD',
  percent_rate        kernel.percent_rate,
  breakpoint_amount   kernel.money_amount,
  billing_frequency   text NOT NULL DEFAULT 'monthly'
                        CHECK (billing_frequency IN ('monthly','quarterly','annual')),
  effective_from      date NOT NULL DEFAULT current_date,
  effective_thru      date,
  created_at          timestamptz NOT NULL DEFAULT now(),
  created_by          uuid DEFAULT kernel.current_actor(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  updated_by          uuid DEFAULT kernel.current_actor(),
  version             integer NOT NULL DEFAULT 1,
  CHECK (effective_thru IS NULL OR effective_thru >= effective_from),
  -- percentage rent requires a rate; fixed components require a non-negative amount.
  CHECK ( (component_type_code = 'percentage_rent' AND percent_rate IS NOT NULL)
       OR (component_type_code <> 'percentage_rent' AND amount >= 0) )
);
COMMENT ON TABLE rent_component IS 'Periodic lease charges. percentage_rent uses percent_rate; others use amount.';

-- Effective-dated integrity (DATA_STANDARDS §temporal): a lease may not have two
-- overlapping charge periods for the same component type. Uses btree_gist.
ALTER TABLE rent_component
  ADD CONSTRAINT ex_rent_component_no_overlap
  EXCLUDE USING gist (
    lease_id            WITH =,
    component_type_code WITH =,
    daterange(effective_from, effective_thru, '[]') WITH &&
  );

CREATE INDEX ix_rent_component_lease ON rent_component(lease_id);
CREATE TRIGGER trg_rent_component_audit
  BEFORE UPDATE ON rent_component FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- ----------------------------------------------------------------------------
-- LeaseDeposit — refundable security deposit held for a lease.
-- journal_entry_id links to the ledger posting that recorded receipt (RESTRICT).
-- ----------------------------------------------------------------------------
CREATE TABLE lease_deposit (
  id               uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id        uuid NOT NULL DEFAULT kernel.current_tenant(),
  lease_id         uuid NOT NULL REFERENCES lease(id) ON DELETE RESTRICT,
  deposit_amount   kernel.money_amount NOT NULL CHECK (deposit_amount >= 0),
  currency         kernel.currency_code NOT NULL DEFAULT 'USD',
  received_date    date,
  status           text NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending','held','applied','refunded','forfeited')),
  journal_entry_id uuid REFERENCES journal_entry(id) ON DELETE RESTRICT,
  created_at       timestamptz NOT NULL DEFAULT now(),
  created_by       uuid DEFAULT kernel.current_actor(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  updated_by       uuid DEFAULT kernel.current_actor(),
  version          integer NOT NULL DEFAULT 1
);
COMMENT ON TABLE lease_deposit IS 'Refundable security deposit. journal_entry_id ties it to the ledger.';

CREATE INDEX ix_lease_deposit_lease ON lease_deposit(lease_id);
CREATE TRIGGER trg_lease_deposit_audit
  BEFORE UPDATE ON lease_deposit FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- ----------------------------------------------------------------------------
-- Delinquency — a point-in-time snapshot of a lease's arrears position.
-- ----------------------------------------------------------------------------
CREATE TABLE delinquency (
  id            uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id     uuid NOT NULL DEFAULT kernel.current_tenant(),
  lease_id      uuid NOT NULL REFERENCES lease(id) ON DELETE RESTRICT,
  as_of_date    date NOT NULL,
  amount_due    kernel.money_amount NOT NULL DEFAULT 0,
  amount_paid   kernel.money_amount NOT NULL DEFAULT 0,
  days_past_due integer NOT NULL DEFAULT 0 CHECK (days_past_due >= 0),
  status        text NOT NULL DEFAULT 'current'
                  CHECK (status IN ('current','delinquent','collections','written_off')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  created_by    uuid DEFAULT kernel.current_actor(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  updated_by    uuid DEFAULT kernel.current_actor(),
  version       integer NOT NULL DEFAULT 1,
  UNIQUE (tenant_id, lease_id, as_of_date)
);
COMMENT ON TABLE delinquency IS 'Point-in-time arrears snapshot per lease.';

CREATE INDEX ix_delinquency_lease ON delinquency(lease_id);
CREATE TRIGGER trg_delinquency_audit
  BEFORE UPDATE ON delinquency FOR EACH ROW EXECUTE FUNCTION kernel.touch_audit();

-- ----------------------------------------------------------------------------
-- Convenience view: active leases with their spaces and lessee.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_active_lease AS
  SELECT l.id AS lease_id, l.lease_no, l.status, l.start_date, l.end_date,
         p.display_name AS lessee_name, loc.name AS location_name,
         s.code AS space_code, s.space_type_code
    FROM lease l
    JOIN party p ON p.id = l.lessee_party_id
    JOIN location loc ON loc.id = l.location_id
    LEFT JOIN lease_space ls ON ls.lease_id = l.id AND ls.thru_date IS NULL
    LEFT JOIN space s ON s.id = ls.space_id
   WHERE l.deleted_at IS NULL;
COMMENT ON VIEW v_active_lease IS 'Active leases joined to lessee, location, and current space.';
