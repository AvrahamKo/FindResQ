import { api } from "./api.js";

// The missing person's record: the single most operationally important piece
// of context in a callout, and also third-party PII about someone who never
// consented to this app. Both facts drive this module:
//   - medical notes get visual prominence (a searcher finding a diabetic
//     subject needs that fact to reach them fast), and
//   - the consent trail and purge deadline are shown as first-class fields,
//     not buried, because a commander editing this record is the person
//     accountable for both.

const MAX_DESCRIPTION = 2000;
const MAX_MEDICAL = 2000;
const MAX_CONSENT = 500;

function esc(value) {
  const div = document.createElement("div");
  div.textContent = value ?? "";
  return div.innerHTML;
}

function formatDate(iso) {
  if (!iso) return "—";
  return new Date(iso).toLocaleString();
}

const DEFAULT_RETENTION_DAYS = 30;
const MS_PER_DAY = 24 * 60 * 60 * 1000;

/// Recovers the retention period that was last saved.
///
/// `SubjectOut` returns the absolute `purge_after` deadline, not the
/// `retention_days` that produced it -- but the backend sets
/// `purge_after = now + retention_days` in the same statement that sets
/// `consent_recorded_at = now()`, so the gap between them IS the retention.
///
/// This matters more than it looks: PUT recomputes `purge_after` from
/// whatever this field holds. Defaulting the box back to 30 would mean a
/// commander who opens the form to fix a typo in the name silently EXTENDS
/// how long this person's medical details are retained. Deriving it keeps an
/// edit that doesn't touch retention from changing retention.
function derivedRetentionDays(subject) {
  if (!subject || !subject.purge_after || !subject.consent_recorded_at) {
    return DEFAULT_RETENTION_DAYS;
  }
  const days = Math.round(
    (new Date(subject.purge_after) - new Date(subject.consent_recorded_at)) / MS_PER_DAY
  );
  // Clamp to the backend's own accepted range rather than sending a value
  // that would 422 (e.g. if a row was written by some other path).
  if (!Number.isFinite(days) || days < 1) return DEFAULT_RETENTION_DAYS;
  return Math.min(days, 180);
}

/// Opens the subject modal. `canEdit` is false for anyone who isn't the
/// event's commander -- the backend enforces this too (403), this just
/// avoids offering an action that can only fail.
export function showSubjectModal(eventId, { canEdit }) {
  const overlay = document.createElement("div");
  overlay.className = "modal-overlay";
  overlay.innerHTML = `
    <div class="modal" role="dialog" aria-modal="true" aria-label="Subject record">
      <div class="modal-head">
        <h3>Subject — missing person</h3>
        <button class="secondary" id="subject-close">Close</button>
      </div>
      <div class="modal-body" id="subject-body">
        <div class="empty-hint">Loading…</div>
      </div>
    </div>
  `;
  document.body.appendChild(overlay);

  const close = () => overlay.remove();
  overlay.querySelector("#subject-close").addEventListener("click", close);
  // Click-outside closes, but only on the backdrop itself -- a click that
  // started inside the dialog must not dismiss it.
  overlay.addEventListener("click", (e) => {
    if (e.target === overlay) close();
  });
  document.addEventListener("keydown", function onKey(e) {
    if (e.key !== "Escape") return;
    document.removeEventListener("keydown", onKey);
    close();
  });

  const body = overlay.querySelector("#subject-body");
  loadAndRender(body, eventId, canEdit);
  return overlay;
}

async function loadAndRender(body, eventId, canEdit) {
  let subject;
  try {
    subject = await api.getSubject(eventId);
  } catch (e) {
    body.innerHTML = `<div class="form-error">${esc(e.message || "failed to load subject")}</div>`;
    return;
  }
  if (subject === null) {
    if (!canEdit) {
      body.innerHTML =
        '<div class="empty-hint">No subject recorded for this event yet.</div>';
      return;
    }
    renderForm(body, eventId, null, canEdit);
    return;
  }
  renderView(body, eventId, subject, canEdit);
}

function renderView(body, eventId, subject, canEdit) {
  const rows = [
    ["Name", esc(subject.display_name)],
    ["Age", subject.age_years == null ? "—" : `${subject.age_years}`],
    ["Description", esc(subject.description) || "—"],
  ];

  body.innerHTML = `
    ${rows
      .map(
        ([label, value]) =>
          `<div class="field-row"><span class="field-label">${label}</span><span class="field-value">${value}</span></div>`
      )
      .join("")}
    <div class="medical-block">
      <div class="field-label">Medical notes</div>
      <div class="field-value">${esc(subject.medical_notes) || "None recorded"}</div>
    </div>
    <div class="field-row"><span class="field-label">Consent basis</span><span class="field-value">${esc(subject.consent_basis) || "—"}</span></div>
    <div class="field-row"><span class="field-label">Consent recorded</span><span class="field-value">${formatDate(subject.consent_recorded_at)}</span></div>
    <div class="purge-notice">
      PII auto-purge deadline: <strong>${formatDate(subject.purge_after)}</strong>
    </div>
    <div class="modal-actions" id="subject-actions"></div>
  `;

  if (!canEdit) return;
  const editBtn = document.createElement("button");
  editBtn.id = "subject-edit";
  editBtn.textContent = "Edit details";
  editBtn.addEventListener("click", () => renderForm(body, eventId, subject, canEdit));
  body.querySelector("#subject-actions").appendChild(editBtn);
}

function renderForm(body, eventId, existing, canEdit) {
  const isNew = existing === null;
  // Prefilled from the CURRENT record, always. PUT overwrites every column,
  // so submitting a partially-filled form would silently null out whatever
  // was left blank -- including medical notes.
  const v = existing ?? {};

  body.innerHTML = `
    ${isNew ? '<div class="empty-hint">No subject recorded yet — add the details below.</div>' : ""}
    <div class="form-field">
      <label for="subj-name">Name <span class="req">*</span></label>
      <input id="subj-name" maxlength="200" value="${esc(v.display_name)}" />
    </div>
    <div class="form-field">
      <label for="subj-age">Age (years)</label>
      <input id="subj-age" type="number" min="0" max="130" value="${v.age_years ?? ""}" />
    </div>
    <div class="form-field">
      <label for="subj-description">Description (clothing, build, last seen)</label>
      <textarea id="subj-description" rows="3" maxlength="${MAX_DESCRIPTION}">${esc(v.description)}</textarea>
    </div>
    <div class="form-field medical-block">
      <label for="subj-medical">Medical notes</label>
      <textarea id="subj-medical" rows="3" maxlength="${MAX_MEDICAL}">${esc(v.medical_notes)}</textarea>
      <div class="field-hint">Conditions, medication, allergies — reaches searchers who find the subject.</div>
    </div>
    <div class="form-field">
      <label for="subj-consent">Consent basis <span class="req">*</span></label>
      <input id="subj-consent" maxlength="${MAX_CONSENT}"
             placeholder="e.g. verbal, from spouse, by phone"
             value="${esc(v.consent_basis)}" />
      <div class="field-hint">Who authorised recording this person's details, and how.</div>
    </div>
    <div class="form-field">
      <label for="subj-retention">Retention (days)</label>
      <input id="subj-retention" type="number" min="1" max="180"
             value="${derivedRetentionDays(existing)}" />
      <div class="field-hint">
        Saving always restarts the purge countdown from now.
      </div>
    </div>
    <div class="form-error" id="subject-error"></div>
    <div class="modal-actions">
      <button id="subject-save">${isNew ? "Save subject" : "Save changes"}</button>
      <button class="secondary" id="subject-cancel">Cancel</button>
    </div>
  `;

  const errorEl = body.querySelector("#subject-error");
  const saveBtn = body.querySelector("#subject-save");

  body.querySelector("#subject-cancel").addEventListener("click", () => {
    if (isNew) loadAndRender(body, eventId, canEdit);
    else renderView(body, eventId, existing, canEdit);
  });

  saveBtn.addEventListener("click", async () => {
    errorEl.textContent = "";
    const name = body.querySelector("#subj-name").value.trim();
    const consent = body.querySelector("#subj-consent").value.trim();
    if (!name) {
      errorEl.textContent = "Name is required.";
      return;
    }
    if (!consent) {
      errorEl.textContent = "Consent basis is required — it is the record of who authorised this.";
      return;
    }

    const ageRaw = body.querySelector("#subj-age").value.trim();
    const retentionRaw = body.querySelector("#subj-retention").value.trim();
    const description = body.querySelector("#subj-description").value.trim();
    const medical = body.querySelector("#subj-medical").value.trim();

    saveBtn.disabled = true;
    try {
      await api.upsertSubject(eventId, {
        display_name: name,
        // Empty string would fail the backend's int validation, so an
        // unknown age is sent as an explicit null rather than "".
        age_years: ageRaw === "" ? null : Number(ageRaw),
        description: description === "" ? null : description,
        medical_notes: medical === "" ? null : medical,
        consent_basis: consent,
        retention_days: retentionRaw === "" ? 30 : Number(retentionRaw),
      });
      await loadAndRender(body, eventId, canEdit);
    } catch (e) {
      errorEl.textContent = e.message || "failed to save subject";
      saveBtn.disabled = false;
    }
  });
}
