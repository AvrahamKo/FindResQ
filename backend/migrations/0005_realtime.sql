-- Phase 4: realtime transport for the Commander dashboard.
--
-- Broadcast is implemented as a property of the DATA changing, not something
-- every write path has to remember to trigger. `hex_coverage_state` already
-- gets bulk-UPSERTed by `recalc_hex_coverage()`; `device_presence` gets
-- upserted by ingest (raw facts) and by the periodic presence sweep (derived
-- state). Both get an AFTER INSERT OR UPDATE trigger that notifies with just
-- the sector_id -- verified empirically (not assumed) that Postgres collapses
-- identical (channel, payload) notifications fired within one transaction
-- into a single delivery, so a bulk UPSERT touching hundreds of rows for one
-- sector produces exactly one notification, not hundreds.
--
-- The realtime listener re-queries "what changed since my last checkpoint
-- for this sector" on each notification rather than trusting the payload to
-- carry the actual delta -- NOTIFY payloads are capped at 8000 bytes, and a
-- delta-since-timestamp query is self-healing against any missed/coalesced
-- notification anyway.

ALTER TABLE device_presence ADD COLUMN updated_at TIMESTAMPTZ NOT NULL DEFAULT now();

CREATE OR REPLACE FUNCTION notify_hex_coverage_change() RETURNS TRIGGER AS $$
BEGIN
    PERFORM pg_notify('sector_coverage_channel', NEW.sector_id::text);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER hex_coverage_state_notify
    AFTER INSERT OR UPDATE ON hex_coverage_state
    FOR EACH ROW EXECUTE FUNCTION notify_hex_coverage_change();

CREATE OR REPLACE FUNCTION notify_presence_change() RETURNS TRIGGER AS $$
BEGIN
    PERFORM pg_notify('sector_presence_channel', NEW.sector_id::text);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER device_presence_notify
    AFTER INSERT OR UPDATE ON device_presence
    FOR EACH ROW EXECUTE FUNCTION notify_presence_change();
