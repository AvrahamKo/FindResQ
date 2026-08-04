import { getToken, setToken } from "./api.js";
import { renderLogin } from "./auth-view.js";
import { renderEvents } from "./events-view.js";
import { renderDashboard } from "./dashboard-view.js";

const root = document.getElementById("app");

// Navigation always goes through location.hash + the hashchange listener
// below -- never calling route() directly from a callback -- so a
// programmatic change and a browser back/forward both funnel through the
// exact same path instead of risking a double render.

function logout() {
  setToken(null);
  const wasEvents = location.hash !== "" && location.hash !== "#/events";
  location.hash = "";
  if (!wasEvents) route(); // hash didn't actually change, so it won't fire hashchange
}

async function route() {
  const token = getToken();
  if (!token) {
    renderLogin(root, {
      onLoggedIn: () => {
        const unchanged = location.hash === "#/events";
        location.hash = "#/events";
        if (unchanged) route();
      },
    });
    return;
  }

  const hash = location.hash || "#/events";
  const eventMatch = hash.match(/^#\/events\/([0-9a-fA-F-]+)$/);
  if (eventMatch) {
    renderDashboard(root, { eventId: eventMatch[1], onLogout: logout });
    return;
  }

  renderEvents(root, {
    onOpenEvent: (id) => {
      location.hash = `#/events/${id}`;
    },
    onLogout: logout,
  });
}

window.addEventListener("hashchange", route);
route();
