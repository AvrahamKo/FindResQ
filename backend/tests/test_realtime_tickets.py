"""WebSocket connection tickets: short-lived, single-use, event-scoped. Pure."""

from __future__ import annotations

import time
import uuid

from app.realtime.tickets import TicketStore


def test_issued_ticket_redeems_for_the_correct_event() -> None:
    store = TicketStore(ttl_seconds=30)
    user_id, event_id = uuid.uuid4(), uuid.uuid4()

    token, _ = store.issue(user_id, event_id)
    assert store.redeem(token, event_id) == user_id


def test_ticket_is_single_use() -> None:
    store = TicketStore(ttl_seconds=30)
    user_id, event_id = uuid.uuid4(), uuid.uuid4()

    token, _ = store.issue(user_id, event_id)
    assert store.redeem(token, event_id) == user_id
    assert store.redeem(token, event_id) is None  # consumed


def test_ticket_rejected_for_the_wrong_event() -> None:
    store = TicketStore(ttl_seconds=30)
    user_id, event_id = uuid.uuid4(), uuid.uuid4()
    wrong_event_id = uuid.uuid4()

    token, _ = store.issue(user_id, event_id)
    assert store.redeem(token, wrong_event_id) is None


def test_ticket_is_consumed_even_on_event_mismatch() -> None:
    """A client cannot retry the same ticket against a different event after
    a failed attempt -- one shot, no matter what."""
    store = TicketStore(ttl_seconds=30)
    user_id, event_id = uuid.uuid4(), uuid.uuid4()

    token, _ = store.issue(user_id, event_id)
    assert store.redeem(token, uuid.uuid4()) is None  # wrong event: rejected
    assert store.redeem(token, event_id) is None  # now gone even for the RIGHT event


def test_expired_ticket_is_rejected() -> None:
    store = TicketStore(ttl_seconds=0.05)
    user_id, event_id = uuid.uuid4(), uuid.uuid4()

    token, _ = store.issue(user_id, event_id)
    time.sleep(0.1)
    assert store.redeem(token, event_id) is None


def test_unknown_token_is_rejected() -> None:
    store = TicketStore(ttl_seconds=30)
    assert store.redeem("not-a-real-token", uuid.uuid4()) is None


def test_tickets_for_different_events_are_independent() -> None:
    store = TicketStore(ttl_seconds=30)
    user_a, event_a = uuid.uuid4(), uuid.uuid4()
    user_b, event_b = uuid.uuid4(), uuid.uuid4()

    token_a, _ = store.issue(user_a, event_a)
    token_b, _ = store.issue(user_b, event_b)

    assert store.redeem(token_a, event_a) == user_a
    assert store.redeem(token_b, event_b) == user_b
