# LifeSearch API

Search & rescue coordination backend. FastAPI + PostgreSQL/PostGIS + asyncpg.

## Prerequisites

- **Python 3.11+** (3.12 recommended). The system Python on this machine is
  3.9.5, which is end-of-life and will not run this code — `slots=True`
  dataclasses require 3.10+.
- PostgreSQL 15+ with PostGIS.

## Setup

```powershell
cd C:\Users\avrah\FindResQ\backend

py -3.12 -m venv .venv
.\.venv\Scripts\Activate.ps1

python -m pip install --upgrade pip
pip install -r requirements.txt
```

### Database

```powershell
psql -U postgres -c "CREATE DATABASE lifesearch;"
psql -U postgres -c "CREATE USER lifesearch WITH PASSWORD 'lifesearch';"
psql -U postgres -c "GRANT ALL PRIVILEGES ON DATABASE lifesearch TO lifesearch;"

psql -U postgres -d lifesearch -f migrations\0001_init.sql
psql -U postgres -d lifesearch -f migrations\0002_auth.sql
```

### Configuration

```powershell
Copy-Item .env.example .env
python -c "import secrets; print(secrets.token_urlsafe(64))"   # paste into JWT_SECRET
```

## Run

```powershell
uvicorn app.main:app --reload --port 8000
```

- Interactive docs: <http://localhost:8000/docs> (local only)
- Liveness: `GET /healthz` · Readiness: `GET /readyz`

## Tests

```powershell
pytest
```

The Phase 1 suite is pure — no database, no HTTP — and covers the enrolment
crypto boundary.

## Phase 1 flow

```
POST /auth/otp/request      { phone_e164 }
   -> { challenge_id, expires_at, dev_code }      # dev_code only when ENV=local

POST /auth/otp/verify       { challenge_id, code, display_name }
   -> { access_token, expires_at, user }

POST /devices/key-challenge                        # Authorization: Bearer <token>
   -> { challenge_id, nonce, expires_at }

POST /devices               { challenge_id, public_key, signature, platform }
   -> { id, wire_id, public_key, platform, mesh_capable, ... }

GET    /devices                                    # list this user's devices
DELETE /devices/{id}                               # soft-revoke
```

## Layout

```
app/
  config.py          Settings; refuses to boot with a placeholder secret
  db.py              asyncpg pool lifecycle
  errors.py          Typed errors -> HTTP, rendered by one handler in main
  main.py            App assembly
  security/
    signatures.py    Ed25519 encode/decode/verify  (pure)
    tokens.py        JWT issue/decode
    otp.py           OTP generation + PBKDF2 hashing  (pure)
  repositories/      SQL only. No HTTP types cross this boundary.
  api/
    deps.py          get_conn, current_user
    schemas/         Pydantic request/response models
    routes/          HTTP handlers
migrations/          Plain .sql, applied in order
tests/
```

## Design notes

**Device enrolment is proof-of-possession.** The Ed25519 keypair is generated on
the device and never leaves it. Registration is two steps: the server issues a
random nonce, the device signs it, and the server verifies the signature
*against the submitted public key* before binding it to the account. Without
this, an attacker could register a victim's public key under their own account —
they could not forge that device's packets, but the server would attribute the
victim's genuine telemetry to the attacker. That is an attribution attack on the
coverage map.

**`wire_id` exists for the BLE budget.** A signed, encrypted position packet is
~128 bytes against a ~24-byte usable BLE advertisement payload. A UUID sender ID
would cost 16 of those bytes; the 4-byte `wire_id` costs 4.

**`mesh_capable` is server-decided, not client-claimed.** iOS cannot advertise
arbitrary payloads in the background, so iOS devices are passive endpoints:
they log locally and upload on reconnect. Only Android relays.

**Devices are never hard-deleted.** `track_points` references them, and a
revoked device's historical contributions must stay attributable so the
Commander can always answer "who covered this hex?".
