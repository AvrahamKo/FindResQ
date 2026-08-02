-- Phase 3: ingest pipeline and coverage engine support.

-- Missing plausibility-scoring tuning parameter (Q3/stage 7): a 'walker'
-- segment whose point-to-point speed exceeds this is flagged as a likely
-- vehicle. No equivalent upper bound exists for 'vehicle' mode -- a car can
-- legitimately go highway speed, so only walkers are checked.
ALTER TABLE sectors
    ADD COLUMN max_walker_speed_mps NUMERIC(4,2) NOT NULL DEFAULT 3.0;

-- Denormalized tail of the segment's most recent point. Lets the ingest
-- pipeline decide "does this batch's first new point continue the device's
-- open segment?" with a single indexed row lookup instead of a MAX() scan
-- over track_points on every batch.
ALTER TABLE track_segments
    ADD COLUMN last_recorded_at TIMESTAMPTZ,
    ADD COLUMN last_lat DOUBLE PRECISION,
    ADD COLUMN last_lng DOUBLE PRECISION;

-- A device is physically in one place at a time: at most one open
-- (un-ended) segment per device. The ingest pipeline relies on this being
-- true rather than merely convention.
CREATE UNIQUE INDEX track_segments_open_idx
    ON track_segments (device_id) WHERE ended_at IS NULL;

-- No new index needed for wire_id lookups: `devices.wire_id` already carries
-- a UNIQUE constraint from 0001_init.sql, which Postgres backs with its own
-- index automatically.
