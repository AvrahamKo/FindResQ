"""Stage 1 (frame reassembly) and stage 2 (envelope dedup) from the ingest
pipeline design.

Scope note, read before wiring this into an endpoint:

The cleartext fragment envelope below (msg_id / ttl / frag_index / frag_total
/ sector_hash) exists because a BLE relay node must be able to route, dedup,
and decrement TTL on a packet it CANNOT decrypt -- it may be relaying a
different sector's traffic entirely. That is a property of the Android relay
client (Phase 7), which does not exist yet. Two consequences:

1. `FragmentAssembler` here is real, tested reassembly logic, but nothing
   currently feeds it multi-fragment input in production. The live `/ingest`
   endpoint (Phase 3) is the DIRECT-upload path: a device with connectivity
   uploading its own buffered points over HTTPS, authenticated by its own
   session. Every "message" on that path is inherently a single fragment
   (frag_index=0, frag_total=1), so reassembly is a pass-through. This module
   exists so the *algorithm* is correct and tested before the client that
   needs it is built -- not to pretend the mesh transport is finished.

2. `SeenSet` mirrors the flood-control cache the architecture review assigned
   to each Android relay node, NOT the server. The server's authoritative
   replay defense is the UNIQUE index on `track_points.signature` (checked
   after decryption); msg_id-level dedup is a pre-decryption cost-avoidance
   optimization for a relay that cannot decrypt at all. It is provided here
   for whichever client eventually implements the relay side, and is not
   required for server-side correctness.
"""

from __future__ import annotations

import struct
from collections import OrderedDict, defaultdict
from dataclasses import dataclass

_HEADER_FORMAT = "!8sBBBI"  # msg_id(8) frag_index(1) frag_total(1) ttl(1) sector_hash(4)
HEADER_BYTES = struct.calcsize(_HEADER_FORMAT)
assert HEADER_BYTES == 15

MSG_ID_BYTES = 8
SECTOR_HASH_BYTES = 4


class FragmentError(ValueError):
    pass


@dataclass(frozen=True, slots=True)
class Fragment:
    msg_id: bytes
    frag_index: int
    frag_total: int
    ttl: int
    sector_hash: bytes
    body: bytes


def pack_fragment(
    *, msg_id: bytes, frag_index: int, frag_total: int, ttl: int, sector_hash: bytes, body: bytes
) -> bytes:
    if len(msg_id) != MSG_ID_BYTES:
        raise FragmentError(f"msg_id must be {MSG_ID_BYTES} bytes")
    if len(sector_hash) != SECTOR_HASH_BYTES:
        raise FragmentError(f"sector_hash must be {SECTOR_HASH_BYTES} bytes")
    if not (0 <= frag_index < frag_total):
        raise FragmentError(f"frag_index {frag_index} out of range for total {frag_total}")
    header = struct.pack(_HEADER_FORMAT, msg_id, frag_index, frag_total, ttl, int.from_bytes(sector_hash, "big"))
    return header + body


def unpack_fragment(raw: bytes) -> Fragment:
    if len(raw) < HEADER_BYTES:
        raise FragmentError(f"frame shorter than header ({len(raw)} < {HEADER_BYTES} bytes)")
    msg_id, frag_index, frag_total, ttl, sector_hash_int = struct.unpack(
        _HEADER_FORMAT, raw[:HEADER_BYTES]
    )
    if frag_total == 0 or frag_index >= frag_total:
        raise FragmentError(f"invalid frag_index/frag_total: {frag_index}/{frag_total}")
    return Fragment(
        msg_id=msg_id,
        frag_index=frag_index,
        frag_total=frag_total,
        ttl=ttl,
        sector_hash=sector_hash_int.to_bytes(SECTOR_HASH_BYTES, "big"),
        body=raw[HEADER_BYTES:],
    )


class FragmentAssembler:
    """Groups fragments by `msg_id` within a single batch and reassembles any
    message for which every `frag_index` in `[0, frag_total)` is present.
    Incomplete messages are simply not returned -- there is no cross-batch
    persistence here (see module docstring)."""

    def __init__(self) -> None:
        self._buckets: dict[bytes, dict[int, Fragment]] = defaultdict(dict)

    def add(self, fragment: Fragment) -> None:
        bucket = self._buckets[fragment.msg_id]
        if bucket and next(iter(bucket.values())).frag_total != fragment.frag_total:
            raise FragmentError(
                f"conflicting frag_total for msg_id {fragment.msg_id.hex()}"
            )
        bucket[fragment.frag_index] = fragment

    def complete_messages(self) -> dict[bytes, bytes]:
        """Returns {msg_id: reassembled_body} for every fully-received message."""
        completed: dict[bytes, bytes] = {}
        for msg_id, bucket in self._buckets.items():
            first = next(iter(bucket.values()))
            if len(bucket) == first.frag_total:
                ordered = [bucket[i].body for i in range(first.frag_total)]
                completed[msg_id] = b"".join(ordered)
        return completed

    def incomplete_msg_ids(self) -> set[bytes]:
        return {
            msg_id
            for msg_id, bucket in self._buckets.items()
            if len(bucket) != next(iter(bucket.values())).frag_total
        }


class SeenSet:
    """Bounded LRU of recently-seen `msg_id`s, for a mesh relay node deciding
    whether to rebroadcast a frame it has already forwarded. Not used
    server-side (see module docstring)."""

    def __init__(self, capacity: int = 1000) -> None:
        if capacity <= 0:
            raise ValueError("capacity must be positive")
        self._capacity = capacity
        self._seen: OrderedDict[bytes, None] = OrderedDict()

    def __contains__(self, msg_id: bytes) -> bool:
        return msg_id in self._seen

    def add(self, msg_id: bytes) -> None:
        if msg_id in self._seen:
            self._seen.move_to_end(msg_id)
            return
        self._seen[msg_id] = None
        if len(self._seen) > self._capacity:
            self._seen.popitem(last=False)

    def __len__(self) -> int:
        return len(self._seen)
