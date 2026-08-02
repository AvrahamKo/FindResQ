"""XChaCha20-Poly1305 for mesh/point payload encryption.

This is deliberately NOT `nacl.secret.SecretBox` -- SecretBox implements
XSalsa20-Poly1305, a different (older) construction. The architecture review
specified XChaCha20-Poly1305 specifically: it outperforms AES on phones
without AES-NI, and its 192-bit nonce lets every device pick a fully random
nonce per packet with no coordination, safe even across an offline mesh of
uncoordinated devices (see requirements.txt's crypto comment, and Q6 of the
design review). PyNaCl exposes it only via the low-level `nacl.bindings`
layer, used directly here.

Wire representation: `nonce (24 bytes) || ciphertext_with_tag`. The nonce
travels with the ciphertext as one opaque blob rather than a separate field --
simpler for both the direct-HTTPS path and a future BLE frame, and there is
nothing sensitive about the nonce itself.
"""

from __future__ import annotations

from nacl import bindings, utils
from nacl.exceptions import CryptoError

KEY_BYTES = bindings.crypto_aead_xchacha20poly1305_ietf_KEYBYTES
NONCE_BYTES = bindings.crypto_aead_xchacha20poly1305_ietf_NPUBBYTES
TAG_BYTES = bindings.crypto_aead_xchacha20poly1305_ietf_ABYTES

assert KEY_BYTES == 32
assert NONCE_BYTES == 24
assert TAG_BYTES == 16


class MeshCryptoError(ValueError):
    """Raised on a malformed blob or failed authentication (wrong key or a
    tampered/corrupted ciphertext -- these are indistinguishable, by design:
    an AEAD must fail closed without leaking which."""


def encrypt(key: bytes, plaintext: bytes) -> bytes:
    if len(key) != KEY_BYTES:
        raise MeshCryptoError(f"key must be {KEY_BYTES} bytes")

    nonce = utils.random(NONCE_BYTES)
    ciphertext = bindings.crypto_aead_xchacha20poly1305_ietf_encrypt(
        plaintext, None, nonce, key
    )
    return nonce + ciphertext


def decrypt(key: bytes, blob: bytes) -> bytes:
    if len(key) != KEY_BYTES:
        raise MeshCryptoError(f"key must be {KEY_BYTES} bytes")
    if len(blob) < NONCE_BYTES + TAG_BYTES:
        raise MeshCryptoError(
            f"blob too short to contain a nonce and auth tag ({len(blob)} bytes)"
        )

    nonce, ciphertext = blob[:NONCE_BYTES], blob[NONCE_BYTES:]
    try:
        return bindings.crypto_aead_xchacha20poly1305_ietf_decrypt(
            ciphertext, None, nonce, key
        )
    except CryptoError as exc:
        raise MeshCryptoError(
            "decryption failed -- wrong sector key, or the blob was tampered with"
        ) from exc
