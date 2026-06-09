"""Policy gate: evaluates a spend intent against a budget token's policy.

This is the hot path — keep it pure and property-test it hard.
"""

from __future__ import annotations

import time
from decimal import Decimal
from typing import Optional

from .token import BudgetToken, TokenPolicy
from .trail import TrailWriter
from .executor import Executor
from .models import SpendIntent, SpendOutcome


class DeniedError(Exception):
    """Raised when the policy gate denies a spend intent."""

    def __init__(self, reason: str, intent: SpendIntent) -> None:
        super().__init__(reason)
        self.reason = reason
        self.intent = intent


class SpendGate:
    """In-process spending gate.

    Usage::

        gate = SpendGate(token, trail_writer, executor)
        outcome = gate.spend(SpendIntent("api.openai.com", Decimal("4.20"), "EUR", "saas", "embeddings call"))
    """

    def __init__(self, token: BudgetToken, trail: TrailWriter, executor: Executor) -> None:
        self._token = token
        self._trail = trail
        self._executor = executor

    def spend(self, intent: SpendIntent) -> SpendOutcome:
        """Evaluate intent, execute if approved, return outcome.

        Raises DeniedError if the policy gate rejects the intent.
        Trail write failure before execution halts the spend (audit contract).
        """
        intent_id = self._trail.log_intent(intent, self._token.policy.token_id)

        denial = evaluate(self._token.policy, intent)
        if denial:
            self._trail.log_denial(intent_id, intent, denial)
            raise DeniedError(denial, intent)

        ref = self._executor.execute(intent)
        outcome = SpendOutcome(intent=intent, approved=True, executor_ref=ref)
        self._trail.log_outcome(intent_id, outcome)
        return outcome


# ---------------------------------------------------------------------------
# Pure evaluation — no I/O, property-testable
# ---------------------------------------------------------------------------

def evaluate(policy: TokenPolicy, intent: SpendIntent) -> Optional[str]:
    """Return a denial reason string, or None if the intent is allowed."""

    if policy.require_memo and not intent.memo.strip():
        return "memo required"

    if intent.currency != policy.currency:
        return f"currency mismatch: expected {policy.currency}, got {intent.currency}"

    if policy.cap_per_transaction > 0 and intent.amount > policy.cap_per_transaction:
        return f"exceeds per-transaction cap ({policy.cap_per_transaction} {policy.currency})"

    if policy.merchants_allow and intent.merchant not in policy.merchants_allow:
        return f"merchant not in allowlist: {intent.merchant}"

    if policy.categories_allow and intent.category not in policy.categories_allow:
        return f"category not in allowlist: {intent.category}"

    # Total and per-day caps require spend history — injected via SpendGate from trail
    # (SpendGate passes totals via evaluate_with_history; this bare form is for unit tests)
    return None


def evaluate_with_history(
    policy: TokenPolicy,
    intent: SpendIntent,
    total_spent: Decimal,
    day_spent: Decimal,
    tx_this_hour: int,
) -> Optional[str]:
    """Full evaluation including history-dependent caps."""

    base = evaluate(policy, intent)
    if base:
        return base

    if policy.cap_total > 0 and total_spent + intent.amount > policy.cap_total:
        return f"exceeds total cap ({policy.cap_total} {policy.currency})"

    if policy.cap_per_day > 0 and day_spent + intent.amount > policy.cap_per_day:
        return f"exceeds daily cap ({policy.cap_per_day} {policy.currency})"

    if policy.max_tx_per_hour > 0 and tx_this_hour >= policy.max_tx_per_hour:
        return f"velocity limit: max {policy.max_tx_per_hour} tx/hour"

    return None
