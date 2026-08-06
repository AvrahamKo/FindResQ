import { api } from "./api.js";

export async function renderEvents(root, { onOpenEvent, onLogout }) {
  root.innerHTML = `
    <div class="top-bar">
      <div class="title">LifeSearch — Commander Dashboard</div>
      <div class="spacer"></div>
      <button class="secondary" id="logout">Log out</button>
    </div>
    <div class="events-page">
      <div class="new-event-form">
        <input id="new-event-name" placeholder="New event name" />
        <button id="create-event">Create event</button>
      </div>
      <div id="list">Loading…</div>
    </div>
  `;
  root.querySelector("#logout").addEventListener("click", onLogout);

  const nameInput = root.querySelector("#new-event-name");
  const createBtn = root.querySelector("#create-event");
  createBtn.addEventListener("click", async () => {
    const name = nameInput.value.trim();
    if (!name) return;
    createBtn.disabled = true;
    try {
      const event = await api.createEvent(name);
      nameInput.value = "";
      onOpenEvent(event.id);
    } catch (e) {
      alert(e.message || "failed to create event");
    } finally {
      createBtn.disabled = false;
    }
  });
  nameInput.addEventListener("keydown", (e) => {
    if (e.key === "Enter") createBtn.click();
  });

  const listEl = root.querySelector("#list");
  let me = null;

  async function renderList() {
    let events;
    try {
      events = await api.listEvents();
    } catch (e) {
      listEl.innerHTML = `<div class="error">${escapeHtml(e.message || "failed to load events")}</div>`;
      return;
    }
    if (events.length === 0) {
      listEl.innerHTML = '<div class="empty-hint">No events yet — create one above.</div>';
      return;
    }
    listEl.innerHTML = "";
    for (const ev of events) {
      const row = document.createElement("div");
      row.className = "event-row";
      row.innerHTML = `<div>${escapeHtml(ev.name)}</div><div class="status">${ev.status}</div>`;
      row.addEventListener("click", () => onOpenEvent(ev.id));

      // Deletion is commander-only server-side. Offered here as well as
      // inside the event so a commander can clear out old callouts without
      // opening each one first -- but never for an event they merely hold a
      // membership in, where it could only ever 403.
      if (me && ev.commander_id === me.id) {
        const del = document.createElement("button");
        del.className = "danger";
        del.textContent = "Delete";
        del.addEventListener("click", async (clickEvent) => {
          // The row itself navigates; without this, deleting would also
          // open the event that is being destroyed.
          clickEvent.stopPropagation();
          if (!confirmEventDeletion(ev.name)) return;
          del.disabled = true;
          try {
            await api.deleteEvent(ev.id);
            await renderList();
          } catch (err) {
            alert(err.message || "failed to delete event");
            del.disabled = false;
          }
        });
        row.appendChild(del);
      }
      listEl.appendChild(row);
    }
  }

  me = await api.me().catch(() => null);
  await renderList();
}

/// Shared by both delete entry points (this list and the event's own top
/// bar) so the warning cannot drift between them. Spells out that this is
/// NOT "End Event": that one closes a callout and keeps the record, this
/// one destroys it.
export function confirmEventDeletion(name) {
  return confirm(
    `PERMANENTLY DELETE "${name}"?\n\n` +
      "This is not the same as ending an event. It erases:\n" +
      "• every sector and its boundary\n" +
      "• every membership and join code\n" +
      "• every recorded track and the entire coverage map\n" +
      "• every report, SOS alert and the subject record\n\n" +
      "Volunteers still in the field lose access immediately.\n" +
      "There is no undo and no backup. Type-check yourself before confirming.",
  );
}

function escapeHtml(str) {
  const div = document.createElement("div");
  div.textContent = str;
  return div.innerHTML;
}
