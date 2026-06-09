"""Attestation trail writer.

Mirrors the lex-trail format: content-addressed events with parent linkage.
Emitting `spend.intent` before execution and `spend.outcome` after is the
audit contract — trail write failure pre-execution halts the spend.
"""

from __future__ import annotations

import hashlib
import json
import time
from dataclasses import dataclass, field
from typing import Optional


@dataclass
class TrailEvent:
    id: str          # SHA-256 content hash (hex)
    kind: str
    parent: Optional[str]
    ts_ms: int
    payload: dict


class TrailWriteError(Exception):
    pass


class TrailWriter:
    """In-memory trail writer (swap for DB-backed writer in production)."""

    def __init__(self) -> None:
        self._events: list[TrailEvent] = []

    def append(self, kind: str, parent: Optional[str], payload: dict) -> TrailEvent:
        ts_ms = int(time.time() * 1000)
        body = {"kind": kind, "parent": parent, "ts_ms": ts_ms, "payload": payload}
        event_id = hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()
        evt = TrailEvent(id=event_id, kind=kind, parent=parent, ts_ms=ts_ms, payload=payload)
        self._events.append(evt)
        return evt

    def log_intent(self, intent, token_id: str) -> str:
        evt = self.append(
            "spend.intent",
            None,
            {
                "token_id": token_id,
                "merchant": intent.merchant,
                "amount": str(intent.amount),
                "currency": intent.currency,
                "category": intent.category,
                "memo": intent.memo,
            },
        )
        return evt.id

    def log_denial(self, intent_id: str, intent, reason: str) -> None:
        self.append(
            "spend.denied",
            intent_id,
            {"merchant": intent.merchant, "amount": str(intent.amount), "reason": reason},
        )

    def log_outcome(self, intent_id: str, outcome) -> None:
        self.append(
            "spend.outcome",
            intent_id,
            {
                "merchant": outcome.intent.merchant,
                "amount": str(outcome.intent.amount),
                "approved": outcome.approved,
                "executor_ref": outcome.executor_ref,
            },
        )

    def events(self) -> list[TrailEvent]:
        return list(self._events)

    def export_jsonl(self) -> str:
        return "\n".join(json.dumps(e.__dict__) for e in self._events)
