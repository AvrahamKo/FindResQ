-- Phase 1: authentication and device-key enrolment.
-- Depends on 0001_init.sql (users, devices).

-- ---------------------------------------------------------------------------
-- OTP challenges. Codes are stored salted+hashed, never in plaintext.
-- ---------------------------------------------------------------------------
CREATE TABLE otp_challenges (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    phone_e164  TEXT        NOT NULL,
    salt        BYTEA       NOT NULL,
    code_hash   BYTEA       NOT NULL,
    attempts    SMALLINT    NOT NULL DEFAULT 0,
    expires_at  TIMESTAMPTZ NOT NULL,
    consumed_at TIMESTAMPTZ,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX otp_challenges_phone_idx
    ON otp_challenges (phone_e164, created_at DESC);

-- ---------------------------------------------------------------------------
-- Device key-enrolment challenges (proof of possession).
--
-- Without this, anyone could register someone else's Ed25519 PUBLIC key under
-- their own account. They still could not forge that device's packets -- but
-- the server would attribute the victim's genuine, correctly-signed telemetry
-- to the attacker's user. That is an attribution attack on the coverage map,
-- and the coverage map is the product. So: prove possession of the private key
-- before the public key is bound to a user.
-- ---------------------------------------------------------------------------
CREATE TABLE device_key_challenges (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    nonce       BYTEA       NOT NULL,
    expires_at  TIMESTAMPTZ NOT NULL,
    consumed_at TIMESTAMPTZ,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX device_key_challenges_user_idx
    ON device_key_challenges (user_id, created_at DESC);

-- Useful for the "reinstall on the same handset" path in Phase 2.
ALTER TABLE devices ADD COLUMN IF NOT EXISTS label TEXT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS last_seen_at TIMESTAMPTZ;
