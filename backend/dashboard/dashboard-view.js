import { api } from "./api.js";
import { confirmEventDeletion } from "./events-view.js";
import { DashboardSocket } from "./ws.js";
import { TacticalMap, PRESENCE_COLORS, REPORT_KIND_STYLE } from "./map.js";
import { showSubjectModal } from "./subject-view.js";
import {
  formatArea,
  geoJsonPolygonToRing,
  isSelfIntersecting,
  ringAreaSquareMeters,
} from "./geo.js";

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
      <button class="secondary" id="subject-btn">Subject</button>
      <button class="danger" id="end-event-btn" style="display:none">End Event</button>
      <button class="danger" id="delete-event-btn" style="display:none">Delete Event</button>
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
  // ALL alerts, not just open ones. Closed alerts used to be dropped on
  // arrival, which made them unreachable -- and "clear the obsolete alerts"
  // needs them to be reachable. They are rendered in a separate, quieter
  // section so keeping them cannot dilute the open list.
  const sosAlerts = new Map(); // alertId -> { alert, sectorId }
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

  /// Whether the logged-in user may acknowledge, resolve or clear alerts in
  /// this sector. Mirrors the backend's `require_alert_moderator`: the
  /// event's Commander anywhere, or that specific sector's Lead (the Sector
  /// Manager) in their own sector -- and nobody else, including a Lead
  /// looking at a sector they do not run.
  ///
  /// The server enforces this regardless; hiding the control here is so a
  /// user is never offered an action whose only possible outcome is a 403.
  function canModerateAlerts(sectorId) {
    if (isCommander()) return true;
    const sector = sectors.get(sectorId);
    return !!(me && sector && sector.lead_user_id === me.id);
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
        <h2>Boundary</h2>
        <div id="boundary-control"></div>
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
      renderBoundaryControl();
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

  function renderBoundaryControl() {
    const el = root.querySelector("#boundary-control");
    if (!el) return;
    const sector = sectors.get(selectedSectorId);
    if (!sector) return;

    const ring = geoJsonPolygonToRing(sector.boundary);
    el.innerHTML = `<span class="geo-readout">${ring.length} points · ${formatArea(
      ringAreaSquareMeters(ring)
    )}</span>`;

    const editBtn = document.createElement("button");
    editBtn.className = "secondary";
    editBtn.id = "edit-boundary-btn";
    editBtn.textContent = "Edit boundary";
    editBtn.addEventListener("click", () => startBoundaryEdit(sector));
    el.appendChild(editBtn);
  }

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
      removeBtn.title = `Remove from ${sector.name} only`;
      removeBtn.addEventListener("click", async () => {
        if (
          !confirm(
            `Remove ${m.user_id.slice(0, 8)} from ${sector.name}?\n\n` +
              "Their session stops working on their next request and any live " +
              "connection is closed immediately. Their recorded scans are kept.\n\n" +
              "They keep the sector key until it is re-keyed, and MAY re-apply " +
              "with a valid join code."
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

      // Removing someone from the whole event is a separate, stronger
      // action than removing them from this one sector -- a volunteer
      // working two sectors is not removed from the callout by being taken
      // off one of them. Commander-only, matching the backend.
      const removeFromEventBtn = document.createElement("button");
      removeFromEventBtn.className = "danger";
      removeFromEventBtn.textContent = "Remove from event";
      if (!isCommander()) {
        removeFromEventBtn.disabled = true;
        removeFromEventBtn.title = "Only the event commander can remove a user from the event";
      } else {
        removeFromEventBtn.addEventListener("click", async () => {
          if (
            !confirm(
              `Remove ${m.user_id.slice(0, 8)} from the ENTIRE event?\n\n` +
                "• Every membership they hold, in every sector, is revoked\n" +
                "• Any Sector Lead role they hold is vacated\n" +
                "• Their sessions stop working immediately and any live " +
                "connection is closed\n\n" +
                "Their recorded scan history is KEPT and stays credited to " +
                "them — the coverage map still shows the ground they searched."
            )
          ) {
            return;
          }
          removeFromEventBtn.disabled = true;
          try {
            const result = await api.removeEventMember(eventId, m.user_id);
            // Several sectors and possibly a lead pointer changed, so
            // refetch rather than patching local state.
            const refreshed = await api.listSectors(eventId).catch(() => []);
            for (const s of refreshed) sectors.set(s.id, s);
            await Promise.all([...sectors.keys()].map(refreshMemberships));
            renderSectorList();
            renderRightPanel();
            if (result.lead_roles_cleared > 0) {
              alert(
                `${result.lead_roles_cleared} sector(s) now have no Lead — ` +
                  "assign a replacement.",
              );
            }
          } catch (e) {
            showError(e);
            removeFromEventBtn.disabled = false;
          }
        });
      }
      actions.appendChild(removeFromEventBtn);

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

  const OPEN_SOS_STATUSES = new Set(["active", "acknowledged"]);

  function renderSosList() {
    const el = root.querySelector("#sos-list");
    if (!el) return;

    const inView = [...sosAlerts.values()].filter((e) => inScope(e.sectorId));
    const byNewest = (a, b) =>
      new Date(b.alert.triggered_at) - new Date(a.alert.triggered_at);
    const open = inView.filter((e) => OPEN_SOS_STATUSES.has(e.alert.status)).sort(byNewest);
    const closed = inView.filter((e) => !OPEN_SOS_STATUSES.has(e.alert.status)).sort(byNewest);

    el.innerHTML = "";

    if (open.length === 0) {
      const empty = document.createElement("div");
      empty.className = "empty-hint";
      empty.textContent = "No open alerts.";
      el.appendChild(empty);
    }
    for (const entry of open) el.appendChild(buildSosCard(entry, { closed: false }));

    if (closed.length === 0) return;

    // Closed alerts get a heading of their own so a resolved alarm can never
    // be mistaken at a glance for a live one on a busy screen.
    const heading = document.createElement("div");
    heading.className = "panel-hint";
    heading.textContent = `Closed (${closed.length})`;
    el.appendChild(heading);

    for (const entry of closed) el.appendChild(buildSosCard(entry, { closed: true }));

    // One button for the common case: a list cluttered with alerts that are
    // all long over. Open alerts are excluded server-side, not merely
    // omitted from this count, so this cannot silence a live alarm.
    const clearableSectors = new Set(
      closed.filter((e) => canModerateAlerts(e.sectorId)).map((e) => e.sectorId)
    );
    if (clearableSectors.size === 0) return;

    const clearAll = document.createElement("button");
    clearAll.className = "danger";
    clearAll.textContent = `Clear ${closed.length} closed alert(s)`;
    clearAll.addEventListener("click", async () => {
      if (
        !confirm(
          `Permanently delete ${closed.length} closed alert(s)?\n\n` +
            "Open and acknowledged alerts are never affected.\n" +
            "This cannot be undone.",
        )
      ) {
        return;
      }
      clearAll.disabled = true;
      try {
        // Per sector, because the endpoint is sector-scoped -- in the
        // event-wide overview this can legitimately span several.
        await Promise.all([...clearableSectors].map((id) => api.clearClosedSos(id)));
        // The `sos_deleted` socket messages remove the cards; this is only
        // a fallback for a dropped socket.
        for (const entry of closed) sosAlerts.delete(entry.alert.id);
        renderSosList();
      } catch (e) {
        showError(e);
        clearAll.disabled = false;
      }
    });
    el.appendChild(clearAll);
  }

  function buildSosCard({ alert: sosAlert, sectorId }, { closed }) {
    const card = document.createElement("div");
    card.className = `alert-card sos${closed ? " closed" : ""}`;
    card.innerHTML = `
      <div><strong>SOS</strong>${selectedSectorId ? "" : ` · ${escapeHtml(sectorName(sectorId))}`}</div>
      <div class="meta">${sosAlert.status} · ${new Date(sosAlert.triggered_at).toLocaleTimeString()}</div>
      <div class="actions"></div>
    `;
    const actions = card.querySelector(".actions");
    const mayModerate = canModerateAlerts(sectorId);

    if (!mayModerate) {
      // Visible, but read-only. A searcher or a Lead from another sector can
      // SEE that an alert exists -- situational awareness -- without being
      // able to acknowledge it on someone else's behalf.
      const note = document.createElement("span");
      note.className = "panel-hint";
      note.textContent = "Sector manager or commander only";
      actions.appendChild(note);
      return card;
    }

    if (sosAlert.status === "active") {
      actions.appendChild(
        actionButton("Acknowledge", "", () => api.acknowledgeSos(sosAlert.id))
      );
    }
    if (OPEN_SOS_STATUSES.has(sosAlert.status)) {
      actions.appendChild(
        actionButton("Resolve", "secondary", () => api.resolveSos(sosAlert.id))
      );
    } else {
      // Clearing is offered ONLY on an alert that is already over. The
      // backend refuses to delete an open one outright -- deletion must
      // never become the quick way to make a live alarm go away.
      actions.appendChild(
        actionButton("Clear", "danger", async () => {
          await api.deleteSos(sosAlert.id);
          sosAlerts.delete(sosAlert.id);
          map.removeSos(sectorId, sosAlert.id);
          renderSosList();
        })
      );
    }
    return card;
  }

  /// A button that disables itself while its action is in flight and
  /// re-enables on failure. The success path deliberately does NOT
  /// re-enable: either the socket update re-renders the list, or the
  /// handler did it itself.
  function actionButton(label, className, action) {
    const btn = document.createElement("button");
    if (className) btn.className = className;
    btn.textContent = label;
    btn.addEventListener("click", async () => {
      btn.disabled = true;
      try {
        await action();
      } catch (e) {
        showError(e);
        btn.disabled = false;
      }
    });
    return btn;
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
    // Every alert is retained, whatever its status -- a closed one is still
    // a row a commander may want to clear. `renderSosList` splits them.
    for (const a of alerts) sosAlerts.set(a.id, { alert: a, sectorId });
    map.applySos(sectorId, alerts);
    renderSosList();
  }

  /// An alert was permanently deleted, here or on another dashboard. There
  /// is no delta row to reconcile against -- the row is gone -- so the
  /// server sends the id and this drops it.
  function applySosDeletion(sectorId, alertId) {
    sosAlerts.delete(alertId);
    map.removeSos(sectorId, alertId);
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
  // Decides whether commander-only actions ("Make Lead", editing the subject
  // record) are actionable. The backend enforces them regardless; this only
  // avoids offering an action that can only 403.
  me = await api.me().catch(() => null);
  renderEventStatus();
  renderRightPanel();
  wireSubjectButton();

  function wireSubjectButton() {
    const btn = root.querySelector("#subject-btn");
    btn.addEventListener("click", () =>
      showSubjectModal(eventId, { canEdit: isCommander() }),
    );
    // Nudge the commander when the callout has no subject on file yet --
    // it is the one piece of context every searcher ultimately depends on,
    // and an event can legitimately be created before it's known.
    if (!isCommander()) return;
    api
      .getSubject(eventId)
      .then((subject) => {
        if (subject === null) btn.classList.add("needs-attention");
      })
      .catch(() => {});
  }

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

    // Teardown is commander-only and irreversible, so it appears only while
    // there is something to tear down.
    const endBtn = root.querySelector("#end-event-btn");
    const canEnd = isCommander() && event.status !== "ended";
    endBtn.style.display = canEnd ? "" : "none";
    endBtn.disabled = false;
    endBtn.onclick = () => confirmAndEndEvent(endBtn);

    // Deletion stays available even after an event has ended -- clearing out
    // a finished callout is the most common reason to reach for it.
    const deleteBtn = root.querySelector("#delete-event-btn");
    deleteBtn.style.display = isCommander() ? "" : "none";
    deleteBtn.disabled = false;
    deleteBtn.onclick = () => confirmAndDeleteEvent(deleteBtn);
  }

  async function confirmAndDeleteEvent(deleteBtn) {
    if (!confirmEventDeletion(event.name)) return;

    // A second, typed confirmation. This is the only irreversible,
    // total-destruction action in the product, and it sits in the same top
    // bar as "End Event" -- one misplaced click on a tired night should not
    // be able to erase a callout's entire search record.
    const typed = prompt(
      `To confirm deletion, type the event name exactly:\n\n${event.name}`,
    );
    if (typed === null) return;
    if (typed.trim() !== event.name) {
      alert("Name did not match — nothing was deleted.");
      return;
    }

    deleteBtn.disabled = true;
    try {
      const result = await api.deleteEvent(eventId);
      socket.stop();
      clearInterval(membershipPoll);
      alert(
        `"${event.name}" deleted.\n\n` +
          `${result.sectors_deleted} sector(s), ` +
          `${result.memberships_deleted} membership(s), ` +
          `${result.track_points_deleted} track point(s), ` +
          `${result.hex_contributions_deleted} coverage contribution(s), ` +
          `${result.reports_deleted} report(s) and ` +
          `${result.sos_alerts_deleted} alert(s) were removed.`,
      );
      location.hash = "#/events";
    } catch (e) {
      showError(e);
      deleteBtn.disabled = false;
    }
  }

  async function confirmAndEndEvent(endBtn) {
    const sectorCount = sectors.size;
    const activeMembers = [...sectors.keys()].reduce(
      (total, id) => total + activeFor(id).length,
      0,
    );
    // Spells out the actual consequences with real counts rather than a
    // generic "are you sure?" -- this closes every sector and kills every
    // live session, and there is no reopen.
    const confirmed = confirm(
      `End "${event.name}"?\n\n` +
        `• ${sectorCount} sector(s) will be closed to new joins\n` +
        `• ${activeMembers} active member session(s) will stop working on their next request\n` +
        `• Volunteers still in the field will lose the ability to send telemetry, reports and SOS\n\n` +
        "This cannot be undone — there is no way to reopen an ended event.",
    );
    if (!confirmed) return;

    endBtn.disabled = true;
    try {
      event = await api.endEvent(eventId);
      // Sector statuses all became 'closed' server-side; refetch rather than
      // guessing, so the sidebar dots and recruitment controls tell the truth.
      const refreshed = await api.listSectors(eventId).catch(() => []);
      for (const sector of refreshed) sectors.set(sector.id, sector);
      renderEventStatus();
      renderSectorList();
      renderRightPanel();
    } catch (e) {
      showError(e);
      endBtn.disabled = false;
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

  /// Shared live feedback for BOTH drawing and editing: vertex count, true
  /// spherical area, and a self-intersection warning. Returns whether the
  /// ring is currently valid, so callers can gate their save button on the
  /// same judgement the commander is reading off the screen.
  function updateGeometryReadout(container, points) {
    const readout = container.querySelector("#geo-readout");
    const warning = container.querySelector("#geo-warning");
    const enoughPoints = points.length >= 3;
    const crossed = enoughPoints && isSelfIntersecting(points);

    if (readout) {
      readout.textContent = enoughPoints
        ? `${points.length} points · ${formatArea(ringAreaSquareMeters(points))}`
        : `${points.length} point${points.length === 1 ? "" : "s"} · need at least 3`;
    }
    if (warning) {
      warning.textContent = crossed
        ? "Boundary crosses itself — coverage hexes would be computed for the wrong area."
        : "";
      warning.style.display = crossed ? "" : "none";
    }
    return enoughPoints && !crossed;
  }

  function startSectorDraw() {
    drawControls.innerHTML = `
      <input id="sector-name" placeholder="Sector name" />
      <div class="draw-hint">Click the map to place boundary points (3+), then Finish.</div>
      <div class="geo-readout" id="geo-readout"></div>
      <div class="geo-warning" id="geo-warning" style="display:none"></div>
      <div class="row">
        <button id="finish-draw" disabled>Finish</button>
        <button class="secondary" id="undo-point" disabled>Undo</button>
        <button class="secondary" id="cancel-draw">Cancel</button>
      </div>
    `;
    const finishBtn = drawControls.querySelector("#finish-draw");
    const undoBtn = drawControls.querySelector("#undo-point");

    map.startDrawing(({ points }) => {
      const valid = updateGeometryReadout(drawControls, points);
      finishBtn.disabled = !valid;
      undoBtn.disabled = points.length === 0;
    });

    undoBtn.addEventListener("click", () => map.undoLastPoint());
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

  /// Vertex editing for an existing sector. Reachable only from that sector's
  /// own panel, so there is never ambiguity about which outline is being
  /// edited.
  function startBoundaryEdit(sector) {
    drawControls.innerHTML = `
      <div class="draw-hint">
        Drag a vertex to move it. Drag a small grey handle to add one.
        Right-click a vertex to delete it.
      </div>
      <div class="geo-readout" id="geo-readout"></div>
      <div class="geo-warning" id="geo-warning" style="display:none"></div>
      <div class="row">
        <button id="save-boundary">Save boundary</button>
        <button class="secondary" id="cancel-boundary">Cancel</button>
      </div>
      <div class="panel-hint">
        Previously-searched coverage is kept — it records where searchers
        actually walked, not what the outline says.
      </div>
    `;
    const saveBtn = drawControls.querySelector("#save-boundary");

    map.startEditingSector(sector.id, geoJsonPolygonToRing(sector.boundary), ({ points }) => {
      saveBtn.disabled = !updateGeometryReadout(drawControls, points);
    });

    drawControls.querySelector("#cancel-boundary").addEventListener("click", resetDrawControls);
    saveBtn.addEventListener("click", async () => {
      const boundary = map.getEditedBoundary();
      if (!boundary) {
        alert("a boundary needs at least 3 points");
        return;
      }
      saveBtn.disabled = true;
      try {
        const updated = await api.updateSectorBoundary(sector.id, boundary);
        sectors.set(updated.id, updated);
        map.cancelDrawing();
        map.replaceSectorBoundary(updated.id, updated.boundary, updated.name);
        resetDrawControls();
        renderRightPanel();
      } catch (e) {
        showError(e);
        saveBtn.disabled = false;
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
        case "sos_deleted":
          applySosDeletion(msg.sector_id, msg.alert_id);
          break;
        case "report_delta":
          applyReportUpdate(msg.sector_id, msg.reports);
          break;
        case "event_deleted":
          // Someone (possibly this commander in another tab) destroyed the
          // event. Everything on screen now describes rows that no longer
          // exist, so leave rather than degrade into a wall of 404s.
          alert("This event has been deleted.");
          location.hash = "#/events";
          break;
        case "access_revoked":
          // This user was removed from the event. The socket is already
          // being closed server-side; say why, since an unexplained
          // disconnect is indistinguishable from a flaky link.
          alert("Your access to this event has been revoked.");
          location.hash = "#/events";
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
