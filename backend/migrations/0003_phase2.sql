-- Phase 2: events/sectors/join-code workflow. All core tables already exist
-- from 0001_init.sql; this migration adds the constraints and indexes Phase 2
-- code relies on.

-- One subject per event for the MVP (multi-subject searches are a v2 concern).
-- Backs the ON CONFLICT (event_id) upsert in repositories/subjects.py.
ALTER TABLE subjects ADD CONSTRAINT subjects_event_id_unique UNIQUE (event_id);

-- The Lead/Commander dashboard's "pending join requests" query filters on
-- exactly this pair.
CREATE INDEX sector_memberships_sector_status_idx
    ON sector_memberships (sector_id, status);

-- A user's own memberships, across sectors/events (join-status polling).
CREATE INDEX sector_memberships_user_idx
    ON sector_memberships (user_id, status);

-- Sector Lead's "join codes I've issued" and the redemption lookup path.
CREATE INDEX join_codes_sector_idx ON join_codes (sector_id);

-- Sectors-by-event listing (event detail screen).
CREATE INDEX sectors_event_idx ON sectors (event_id);
