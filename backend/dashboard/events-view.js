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
  try {
    const events = await api.listEvents();
    if (events.length === 0) {
      listEl.innerHTML = '<div class="empty-hint">No events yet — create one above.</div>';
      return;
    }
    listEl.innerHTML = "";
    for (const ev of events) {
      const row = document.createElement("div");
      row.className = "event-row";
      row.innerHTML = `<div>${ev.name}</div><div class="status">${ev.status}</div>`;
      row.addEventListener("click", () => onOpenEvent(ev.id));
      listEl.appendChild(row);
    }
  } catch (e) {
    listEl.innerHTML = `<div class="error">${e.message || "failed to load events"}</div>`;
  }
}
