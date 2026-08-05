import { api, getToken } from "./api.js";

// Field simulator: virtual units walking real paths, pushing REAL encrypted
// telemetry through the REAL /ingest endpoint.
//
// This file contains no cryptography by design. Packet signing/encryption
// lives in the backend's dev_sim router so it reuses `wire_format.pack` and
// `mesh_crypto.encrypt` -- the exact functions the ingest pipeline decodes
// with. A JS reimplementation would be a third copy of the wire format with
// nothing holding it to the other two. Here the flow is:
//
//   POST /dev/sim/units/{id}/encode-points  -> opaque base64 blobs
//   POST /ingest  (Bearer <unit session token>, {blobs})   <- the real thing
//
// so the request that reaches the pipeline is byte-for-byte the shape the
// mobile app sends, including auth.

const UNIT_COLORS = [
  "#3fa9f5", "#e67e22", "#2ecc71", "#e91e63",
  "#9b59b6", "#f1c40f", "#1abc9c", "#e74c3c",
];

/// Emit a point once the unit has covered this much ground. Mirrors the
/// mobile app's distance-filtered sampling (LocationSamplingPolicy's high
/// tier) rather than a fixed timer -- a stationary searcher should produce
/// no telemetry, and the pipeline's segmentation expects that spacing.
const SAMPLE_DISTANCE_M = 10;

const TICK_MS = 1000;

const state = {
  units: new Map(),
  selectedUnitId: null,
  playing: false,
  speedKmh: 5, // realistic walking pace
  sectorId: null,
  sectorName: null,
  timer: null,
  stats: { sent: 0, accepted: 0, rejected: 0, failed: 0, hexes: 0 },
};

let map;
const root = document.getElementById("app");

// --- helpers ---------------------------------------------------------------

function log(message, cls = "") {
  const el = document.getElementById("sim-log");
  if (!el) return;
  const time = new Date().toLocaleTimeString();
  const line = document.createElement("div");
  if (cls) line.className = cls;
  line.textContent = `${time}  ${message}`;
  el.appendChild(line);
  el.scrollTop = el.scrollHeight;
  while (el.childElementCount > 300) el.removeChild(el.firstChild);
}

function esc(s) {
  const d = document.createElement("div");
  d.textContent = s ?? "";
  return d.innerHTML;
}

/// Cumulative distances along a polyline, so a unit's position at "N metres
/// travelled" is a lookup rather than a re-walk of the whole path each tick.
function pathMetrics(latlngs) {
  const cum = [0];
  for (let i = 1; i < latlngs.length; i++) {
    cum.push(cum[i - 1] + latlngs[i - 1].distanceTo(latlngs[i]));
  }
  return { cum, total: cum[cum.length - 1] || 0 };
}

/// Position at `distance` metres along the path. Linear interpolation in
/// lat/lng is accurate enough here: segments are tens of metres, far below
/// the scale where great-circle curvature matters.
function pointAtDistance(latlngs, cum, distance) {
  if (latlngs.length === 0) return null;
  if (distance <= 0) return latlngs[0];
  const total = cum[cum.length - 1];
  if (distance >= total) return latlngs[latlngs.length - 1];

  let i = 1;
  while (i < cum.length && cum[i] < distance) i++;
  const segStart = latlngs[i - 1];
  const segEnd = latlngs[i];
  const segLen = cum[i] - cum[i - 1];
  const t = segLen === 0 ? 0 : (distance - cum[i - 1]) / segLen;
  return L.latLng(
    segStart.lat + (segEnd.lat - segStart.lat) * t,
    segStart.lng + (segEnd.lng - segStart.lng) * t,
  );
}

// --- layout ----------------------------------------------------------------

function render() {
  root.innerHTML = `
    <div class="sim-banner">
      <span>&#9888; DEV SIMULATOR &mdash; generates synthetic field traffic against the real pipeline</span>
      <span class="spacer"></span>
      <a href="index.html">Open Commander Dashboard &rarr;</a>
    </div>
    <div class="top-bar">
      <div class="title">Field Simulator</div>
      <span id="sector-label" class="event-status-label status-draft">no sector</span>
      <div class="spacer"></div>
      <span id="conn-note" style="font-size:12px;color:var(--text-dim)"></span>
    </div>
    <div class="sim-layout">
      <div class="sim-panel">
        <h2>1. Target sector</h2>
        <div class="sim-row">
          <select id="event-select"><option value="">Loading events…</option></select>
        </div>
        <div class="sim-row">
          <select id="sector-select"><option value="">Pick an event first</option></select>
        </div>

        <h2>2. Units</h2>
        <div class="sim-row">
          <input id="unit-name" placeholder="Callsign, e.g. Alpha" />
          <button id="add-unit">Add</button>
        </div>
        <div id="unit-list"></div>

        <h2>3. Playback</h2>
        <div class="playback">
          <button id="play-btn">&#9654; Play</button>
          <button class="secondary" id="reset-btn">Reset</button>
        </div>
        <div class="playback" style="margin-top:8px">
          <label for="speed">Speed</label>
          <input type="range" id="speed" min="1" max="40" step="1" value="5" />
          <span id="speed-label" class="geo-readout">5 km/h</span>
        </div>
        <div class="panel-hint" style="margin-top:6px">
          Select a unit, then click the map to lay its route. Points are sent
          every ${SAMPLE_DISTANCE_M}m of travel, matching the app's
          distance-filtered sampling.
        </div>

        <h2>Ingest stats</h2>
        <div class="stat-grid" id="stats"></div>

        <h2>Activity</h2>
        <div class="sim-log" id="sim-log"></div>
        <div class="sim-row" style="margin-top:8px">
          <button class="danger" id="cleanup">Delete all sim units + data</button>
        </div>
      </div>
      <div id="sim-map"></div>
    </div>
  `;

  map = L.map("sim-map", { zoomAnimation: false }).setView([31.52, 34.77], 14);
  L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
    attribution: "&copy; OpenStreetMap contributors",
    maxZoom: 19,
  }).addTo(map);

  map.on("click", (e) => {
    const unit = state.units.get(state.selectedUnitId);
    if (!unit) {
      log("Select a unit before laying a route.", "dim");
      return;
    }
    unit.path.push(e.latlng);
    redrawUnitPath(unit);
    renderUnits();
  });

  document.getElementById("add-unit").addEventListener("click", addUnit);
  document.getElementById("play-btn").addEventListener("click", togglePlay);
  document.getElementById("reset-btn").addEventListener("click", resetPlayback);
  document.getElementById("cleanup").addEventListener("click", cleanup);
  document.getElementById("speed").addEventListener("input", (e) => {
    state.speedKmh = Number(e.target.value);
    document.getElementById("speed-label").textContent = `${state.speedKmh} km/h`;
  });
  document.getElementById("event-select").addEventListener("change", onEventChange);
  document.getElementById("sector-select").addEventListener("change", onSectorChange);

  renderStats();
}

// --- sector selection ------------------------------------------------------

async function loadEvents() {
  const select = document.getElementById("event-select");
  try {
    const events = await api.listEvents();
    if (events.length === 0) {
      select.innerHTML = '<option value="">No events — create one in the dashboard</option>';
      return;
    }
    select.innerHTML =
      '<option value="">Select an event…</option>' +
      events.map((e) => `<option value="${e.id}">${esc(e.name)} (${e.status})</option>`).join("");
  } catch (e) {
    select.innerHTML = '<option value="">Not logged in</option>';
    document.getElementById("conn-note").textContent =
      "Log in via the Commander Dashboard first — this page reuses that session.";
    log(`Could not load events: ${e.message}`, "err");
  }
}

async function onEventChange(e) {
  const eventId = e.target.value;
  const select = document.getElementById("sector-select");
  state.sectorId = null;
  if (!eventId) {
    select.innerHTML = '<option value="">Pick an event first</option>';
    return;
  }
  const sectors = await api.listSectors(eventId).catch(() => []);
  if (sectors.length === 0) {
    select.innerHTML = '<option value="">No sectors — draw one in the dashboard</option>';
    return;
  }
  select.innerHTML =
    '<option value="">Select a sector…</option>' +
    sectors.map((s) => `<option value="${s.id}">${esc(s.name)}</option>`).join("");
  window.__sectors = sectors;
}

function onSectorChange(e) {
  state.sectorId = e.target.value || null;
  const sector = (window.__sectors || []).find((s) => s.id === state.sectorId);
  state.sectorName = sector ? sector.name : null;
  const label = document.getElementById("sector-label");
  label.textContent = state.sectorName || "no sector";
  label.className = `event-status-label ${state.sectorId ? "status-active" : "status-draft"}`;

  if (!sector) return;
  // Draw the sector so routes can be laid inside it, and frame the map on it.
  if (window.__sectorLayer) map.removeLayer(window.__sectorLayer);
  window.__sectorLayer = L.geoJSON(sector.boundary, {
    style: { color: "#8b95a1", weight: 2, dashArray: "5 5", fillOpacity: 0.04 },
    interactive: false,
  }).addTo(map);
  const bounds = window.__sectorLayer.getBounds();
  if (bounds.isValid()) map.fitBounds(bounds, { padding: [40, 40] });
  log(`Target sector: ${sector.name}`);
}

// --- units -----------------------------------------------------------------

async function addUnit() {
  if (!state.sectorId) {
    alert("Pick a target sector first.");
    return;
  }
  const input = document.getElementById("unit-name");
  const name = input.value.trim() || `Unit ${state.units.size + 1}`;
  const btn = document.getElementById("add-unit");
  btn.disabled = true;
  try {
    const res = await fetch("/dev/sim/units", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name, sector_id: state.sectorId, movement_mode: "walker" }),
    });
    if (!res.ok) throw new Error((await res.json()).error?.message || res.statusText);
    const unit = await res.json();

    const color = UNIT_COLORS[state.units.size % UNIT_COLORS.length];
    state.units.set(unit.unit_id, {
      ...unit,
      color,
      path: [],
      pathLayer: null,
      marker: null,
      travelled: 0,
      lastSentAt: -Infinity,
      pointsSent: 0,
      metrics: { cum: [0], total: 0 },
    });
    state.selectedUnitId = unit.unit_id;
    input.value = "";
    renderUnits();
    log(`Unit "${name}" provisioned (device ${unit.device_id.slice(0, 8)})`, "ok");
  } catch (e) {
    log(`Failed to create unit: ${e.message}`, "err");
    alert(`Failed to create unit: ${e.message}`);
  } finally {
    btn.disabled = false;
  }
}

function redrawUnitPath(unit) {
  if (unit.pathLayer) map.removeLayer(unit.pathLayer);
  if (unit.path.length >= 2) {
    unit.pathLayer = L.polyline(unit.path, {
      color: unit.color, weight: 3, opacity: 0.75, dashArray: "6 5",
    }).addTo(map);
  } else if (unit.path.length === 1) {
    unit.pathLayer = L.circleMarker(unit.path[0], {
      radius: 4, color: unit.color, fillOpacity: 1,
    }).addTo(map);
  } else {
    unit.pathLayer = null;
  }
  unit.metrics = pathMetrics(unit.path);
}

function moveUnitMarker(unit, latlng) {
  if (!unit.marker) {
    unit.marker = L.marker(latlng, {
      icon: L.divIcon({
        className: "",
        html: `<div class="sim-unit-marker">
                 <span class="sim-unit-dot" style="background:${unit.color}"></span>
                 <span class="sim-unit-label">${esc(unit.name)}</span>
               </div>`,
        iconSize: [0, 0],
      }),
    }).addTo(map);
  } else {
    unit.marker.setLatLng(latlng);
  }
}

function renderUnits() {
  const el = document.getElementById("unit-list");
  if (state.units.size === 0) {
    el.innerHTML = '<div class="empty-hint">No units yet.</div>';
    return;
  }
  el.innerHTML = "";
  for (const unit of state.units.values()) {
    const card = document.createElement("div");
    card.className = `unit-card${unit.unit_id === state.selectedUnitId ? " selected" : ""}`;
    card.style.borderLeftColor = unit.color;
    card.innerHTML = `
      <div class="unit-head">
        <span class="sim-unit-dot" style="background:${unit.color}"></span>
        <span class="unit-name">${esc(unit.name)}</span>
      </div>
      <div class="unit-meta">
        ${unit.path.length} waypoint(s) &middot; ${Math.round(unit.metrics.total)}m route
        &middot; ${unit.pointsSent} pts sent
      </div>
      <div class="unit-actions"></div>
    `;
    card.querySelector(".unit-name").addEventListener("click", () => {
      state.selectedUnitId = unit.unit_id;
      renderUnits();
    });

    const actions = card.querySelector(".unit-actions");
    const act = (label, cls, fn) => {
      const b = document.createElement("button");
      b.className = cls;
      b.textContent = label;
      b.addEventListener("click", fn);
      actions.appendChild(b);
    };
    act("Clear route", "secondary", () => {
      unit.path = [];
      unit.travelled = 0;
      redrawUnitPath(unit);
      renderUnits();
    });
    act("Breadcrumb", "secondary", () => sendBreadcrumb(unit));
    act("Hazard", "secondary", () => sendReport(unit, "hazard", "Simulated hazard"));
    act("Subject", "secondary", () => sendReport(unit, "subject_found", "Simulated subject sighting"));
    act("SOS", "danger", () => sendSos(unit));

    el.appendChild(card);
  }
}

// --- the real ingest path --------------------------------------------------

/// Encode in Python (real crypto), then POST to the REAL /ingest with the
/// unit's real session token.
async function pushPoints(unit, points) {
  const encoded = await fetch(`/dev/sim/units/${unit.unit_id}/encode-points`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ points }),
  });
  if (!encoded.ok) {
    throw new Error((await encoded.json()).error?.message || "encode failed");
  }
  const { blobs, session_token } = await encoded.json();

  const ingest = await fetch("/ingest", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${session_token}`,
    },
    body: JSON.stringify({ blobs }),
  });
  if (!ingest.ok) {
    throw new Error((await ingest.json()).error?.message || "ingest failed");
  }
  return ingest.json();
}

async function flush(unit, points) {
  state.stats.sent += points.length;
  try {
    const result = await pushPoints(unit, points);
    state.stats.accepted += result.accepted;
    const rejected =
      result.duplicate + result.decrypt_failed + result.signature_invalid +
      result.wrong_device + result.malformed;
    state.stats.rejected += rejected;
    // hexes_touched is the number that actually matters: points can be
    // "accepted" (stored) yet contribute nothing to coverage if the
    // plausibility stage judged the fix untrustworthy. Note this is a sum of
    // PER-REQUEST touches, so consecutive points re-touching the same cell
    // count each time -- it is a "coverage is happening" signal, not the
    // distinct hex count (query hex_coverage_state for that).
    state.stats.hexes += result.hexes_touched;
    unit.pointsSent += points.length;
    if (rejected) {
      log(`${unit.name}: ${result.accepted} accepted, ${rejected} rejected ${JSON.stringify(result)}`, "dim");
    }
  } catch (e) {
    state.stats.failed += points.length;
    log(`${unit.name}: ingest failed — ${e.message}`, "err");
  }
  renderStats();
  renderUnits();
}

async function sendBreadcrumb(unit) {
  const pos = unit.marker ? unit.marker.getLatLng() : unit.path[0];
  if (!pos) {
    log(`${unit.name}: no position yet — lay a route first.`, "dim");
    return;
  }
  await flush(unit, [{ lat: pos.lat, lng: pos.lng, accuracy_m: 5, speed_mps: 0 }]);
  log(`${unit.name}: manual breadcrumb at ${pos.lat.toFixed(5)}, ${pos.lng.toFixed(5)}`);
}

async function sendReport(unit, kind, note) {
  const pos = unit.marker ? unit.marker.getLatLng() : unit.path[0];
  if (!pos) {
    log(`${unit.name}: no position yet.`, "dim");
    return;
  }
  try {
    const encoded = await fetch(`/dev/sim/units/${unit.unit_id}/encode-report`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ kind, lat: pos.lat, lng: pos.lng, note }),
    });
    if (!encoded.ok) throw new Error((await encoded.json()).error?.message || "encode failed");
    const { blobs, session_token } = await encoded.json();

    const res = await fetch("/reports", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${session_token}` },
      body: JSON.stringify({ blobs }),
    });
    if (!res.ok) throw new Error((await res.json()).error?.message || "report failed");
    log(`${unit.name}: ${kind} report filed`, "ok");
  } catch (e) {
    log(`${unit.name}: report failed — ${e.message}`, "err");
  }
}

async function sendSos(unit) {
  const pos = unit.marker ? unit.marker.getLatLng() : unit.path[0];
  try {
    const res = await fetch("/sos", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${unit.session_token}` },
      body: JSON.stringify(pos ? { lat: pos.lat, lng: pos.lng } : {}),
    });
    if (!res.ok) throw new Error((await res.json()).error?.message || "sos failed");
    log(`${unit.name}: SOS TRIGGERED`, "err");
  } catch (e) {
    log(`${unit.name}: SOS failed — ${e.message}`, "err");
  }
}

// --- playback --------------------------------------------------------------

function togglePlay() {
  state.playing = !state.playing;
  document.getElementById("play-btn").innerHTML = state.playing ? "&#10073;&#10073; Pause" : "&#9654; Play";
  if (state.playing) {
    state.timer = setInterval(tick, TICK_MS);
    log(`Playback started at ${state.speedKmh} km/h`);
  } else {
    clearInterval(state.timer);
    state.timer = null;
    log("Playback paused");
  }
}

function resetPlayback() {
  if (state.playing) togglePlay();
  for (const unit of state.units.values()) {
    unit.travelled = 0;
    unit.lastSentAt = -Infinity;
    if (unit.path.length) moveUnitMarker(unit, unit.path[0]);
  }
  log("Playback reset to route start");
}

/// One second of simulated time per tick, scaled by the speed control.
function tick() {
  const metresPerTick = (state.speedKmh * 1000 / 3600) * (TICK_MS / 1000);

  for (const unit of state.units.values()) {
    if (unit.path.length < 2) continue;
    if (unit.travelled >= unit.metrics.total) continue;

    unit.travelled = Math.min(unit.travelled + metresPerTick, unit.metrics.total);
    const pos = pointAtDistance(unit.path, unit.metrics.cum, unit.travelled);
    if (!pos) continue;
    moveUnitMarker(unit, pos);

    // Distance-filtered emission, exactly like the mobile app: a unit that
    // has not covered SAMPLE_DISTANCE_M since its last fix sends nothing.
    if (unit.travelled - unit.lastSentAt >= SAMPLE_DISTANCE_M) {
      unit.lastSentAt = unit.travelled;
      flush(unit, [{
        lat: pos.lat,
        lng: pos.lng,
        accuracy_m: 4 + Math.random() * 4,
        speed_mps: state.speedKmh / 3.6,
        battery_pct: 85,
      }]);
    }

    if (unit.travelled >= unit.metrics.total) {
      log(`${unit.name}: reached end of route`, "ok");
    }
  }
}

// --- stats / cleanup -------------------------------------------------------

function renderStats() {
  const el = document.getElementById("stats");
  if (!el) return;
  const s = state.stats;
  el.innerHTML = `
    <span class="k">Points sent</span><span class="v">${s.sent}</span>
    <span class="k">Accepted</span><span class="v" style="color:var(--ok)">${s.accepted}</span>
    <span class="k">Rejected</span><span class="v" style="color:var(--warn)">${s.rejected}</span>
    <span class="k">Hex touches</span><span class="v" style="color:var(--accent)">${s.hexes}</span>
    <span class="k">Request failures</span><span class="v" style="color:var(--danger)">${s.failed}</span>
  `;
}

async function cleanup() {
  if (!confirm(
    "Delete every simulated unit and ALL data they generated?\n\n" +
    "Removes their track points, segments, coverage contributions, presence, " +
    "reports, SOS alerts, devices and users. Real volunteer data is untouched " +
    "(only rows tagged [SIM] are matched)."
  )) return;

  if (state.playing) togglePlay();
  try {
    const res = await fetch("/dev/sim/units", { method: "DELETE" });
    const body = await res.json();
    for (const unit of state.units.values()) {
      if (unit.pathLayer) map.removeLayer(unit.pathLayer);
      if (unit.marker) map.removeLayer(unit.marker);
    }
    state.units.clear();
    state.selectedUnitId = null;
    state.stats = { sent: 0, accepted: 0, rejected: 0, failed: 0, hexes: 0 };
    renderUnits();
    renderStats();
    log(`Cleanup: ${body.units_cleared} unit(s), ${body.devices_deleted} device row(s) removed`, "ok");
  } catch (e) {
    log(`Cleanup failed: ${e.message}`, "err");
  }
}

// --- boot ------------------------------------------------------------------

render();
renderUnits();
if (!getToken()) {
  document.getElementById("conn-note").textContent =
    "Not logged in — open the Commander Dashboard and sign in first.";
}
loadEvents();
