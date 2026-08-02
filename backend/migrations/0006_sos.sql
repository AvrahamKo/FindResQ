-- Phase 6: SOS state machine.
--
-- A searcher-triggered distress signal -- explicit and immediate, unlike
-- Phase 4's passive correlated-silence presence heuristic (that's an
-- inference from a device going quiet; this is an affirmative "I need help
-- now" action). States:
--
--   active -> acknowledged -> resolved
--      \-----------------------^
--   active -> cancelled                 (only the triggering user: false alarm)
--   acknowledged -> cancelled           (still only the triggering user)
--
-- Realtime broadcast follows the exact same pattern as hex_coverage_state/
-- device_presence (migration 0005): an AFTER INSERT OR UPDATE trigger
-- notifies with just the sector_id, and the listener re-queries "what
-- changed since my checkpoint" rather than trusting the NOTIFY payload to
-- carry the delta.

CREATE TABLE sos_alerts (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sector_id       UUID NOT NULL REFERENCES sectors(id) ON DELETE CASCADE,
    device_id       UUID NOT NULL REFERENCES devices(id),
    user_id         UUID NOT NULL REFERENCES users(id),
    status          TEXT NOT NULL DEFAULT 'active'
                      CHECK (status IN ('active','acknowledged','resolved','cancelled')),
    geom            geography(Point,4326),
    triggered_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    acknowledged_at TIMESTAMPTZ,
    acknowledged_by UUID REFERENCES users(id),
    resolved_at     TIMESTAMPTZ,
    resolved_by     UUID REFERENCES users(id),
    cancelled_at    TIMESTAMPTZ,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX sos_alerts_sector_status_idx  ON sos_alerts (sector_id, status);
CREATE INDEX sos_alerts_sector_updated_idx ON sos_alerts (sector_id, updated_at);

-- At most one OPEN (active/acknowledged) alert per device. A second SOS
-- trigger while one is already open must never fork into a duplicate
-- incident -- the route layer treats this as "hand back the existing one",
-- not an error, but the database enforces it can never happen even under a
-- race between two near-simultaneous requests.
CREATE UNIQUE INDEX sos_alerts_one_open_per_device
    ON sos_alerts (device_id)
    WHERE status IN ('active', 'acknowledged');

CREATE OR REPLACE FUNCTION notify_sos_change() RETURNS TRIGGER AS $$
BEGIN
    PERFORM pg_notify('sector_sos_channel', NEW.sector_id::text);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER sos_alerts_notify
    AFTER INSERT OR UPDATE ON sos_alerts
    FOR EACH ROW EXECUTE FUNCTION notify_sos_change();
