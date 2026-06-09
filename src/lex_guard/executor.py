"""Executor interface and built-in implementations.

The gate calls executor.execute(intent) only AFTER the policy approves.
Customers provide their own executor wrapping Stripe Issuing, x402, etc.
"""

from __future__ import annotations

import uuid
from abc import ABC, abstractmethod

from .models import SpendIntent


class Executor(ABC):
    @abstractmethod
    def execute(self, intent: SpendIntent) -> str:
        """Submit the charge and return a transaction reference."""


class MockExecutor(Executor):
    """Records calls for testing; never touches a payment network."""

    def __init__(self) -> None:
        self.calls: list[SpendIntent] = []

    def execute(self, intent: SpendIntent) -> str:
        self.calls.append(intent)
        return "mock_" + uuid.uuid4().hex[:8]


class HTTPExecutor(Executor):
    """Generic HTTP executor: POSTs intent JSON to a customer endpoint."""

    def __init__(self, url: str, headers: dict[str, str] | None = None) -> None:
        self._url = url
        self._headers = headers or {}

    def execute(self, intent: SpendIntent) -> str:
        import urllib.request
        import json

        payload = json.dumps({
            "merchant": intent.merchant,
            "amount": str(intent.amount),
            "currency": intent.currency,
            "category": intent.category,
            "memo": intent.memo,
        }).encode()

        req = urllib.request.Request(self._url, data=payload, headers={
            "Content-Type": "application/json",
            **self._headers,
        })
        with urllib.request.urlopen(req) as resp:
            body = json.loads(resp.read())
            return body.get("ref", "")
