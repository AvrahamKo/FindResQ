import { api, setToken } from "./api.js";

export function renderLogin(root, { onLoggedIn }) {
  let stage = "phone"; // "phone" | "otp"
  let challengeId = null;
  let phone = "";
  let devCode = null;

  function render() {
    root.innerHTML = "";
    const wrap = document.createElement("div");
    wrap.className = "centered-form";
    const card = document.createElement("div");
    card.className = "card";
    wrap.appendChild(card);
    root.appendChild(wrap);

    if (stage === "phone") {
      card.innerHTML = `
        <h1>LifeSearch — Commander Dashboard</h1>
        <div class="field">
          <label>Phone number (E.164, e.g. +15551234567)</label>
          <input id="phone" type="tel" placeholder="+15551234567" value="${phone}" />
        </div>
        <div class="error" id="err"></div>
        <button id="submit">Send code</button>
      `;
      const submit = async () => {
        phone = card.querySelector("#phone").value.trim();
        const errEl = card.querySelector("#err");
        errEl.textContent = "";
        try {
          const res = await api.requestOtp(phone);
          challengeId = res.challenge_id;
          devCode = res.dev_code;
          stage = "otp";
          render();
        } catch (e) {
          errEl.textContent = e.message || "failed to request code";
        }
      };
      card.querySelector("#submit").addEventListener("click", submit);
      card.querySelector("#phone").addEventListener("keydown", (e) => {
        if (e.key === "Enter") submit();
      });
    } else {
      card.innerHTML = `
        <h1>Enter code</h1>
        <div class="field">
          <label>6-digit code sent to ${phone}</label>
          <input id="code" inputmode="numeric" maxlength="6" placeholder="123456" />
        </div>
        <div class="field">
          <label>Display name (optional)</label>
          <input id="name" placeholder="Commander" />
        </div>
        <div class="error" id="err"></div>
        <button id="submit">Verify</button>
        <button class="secondary" id="back" style="margin-left:8px;">Back</button>
        ${devCode ? `<div class="hint">Local dev code: ${devCode}</div>` : ""}
      `;
      card.querySelector("#back").addEventListener("click", () => {
        stage = "phone";
        render();
      });
      const submit = async () => {
        const code = card.querySelector("#code").value.trim();
        const name = card.querySelector("#name").value.trim();
        const errEl = card.querySelector("#err");
        errEl.textContent = "";
        try {
          const res = await api.verifyOtp(challengeId, code, name);
          setToken(res.access_token);
          onLoggedIn();
        } catch (e) {
          errEl.textContent = e.message || "invalid code";
        }
      };
      card.querySelector("#submit").addEventListener("click", submit);
      card.querySelector("#code").addEventListener("keydown", (e) => {
        if (e.key === "Enter") submit();
      });
    }
  }

  render();
}
