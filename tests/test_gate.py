"""Golden tests for the policy evaluator.

Covers: every cap type, boundary amounts, merchant/category allowlists,
velocity, memo requirement, currency mismatch, and combined scenarios.
"""

from decimal import Decimal

import pytest

from lex_guard.gate import DeniedError, SpendIntent, SpendGate, evaluate, evaluate_with_history
from lex_guard.token import TokenPolicy
from lex_guard.trail import TrailWriter
from lex_guard.executor import MockExecutor


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

def make_policy(**kwargs) -> TokenPolicy:
    defaults = dict(
        token_id="tok_test",
        agent_id="agent-1",
        currency="EUR",
        cap_total=Decimal("200"),
        cap_per_day=Decimal("50"),
        cap_per_transaction=Decimal("25"),
        merchants_allow=["api.openai.com", "aws.amazon.com"],
        categories_allow=["saas", "cloud"],
        max_tx_per_hour=6,
        require_memo=False,
    )
    defaults.update(kwargs)
    return TokenPolicy(**defaults)


def make_intent(**kwargs) -> SpendIntent:
    defaults = dict(
        merchant="api.openai.com",
        amount=Decimal("10"),
        currency="EUR",
        category="saas",
        memo="embeddings call",
    )
    defaults.update(kwargs)
    return SpendIntent(**defaults)


# ---------------------------------------------------------------------------
# evaluate() — pure cap checks
# ---------------------------------------------------------------------------

class TestEvaluatePure:
    def test_allows_valid_intent(self):
        assert evaluate(make_policy(), make_intent()) is None

    def test_denies_currency_mismatch(self):
        reason = evaluate(make_policy(), make_intent(currency="USD"))
        assert reason and "currency mismatch" in reason

    def test_denies_per_transaction_exceeded(self):
        reason = evaluate(make_policy(), make_intent(amount=Decimal("25.01")))
        assert reason and "per-transaction cap" in reason

    def test_allows_per_transaction_exact_boundary(self):
        assert evaluate(make_policy(), make_intent(amount=Decimal("25.00"))) is None

    def test_denies_merchant_not_in_allowlist(self):
        reason = evaluate(make_policy(), make_intent(merchant="evil.example.com"))
        assert reason and "allowlist" in reason

    def test_allows_merchant_when_list_empty(self):
        policy = make_policy(merchants_allow=[])
        assert evaluate(policy, make_intent(merchant="anyone.example.com")) is None

    def test_denies_category_not_in_allowlist(self):
        reason = evaluate(make_policy(), make_intent(category="gambling"))
        assert reason and "category" in reason

    def test_allows_category_when_list_empty(self):
        policy = make_policy(categories_allow=[])
        assert evaluate(policy, make_intent(category="anything")) is None

    def test_denies_empty_memo_when_required(self):
        policy = make_policy(require_memo=True)
        reason = evaluate(policy, make_intent(memo=""))
        assert reason and "memo required" in reason

    def test_allows_nonempty_memo_when_required(self):
        policy = make_policy(require_memo=True)
        assert evaluate(policy, make_intent(memo="valid reason")) is None

    def test_allows_whitespace_only_memo_denied(self):
        policy = make_policy(require_memo=True)
        reason = evaluate(policy, make_intent(memo="   "))
        assert reason and "memo required" in reason


class TestEvaluateWithHistory:
    def test_denies_total_cap_exceeded(self):
        reason = evaluate_with_history(
            make_policy(cap_total=Decimal("200")),
            make_intent(amount=Decimal("10")),
            total_spent=Decimal("195"),
            day_spent=Decimal("0"),
            tx_this_hour=0,
        )
        assert reason and "total cap" in reason

    def test_allows_total_cap_exact(self):
        reason = evaluate_with_history(
            make_policy(cap_total=Decimal("200")),
            make_intent(amount=Decimal("10")),
            total_spent=Decimal("190"),
            day_spent=Decimal("0"),
            tx_this_hour=0,
        )
        assert reason is None

    def test_denies_daily_cap_exceeded(self):
        reason = evaluate_with_history(
            make_policy(cap_per_day=Decimal("50")),
            make_intent(amount=Decimal("10")),
            total_spent=Decimal("0"),
            day_spent=Decimal("45"),
            tx_this_hour=0,
        )
        assert reason and "daily cap" in reason

    def test_denies_velocity_exceeded(self):
        reason = evaluate_with_history(
            make_policy(max_tx_per_hour=6),
            make_intent(),
            total_spent=Decimal("0"),
            day_spent=Decimal("0"),
            tx_this_hour=6,
        )
        assert reason and "velocity" in reason

    def test_allows_velocity_at_limit_minus_one(self):
        reason = evaluate_with_history(
            make_policy(max_tx_per_hour=6),
            make_intent(),
            total_spent=Decimal("0"),
            day_spent=Decimal("0"),
            tx_this_hour=5,
        )
        assert reason is None

    def test_unlimited_velocity_when_zero(self):
        reason = evaluate_with_history(
            make_policy(max_tx_per_hour=0),
            make_intent(),
            total_spent=Decimal("0"),
            day_spent=Decimal("0"),
            tx_this_hour=999,
        )
        assert reason is None


# ---------------------------------------------------------------------------
# SpendGate — integration (MockExecutor + TrailWriter)
# ---------------------------------------------------------------------------

class TestSpendGate:
    def _make_gate(self, **policy_kwargs):
        from lex_guard.token import BudgetToken
        policy = make_policy(**policy_kwargs)
        token = BudgetToken(raw="raw", policy=policy)
        trail = TrailWriter()
        executor = MockExecutor()
        gate = SpendGate(token, trail, executor)
        return gate, trail, executor

    def test_approved_spend_records_two_events(self):
        gate, trail, executor = self._make_gate()
        gate.spend(make_intent())
        events = trail.events()
        assert len(events) == 2
        assert events[0].kind == "spend.intent"
        assert events[1].kind == "spend.outcome"
        assert events[1].parent == events[0].id

    def test_denied_spend_raises_and_records_denial(self):
        gate, trail, executor = self._make_gate()
        with pytest.raises(DeniedError) as exc:
            gate.spend(make_intent(merchant="blocked.example.com"))
        assert "allowlist" in str(exc.value)
        events = trail.events()
        assert len(events) == 2
        assert events[0].kind == "spend.intent"
        assert events[1].kind == "spend.denied"
        assert len(executor.calls) == 0

    def test_executor_not_called_on_denial(self):
        gate, trail, executor = self._make_gate()
        with pytest.raises(DeniedError):
            gate.spend(make_intent(amount=Decimal("9999")))
        assert len(executor.calls) == 0

    def test_executor_called_on_approval(self):
        gate, trail, executor = self._make_gate()
        gate.spend(make_intent())
        assert len(executor.calls) == 1
