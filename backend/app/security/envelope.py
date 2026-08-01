"""Envelope encryption for sector keys at rest.

Each sector gets a freshly generated 32-byte symmetric key (used by the
Flutter client for XChaCha20-Poly1305 mesh-payload encryption, per the Phase 3
crypto design). The server must persist that key to hand it to future joiners
and to re-derive it for the "who can decrypt this" story -- so it cannot be
plaintext at rest in `sector_keys.key_wrapped`.

For the MVP this wraps with a single master key from configuration via
NaCl SecretBox (XSalsa20-Poly1305, 24-byte random nonce per wrap). Swap this
module for a real KMS (AWS KMS / GCP KMS / Vault transit) before production --
callers only ever see `wrap()` / `unwrap()`, so nothing else changes.
"""

from __future__ import annotations

import base64
import binascii

from nacl import utils
from nacl.exceptions import CryptoError
from nacl.secret import SecretBox

SECTOR_KEY_BYTES = 32  # matches XChaCha20-Poly1305's key size


class WrapError(RuntimeError):
    """Raised when the master key is misconfigured or wrapped data is corrupt."""


def _master_box(master_key_b64: str) -> SecretBox:
    try:
        raw = base64.b64decode(master_key_b64, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise WrapError("SECTOR_KEY_WRAP_SECRET is not valid base64") from exc

    if len(raw) != SecretBox.KEY_SIZE:
        raise WrapError(
            f"SECTOR_KEY_WRAP_SECRET must decode to {SecretBox.KEY_SIZE} bytes, "
            f"got {len(raw)}. Generate with: "
            "python -c \"import secrets,base64; "
            "print(base64.b64encode(secrets.token_bytes(32)).decode())\""
        )
    return SecretBox(raw)


def generate_sector_key() -> bytes:
    return utils.random(SECTOR_KEY_BYTES)


def wrap(master_key_b64: str, raw_key: bytes) -> bytes:
    if len(raw_key) != SECTOR_KEY_BYTES:
        raise WrapError(f"sector key must be {SECTOR_KEY_BYTES} bytes")
    box = _master_box(master_key_b64)
    # SecretBox.encrypt generates its own nonce and prepends it to the output;
    # the blob is self-contained and safe to store as opaque bytes.
    return bytes(box.encrypt(raw_key))


def unwrap(master_key_b64: str, wrapped: bytes) -> bytes:
    box = _master_box(master_key_b64)
    try:
        return box.decrypt(wrapped)
    except CryptoError as exc:
        raise WrapError(
            "sector key could not be decrypted -- wrong master key, or "
            "the row was wrapped under a different one"
        ) from exc
