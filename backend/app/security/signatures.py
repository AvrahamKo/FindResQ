"""Ed25519 verification.

This module is pure: no I/O, no database, no framework. It is the single place
signature length and encoding rules live, and it is what the Phase 3 ingest
pipeline will call for every packet that crosses the mesh.
"""

from __future__ import annotations

import base64
import binascii

from nacl.exceptions import BadSignatureError
from nacl.signing import VerifyKey

ED25519_PUBLIC_KEY_BYTES = 32
ED25519_SIGNATURE_BYTES = 64


class InvalidKeyEncoding(ValueError):
    """Raised when supplied bytes are not a well-formed Ed25519 public key."""


def decode_public_key(value: str) -> bytes:
    """Decode a standard-base64 Ed25519 public key and validate its length."""
    try:
        raw = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise InvalidKeyEncoding("public key is not valid base64") from exc

    if len(raw) != ED25519_PUBLIC_KEY_BYTES:
        raise InvalidKeyEncoding(
            f"public key must be {ED25519_PUBLIC_KEY_BYTES} bytes, got {len(raw)}"
        )

    # A key that libsodium cannot load is not a key, regardless of length.
    try:
        VerifyKey(raw)
    except Exception as exc:  # noqa: BLE001 - nacl raises assorted types here
        raise InvalidKeyEncoding("public key is not a valid Ed25519 point") from exc

    return raw


def decode_signature(value: str) -> bytes:
    try:
        raw = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise InvalidKeyEncoding("signature is not valid base64") from exc

    if len(raw) != ED25519_SIGNATURE_BYTES:
        raise InvalidKeyEncoding(
            f"signature must be {ED25519_SIGNATURE_BYTES} bytes, got {len(raw)}"
        )
    return raw


def verify(public_key: bytes, message: bytes, signature: bytes) -> bool:
    """Constant-time verification. Returns False rather than raising."""
    if len(public_key) != ED25519_PUBLIC_KEY_BYTES:
        return False
    if len(signature) != ED25519_SIGNATURE_BYTES:
        return False
    try:
        VerifyKey(public_key).verify(message, signature)
    except (BadSignatureError, ValueError):
        return False
    return True


def encode_public_key(raw: bytes) -> str:
    return base64.b64encode(raw).decode("ascii")
