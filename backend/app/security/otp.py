"""One-time passcode generation and hashing.

Codes are never stored in plaintext. They are short and low-entropy by nature,
so the defences are: a per-challenge random salt, a short TTL, a hard attempt
cap, and a resend cooldown -- all enforced in the repository layer.
"""

from __future__ import annotations

import hashlib
import hmac
import secrets

CODE_LENGTH = 6
SALT_BYTES = 16


def generate_code() -> str:
    """A uniformly random numeric code, zero-padded (leading zeros allowed)."""
    upper = 10**CODE_LENGTH
    return str(secrets.randbelow(upper)).zfill(CODE_LENGTH)


def generate_salt() -> bytes:
    return secrets.token_bytes(SALT_BYTES)


def hash_code(code: str, salt: bytes) -> bytes:
    return hashlib.pbkdf2_hmac("sha256", code.encode("utf-8"), salt, 100_000)


def verify_code(code: str, salt: bytes, expected_hash: bytes) -> bool:
    return hmac.compare_digest(hash_code(code, salt), expected_hash)
