import { api } from "./api.js";

// Tickets are single-use and expire in 30s server-side (see
// realtime/tickets.py), so a fresh one must be minted on every connection
// attempt -- including reconnects, not just the first one.
const INITIAL_BACKOFF_MS = 1000;
const MAX_BACKOFF_MS = 30000;

export class DashboardSocket {
  constructor(eventId, { onMessage, onStatusChange } = {}) {
    this.eventId = eventId;
    this.onMessage = onMessage || (() => {});
    this.onStatusChange = onStatusChange || (() => {});
    this.ws = null;
    this.stopped = true;
    this.backoffMs = INITIAL_BACKOFF_MS;
    this.reconnectTimer = null;
  }

  start() {
    this.stopped = false;
    this._connect();
  }

  stop() {
    this.stopped = true;
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    if (this.ws) {
      const ws = this.ws;
      this.ws = null;
      ws.close();
    }
  }

  async _connect() {
    if (this.stopped) return;
    this.onStatusChange("connecting");

    let ticket;
    try {
      ticket = await api.createWsTicket(this.eventId);
    } catch (err) {
      this._scheduleReconnect();
      return;
    }
    if (this.stopped) return;

    const protocol = location.protocol === "https:" ? "wss" : "ws";
    const url = `${protocol}://${location.host}/ws/events/${this.eventId}?ticket=${encodeURIComponent(ticket.ticket)}`;
    const ws = new WebSocket(url);
    this.ws = ws;

    ws.onopen = () => {
      this.backoffMs = INITIAL_BACKOFF_MS;
    };
    ws.onmessage = (evt) => {
      let msg;
      try {
        msg = JSON.parse(evt.data);
      } catch {
        return;
      }
      if (msg.type === "connected") {
        this.onStatusChange("connected");
        return;
      }
      if (msg.type === "pong") return;
      this.onMessage(msg);
    };
    ws.onclose = () => {
      if (this.ws !== ws) return; // superseded by a newer connection attempt
      this.ws = null;
      if (this.stopped) return;
      this.onStatusChange("disconnected");
      this._scheduleReconnect();
    };
    ws.onerror = () => ws.close();
  }

  _scheduleReconnect() {
    if (this.stopped) return;
    this.reconnectTimer = setTimeout(() => {
      this.backoffMs = Math.min(this.backoffMs * 2, MAX_BACKOFF_MS);
      this._connect();
    }, this.backoffMs);
  }
}
