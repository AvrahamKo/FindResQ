"""Proof-of-possession logic, tested without a database or a server.

These are pure-function tests over the crypto boundary. They are fast, they have
no fixtures, and they are the pattern the Phase 3 coverage-engine tests follow:
keep the logic that matters free of I/O so it can be tested exhaustively.
"""

from __future__ import annotations

import base64

import pytest
from nacl.signing import SigningKey

from app.security import signatures


def _keypair() -> tuple[SigningKey, str]:
    sk = SigningKey.generate()
    return sk, base64.b64encode(bytes(sk.verify_key)).decode()


def test_valid_public_key_round_trips() -> None:
    sk, pub_b64 = _keypair()
    raw = signatures.decode_public_key(pub_b64)
    assert raw == bytes(sk.verify_key)
    assert signatures.encode_public_key(raw) == pub_b64


@pytest.mark.parametrize(
    "bad",
    ["not-base64!!", base64.b64encode(b"too short").decode(), ""],
)
def test_malformed_public_keys_are_rejected(bad: str) -> None:
    with pytest.raises(signatures.InvalidKeyEncoding):
        signatures.decode_public_key(bad)


def test_device_proves_possession_of_its_private_key() -> None:
    sk, pub_b64 = _keypair()
    nonce = b"\x01" * 32
    sig = sk.sign(nonce).signature

    assert signatures.verify(signatures.decode_public_key(pub_b64), nonce, sig)


def test_attacker_cannot_bind_someone_elses_public_key() -> None:
    """The attribution attack 0002_auth.sql exists to prevent.

    An attacker submits the victim's public key with a signature from their own
    key. Enrolment must fail, or the victim's genuine telemetry would later be
    attributed to the attacker's account.
    """
    victim, victim_pub_b64 = _keypair()
    attacker, _ = _keypair()
    nonce = b"\x02" * 32

    forged = attacker.sign(nonce).signature
    assert not signatures.verify(
        signatures.decode_public_key(victim_pub_b64), nonce, forged
    )

    # Sanity: the victim themselves would succeed.
    assert signatures.verify(
        signatures.decode_public_key(victim_pub_b64), nonce, victim.sign(nonce).signature
    )


def test_signature_over_a_different_nonce_is_rejected() -> None:
    """Guards against replaying an old challenge response."""
    sk, pub_b64 = _keypair()
    sig_for_old_nonce = sk.sign(b"\x03" * 32).signature

    assert not signatures.verify(
        signatures.decode_public_key(pub_b64), b"\x04" * 32, sig_for_old_nonce
    )
