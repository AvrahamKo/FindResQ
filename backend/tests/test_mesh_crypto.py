"""XChaCha20-Poly1305 mesh payload encryption. Pure -- no database."""

from __future__ import annotations

import pytest
from nacl import utils

from app.security import mesh_crypto


def _key() -> bytes:
    return utils.random(mesh_crypto.KEY_BYTES)


def test_round_trips() -> None:
    key = _key()
    plaintext = b"a" * 91  # 27-byte payload + 64-byte Ed25519 signature
    blob = mesh_crypto.encrypt(key, plaintext)

    assert len(blob) == mesh_crypto.NONCE_BYTES + len(plaintext) + mesh_crypto.TAG_BYTES
    assert mesh_crypto.decrypt(key, blob) == plaintext


def test_nonce_is_random_per_call() -> None:
    key = _key()
    a = mesh_crypto.encrypt(key, b"same message")
    b = mesh_crypto.encrypt(key, b"same message")
    assert a != b  # different nonce -> different ciphertext for identical plaintext


def test_wrong_key_fails_closed() -> None:
    blob = mesh_crypto.encrypt(_key(), b"secret")
    with pytest.raises(mesh_crypto.MeshCryptoError):
        mesh_crypto.decrypt(_key(), blob)


def test_tampered_blob_is_rejected() -> None:
    key = _key()
    blob = bytearray(mesh_crypto.encrypt(key, b"trust me"))
    blob[-1] ^= 0xFF  # flip a bit in the auth tag
    with pytest.raises(mesh_crypto.MeshCryptoError):
        mesh_crypto.decrypt(key, bytes(blob))


def test_truncated_blob_is_rejected() -> None:
    with pytest.raises(mesh_crypto.MeshCryptoError):
        mesh_crypto.decrypt(_key(), b"short")


def test_wrong_key_length_is_rejected() -> None:
    with pytest.raises(mesh_crypto.MeshCryptoError):
        mesh_crypto.encrypt(b"too short", b"message")
