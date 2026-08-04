// REST client for the LifeSearch backend. Same-origin (served by FastAPI's
// static mount), so no base URL configuration is needed.

const TOKEN_KEY = "lifesearch_dashboard_token";

export function getToken() {
  return localStorage.getItem(TOKEN_KEY);
}

export function setToken(token) {
  if (token) localStorage.setItem(TOKEN_KEY, token);
  else localStorage.removeItem(TOKEN_KEY);
}

export class ApiError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

async function request(method, path, { body, auth = true } = {}) {
  const headers = { "Content-Type": "application/json" };
  if (auth) {
    const token = getToken();
    if (token) headers.Authorization = `Bearer ${token}`;
  }
  const res = await fetch(path, {
    method,
    headers,
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });

  if (res.status === 204) return null;
  const data = await res.json().catch(() => null);

  if (!res.ok) {
    const err = (data && data.error) || {};
    throw new ApiError(res.status, err.code || "unknown", err.message || res.statusText);
  }
  return data;
}

export const api = {
  requestOtp: (phone_e164) =>
    request("POST", "/auth/otp/request", { body: { phone_e164 }, auth: false }),
  verifyOtp: (challenge_id, code, display_name) =>
    request("POST", "/auth/otp/verify", {
      body: { challenge_id, code, display_name },
      auth: false,
    }),
  me: () => request("GET", "/auth/me"),

  listEvents: () => request("GET", "/events"),
  createEvent: (name) => request("POST", "/events", { body: { name } }),
  getEvent: (eventId) => request("GET", `/events/${eventId}`),
  startEvent: (eventId) => request("POST", `/events/${eventId}/start`),

  // --- Subject (missing person) ------------------------------------------
  // Commander-only, both directions. "No subject recorded yet" is a 404, not
  // an empty body, so it is normalised to null here -- it is an ordinary
  // state (an event can be spun up before the subject details are known),
  // not an error the UI should surface as one.
  getSubject: async (eventId) => {
    try {
      return await request("GET", `/events/${eventId}/subject`);
    } catch (e) {
      if (e instanceof ApiError && e.status === 404) return null;
      throw e;
    }
  },
  // PUT is a true UPSERT that overwrites EVERY column (see
  // subjects_repo.upsert's ON CONFLICT ... DO UPDATE). Any field omitted
  // here is written as NULL, so callers must send the full record, not a
  // patch -- the form is always prefilled from the current values for
  // exactly this reason. `retention_days` also RESETS the purge deadline on
  // every save.
  upsertSubject: (eventId, subject) =>
    request("PUT", `/events/${eventId}/subject`, { body: subject }),

  listSectors: (eventId) => request("GET", `/events/${eventId}/sectors`),
  createSector: (eventId, name, boundary) =>
    request("POST", `/events/${eventId}/sectors`, { body: { name, boundary } }),
  // 'closed' is excluded server-side -- that's set by event teardown, not
  // this toggle. Independent of the event's own draft/active status: an
  // 'open' sector still rejects joins if its event was never started.
  updateSectorStatus: (sectorId, status) =>
    request("PATCH", `/sectors/${sectorId}`, { body: { status } }),

  // No GET /sectors/{id}/join-codes exists server-side -- codes are
  // ephemeral by design (default 12h TTL, see JoinCodeCreate), so the
  // dashboard can only ever know about a code it just created itself.
  createJoinCode: (sectorId) =>
    request("POST", `/sectors/${sectorId}/join-codes`, { body: {} }),
  revokeJoinCode: (sectorId, code) =>
    request("DELETE", `/sectors/${sectorId}/join-codes/${code}`),

  // Actual routes are /sectors/{id}/memberships (not /members) and
  // /memberships/{id}/approve|reject (membership id, not user id) -- see
  // app/api/routes/memberships.py. No membership_delta over the WS socket
  // exists (only hex/presence/sos/report do), so the dashboard has to poll
  // this, same convention as the mobile app's own Lead/Commander screens.
  listMemberships: (sectorId, statusFilter) =>
    request(
      "GET",
      `/sectors/${sectorId}/memberships${statusFilter ? `?status_filter=${statusFilter}` : ""}`
    ),
  approveMembership: (membershipId) => request("POST", `/memberships/${membershipId}/approve`),
  rejectMembership: (membershipId) => request("POST", `/memberships/${membershipId}/reject`),
  // Revoke ends an APPROVED membership (409s on any other status). It does
  // not re-key the sector -- the removed device keeps the sector key until
  // the epoch is bumped -- but its next request fails the membership check.
  revokeMembership: (membershipId) => request("POST", `/memberships/${membershipId}/revoke`),

  // COMMANDER-ONLY (require_commander, not lead-or-commander), and the target
  // must already hold an approved membership in this sector -- promotion runs
  // through the same join+approve path as any volunteer, this only elevates.
  // Demotes whoever currently leads the sector in the same transaction.
  assignLead: (sectorId, userId) =>
    request("POST", `/sectors/${sectorId}/lead`, { body: { user_id: userId } }),

  getHexes: (sectorId) => request("GET", `/sectors/${sectorId}/hexes`),
  getPresence: (sectorId) => request("GET", `/sectors/${sectorId}/presence`),
  getSos: (sectorId) => request("GET", `/sectors/${sectorId}/sos`),
  acknowledgeSos: (alertId) => request("POST", `/sos/${alertId}/acknowledge`),
  resolveSos: (alertId) => request("POST", `/sos/${alertId}/resolve`),

  getReports: (sectorId) => request("GET", `/sectors/${sectorId}/reports`),
  acknowledgeReport: (reportId) => request("POST", `/reports/${reportId}/acknowledge`),

  createWsTicket: (eventId) => request("POST", `/events/${eventId}/ws-ticket`),
};
