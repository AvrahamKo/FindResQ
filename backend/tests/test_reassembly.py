"""Fragment header pack/unpack and reassembly. Pure -- no database, no BLE."""

from __future__ import annotations

import pytest

from app.mesh.reassembly import (
    Fragment,
    FragmentAssembler,
    FragmentError,
    SeenSet,
    pack_fragment,
    unpack_fragment,
)


def _sector_hash() -> bytes:
    return b"\xab\xcd\xef\x01"


def test_fragment_header_round_trips() -> None:
    raw = pack_fragment(
        msg_id=b"12345678", frag_index=1, frag_total=3, ttl=5,
        sector_hash=_sector_hash(), body=b"payload-bytes",
    )
    fragment = unpack_fragment(raw)
    assert fragment == Fragment(
        msg_id=b"12345678", frag_index=1, frag_total=3, ttl=5,
        sector_hash=_sector_hash(), body=b"payload-bytes",
    )


def test_reassembles_out_of_order_fragments() -> None:
    msg_id = b"msgmsgid"
    parts = [b"AAA", b"BBB", b"CCC"]
    fragments = [
        unpack_fragment(
            pack_fragment(
                msg_id=msg_id, frag_index=i, frag_total=len(parts), ttl=5,
                sector_hash=_sector_hash(), body=part,
            )
        )
        for i, part in enumerate(parts)
    ]

    assembler = FragmentAssembler()
    for fragment in reversed(fragments):  # deliver out of order
        assembler.add(fragment)

    assert assembler.complete_messages() == {msg_id: b"AAABBBCCC"}
    assert assembler.incomplete_msg_ids() == set()


def test_incomplete_message_is_not_returned() -> None:
    msg_id = b"partmsg1"
    assembler = FragmentAssembler()
    assembler.add(
        unpack_fragment(
            pack_fragment(
                msg_id=msg_id, frag_index=0, frag_total=2, ttl=5,
                sector_hash=_sector_hash(), body=b"only-half",
            )
        )
    )
    assert assembler.complete_messages() == {}
    assert assembler.incomplete_msg_ids() == {msg_id}


def test_duplicate_fragment_delivery_does_not_break_reassembly() -> None:
    """A fragment relayed twice through different mesh paths should not
    prevent the message from completing once."""
    msg_id = b"dupemsg1"
    frag0 = unpack_fragment(
        pack_fragment(msg_id=msg_id, frag_index=0, frag_total=2, ttl=5,
                      sector_hash=_sector_hash(), body=b"AA")
    )
    frag1 = unpack_fragment(
        pack_fragment(msg_id=msg_id, frag_index=1, frag_total=2, ttl=5,
                      sector_hash=_sector_hash(), body=b"BB")
    )
    assembler = FragmentAssembler()
    assembler.add(frag0)
    assembler.add(frag0)  # redelivered
    assembler.add(frag1)
    assert assembler.complete_messages() == {msg_id: b"AABB"}


def test_conflicting_frag_total_is_rejected() -> None:
    msg_id = b"badmsg01"
    assembler = FragmentAssembler()
    assembler.add(
        unpack_fragment(
            pack_fragment(msg_id=msg_id, frag_index=0, frag_total=2, ttl=5,
                          sector_hash=_sector_hash(), body=b"A")
        )
    )
    with pytest.raises(FragmentError):
        assembler.add(
            unpack_fragment(
                pack_fragment(msg_id=msg_id, frag_index=1, frag_total=3, ttl=5,
                              sector_hash=_sector_hash(), body=b"B")
            )
        )


def test_frame_shorter_than_header_is_rejected() -> None:
    with pytest.raises(FragmentError):
        unpack_fragment(b"short")


class TestSeenSet:
    def test_tracks_membership(self) -> None:
        seen = SeenSet(capacity=10)
        assert b"abc" not in seen
        seen.add(b"abc")
        assert b"abc" in seen

    def test_evicts_least_recently_used_beyond_capacity(self) -> None:
        seen = SeenSet(capacity=2)
        seen.add(b"first")
        seen.add(b"second")
        seen.add(b"third")  # evicts "first"
        assert b"first" not in seen
        assert b"second" in seen
        assert b"third" in seen
        assert len(seen) == 2

    def test_re_adding_refreshes_recency(self) -> None:
        seen = SeenSet(capacity=2)
        seen.add(b"first")
        seen.add(b"second")
        seen.add(b"first")  # touch "first" again -> "second" becomes oldest
        seen.add(b"third")  # evicts "second", not "first"
        assert b"first" in seen
        assert b"second" not in seen
