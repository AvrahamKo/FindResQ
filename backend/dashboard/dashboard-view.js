import { api } from "./api.js";
import { DashboardSocket } from "./ws.js";
import { TacticalMap, PRESENCE_COLORS, REPORT_KIND_STYLE } from "./map.js";

// The right-hand panel has two modes: an event-wide overview (nothing
// selected) and a focused single-sector management panel. Both render their
// SOS / pending / report lists into the SAME container ids, so those three
// renderers are written once and simply filter by `selectedSectorId` -- the
// alternative (separate renderers per mode) would have meant four near-copies
// of the same card-building code drifting apart over time.

export async function renderDashboard(root, { eventId, onLogout }) {
  root.innerHTML = `
    <div class="top-bar">
      <button class="secondary" id="back">&larr; Events</button>
      <div class="title" id="event-name">Loading…</div>
      <span class="event-status-label" id="event-status-label"></span>
      <button id="start-event-btn" style="display:none">Start Event</button>
      <span class="dot" id="conn-dot"></span>
      <span id="conn-label" style="font-size:12px;color:var(--text-dim)">connecting…</span>
      <div class="spacer"></div>
      <button class="secondary" id="logout">Log out</button>
    </div>
    <div class="dashboard">
      <div class="side-panel">
        <h2>Sectors</h2>
        <div id="sector-list"></div>
        <div class="draw-controls" id="draw-controls">
          <button class="secondary" id="new-sector-btn">+ New sector</button>
        </div>
        <h2>Legend</h2>
        <div id="legend"></div>
      </div>
      <div id="map"></div>
      <div class="side-panel right" id="right-panel"></div>
    </div>
  `;

  root.querySelector("#back").addEventListener("click", () => {
    location.hash = "#/events";
  });
  root.querySelector("#logout").addEventListener("click", onLogout);

  renderLegend(root.querySelector("#legend"));

  const map = new TacticalMap("map");
  const sectors = new Map(); // sectorId -> SectorOut
  const openSos = new Map(); // alertId -> { alert, sectorId }
  const pendingReports = new Map(); // reportId -> { report, sectorId }
  const membershipsBySector = new Map(); // sectorId -> MembershipOut[] (all statuses)
  const joinCodes = new Map(); // sectorId -> JoinCodeOut (only ones created THIS session -- see api.js)

  let selectedSectorId = null;
  let event = null;
  let me = null;

  // ---------- derived state ----------

  function sectorName(sectorId) {
    const s = sectors.get(sectorId);
    return s ? s.name : sectorId.slice(0, 8);
  }

  function membershipsFor(sectorId) {
    return membershipsBySector.get(sectorId) || [];
  }

  function pendingFor(sectorId) {
    return membershipsFor(sectorId).filter((m) => m.status === "pending");
  }

  function activeFor(sectorId) {
    return membershipsFor(sectorId).filter((m) => m.status === "approved");
  }

  function isCommander() {
    return !!(me && event && me.id === event.commander_id);
  }

  function inScope(sectorId) {
    return selectedSectorId === null || sectorId === selectedSectorId;
  }

  // ---------- selection ----------

  function selectSector(sectorId) {
    if (!sectors.has(sectorId)) return;
    selectedSectorId = sectorId;
    map.focusSector(sectorId);
    renderSectorList();
    renderRightPanel();
    // The roster is the one thing the overview never loads eagerly, so pull
    // it fresh on open rather than waiting up to 5s for the next poll tick.
    refreshMemberships(sectorId);
  }

  function clearSelection() {
    selectedSectorId = null;
    map.clearFocus();
    renderSectorList();
    renderRightPanel();
  }

  // ---------- left sidebar: minimal sector list ----------

  function renderSectorList() {
    const el = root.querySelector("#sector-list");
    el.innerHTML = "";
    if (sectors.size === 0) {
      el.innerHTML = '<div class="empty-hint">No sectors yet.</div>';
      return;
    }
    for (const sector of sectors.values()) {
      const pendingCount = pendingFor(sector.id).length;
      const row = document.createElement("button");
      row.className = `sector-row${sector.id === selectedSectorId ? " selected" : ""}`;
      row.type = "button";
      row.innerHTML = `
        <span class="sector-swatch" style="background:${map.sectorColor(sector.id)}"></span>
        <span class="sector-name">${escapeHtml(sector.name)}</span>
        ${pendingCount > 0 ? `<span class="pending-badge" title="${pendingCount} awaiting approval">${pendingCount}</span>` : ""}
        <span class="status-dot status-${sector.status}" title="${sector.status}"></span>
      `;
      row.addEventListener("click", () => selectSector(sector.id));
      el.appendChild(row);
    }
  }

  // ---------- right panel skeletons ----------

  function renderRightPanel() {
    const el = root.querySelector("#right-panel");
    if (selectedSectorId && sectors.has(selectedSectorId)) {
      const sector = sectors.get(selectedSectorId);
      el.innerHTML = `
        <div class="sector-panel-head">
          <button class="secondary" id="close-sector">&larr; All sectors</button>
          <div class="sector-panel-title">
            <span class="sector-swatch" style="background:${map.sectorColor(sector.id)}"></span>
            <span>${escapeHtml(sector.name)}</span>
          </div>
        </div>
        <h2>Recruitment</h2>
        <div id="recruit-control"></div>
        <h2>Join code</h2>
        <div id="joincode-control"></div>
        <h2>Pending approvals</h2>
        <div id="pending-list"></div>
        <h2>Members</h2>
        <div id="members-list"></div>
        <h2>SOS alerts</h2>
        <div id="sos-list"></div>
        <h2>Unacknowledged reports</h2>
        <div id="report-list"></div>
      `;
      el.querySelector("#close-sector").addEventListener("click", clearSelection);
      renderRecruitControl();
      renderJoinCodeControl();
      renderMembersRoster();
    } else {
      el.innerHTML = `
        <h2>Event overview</h2>
        <div class="empty-hint">Select a sector on the left to manage recruitment, join codes and members.</div>
        <h2>Open SOS alerts</h2>
        <div id="sos-list"></div>
        <h2>Pending approvals</h2>
        <div id="pending-list"></div>
        <h2>Unacknowledged reports</h2>
        <div id="report-list"></div>
      `;
    }
    renderPendingApprovals();
    renderSosList();
    renderReportList();
  }

  // ---------- sector panel: recruitment ----------

  function renderRecruitControl() {
    const el = root.querySelector("#recruit-control");
    if (!el) return;
    const sector = sectors.get(selectedSectorId);
    if (!sector) return;
    el.innerHTML = "";

    if (sector.status === "closed") {
      el.innerHTML =
        '<span class="sector-status-label status-closed">Closed</span>' +
        '<div class="panel-hint">Closed by event teardown; it cannot be reopened from here.</div>';
      return;
    }

    const isOpen = sector.status === "open";
    const label = document.createElement("span");
    label.className = `sector-status-label ${isOpen ? "status-open" : "status-paused"}`;
    label.textContent = isOpen ? "Accepting Volunteers" : "Recruitment Paused";
    el.appendChild(label);

    const btn = document.createElement("button");
    btn.className = "secondary";
    btn.textContent = isOpen ? "Pause Recruitment" : "Resume Recruitment";
    btn.addEventListener("click", async () => {
      btn.disabled = true;
      try {
        const updated = await api.updateSectorStatus(sector.id, isOpen ? "paused" : "open");
        sectors.set(updated.id, updated);
        renderSectorList();
        renderRecruitControl();
      } catch (e) {
        showError(e);
        btn.disabled = false;
      }
    });
    el.appendChild(btn);

    if (event && event.status !== "active") {
      // Being 'open' is necessary but not sufficient -- POST /join checks the
      // event's status too, and returns the same opaque error for either.
      const hint = document.createElement("div");
      hint.className = "panel-hint warn";
      hint.textContent = `Event is ${event.status} — volunteers cannot join any sector until it is started.`;
      el.appendChild(hint);
    }
  }

  // ---------- sector panel: join code ----------

  function renderJoinCodeControl() {
    const el = root.querySelector("#joincode-control");
    if (!el) return;
    const sector = sectors.get(selectedSectorId);
    if (!sector) return;

    const entry = joinCodes.get(sector.id);
    const expired = entry && new Date(entry.expires_at) <= new Date();
    if (expired) joinCodes.delete(sector.id);

    el.innerHTML = "";

    if (!entry || expired) {
      const btn = document.createElement("button");
      btn.className = "secondary";
      btn.textContent = "Generate join code";
      btn.addEventListener("click", async () => {
        btn.disabled = true;
        try {
          joinCodes.set(sector.id, await api.createJoinCode(sector.id));
          renderJoinCodeControl();
        } catch (e) {
          showError(e);
          btn.disabled = false;
        }
      });
      el.appendChild(btn);
      const hint = document.createElement("div");
      hint.className = "panel-hint";
      // There is no GET for join codes -- see api.js.
      hint.textContent = "Codes are only visible in the session that created them.";
      el.appendChild(hint);
      return;
    }

    const badge = document.createElement("span");
    badge.className = "join-code-badge";
    badge.textContent = entry.code;
    el.appendChild(badge);

    const revokeBtn = document.createElement("button");
    revokeBtn.className = "secondary";
    revokeBtn.textContent = "Revoke";
    revokeBtn.addEventListener("click", async () => {
      revokeBtn.disabled = true;
      try {
        await api.revokeJoinCode(sector.id, entry.code);
        joinCodes.delete(sector.id);
        renderJoinCodeControl();
      } catch (e) {
        showError(e);
        revokeBtn.disabled = false;
      }
    });
    el.appendChild(revokeBtn);

    const meta = document.createElement("div");
    meta.className = "join-code-meta";
    const usesLabel = entry.max_uses ? `${entry.uses}/${entry.max_uses} uses` : `${entry.uses} used`;
    meta.textContent = `${usesLabel} · expires ${new Date(entry.expires_at).toLocaleTimeString()}`;
    el.appendChild(meta);
  }

  // ---------- sector panel: members roster ----------

  function renderMembersRoster() {
    const el = root.querySelector("#members-list");
    if (!el) return;
    const sector = sectors.get(selectedSectorId);
    if (!sector) return;

    const active = activeFor(sector.id);
    if (active.length === 0) {
      el.innerHTML = '<div class="empty-hint">No active members.</div>';
      return;
    }

    el.innerHTML = "";
    for (const m of active) {
      const isLead = m.role === "lead" || sector.lead_user_id === m.user_id;
      const card = document.createElement("div");
      card.className = "member-card";
      card.innerHTML = `
        <div class="member-head">
          <span class="member-id">${m.user_id.slice(0, 8)}</span>
          ${isLead ? '<span class="lead-badge">LEAD</span>' : ""}
        </div>
        <div class="meta">${m.movement_mode}${m.battery_at_join != null ? ` · joined at ${m.battery_at_join}%` : ""}</div>
        <div class="actions"></div>
      `;
      const actions = card.querySelector(".actions");

      if (!isLead) {
        const leadBtn = document.createElement("button");
        leadBtn.className = "secondary";
        leadBtn.textContent = "Make Lead";
        if (!isCommander()) {
          // require_commander, not require_lead_or_commander -- a Lead
          // cannot hand off their own role. Shown-but-disabled rather than
          // hidden so the capability is discoverable.
          leadBtn.disabled = true;
          leadBtn.title = "Only the event commander can reassign a sector lead";
        } else {
          leadBtn.addEventListener("click", async () => {
            leadBtn.disabled = true;
            try {
              const updated = await api.assignLead(sector.id, m.user_id);
              sectors.set(updated.id, updated);
              // Two rows change role (old lead demoted, this one promoted),
              // so refetch rather than patching state locally.
              await refreshMemberships(sector.id);
              renderSectorList();
            } catch (e) {
              showError(e);
              leadBtn.disabled = false;
            }
          });
        }
        actions.appendChild(leadBtn);
      }

      const removeBtn = document.createElement("button");
      removeBtn.className = "danger";
      removeBtn.textContent = "Remove";
      removeBtn.addEventListener("click", async () => {
        if (
          !confirm(
            `Remove ${m.user_id.slice(0, 8)} from ${sector.name}?\n\n` +
              "Their session stops working on their next request. They keep the " +
              "sector key until it is re-keyed, and can rejoin with a valid code."
          )
        ) {
          return;
        }
        removeBtn.disabled = true;
        try {
          await api.revokeMembership(m.id);
          await refreshMemberships(sector.id);
        } catch (e) {
          showError(e);
          removeBtn.disabled = false;
        }
      });
      actions.appendChild(removeBtn);

      el.appendChild(card);
    }
  }

  // ---------- shared lists (filtered when a sector is selected) ----------

  function renderPendingApprovals() {
    const el = root.querySelector("#pending-list");
    if (!el) return;
    const items = [];
    for (const [sectorId] of sectors) {
      if (!inScope(sectorId)) continue;
      for (const m of pendingFor(sectorId)) items.push({ membership: m, sectorId });
    }
    items.sort((a, b) => new Date(a.membership.created_at) - new Date(b.membership.created_at));

    if (items.length === 0) {
      el.innerHTML = '<div class="empty-hint">No pending approvals.</div>';
      return;
    }
    el.innerHTML = "";
    for (const { membership, sectorId } of items) {
      const card = document.createElement("div");
      card.className = "alert-card approval";
      // No user-lookup endpoint exists server-side -- only the raw user_id
      // is available, not a display name.
      const battery =
        membership.battery_at_join != null
          ? `${membership.battery_at_join}% battery`
          : "battery unknown";
      card.innerHTML = `
        <div><strong>${membership.movement_mode}</strong>${selectedSectorId ? "" : ` · ${escapeHtml(sectorName(sectorId))}`}</div>
        <div class="meta">user ${membership.user_id.slice(0, 8)} · ${battery}${membership.powerbank_attested ? " · powerbank attested" : ""}</div>
        <div class="actions"></div>
      `;
      const actions = card.querySelector(".actions");

      const approveBtn = document.createElement("button");
      approveBtn.textContent = "Approve";
      approveBtn.addEventListener("click", async () => {
        approveBtn.disabled = true;
        try {
          await api.approveMembership(membership.id);
          await refreshMemberships(sectorId);
        } catch (e) {
          showError(e);
          approveBtn.disabled = false;
        }
      });
      actions.appendChild(approveBtn);

      const rejectBtn = document.createElement("button");
      rejectBtn.className = "secondary";
      rejectBtn.textContent = "Reject";
      rejectBtn.addEventListener("click", async () => {
        rejectBtn.disabled = true;
        try {
          await api.rejectMembership(membership.id);
          await refreshMemberships(sectorId);
        } catch (e) {
          showError(e);
          rejectBtn.disabled = false;
        }
      });
      actions.appendChild(rejectBtn);

      el.appendChild(card);
    }
  }

  function renderSosList() {
    const el = root.querySelector("#sos-list");
    if (!el) return;
    const items = [...openSos.values()]
      .filter((e) => inScope(e.sectorId))
      .sort((a, b) => new Date(b.alert.triggered_at) - new Date(a.alert.triggered_at));

    if (items.length === 0) {
      el.innerHTML = '<div class="empty-hint">No open alerts.</div>';
      return;
    }
    el.innerHTML = "";
    for (const { alert: sosAlert, sectorId } of items) {
      const card = document.createElement("div");
      card.className = "alert-card sos";
      card.innerHTML = `
        <div><strong>SOS</strong>${selectedSectorId ? "" : ` · ${escapeHtml(sectorName(sectorId))}`}</div>
        <div class="meta">${sosAlert.status} · ${new Date(sosAlert.triggered_at).toLocaleTimeString()}</div>
        <div class="actions"></div>
      `;
      const actions = card.querySelector(".actions");
      if (sosAlert.status === "active") {
        const ackBtn = document.createElement("button");
        ackBtn.textContent = "Acknowledge";
        ackBtn.addEventListener("click", async () => {
          ackBtn.disabled = true;
          try {
            await api.acknowledgeSos(sosAlert.id);
          } catch (e) {
            showError(e);
            ackBtn.disabled = false;
          }
        });
        actions.appendChild(ackBtn);
      }
      const resolveBtn = document.createElement("button");
      resolveBtn.className = "secondary";
      resolveBtn.textContent = "Resolve";
      resolveBtn.addEventListener("click", async () => {
        resolveBtn.disabled = true;
        try {
          await api.resolveSos(sosAlert.id);
        } catch (e) {
          showError(e);
          resolveBtn.disabled = false;
        }
      });
      actions.appendChild(resolveBtn);
      el.appendChild(card);
    }
  }

  function renderReportList() {
    const el = root.querySelector("#report-list");
    if (!el) return;
    const items = [...pendingReports.values()]
      .filter((e) => inScope(e.sectorId))
      .sort((a, b) => new Date(b.report.received_at) - new Date(a.report.received_at));

    if (items.length === 0) {
      el.innerHTML = '<div class="empty-hint">No unacknowledged reports.</div>';
      return;
    }
    el.innerHTML = "";
    for (const { report, sectorId } of items) {
      const card = document.createElement("div");
      card.className = "alert-card report";
      card.innerHTML = `
        <div><strong>${report.kind}</strong>${selectedSectorId ? "" : ` · ${escapeHtml(sectorName(sectorId))}`}</div>
        <div class="meta">${new Date(report.received_at).toLocaleTimeString()}${report.note ? " · " + escapeHtml(report.note) : ""}</div>
        <div class="actions"></div>
      `;
      const ackBtn = document.createElement("button");
      ackBtn.textContent = "Acknowledge";
      ackBtn.addEventListener("click", async () => {
        ackBtn.disabled = true;
        try {
          await api.acknowledgeReport(report.id);
        } catch (e) {
          showError(e);
          ackBtn.disabled = false;
        }
      });
      card.querySelector(".actions").appendChild(ackBtn);
      el.appendChild(card);
    }
  }

  // ---------- state updates ----------

  function applySosUpdate(sectorId, alerts) {
    for (const a of alerts) {
      if (a.status === "active" || a.status === "acknowledged") {
        openSos.set(a.id, { alert: a, sectorId });
      } else {
        openSos.delete(a.id);
      }
    }
    map.applySos(sectorId, alerts);
    renderSosList();
  }

  function applyReportUpdate(sectorId, reports) {
    for (const report of reports) {
      if (report.status === "acknowledged") {
        pendingReports.delete(report.id);
      } else {
        pendingReports.set(report.id, { report, sectorId });
      }
    }
    map.applyReports(sectorId, reports);
    renderReportList();
  }

  async function refreshMemberships(sectorId) {
    try {
      membershipsBySector.set(sectorId, await api.listMemberships(sectorId));
    } catch (e) {
      return; // transient; the next poll tick retries
    }
    renderSectorList();
    renderPendingApprovals();
    renderMembersRoster();
  }

  async function loadSector(sector) {
    sectors.set(sector.id, sector);
    map.addSector(sector, { onClick: selectSector });
    renderSectorList();

    const [hexes, presence, sos, reports, memberships] = await Promise.all([
      api.getHexes(sector.id).catch(() => ({ hexes: [] })),
      api.getPresence(sector.id).catch(() => []),
      api.getSos(sector.id).catch(() => []),
      api.getReports(sector.id).catch(() => []),
      api.listMemberships(sector.id).catch(() => []),
    ]);
    map.applyHexes(sector.id, hexes.hexes || hexes);
    map.applyPresence(sector.id, presence);
    membershipsBySector.set(sector.id, memberships);
    applySosUpdate(sector.id, sos);
    applyReportUpdate(sector.id, reports);
    renderSectorList();
    renderPendingApprovals();
    renderMembersRoster();
  }

  // ---------- initial load ----------

  try {
    event = await api.getEvent(eventId);
  } catch (e) {
    root.querySelector("#event-name").textContent = "Failed to load event";
    return;
  }
  root.querySelector("#event-name").textContent = event.name;
  // Only used to decide whether "Make Lead" is actionable (commander-only).
  me = await api.me().catch(() => null);
  renderEventStatus();
  renderRightPanel();

  function renderEventStatus() {
    const label = root.querySelector("#event-status-label");
    const startBtn = root.querySelector("#start-event-btn");
    label.textContent = event.status;
    label.className = `event-status-label status-${event.status}`;

    if (event.status === "draft") {
      startBtn.style.display = "";
      startBtn.disabled = false;
      startBtn.onclick = async () => {
        startBtn.disabled = true;
        try {
          event = await api.startEvent(eventId);
          renderEventStatus();
          renderRecruitControl(); // drops the "event is draft" warning
        } catch (e) {
          showError(e);
          startBtn.disabled = false;
        }
      };
    } else {
      startBtn.style.display = "none";
    }
  }

  let sectorList = [];
  try {
    sectorList = await api.listSectors(eventId);
  } catch (e) {
    // fall through with no sectors; the sidebar will show the empty state
  }
  await Promise.all(sectorList.map(loadSector));
  map.fitAll(); // once, after the whole batch is on the map

  // ---------- new sector drawing ----------

  const drawControls = root.querySelector("#draw-controls");
  root.querySelector("#new-sector-btn").addEventListener("click", () => startSectorDraw());

  function startSectorDraw() {
    drawControls.innerHTML = `
      <input id="sector-name" placeholder="Sector name" />
      <div class="draw-hint" id="draw-hint">Click the map to place boundary points (3+), then Finish.</div>
      <div class="row">
        <button id="finish-draw" disabled>Finish (0 pts)</button>
        <button class="secondary" id="cancel-draw">Cancel</button>
      </div>
    `;
    const finishBtn = drawControls.querySelector("#finish-draw");
    map.startDrawing((count) => {
      finishBtn.disabled = count < 3;
      finishBtn.textContent = `Finish (${count} pts)`;
    });
    drawControls.querySelector("#cancel-draw").addEventListener("click", resetDrawControls);
    finishBtn.addEventListener("click", async () => {
      const name = drawControls.querySelector("#sector-name").value.trim();
      if (!name) {
        alert("give the sector a name first");
        return;
      }
      const boundary = map.finishDrawing();
      if (!boundary) {
        alert("place at least 3 points");
        return;
      }
      finishBtn.disabled = true;
      try {
        const sector = await api.createSector(eventId, name, boundary);
        await loadSector(sector);
        // Don't yank the viewport if the commander is focused on a sector.
        if (!selectedSectorId) map.fitAll();
        resetDrawControls();
      } catch (e) {
        showError(e);
        resetDrawControls();
      }
    });
  }

  function resetDrawControls() {
    map.cancelDrawing();
    drawControls.innerHTML = '<button class="secondary" id="new-sector-btn">+ New sector</button>';
    drawControls.querySelector("#new-sector-btn").addEventListener("click", startSectorDraw);
  }

  // ---------- realtime ----------

  const dot = root.querySelector("#conn-dot");
  const label = root.querySelector("#conn-label");
  const socket = new DashboardSocket(eventId, {
    onStatusChange: (status) => {
      dot.className = `dot ${status}`;
      label.textContent = status;
    },
    onMessage: (msg) => {
      switch (msg.type) {
        case "hex_delta":
          map.applyHexes(msg.sector_id, msg.hexes);
          break;
        case "presence_delta":
          map.applyPresence(msg.sector_id, msg.devices);
          break;
        case "sos_delta":
          applySosUpdate(msg.sector_id, msg.alerts);
          break;
        case "report_delta":
          applyReportUpdate(msg.sector_id, msg.reports);
          break;
      }
    },
  });
  socket.start();

  // Membership polling: no membership_delta exists over the WS socket (only
  // hex/presence/sos/report do -- see realtime/listener.py), so this is
  // polled instead, same 5s convention as the mobile app's own Lead/
  // Commander approval screens. Polls every sector, not just the selected
  // one, because the sidebar shows a pending-count badge per sector.
  const membershipPoll = setInterval(() => {
    for (const sectorId of sectors.keys()) refreshMemberships(sectorId);
  }, 5000);

  // Torn down when the hash router re-renders into a different view.
  window.addEventListener(
    "hashchange",
    () => {
      socket.stop();
      clearInterval(membershipPoll);
    },
    { once: true }
  );
}

function renderLegend(el) {
  const presenceItems = Object.entries(PRESENCE_COLORS)
    .map(
      ([state, color]) =>
        `<div class="legend-item"><span class="legend-swatch" style="background:${color}"></span>${state.replace("_", " ")}</div>`
    )
    .join("");
  const reportItems = Object.entries(REPORT_KIND_STYLE)
    .map(
      ([kind, style]) =>
        `<div class="legend-item"><span class="legend-swatch" style="background:${style.color}"></span>${kind}</div>`
    )
    .join("");
  el.innerHTML = `<div class="legend-item" style="margin-bottom:8px"><strong>Presence</strong></div>${presenceItems}
    <div class="legend-item" style="margin:10px 0 8px"><strong>Reports</strong></div>${reportItems}`;
}

function escapeHtml(str) {
  const div = document.createElement("div");
  div.textContent = str;
  return div.innerHTML;
}

function showError(e) {
  alert(e.message || "action failed");
}
