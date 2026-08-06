-- Phase 7: destructive moderation (event deletion, user removal, alert
-- clearing) and the team-track read path.
--
-- Three themes here, all of them following the same rule migration 0005
-- established: BROADCAST IS A PROPERTY OF THE DATA CHANGING, not something a
-- write path has to remember to trigger. 0005/0006 only ever needed AFTER
-- INSERT OR UPDATE triggers because nothing was ever deleted. This phase
-- deletes things, and a delta-since-checkpoint query -- which is how the
-- realtime listener learns about every other change -- structurally cannot
-- observe a row that no longer exists. So deletions get their own DELETE
-- triggers carrying the identity of what vanished, since that identity is
-- the one thing the listener can no longer look up afterwards.
--
--   1. sos_alerts   DELETE -> 'sector_sos_deleted_channel'
--   2. events       DELETE -> 'event_deleted_channel'
--   3. sector_memberships status -> revoked/ended/rejected
--                          -> 'membership_revoked_channel'
--
-- (3) is not a deletion at all -- memberships are never deleted, because
-- their historical scan data must stay attributable -- but it is the moment
-- a user loses access, and the listener turns it into an immediate WebSocket
-- disconnect rather than waiting for that user's next REST call to fail.

-- ===========================================================================
-- 1. Team scan paths: GET /sectors/{id}/tracks
-- ===========================================================================

-- The team-track query walks track_points by segment, in recorded order,
-- for every segment in one sector. `track_points_seg_time_idx` (migration
-- 0001) already covers the per-segment ordering; this covers the "which
-- segments does this sector have, newest first" half so the read does not
-- degrade into a sector-wide sequential scan once a callout has run for
-- hours.
CREATE INDEX IF NOT EXISTS track_segments_sector_started_idx
    ON track_segments (sector_id, started_at DESC);

-- ===========================================================================
-- 2. SOS alert deletion
-- ===========================================================================

-- Payload is 'sector_id:alert_id'. The sector id routes the broadcast to the
-- right dashboard; the alert id is what the client removes. Neither can be
-- recovered by re-querying after the fact, which is exactly why they ride in
-- the payload here when every other channel in this system deliberately
-- carries only a sector id.
CREATE OR REPLACE FUNCTION notify_sos_deleted() RETURNS TRIGGER AS $$
BEGIN
    PERFORM pg_notify(
        'sector_sos_deleted_channel',
        OLD.sector_id::text || ':' || OLD.id::text
    );
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS sos_alerts_notify_deleted ON sos_alerts;
CREATE TRIGGER sos_alerts_notify_deleted
    AFTER DELETE ON sos_alerts
    FOR EACH ROW EXECUTE FUNCTION notify_sos_deleted();

-- ===========================================================================
-- 3. Event deletion (cascade)
-- ===========================================================================

-- Every child table already declares ON DELETE CASCADE back to events or to
-- sectors (migration 0001), so `DELETE FROM events` is a complete purge at
-- the database layer with no application-side delete list to keep in sync.
-- This trigger exists purely so the in-memory layers -- dashboard sockets,
-- WS tickets, the listener's per-sector checkpoints -- find out, since none
-- of those are reachable from SQL.
CREATE OR REPLACE FUNCTION notify_event_deleted() RETURNS TRIGGER AS $$
BEGIN
    PERFORM pg_notify('event_deleted_channel', OLD.id::text);
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS events_notify_deleted ON events;
CREATE TRIGGER events_notify_deleted
    AFTER DELETE ON events
    FOR EACH ROW EXECUTE FUNCTION notify_event_deleted();

-- ===========================================================================
-- 4. Membership revocation -> immediate disconnect
-- ===========================================================================

-- Fires only on a real transition INTO a terminal status, so re-running an
-- idempotent revoke (or any unrelated UPDATE on the row, e.g. set_role) does
-- not spam the channel. Payload is 'sector_id:user_id'.
CREATE OR REPLACE FUNCTION notify_membership_revoked() RETURNS TRIGGER AS $$
BEGIN
    PERFORM pg_notify(
        'membership_revoked_channel',
        NEW.sector_id::text || ':' || NEW.user_id::text
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS sector_memberships_notify_revoked ON sector_memberships;
CREATE TRIGGER sector_memberships_notify_revoked
    AFTER UPDATE ON sector_memberships
    FOR EACH ROW
    WHEN (OLD.status IS DISTINCT FROM NEW.status
          AND NEW.status IN ('revoked', 'ended', 'rejected'))
    EXECUTE FUNCTION notify_membership_revoked();

-- ===========================================================================
-- 5. Re-application after rejection
-- ===========================================================================

-- No schema change is needed for the "rejected volunteer can never re-apply"
-- bug -- UNIQUE (sector_id, device_id) is the correct invariant and stays.
-- The fix is that `POST /join` now UPSERTs onto this constraint, reopening a
-- terminal row as 'pending' instead of letting the insert raise. Recorded
-- here so the constraint's role in that flow is discoverable from the
-- schema history, which is where the next person will look.
COMMENT ON CONSTRAINT sector_memberships_sector_id_device_id_key ON sector_memberships IS
    'One membership row per (sector, device). A rejected/revoked/ended row is '
    'REOPENED to pending by POST /join rather than duplicated -- see '
    'memberships_repo.create_or_reopen_pending.';
