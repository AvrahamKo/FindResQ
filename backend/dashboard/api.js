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

  getHexes: (sectorId) => request("GET", `/sectors/${sectorId}/hexes`),
  getPresence: (sectorId) => request("GET", `/sectors/${sectorId}/presence`),
  getSos: (sectorId) => request("GET", `/sectors/${sectorId}/sos`),
  acknowledgeSos: (alertId) => request("POST", `/sos/${alertId}/acknowledge`),
  resolveSos: (alertId) => request("POST", `/sos/${alertId}/resolve`),

  getReports: (sectorId) => request("GET", `/sectors/${sectorId}/reports`),
  acknowledgeReport: (reportId) => request("POST", `/reports/${reportId}/acknowledge`),

  createWsTicket: (eventId) => request("POST", `/events/${eventId}/ws-ticket`),
};
