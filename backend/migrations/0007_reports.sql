-- Phase 6b: field reports (subject sightings, clues, hazards).
--
-- The `reports` table itself already exists from Phase 0 (migration
-- 0001_init.sql) -- it deliberately mirrors `track_points` (Ed25519
-- `signature` UNIQUE for replay defence, `delivery_path`/`hop_count` for a
-- future mesh relay path, `recorded_at`/`received_at` split for an
-- untrusted device clock vs. server receipt time). This migration only adds
-- what Phase 0 didn't already have: an `updated_at` column (so
-- acknowledging a report, not just creating one, is visible to the
-- checkpoint-based realtime delta query) and the same NOTIFY trigger
-- pattern already used for hex_coverage_state/device_presence (0005) and
-- sos_alerts (0006).

ALTER TABLE reports ADD COLUMN updated_at TIMESTAMPTZ NOT NULL DEFAULT now();

CREATE INDEX reports_sector_updated_idx ON reports (sector_id, updated_at);

CREATE OR REPLACE FUNCTION notify_report_change() RETURNS TRIGGER AS $$
BEGIN
    PERFORM pg_notify('sector_report_channel', NEW.sector_id::text);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER reports_notify
    AFTER INSERT OR UPDATE ON reports
    FOR EACH ROW EXECUTE FUNCTION notify_report_change();
