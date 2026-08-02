# LifeSearch — Session Handover Summary

**Date of handover:** 2026-08-02
**Last commit:** `628bf82` — "Phase 5d completed: Ingest sync engine with batch upload, exponential backoff, and full-chain E2E test against real PostGIS" (Phase 6/SOS work below is uncommitted as of this handover -- commit it before starting Reports or SMS fallback).
**Status:** Phase 6's SOS state machine sub-piece is complete and verified (Reports and SMS fallback are explicitly deferred -- see below). Git tree has uncommitted SOS changes. Both dev servers (Postgres in Docker, FastAPI backend) are healthy and running as of this handover -- **the backend server was restarted mid-session to pick up the new `/sos` route; see gotcha #12 below if a route you just added 404s.**

This is a life-safety SAR (Search & Rescue) coordination app. Backend (Python/FastAPI) built through Phase 4; Flutter mobile client started in Phase 5. Read this whole file before doing anything — it front-loads verification steps that matter.

---

## 1. Exact current state

### Test counts (verified at handover time, not from memory)
- **Backend: 161 pytest tests passing, 0 skipped** (up from 132 at the Phase 5d handover; requires the Docker Postgres container running — see below).
- **Mobile: 163 Dart tests passing** (`flutter test`, up from 131 at the Phase 5d handover), including three real end-to-end tests that hit the actual running backend (auth/join; the full location->buffer->sync->PostGIS chain; and now the full SOS trigger->acknowledge->resolve chain).

If a new session reports different numbers than these, trust the new run, not this document — re-verify rather than assume drift is a bug.

### Infrastructure right now
- **Postgres**: Docker container `lifesearch-db` (`postgis/postgis:16-3.4`), defined in `backend/docker-compose.yml`. This is the **permanent** local dev database — always use it, never assume a different Postgres. Migrations 0001–0006 are applied. Bring it up with:
  ```bash
  cd backend && docker compose up -d
  ```
- **Backend server**: was started manually for verification (`uvicorn app.main:app --host 0.0.0.0 --port 8000`, run with `python -u` for **unbuffered** output — see "Known gotchas" below for why `-u` matters). It may or may not still be running when a new session starts — check first:
  ```bash
  curl -s http://localhost:8000/healthz
  ```
  If not running, start it from `backend/` with the project venv active:
  ```bash
  "C:/Users/avrah/FindResQ/venv/Scripts/python.exe" -u -m uvicorn app.main:app --host 0.0.0.0 --port 8000
  ```
  **The venv lives at `C:\Users\avrah\FindResQ\venv`** — NOT `backend/venv`. This trips people up.
- **Backend `.env`**: exists at `backend/.env` (gitignored, contains real generated secrets — `JWT_SECRET`, `SECTOR_KEY_WRAP_SECRET`). If it's ever missing, regenerate secrets with `python -c "import secrets,base64; print(base64.b64encode(secrets.token_bytes(32)).decode())"` and see `backend/.env.example` for the full variable list.
- **Flutter SDK**: installed at `C:\Users\avrah\develop\flutter_windows_3.44.8-stable\flutter`. It is **not guaranteed to be on PATH** in a fresh shell — if `flutter`/`dart` aren't found, either use the full path (`C:\Users\avrah\develop\flutter_windows_3.44.8-stable\flutter\bin\flutter.bat`) or refresh PATH from the registry:
  ```powershell
  $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
  ```

### What's built, by phase
| Phase | Scope | Status |
|---|---|---|
| 0 | Postgres/PostGIS schema, H3 coverage ledger design | ✅ |
| 1 | Phone/OTP auth, Ed25519 device enrolment (proof-of-possession) | ✅ |
| 2 | Events, sectors, join codes, membership approval, session tokens w/ `key_epoch` | ✅ |
| 3 | Ingest pipeline (11 stages: decrypt→verify→dedup→plausibility→segment→swath→hexify→ledger→recalc), search-theory POD math | ✅ |
| 4 | Realtime dashboard: WebSocket transport, four-state presence + correlated-silence, coverage/presence REST endpoints | ✅ |
| 5a | Flutter scaffold, Dart crypto layer (wire format, XChaCha20-Poly1305, Ed25519) mirroring the backend byte-for-byte | ✅ |
| 5b | Flutter secure storage, API client, auth/join UI + Riverpod controllers | ✅ |
| 5c | Location service (battery-aware GPS sampling) + local SQLite offline buffer + telemetry packet construction/encryption | ✅ |
| 5d | Ingest sync engine: drains the local buffer to `/ingest` in batches, exponential backoff on failure | ✅ |
| 6a | SOS state machine: trigger/acknowledge/resolve/cancel, realtime broadcast to the dashboard channel | ✅ **(this session)** |
| 6b | Reports (clue/subject/hazard sightings) | ⬜ not started |
| 6c | SMS fallback for SOS when offline | ⬜ **deliberately deferred** (see "How to continue") |
| 7 | BLE mesh (Android) | ⬜ not started |
| 8 | Teardown, expiry, PII purge lifecycle | ⬜ not started |

---

## 2. Key architectural decisions (the "why," not just the "what")

### Crypto: real libsodium on both ends, never a reimplementation
- **Backend**: PyNaCl, calling libsodium's low-level bindings directly (`nacl.bindings`), not the higher-level `SecretBox` (which is XSalsa20-Poly1305, a *different* construction).
- **Mobile**: the `sodium` Dart package (**not** `sodium_libs` — that's discontinued, replaced by `sodium` directly as of its v4.0 native-assets rewrite).
- **Why both sides bind to the actual C library**: a pure-Dart or pure-Python reimplementation of XChaCha20-Poly1305/Ed25519 would be a *second, independent implementation* of the same crypto that could silently drift from the other side. Binding both to libsodium eliminates that risk entirely.
- **Wire format is a 27-byte fixed-width binary struct**, not JSON (`backend/app/mesh/wire_format.py` / `mobile/lib/core/crypto/wire_format.dart`). Ed25519 signs raw bytes; JSON would require both languages to agree on canonical serialization (key order, float formatting), a classic cross-language "signature verification fails intermittently" bug. Big-endian, fixed-point lat/lng (×1e7) instead of floats, for the same unambiguity reason.
- **This wire format is proven byte-for-byte compatible with permanent regression tests in both repos** (not just each side's own unit tests): `backend/tests/test_wire_format_interop.py` decodes a fixture generated by the real Dart client; `mobile/test/core/crypto/wire_format_interop_test.dart` decodes one generated by the real Python backend. If you ever change the wire format, regenerate both fixtures (Dart side: `dart run tool/generate_interop_fixture.dart` from `mobile/`).

### Storage: atomic JSON blobs, not scattered keys
`SecureStorageManager` (`mobile/lib/core/storage/`) stores `StoredDeviceIdentity`, `StoredAccount`, and `StoredSession` each as **one JSON blob under one key**, not as several separate key-value pairs. Writing related fields separately risks the app being killed mid-write and leaving e.g. a session token persisted without its sector key. One write, one atomic unit.

The actual storage backend is injected behind a `KeyValueStore` interface — production uses `flutter_secure_storage` (Keychain/Keystore), tests use an in-memory fake. This is what makes storage logic testable without a real platform channel (which doesn't exist in a bare `flutter test` host process).

### State management: Riverpod `StateNotifier` + sealed-class states
`AuthController` and `JoinController` are `StateNotifier`s exposing sealed classes (`AuthState`, `JoinState`) so the UI can exhaustively `switch` over every phase with no missed-case risk. `ApiClient` is deliberately **stateless with respect to auth** — every method takes its bearer token as an explicit parameter rather than the client holding "the current token" as mutable state; the controllers own token lifecycle.

Device registration is retry-safe by construction: the Ed25519 keypair is generated and persisted to Secure Storage *before* any network call, so a dropped connection between "generate key" and "confirm registration" never causes a second keypair on retry. A 409 "already registered to you" conflict from the backend is treated as success (recovered via `GET /devices`), not failure.

### Backend geospatial/coverage decisions (Phases 0–4, still governing)
- **PostGIS `ST_Buffer` on `geography`** for swath buffering, not shapely+pyproj UTM reprojection in Python — `geography` buffering computes true ground-distance meters natively.
- **H3 hexagonal grid, resolution 12** (~9.4m edge) for the coverage ledger.
- **Search-theory POD formula lives in exactly one place**: the SQL function `recalc_hex_coverage()` (migration 0001). Never reimplemented in Python — tests drive the real function, they don't duplicate its math.
- **CQRS-style ledger**: `hex_contributions` (immutable, one row per traverse-episode) + `hex_coverage_state` (derived, rebuildable from the ledger at any time).
- **Realtime broadcast is a property of the data changing**, not application code remembering to notify: `AFTER INSERT OR UPDATE` triggers on `hex_coverage_state`/`device_presence` fire `pg_notify`. Verified empirically (not assumed) that Postgres collapses identical `(channel, payload)` notifications fired within one transaction into a single delivery — so a bulk UPSERT touching hundreds of rows produces exactly one notification.
- **WebSocket auth uses short-lived, single-use tickets** (`POST .../ws-ticket` → `WS ?ticket=...`), not a bearer token in the URL query string (which would land in every proxy/access log).

### Location tracking: battery-aware sampling tiers, packet construction decoupled from upload
- **`LocationSamplingPolicy` (`mobile/lib/core/location/location_sampling_policy.dart`) is pure logic**, no plugin import, mapping `(batteryPct, isCharging) -> SamplingTier` (distance filter in meters + an accuracy hint). Tiers: high (≥60%, 10m), balanced (30–59%, 25m), saver (15–29%, 50m), critical (<15%, 100m) — charging always forces `high` regardless of level. Distance-filtered sampling, not fixed-interval polling, per the original architecture review's Q8: a stationary searcher shouldn't drain the battery for zero new track data.
- **`LocationTrackingController` re-checks the tier after every emitted sample** (not on a separate timer) and re-subscribes to `LocationSource` at the new tier when it changes — keeps the whole controller driven by the position stream, with no wall-clock dependency, which is also what makes it testable via a fake stream with no `fake_async`.
- **`stop()` is synchronous and does NOT await `StreamSubscription.cancel()`** — deliberately. Under `testWidgets`'s test zone, a broadcast `StreamController`'s `cancel()` future was observed to never resolve while `tester.pump()` calls kept being issued back-to-back (see the "known gotchas" entry below); not depending on it also means state reflects "stopped" immediately and a slow/stalled cancel can never block the UI.
- **Telemetry packet construction mirrors the backend exactly**: `TelemetryPacketBuilder` (`mobile/lib/core/location/telemetry_packet_builder.dart`) does `pack(point) -> sign(payload) -> encrypt(payload || signature)`, producing the same 91-byte plaintext shape as `backend/app/ingest/pipeline.py`'s `_EXPECTED_PLAINTEXT_BYTES`. This is Phase 5c's contribution to the wire contract; Phase 5a's `wire_format.dart`/`mesh_crypto.dart` did the packing/crypto primitives, this phase composes them into an actual packet.
- **The local buffer (`TelemetryBufferStore`) is real SQLite** via `sqflite_common`'s `DatabaseFactory` abstraction — the `sqflite` plugin's factory on Android/iOS, `sqflite_common_ffi`'s factory everywhere else (desktop, tests) — not a fake or an in-memory Dart structure. FIFO-capacity-bounded at 10,000 packets per the original PRD; `peekOldest`/`acknowledge` (not a destructive dequeue) so Phase 5d's upload path can retry safely on a dropped connection.
- **`StoredDeviceIdentity` now also carries `wireId`** (previously only `deviceId`, the UUID) — added because the wire format needs the compact `devices.wire_id`, not the UUID, and it wasn't threaded through to storage before this phase. `AuthController._ensureDeviceRegistered` now saves both together via `withRegistration(...)` (was `withDeviceId(...)`).

### Ingest sync: whole-batch acknowledgement, self-scheduling with backoff
- **`IngestSyncController` (`mobile/lib/core/sync/ingest_sync_controller.dart`) acknowledges (deletes from the buffer) the WHOLE batch it sent on ANY 200 response** from `/ingest`, not just the `accepted` count. This is deliberate, not a bug: `IngestResult`'s docstring explains why -- every count bucket the backend returns (`accepted`, `duplicate`, `decrypt_failed`, `signature_invalid`, `wrong_device`, `malformed`) is a TERMINAL, deterministic outcome for that exact packet; there is no "try again later" category in a 200 response, so retrying a permanently-bad packet would just fail identically forever. A batch is only left buffered for retry when the REQUEST ITSELF didn't get a 200 at all (network failure, timeout, 5xx).
- **Self-scheduling via `Timer`, same pattern as `LocationTrackingController`**: `start()` kicks off a loop that reschedules itself after every attempt -- a short fixed interval when healthy/idle, exponential backoff (`SyncBackoffPolicy`, pure/testable, doubling from 5s up to a 5-minute cap) after a failure. `syncOnce()` is public specifically so tests can drive one attempt directly without waiting on real timers.
- **`stop()` is synchronous**, same reasoning as `LocationTrackingController.stop()`: cancel the `Timer` and flip `_running = false` without awaiting anything, so the UI reflects "stopped" immediately and nothing in-flight can block it.
- **The two controllers are wired together at the UI layer, not internally**: `LocationStatusView`'s Start button calls `LocationTrackingController.start()` then `IngestSyncController.start()` -- but ONLY if tracking actually reached `TrackingActive` (checked explicitly). A real bug caught during this phase: an earlier version started sync unconditionally, so a denied location permission left the sync loop running with nothing useful to do (and, in a widget test, a `Timer` that outlived the test). Stop is unconditional both ways (stopping sync even if tracking already failed is harmless).

### SOS state machine: explicit and immediate, separate from passive presence
- **States**: `active -> acknowledged -> resolved`, or `active`/`acknowledged -> cancelled` (only by the triggering user -- a false alarm). See `backend/migrations/0006_sos.sql` for the full diagram. This is deliberately independent of Phase 4's correlated-silence presence heuristic -- that's a passive INFERENCE from a device going quiet; SOS is an explicit, affirmative "I need help now" action from the searcher. They are not merged into one state machine.
- **At most one OPEN alert per device, enforced by the database, not just application code**: a partial unique index (`sos_alerts_one_open_per_device`, on `device_id` `WHERE status IN ('active','acknowledged')`) makes a second trigger from the same device impossible to land as a duplicate row even under a race between two near-simultaneous requests. `sos_repo.trigger()` is idempotent on top of that (checks first, and also catches the unique-violation race and returns the existing row) -- a shaky-hands double-tap or an app restart mid-emergency must never fork into two concurrent incidents for what is the same emergency.
- **Trigger/cancel use the device's SECTOR SESSION token** (same auth as `/ingest`); **list/acknowledge/resolve use the ACCOUNT token plus the existing Lead/Commander RBAC check** (`require_lead_or_commander`, same as membership moderation) -- those actions happen on a different device (the Sector Lead's), not the volunteer's.
- **A missing trigger location falls back to the device's last known presence point** (`device_presence`, Phase 4) rather than requiring a fresh GPS fix before SOS can even be sent -- hitting SOS is exactly the moment a fresh fix might not have landed yet (canyon, indoors, dead zone).
- **Realtime broadcast follows the established `hex_coverage_state`/`device_presence` pattern exactly**: an `AFTER INSERT OR UPDATE` trigger on `sos_alerts` notifies `sector_sos_channel`; `RealtimeListener` re-queries "what changed since my checkpoint" and broadcasts a `sos_delta` message over the same per-event WebSocket. Verified end-to-end against a real connected client in `backend/tests/test_sos_routes.py::TestRealtimeBroadcast`, mirroring `test_ws_dashboard.py`'s existing proof for hex/presence.
- **Mobile: two independent controllers, not one.** `SosController` (searcher's own trigger/cancel) does not persist across app restarts -- there is no "get my current alert" endpoint, and none is needed, since `trigger()` is idempotent server-side, so pressing the button again after a restart safely lands back on the same open alert. `SosAlertsController` (Lead/Commander's list/acknowledge/resolve) is UI-driven polling (`Timer.periodic`, same convention as `PendingApprovalView`), not a `sos_delta` WebSocket client -- no WebSocket client exists in the Flutter app yet (see gotcha #13).
- **Known scope boundary, not a bug**: `SosAlertsController` reads the acting user's `sectorId` from their OWN `StoredSession`, so a pure Commander who has never joined any sector as a member (the backend allows this; Commanders act via `event.commander_id`, no membership required) has no client-side way to discover a sector's id today. The E2E test (`mobile/test/e2e/sos_e2e_test.dart`) works around this by having the "Commander" character also self-join their own sector purely to populate `sectorId` locally -- the actual authorization still comes from the backend's Commander check, independent of that membership. Fine for this session's scope; would need a "my events/sectors" listing endpoint + screen to close properly.

### Testing philosophy established across every phase
**Prefer real infrastructure over mocks, and only mock at the outermost I/O boundary.** Concretely:
- Real Postgres (Docker) for all DB-dependent backend tests — never a mocked database.
- Real libsodium for all crypto tests — never a fake crypto implementation.
- Real running backend server for the mobile e2e test — only the HTTP transport layer is ever mocked (via `http`'s `MockClient`), never the business logic.
- DB-dependent tests skip gracefully (not fail) when the database is unreachable, via a `db_conn` fixture pattern — but tests needing a **real commit** (anything depending on `NOTIFY` delivery, which only fires post-commit) use an independent, non-rollback connection instead of the standard rollback-wrapped fixture.

---

## 3. Where things live (file map)

### Backend (`backend/`)
```
app/
  main.py                  FastAPI app, CORS, lifespan (DB pool, realtime listener, presence sweep)
  config.py                Settings (pydantic-settings, reads .env)
  db.py                    asyncpg pool
  errors.py                Typed exceptions → HTTP error envelope
  mesh/wire_format.py      27-byte struct pack/unpack — THE wire contract
  security/
    mesh_crypto.py         XChaCha20-Poly1305 (raw libsodium bindings)
    signatures.py          Ed25519 verify
    tokens.py              JWT issue/decode (account token + session token)
    envelope.py            Sector key wrap/unwrap at rest
  repositories/            One file per aggregate: users, devices, events, sectors,
                           sector_keys, memberships, join_codes, track_points,
                           hex_contributions, presence, sos (Phase 6)
  ingest/
    pipeline.py            The 11-stage ingest orchestrator
    geometry.py, plausibility.py, segmentation.py, coverage.py   (pure logic, no DB)
  presence/
    classifier.py          Four-state + correlated-silence heuristic (pure)
    sweep.py                DB orchestrator, periodic background task
  realtime/
    manager.py              WebSocket connection tracking (per-process, in-memory)
    tickets.py               Short-lived single-use WS connection tickets
    listener.py              Postgres LISTEN/NOTIFY background task -- now also
                              SOS_CHANNEL -> sos_delta (Phase 6), alongside
                              coverage/presence
  api/routes/               One file per resource: auth, devices, events, sectors,
                            memberships, ingest, coverage, presence, sos (Phase 6), ws
migrations/                 0001_init → 0006_sos, applied in order
tests/                      161 tests; conftest.py has the db_conn skip-if-unreachable
                            fixture; test_sos_repo.py/test_sos_routes.py (Phase 6) add
                            their own local `real_conn` fixture for cases needing
                            `now()` to actually advance between statements -- see
                            gotcha #14
docker-compose.yml           The permanent Postgres+PostGIS dev container
```

### Mobile (`mobile/`)
```
lib/
  main.dart                        Entry point; platform-aware base URL selection
  core/platform_base_url.dart      THE bug-fix from this session — pure, tested
  core/crypto/                     Phase 5a: wire_format, mesh_crypto, device_identity,
                                   sodium_provider — byte-for-byte mirror of the backend
  core/storage/                    key_value_store (interface), secure_key_value_store
                                   (prod), secure_storage_manager, stored_models
  core/api/                        api_client, api_exception, api_models
  core/auth/                       auth_controller, auth_state (sealed classes)
  core/join/                       join_controller, join_state (sealed classes)
  core/location/                   Phase 5c: location_sample, location_source (+
                                   GeolocatorLocationSource), battery_info_provider (+
                                   BatteryPlusInfoProvider), location_sampling_policy
                                   (pure), telemetry_packet_builder, tracking_state
                                   (sealed), location_tracking_controller
  core/storage/telemetry_buffer_store.dart   Phase 5c: real-SQLite FIFO packet buffer
  core/sync/                       Phase 5d: sync_backoff_policy (pure), sync_state
                                   (sealed), ingest_sync_controller
  core/sos/                        Phase 6: sos_state/sos_controller (searcher's own
                                   trigger/cancel), sos_alerts_state/sos_alerts_controller
                                   (Lead/Commander list/acknowledge/resolve)
  core/providers.dart              Riverpod wiring — every I/O-touching provider is
                                   overridable for tests
  app.dart                         Root widget; routes on AuthState → LoginScreen or
                                   JoinScreen
  ui/screens/                      phone_entry_view, otp_entry_view, login_screen,
                                   join_code_view, membership_status_view, join_screen,
                                   location_status_view (Phase 5c/5d debug/ops screen —
                                   drives BOTH LocationTrackingController and
                                   IngestSyncController from one Start/Stop pair,
                                   reached from SessionActiveView), sos_button_view
                                   (searcher SOS, Phase 6), sos_alerts_view
                                   (Lead/Commander SOS list, Phase 6) — both reached
                                   from SessionActiveView
test/
  core/                            Unit tests per module above
  ui/                              Widget tests (app_flow_widget_test.dart drives the
                                   ENTIRE UI flow through real screens)
  e2e/auth_join_e2e_test.dart      Real end-to-end test against the real backend —
                                   run this first if anything auth/join-related seems off
  e2e/location_sync_e2e_test.dart  Phase 5d: the FULL chain against the real backend —
                                   fake GPS -> real crypto -> real SQLite buffer -> real
                                   /ingest -> real PostGIS (hexes_touched proves it)
  e2e/sos_e2e_test.dart            Phase 6: real trigger -> real list -> real
                                   acknowledge -> real resolve, against the real backend
  helpers/in_memory_key_value_store.dart   Test double for KeyValueStore
  helpers/commander_fixture.dart   Shared E2E fixture (account/event/sector/join-code/
                                   approve against the real backend) -- used by both
                                   e2e test files, factored out in Phase 5d to avoid
                                   duplicating it
  helpers/fake_location_source.dart, fake_battery_info_provider.dart   Test doubles for
                                   LocationSource/BatteryInfoProvider (real GPS/battery
                                   have no host-process equivalent)
tool/generate_interop_fixture.dart          Regenerate the Dart→Python interop fixture
                                            if the wire format ever changes
```

---

## 4. Known gaps and gotchas (read before debugging blind)

1. **Flutter web target doesn't work yet.** The `sodium` package needs a manual JS-libsodium-asset download step for web builds (its own README calls this out) that was never done. Not a bug, just unfinished — orthogonal to everything else. `web/` and `windows/` platform folders exist in the repo (added during this session's debugging) but web specifically will hang on a blank splash screen forever if you try to run it without that extra step.
2. **Android toolchain is incomplete.** `flutter doctor` reports missing `cmdline-tools` and unaccepted licenses. This does **not** block `flutter test` (runs on the host Dart VM regardless of mobile toolchain state) but **does** block building/running on an actual Android emulator or device. Needed before Phase 5c if location-service testing requires a real/emulated Android device.
3. **Server output buffering**: if you ever redirect the backend's stdout to a file or pipe it through a task runner / IDE console, Python block-buffers non-TTY output and log lines can sit unwritten for a long time. Always run with `python -u` (or `PYTHONUNBUFFERED=1`) when output isn't going straight to a visible terminal.
4. **`10.0.2.2` is Android-emulator-only.** If you ever see a Flutter client hang on any network call with nothing reaching the backend, check `mobile/lib/core/platform_base_url.dart` and confirm the target platform is being detected correctly — this exact bug already happened once this session.
5. **Don't trust an analyzer-suggested rewrite without checking its actual behavior.** `flutter analyze`'s own suggestion to rewrite `if (label != null) 'label': label` as `?'label': label` silently changed the semantics (null-checks the map *key*, not the *value* — the key is a string literal, so the entry was always included). Caught by direct empirical testing, not by reading documentation. If `flutter analyze` suggests a rewrite involving `?` on a literal map key, verify it doesn't change behavior before applying it.
6. **Battery percentage in the join-code UI is still user-entered** (a slider) — Phase 5c added `BatteryPlusInfoProvider` for real device battery, but only for the location-tracking sampling policy, not (yet) wired back into the join-code UI's slider. Leave as-is unless asked to change it; it's a deliberate scope boundary, not an oversight.
7. **`MembershipInfo.role`/`movementMode` from the backend must be threaded through the join flow explicitly** — an earlier draft of `JoinController` hardcoded placeholder values instead of using the real fields already returned by `GET /memberships/{id}`; this was caught and fixed, but if you're extending the join flow, make sure new state transitions keep passing these through rather than reintroducing placeholders.
8. **`sqflite_common_ffi`'s isolate-backed `databaseFactoryFfi` does not work inside `testWidgets`** (Flutter's widget-test zone) — its background isolate's replies arrive via the real event loop in a way `tester.pump()` never observes, so any `await` on it can hang indefinitely while pumps keep getting issued. Use `databaseFactoryFfiNoIsolate` (same package) for any widget test that touches `TelemetryBufferStore`; the plain, non-widget `test()`-based controller test uses the normal isolate-backed `databaseFactoryFfi` instead, since a bare `test()` isn't wrapped in that zone. See `mobile/test/ui/screens/location_status_view_test.dart`'s `setUp` for the concrete pattern.
9. **`TelemetryBufferStore` opens with `singleInstance: false`.** `sqflite_common`'s factories cache open connections by literal path string when `singleInstance` isn't set to false — every test using the literal `inMemoryDatabasePath` (`':memory:'`) would otherwise silently share ONE underlying connection across different `TelemetryBufferStore` instances, and close()/open() timing races between tests caused real (previously debugged) cross-test data leakage. If you ever see a `TelemetryBufferStore`-related test with an inexplicably wrong row count, check this first.
10. **A real `Timer`-owning controller (like `IngestSyncController`) must be stopped as the LAST STATEMENT inside the `testWidgets` body itself, not via `tearDown` or `addTearDown`.** Flutter's test binding asserts no `Timer` is still pending as part of `_runTestBody`, which runs BEFORE both `tearDown` and `addTearDown` callbacks get a chance to fire — so `container.dispose()` (which would otherwise cancel the timer through the controller's own `dispose()`) is always too late if only called from `tearDown`. See `location_status_view_test.dart`'s `stopControllers()` helper and its usage for the working pattern.
11. **A bare `await Future.delayed(...)` with no `tester.pump()` calls around it can hang indefinitely inside `testWidgets`** — real Timer/event-loop progress in that test binding only reliably happens interleaved with `pump()` calls. Any "wait for something timer-driven to happen" in a widget test must go through a `pump()` loop (see `pumpUntilFound` in `location_status_view_test.dart`), never a standalone delay. This is a DIFFERENT issue from gotcha #10 (or from Phase 5c's `sqflite_common_ffi`-under-FakeAsync gotcha) but produces the same symptom (a hang), so if a widget test hangs, check for a bare `Future.delayed` first — it's the cheapest thing to rule out.
12. **After adding a new route to `main.py`, the ALREADY-RUNNING backend server process is still serving the OLD code until restarted.** Hit this directly this session: `POST /sos` 404'd against the running server for several minutes of debugging before realizing the fix was in the code, not the test -- the uvicorn process just hadn't picked up the new router registration (it wasn't started with `--reload`). If a route you just added/changed 404s or behaves like it doesn't exist, restart the server (`netstat -ano | grep :8000` to find the PID, kill it, relaunch per Section 1's start command) before debugging further.
13. **There is still no WebSocket client anywhere in the Flutter app.** The backend's realtime broadcast (coverage/presence/SOS deltas, all three now) is fully built and proven end-to-end from the SERVER side (`test_ws_dashboard.py`, `test_sos_routes.py::TestRealtimeBroadcast`), but nothing on the mobile side subscribes to it -- `SosAlertsView`'s Lead/Commander list uses plain REST polling (`Timer.periodic`, 5s), same convention as `PendingApprovalView`. Building a real WS client in Flutter (ticket fetch -> connect -> handle `hex_delta`/`presence_delta`/`sos_delta`) is still open work, likely warranted once there's a concrete reason to want push latency instead of a 5s poll.
14. **Postgres's `now()` is frozen at TRANSACTION START, not per-statement** — `conftest.py`'s `db_conn` fixture wraps a whole test in ONE transaction, so two sequential inserts under `db_conn` can get the IDENTICAL `now()`-derived timestamp, breaking any assertion that depends on strict ordering or a `updated_at > checkpoint` delta query. Hit this writing `test_sos_repo.py`'s `TestListAndDeltaQueries` (two triggers landed on the same `triggered_at`, and a resolve's `updated_at` didn't compare greater than its own trigger's checkpoint). Fix: use a local `real_conn` fixture (separate `asyncpg.connect()`, no wrapping transaction, manual cleanup -- same shape as `test_ws_dashboard.py`'s) for any test that needs `now()` to actually advance between statements; `db_conn` is still correct and preferred for everything else (its transaction-per-test isolation is exactly what most tests want).

---

## 5. How to continue in a new session

**First, always re-verify rather than trust this document blindly** (it may already be stale by the time you read it):
```bash
cd backend && docker compose up -d   # ensure Postgres is up
curl -s http://localhost:8000/healthz   # check if the backend is already running
# if not running, start it (see section 1 above)
cd backend && "C:/Users/avrah/FindResQ/venv/Scripts/python.exe" -m pytest -q
cd mobile && flutter test
```
If both suites are green and match (or exceed) the counts in Section 1, the project is in the state this document describes.

**Then, pick up wherever the user directs — likely candidates, in the order they were originally planned:**
- **Phase 6b (Reports)**: clue/subject/hazard sightings, structured, attached to a sector/location. Mostly CRUD + a mobile form + a Lead/Commander-side view -- the SOS work this session (migration + repo + schema + route + realtime broadcast + `sos_repo`'s idempotent-trigger pattern) is a reasonable template to follow for the backend shape, though Reports won't need the "one open per device" invariant or the session-vs-account-token split SOS has.
- **Phase 6c (SMS fallback)**: explicitly deferred this session by user decision -- needs a real transport choice first (device-native `SmsManager` on Android vs. a server-side gateway like Twilio) before any code should be written; see the two options discussed and ask before assuming one.
- **Phase 7+**: BLE mesh (Android), teardown/PII purge lifecycle -- still fully unstarted, matching the original architecture review's build order.
- **A real WebSocket client in Flutter** (gotcha #13) would let `SosAlertsView` (and a future coverage/presence dashboard view) push-update instead of polling every 5s -- not urgent, but the backend has supported it since Phase 4 and now broadcasts three delta types (`hex_delta`, `presence_delta`, `sos_delta`) that nothing on the client consumes yet.
- A few things intentionally deferred, not forgotten, if they come up: the join-code UI's battery slider is still user-entered rather than reading `BatteryPlusInfoProvider` (gotcha #6); `IngestSyncController`'s batch size (200) and intervals (30s base / 5s–5min backoff) are reasonable defaults but untuned against real cellular conditions; there's no UI surfacing of a stuck/growing buffer beyond the debug view's raw pending count; `SosAlertsController` requires the acting Lead/Commander to have a `StoredSession` of their own (gotcha-adjacent, see the SOS architectural section above) -- a "my events/sectors" endpoint + screen would close that gap for a pure Commander who never joins a sector as a member.
- Note: the Android toolchain is still incomplete (`flutter doctor` reports missing `cmdline-tools`/licenses — see gotcha #2), so neither the location service nor the sync engine has been verified on a real/emulated Android device — only via `flutter test` (fake `LocationSource`/`BatteryInfoProvider`, real crypto/SQLite/HTTP) and the E2E tests against the real backend. If later work needs to verify real GPS/permission/background-execution behavior on-device, the toolchain will need fixing first.

**Whatever you build next, hold it to the same standard already established**: real infrastructure over mocks wherever feasible, a genuine end-to-end test (not just unit tests) for anything crossing a real boundary (network, DB, native crypto), and don't trust a tool's own suggestion (linter, formatter) without empirically checking it preserves behavior.
