"""Sector-key envelope encryption. Pure -- no database, no server."""

from __future__ import annotations

import base64
import secrets

import pytest

from app.security import envelope


def _master_key_b64() -> str:
    return base64.b64encode(secrets.token_bytes(32)).decode()


def test_wrap_unwrap_round_trips() -> None:
    master = _master_key_b64()
    raw = envelope.generate_sector_key()

    wrapped = envelope.wrap(master, raw)
    assert wrapped != raw  # actually encrypted, not a no-op

    assert envelope.unwrap(master, wrapped) == raw


def test_generated_keys_are_unique() -> None:
    assert envelope.generate_sector_key() != envelope.generate_sector_key()


def test_unwrap_fails_under_the_wrong_master_key() -> None:
    raw = envelope.generate_sector_key()
    wrapped = envelope.wrap(_master_key_b64(), raw)

    with pytest.raises(envelope.WrapError):
        envelope.unwrap(_master_key_b64(), wrapped)


def test_unwrap_rejects_a_tampered_blob() -> None:
    """Poly1305/SecretBox must fail closed on any bit-flip, not decrypt garbage."""
    master = _master_key_b64()
    wrapped = bytearray(envelope.wrap(master, envelope.generate_sector_key()))
    wrapped[-1] ^= 0xFF

    with pytest.raises(envelope.WrapError):
        envelope.unwrap(master, bytes(wrapped))


def test_wrap_rejects_wrong_length_input() -> None:
    with pytest.raises(envelope.WrapError):
        envelope.wrap(_master_key_b64(), b"too short")


@pytest.mark.parametrize(
    "bad_master",
    ["not-base64!!", base64.b64encode(b"only16bytes12345").decode()],
)
def test_misconfigured_master_key_fails_clearly(bad_master: str) -> None:
    with pytest.raises(envelope.WrapError):
        envelope.wrap(bad_master, envelope.generate_sector_key())
