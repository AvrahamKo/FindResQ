import { api } from "./api.js";
import { DashboardSocket } from "./ws.js";
import { TacticalMap, PRESENCE_COLORS, REPORT_KIND_STYLE } from "./map.js";

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
      <div class="side-panel right">
        <h2>Open SOS alerts</h2>
        <div id="sos-list"></div>
        <h2>Pending Approvals</h2>
        <div id="pending-list"></div>
        <h2>Unacknowledged reports</h2>
        <div id="report-list"></div>
      </div>
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
  const pendingMemberships = new Map(); // membershipId -> { membership, sectorId }
  const joinCodes = new Map(); // sectorId -> JoinCodeOut (only ones created THIS session -- see api.js)

  function sectorName(sectorId) {
    const s = sectors.get(sectorId);
    return s ? s.name : sectorId.slice(0, 8);
  }

  function renderSectorList() {
    const el = root.querySelector("#sector-list");
    el.innerHTML = "";
    if (sectors.size === 0) {
      el.innerHTML = '<div class="empty-hint">No sectors yet.</div>';
      return;
    }
    for (const sector of sectors.values()) {
      const color = map.sectorColor(sector.id);
      const row = document.createElement("div");
      row.className = "sector-row";

      const top = document.createElement("div");
      top.className = "sector-row-top";
      top.innerHTML = `<span class="sector-swatch" style="background:${color}"></span><span class="sector-name">${sector.name}</span>`;
      row.appendChild(top);

      const statusLine = document.createElement("div");
      statusLine.className = "sector-status-line";
      row.appendChild(statusLine);
      renderStatusToggle(statusLine, sector);

      const codeLine = document.createElement("div");
      codeLine.className = "sector-join-code";
      row.appendChild(codeLine);
      renderJoinCodeLine(codeLine, sector);

      el.appendChild(row);
    }
  }

  function renderStatusToggle(el, sector) {
    el.innerHTML = "";

    if (sector.status === "closed") {
      const label = document.createElement("span");
      label.className = "sector-status-label status-closed";
      label.textContent = "Closed";
      el.appendChild(label);
      return;
    }

    const isOpen = sector.status === "open";
    const label = document.createElement("span");
    label.className = `sector-status-label ${isOpen ? "status-open" : "status-paused"}`;
    label.textContent = isOpen ? "Accepting Volunteers" : "Recruitment Paused";
    el.appendChild(label);

    const btn = document.createElement("button");
    btn.className = "secondary status-toggle-btn";
    btn.textContent = isOpen ? "Pause Recruitment" : "Resume Recruitment";
    btn.addEventListener("click", async () => {
      btn.disabled = true;
      const nextStatus = isOpen ? "paused" : "open";
      try {
        const updated = await api.updateSectorStatus(sector.id, nextStatus);
        sector.status = updated.status;
        renderStatusToggle(el, sector);
      } catch (e) {
        alert(e.message || "failed to update sector status");
        btn.disabled = false;
      }
    });
    el.appendChild(btn);
  }

  function renderJoinCodeLine(el, sector) {
    const entry = joinCodes.get(sector.id);
    const expired = entry && new Date(entry.expires_at) <= new Date();
    if (!entry || expired) {
      if (expired) joinCodes.delete(sector.id);
      el.innerHTML = "";
      const btn = document.createElement("button");
      btn.className = "secondary gen-code-btn";
      btn.textContent = "Generate join code";
      btn.addEventListener("click", async () => {
        btn.disabled = true;
        try {
          const code = await api.createJoinCode(sector.id);
          joinCodes.set(sector.id, code);
          renderJoinCodeLine(el, sector);
        } catch (e) {
          alert(e.message || "failed to create join code");
          btn.disabled = false;
        }
      });
      el.appendChild(btn);
      return;
    }

    el.innerHTML = "";
    const badge = document.createElement("span");
    badge.className = "join-code-badge";
    badge.textContent = entry.code;
    el.appendChild(badge);

    const meta = document.createElement("span");
    meta.className = "join-code-meta";
    const usesLabel = entry.max_uses ? `${entry.uses}/${entry.max_uses} uses` : `${entry.uses} used`;
    meta.textContent = `${usesLabel} · expires ${new Date(entry.expires_at).toLocaleTimeString()}`;
    el.appendChild(meta);

    const revokeBtn = document.createElement("button");
    revokeBtn.className = "secondary";
    revokeBtn.textContent = "Revoke";
    revokeBtn.addEventListener("click", async () => {
      revokeBtn.disabled = true;
      try {
        await api.revokeJoinCode(sector.id, entry.code);
        joinCodes.delete(sector.id);
        renderJoinCodeLine(el, sector);
      } catch (e) {
        alert(e.message || "failed to revoke join code");
        revokeBtn.disabled = false;
      }
    });
    el.appendChild(revokeBtn);
  }

  function renderSosList() {
    const el = root.querySelector("#sos-list");
    const items = [...openSos.values()].sort(
      (a, b) => new Date(b.alert.triggered_at) - new Date(a.alert.triggered_at)
    );
    if (items.length === 0) {
      el.innerHTML = '<div class="empty-hint">No open alerts.</div>';
      return;
    }
    el.innerHTML = "";
    for (const { alert, sectorId } of items) {
      const card = document.createElement("div");
      card.className = "alert-card sos";
      card.innerHTML = `
        <div><strong>SOS</strong> · ${sectorName(sectorId)}</div>
        <div class="meta">${alert.status} · ${new Date(alert.triggered_at).toLocaleTimeString()}</div>
        <div class="actions"></div>
      `;
      const actions = card.querySelector(".actions");
      if (alert.status === "active") {
        const ackBtn = document.createElement("button");
        ackBtn.textContent = "Acknowledge";
        ackBtn.addEventListener("click", async () => {
          ackBtn.disabled = true;
          try {
            await api.acknowledgeSos(alert.id);
          } catch (e) {
            alert_error(e);
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
          await api.resolveSos(alert.id);
        } catch (e) {
          alert_error(e);
          resolveBtn.disabled = false;
        }
      });
      actions.appendChild(resolveBtn);
      el.appendChild(card);
    }
  }

  function renderReportList() {
    const el = root.querySelector("#report-list");
    const items = [...pendingReports.values()].sort(
      (a, b) => new Date(b.report.received_at) - new Date(a.report.received_at)
    );
    if (items.length === 0) {
      el.innerHTML = '<div class="empty-hint">No unacknowledged reports.</div>';
      return;
    }
    el.innerHTML = "";
    for (const { report, sectorId } of items) {
      const card = document.createElement("div");
      card.className = "alert-card report";
      card.innerHTML = `
        <div><strong>${report.kind}</strong> · ${sectorName(sectorId)}</div>
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
          alert_error(e);
          ackBtn.disabled = false;
        }
      });
      card.querySelector(".actions").appendChild(ackBtn);
      el.appendChild(card);
    }
  }

  function renderPendingApprovals() {
    const el = root.querySelector("#pending-list");
    const items = [...pendingMemberships.values()].sort(
      (a, b) => new Date(a.membership.created_at) - new Date(b.membership.created_at)
    );
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
        membership.battery_at_join != null ? `${membership.battery_at_join}% battery` : "battery unknown";
      card.innerHTML = `
        <div><strong>${membership.movement_mode}</strong> · ${sectorName(sectorId)}</div>
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
          pendingMemberships.delete(membership.id);
          renderPendingApprovals();
        } catch (e) {
          alert_error(e);
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
          pendingMemberships.delete(membership.id);
          renderPendingApprovals();
        } catch (e) {
          alert_error(e);
          rejectBtn.disabled = false;
        }
      });
      actions.appendChild(rejectBtn);

      el.appendChild(card);
    }
  }

  function applySosUpdate(sectorId, alerts) {
    for (const alert of alerts) {
      if (alert.status === "active" || alert.status === "acknowledged") {
        openSos.set(alert.id, { alert, sectorId });
      } else {
        openSos.delete(alert.id);
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

  function applyPendingMemberships(sectorId, memberships) {
    for (const [id, entry] of pendingMemberships) {
      if (entry.sectorId === sectorId && !memberships.some((m) => m.id === id)) {
        pendingMemberships.delete(id);
      }
    }
    for (const m of memberships) {
      if (m.status === "pending") {
        pendingMemberships.set(m.id, { membership: m, sectorId });
      } else {
        pendingMemberships.delete(m.id);
      }
    }
    renderPendingApprovals();
  }

  async function loadSector(sector) {
    sectors.set(sector.id, sector);
    map.addSector(sector);
    renderSectorList();

    const [hexes, presence, sos, reports, memberships] = await Promise.all([
      api.getHexes(sector.id).catch(() => ({ hexes: [] })),
      api.getPresence(sector.id).catch(() => []),
      api.getSos(sector.id).catch(() => []),
      api.getReports(sector.id).catch(() => []),
      api.listMemberships(sector.id, "pending").catch(() => []),
    ]);
    map.applyHexes(sector.id, hexes.hexes || hexes);
    map.applyPresence(sector.id, presence);
    applySosUpdate(sector.id, sos);
    applyPendingMemberships(sector.id, memberships);
    applyReportUpdate(sector.id, reports);
  }

  // ---- initial load ----
  let event;
  try {
    event = await api.getEvent(eventId);
  } catch (e) {
    root.querySelector("#event-name").textContent = "Failed to load event";
    return;
  }
  root.querySelector("#event-name").textContent = event.name;
  renderEventStatus();

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
        } catch (e) {
          alert(e.message || "failed to start event");
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

  // ---- new sector drawing ----
  const newSectorBtn = root.querySelector("#new-sector-btn");
  const drawControls = root.querySelector("#draw-controls");
  newSectorBtn.addEventListener("click", () => startSectorDraw());

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
        resetDrawControls();
      } catch (e) {
        alert(e.message || "failed to create sector");
        resetDrawControls();
      }
    });
  }

  function resetDrawControls() {
    map.cancelDrawing();
    drawControls.innerHTML = '<button class="secondary" id="new-sector-btn">+ New sector</button>';
    drawControls.querySelector("#new-sector-btn").addEventListener("click", startSectorDraw);
  }

  // ---- realtime ----
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

  // Pending-membership polling: no membership_delta exists over the WS
  // socket (only hex/presence/sos/report do -- see realtime/listener.py),
  // so this is polled instead, same 5s convention as the mobile app's own
  // Lead/Commander approval screens.
  const pendingApprovalsPoll = setInterval(async () => {
    for (const sector of sectors.values()) {
      try {
        const memberships = await api.listMemberships(sector.id, "pending");
        applyPendingMemberships(sector.id, memberships);
      } catch (e) {
        // transient poll failure -- next tick will retry
      }
    }
  }, 5000);

  // Torn down when the hash router re-renders into a different view.
  window.addEventListener(
    "hashchange",
    () => {
      socket.stop();
      clearInterval(pendingApprovalsPoll);
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

function alert_error(e) {
  alert(e.message || "action failed");
}
