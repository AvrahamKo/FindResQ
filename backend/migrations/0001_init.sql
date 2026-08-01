-- Phase 0: LifeSearch core schema.

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ===========================================================================
-- Identity
-- ===========================================================================

CREATE TABLE users (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    phone_e164          TEXT UNIQUE NOT NULL,
    display_name        TEXT NOT NULL,
    verification_status TEXT NOT NULL DEFAULT 'unverified'
                          CHECK (verification_status IN
                            ('unverified','pending','verified','rejected')),
    verified_org        TEXT,
    verified_at         TIMESTAMPTZ,
    verified_by         UUID REFERENCES users(id),
    disabled_at         TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- The Ed25519 keypair belongs to an INSTALL, not a person. Reinstall = new key.
-- Packets therefore identify a device, not a user.
CREATE TABLE devices (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id            UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    wire_id            INTEGER GENERATED ALWAYS AS IDENTITY UNIQUE,
    ed25519_public_key BYTEA NOT NULL UNIQUE
                         CHECK (octet_length(ed25519_public_key) = 32),
    platform           TEXT NOT NULL CHECK (platform IN ('android','ios')),
    mesh_capable       BOOLEAN NOT NULL DEFAULT false,
    push_token         TEXT,
    registered_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    revoked_at         TIMESTAMPTZ
);

-- ===========================================================================
-- Events, subject, sectors
-- ===========================================================================

CREATE TABLE events (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name              TEXT NOT NULL,
    commander_id      UUID NOT NULL REFERENCES users(id),
    status            TEXT NOT NULL DEFAULT 'draft'
                        CHECK (status IN ('draft','active','ended')),
    command_post_sms  TEXT,
    session_ttl_hours INT NOT NULL DEFAULT 14,
    started_at        TIMESTAMPTZ,
    ended_at          TIMESTAMPTZ,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Third-party PII. Server-side of record; devices hold an encrypted copy only.
CREATE TABLE subjects (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id            UUID NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    display_name        TEXT NOT NULL,
    age_years           SMALLINT,
    description         TEXT,
    medical_notes       TEXT,
    photo_object_key    TEXT,
    consent_obtained_by UUID REFERENCES users(id),
    consent_recorded_at TIMESTAMPTZ,
    consent_basis       TEXT,
    purge_after         TIMESTAMPTZ NOT NULL,
    purged_at           TIMESTAMPTZ
);

CREATE TABLE sectors (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id              UUID NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    name                  TEXT NOT NULL,
    boundary              geography(Polygon,4326) NOT NULL,
    lead_user_id          UUID REFERENCES users(id),
    status                TEXT NOT NULL DEFAULT 'open'
                            CHECK (status IN ('open','paused','closed')),
    key_epoch             INT NOT NULL DEFAULT 1,

    -- Coverage tuning. Lead-overridable; never hardcode these in app code.
    h3_resolution         SMALLINT     NOT NULL DEFAULT 12,
    walker_radius_m       NUMERIC(5,1) NOT NULL DEFAULT 10.0,
    vehicle_base_radius_m NUMERIC(5,1) NOT NULL DEFAULT 5.0,
    base_pod_day          NUMERIC(4,3) NOT NULL DEFAULT 0.400,
    base_pod_night        NUMERIC(4,3) NOT NULL DEFAULT 0.250,
    repeat_discount       NUMERIC(4,3) NOT NULL DEFAULT 0.250,
    max_gap_seconds       INT          NOT NULL DEFAULT 30,
    max_gap_meters        INT          NOT NULL DEFAULT 50,
    min_accuracy_m        INT          NOT NULL DEFAULT 30,
    created_at            TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX sectors_boundary_gix ON sectors USING GIST (boundary);

CREATE TABLE sector_keys (
    sector_id   UUID NOT NULL REFERENCES sectors(id) ON DELETE CASCADE,
    epoch       INT  NOT NULL,
    key_wrapped BYTEA NOT NULL,   -- wrapped by KMS/master key; never plaintext
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    retired_at  TIMESTAMPTZ,
    PRIMARY KEY (sector_id, epoch)
);

-- ===========================================================================
-- Membership
-- ===========================================================================

CREATE TABLE sector_memberships (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sector_id          UUID NOT NULL REFERENCES sectors(id) ON DELETE CASCADE,
    user_id            UUID NOT NULL REFERENCES users(id),
    device_id          UUID NOT NULL REFERENCES devices(id),
    role               TEXT NOT NULL CHECK (role IN ('commander','lead','volunteer')),
    movement_mode      TEXT NOT NULL DEFAULT 'walker'
                         CHECK (movement_mode IN ('walker','vehicle')),
    status             TEXT NOT NULL DEFAULT 'pending'
                         CHECK (status IN ('pending','approved','rejected','revoked','ended')),
    key_epoch_issued   INT,
    approved_by        UUID REFERENCES users(id),
    approved_at        TIMESTAMPTZ,
    revoked_at         TIMESTAMPTZ,
    session_expires_at TIMESTAMPTZ,
    battery_at_join    SMALLINT,
    powerbank_attested BOOLEAN NOT NULL DEFAULT false,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (sector_id, device_id)
);

-- Short numeric codes are brute-forceable by design. The real control is the
-- Lead approval gate; expiry and use caps mitigate the rest.
CREATE TABLE join_codes (
    code       TEXT PRIMARY KEY,
    sector_id  UUID NOT NULL REFERENCES sectors(id) ON DELETE CASCADE,
    created_by UUID NOT NULL REFERENCES users(id),
    expires_at TIMESTAMPTZ NOT NULL,
    max_uses   INT,
    uses       INT NOT NULL DEFAULT 0,
    revoked_at TIMESTAMPTZ
);

-- ===========================================================================
-- Telemetry
-- ===========================================================================

CREATE TABLE track_segments (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sector_id          UUID NOT NULL REFERENCES sectors(id) ON DELETE CASCADE,
    device_id          UUID NOT NULL REFERENCES devices(id),
    user_id            UUID NOT NULL REFERENCES users(id),
    movement_mode      TEXT NOT NULL,
    started_at         TIMESTAMPTZ NOT NULL,
    ended_at           TIMESTAMPTZ,
    point_count        INT NOT NULL DEFAULT 0,
    path               geography(LineString,4326),
    swath              geography(Polygon,4326),
    is_valid           BOOLEAN NOT NULL DEFAULT true,
    invalidated_by     UUID REFERENCES users(id),
    invalidated_reason TEXT,
    plausibility_flags TEXT[] NOT NULL DEFAULT '{}'
);

CREATE TABLE track_points (
    id            BIGSERIAL PRIMARY KEY,
    segment_id    UUID REFERENCES track_segments(id) ON DELETE CASCADE,
    sector_id     UUID NOT NULL REFERENCES sectors(id) ON DELETE CASCADE,
    device_id     UUID NOT NULL REFERENCES devices(id),
    geom          geography(Point,4326) NOT NULL,
    recorded_at   TIMESTAMPTZ NOT NULL,   -- device clock. UNTRUSTED.
    received_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    accuracy_m    REAL,
    speed_mps     REAL,
    battery_pct   SMALLINT,
    is_mocked     BOOLEAN NOT NULL DEFAULT false,
    delivery_path TEXT NOT NULL CHECK (delivery_path IN ('direct','mesh','sms')),
    hop_count     SMALLINT,
    signature     BYTEA NOT NULL CHECK (octet_length(signature) = 64)
);

-- Replay defence as a database invariant, not application logic.
CREATE UNIQUE INDEX track_points_sig_uidx     ON track_points (signature);
CREATE INDEX        track_points_geom_gix     ON track_points USING GIST (geom);
CREATE INDEX        track_points_seg_time_idx ON track_points (segment_id, recorded_at);

-- ===========================================================================
-- Coverage: immutable ledger + derived state
-- ===========================================================================

CREATE TABLE hex_contributions (
    id                 BIGSERIAL PRIMARY KEY,
    sector_id          UUID NOT NULL REFERENCES sectors(id) ON DELETE CASCADE,
    hex_id             BIGINT NOT NULL,
    user_id            UUID NOT NULL REFERENCES users(id),
    device_id          UUID NOT NULL REFERENCES devices(id),
    segment_id         UUID NOT NULL REFERENCES track_segments(id) ON DELETE CASCADE,
    segment_started_at TIMESTAMPTZ NOT NULL,  -- ranking key: real time, not arrival
    base_pod           NUMERIC(4,3) NOT NULL,
    is_valid           BOOLEAN NOT NULL DEFAULT true,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- One traverse episode = one contribution, whether the device emitted
    -- 3 points or 600. This is what stops a stationary phone from driving a
    -- hex to POD 0.99999. Enforced by the database, not by application code.
    UNIQUE (hex_id, segment_id)
);
CREATE INDEX hex_contrib_lookup_idx  ON hex_contributions (sector_id, hex_id) WHERE is_valid;
CREATE INDEX hex_contrib_segment_idx ON hex_contributions (segment_id);

-- Note the absence of `discount_factor`: a stored discount goes stale the
-- moment a contribution is retracted. Rank is derived at recalc time.
CREATE TABLE hex_coverage_state (
    sector_id            UUID NOT NULL REFERENCES sectors(id) ON DELETE CASCADE,
    hex_id               BIGINT NOT NULL,
    cumulative_pod       NUMERIC(5,4) NOT NULL DEFAULT 0,
    valid_contributions  INT NOT NULL DEFAULT 0,
    distinct_searchers   INT NOT NULL DEFAULT 0,
    last_contribution_at TIMESTAMPTZ,
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (sector_id, hex_id)
);

CREATE OR REPLACE FUNCTION recalc_hex_coverage(p_sector_id UUID, p_hexes BIGINT[])
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
    v_discount NUMERIC;
    v_rows     INT;
BEGIN
    SELECT repeat_discount INTO v_discount FROM sectors WHERE id = p_sector_id;

    WITH target AS (
        SELECT DISTINCT unnest(p_hexes) AS hex_id
    ),
    -- Rank each user's passes over each hex by real time, valid rows only.
    -- Retracting pass #1 correctly promotes pass #2 to full weight.
    ranked AS (
        SELECT c.hex_id, c.user_id, c.base_pod, c.segment_started_at,
               ROW_NUMBER() OVER (PARTITION BY c.hex_id, c.user_id
                                  ORDER BY c.segment_started_at, c.id) AS pass_ordinal
        FROM hex_contributions c
        JOIN target t USING (hex_id)
        WHERE c.sector_id = p_sector_id AND c.is_valid
    ),
    weighted AS (
        SELECT hex_id, user_id, segment_started_at,
               LEAST(base_pod * POWER(v_discount, pass_ordinal - 1), 0.99) AS pod
        FROM ranked
    ),
    -- Search theory: POD_total = 1 - PRODUCT(1 - POD_i), computed in log space.
    agg AS (
        SELECT hex_id,
               1 - exp(sum(ln(1 - pod))) AS cumulative_pod,
               count(*)                  AS valid_contributions,
               count(DISTINCT user_id)   AS distinct_searchers,
               max(segment_started_at)   AS last_contribution_at
        FROM weighted GROUP BY hex_id
    ),
    final AS (
        SELECT t.hex_id,
               COALESCE(a.cumulative_pod, 0)      AS cumulative_pod,
               COALESCE(a.valid_contributions, 0) AS valid_contributions,
               COALESCE(a.distinct_searchers, 0)  AS distinct_searchers,
               a.last_contribution_at
        FROM target t
        LEFT JOIN agg a USING (hex_id)   -- fully-retracted hexes reset to 0
    )
    INSERT INTO hex_coverage_state AS s
        (sector_id, hex_id, cumulative_pod, valid_contributions,
         distinct_searchers, last_contribution_at, updated_at)
    SELECT p_sector_id, hex_id, cumulative_pod, valid_contributions,
           distinct_searchers, last_contribution_at, now()
    FROM final
    ON CONFLICT (sector_id, hex_id) DO UPDATE SET
        cumulative_pod       = EXCLUDED.cumulative_pod,
        valid_contributions  = EXCLUDED.valid_contributions,
        distinct_searchers   = EXCLUDED.distinct_searchers,
        last_contribution_at = EXCLUDED.last_contribution_at,
        updated_at           = now();

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows;
END $$;

-- ===========================================================================
-- Reports and presence
-- ===========================================================================

CREATE TABLE reports (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sector_id        UUID NOT NULL REFERENCES sectors(id) ON DELETE CASCADE,
    device_id        UUID NOT NULL REFERENCES devices(id),
    user_id          UUID NOT NULL REFERENCES users(id),
    kind             TEXT NOT NULL CHECK (kind IN
                       ('subject_found','medical','item_found','hazard','no_passage')),
    geom             geography(Point,4326) NOT NULL,
    note             TEXT,
    photo_object_key TEXT,
    recorded_at      TIMESTAMPTZ NOT NULL,
    received_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    delivery_path    TEXT NOT NULL,
    hop_count        SMALLINT,
    signature        BYTEA NOT NULL UNIQUE CHECK (octet_length(signature) = 64),
    acknowledged_by  UUID REFERENCES users(id),
    acknowledged_at  TIMESTAMPTZ,   -- Command Post saw it
    ack_delivered_at TIMESTAMPTZ,   -- originating device confirmed the Ack
    status           TEXT NOT NULL DEFAULT 'open'
);
CREATE INDEX reports_sector_idx ON reports (sector_id, received_at DESC);

CREATE TABLE device_presence (
    sector_id          UUID NOT NULL REFERENCES sectors(id) ON DELETE CASCADE,
    device_id          UUID NOT NULL REFERENCES devices(id),
    last_point_at      TIMESTAMPTZ,
    last_geom          geography(Point,4326),
    last_battery_pct   SMALLINT,
    last_delivery_path TEXT,
    presence_state     TEXT NOT NULL DEFAULT 'active'
                         CHECK (presence_state IN
                           ('active','stale','dead_zone','battery_dead','mia')),
    state_changed_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (sector_id, device_id)
);
