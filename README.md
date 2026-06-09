# lex-guard

Agent spending guardrails: capability-gated budget tokens with attestation trail.

Your agent gets an allowance, not your card — and you can prove what it did.

## Install

```bash
pip install lex-guard
```

## Quick start

```python
from decimal import Decimal
from lex_guard import SpendGate, SpendIntent, TrailWriter, MockExecutor, load_token_unsafe

token = load_token_unsafe("<your-budget-token-jwt>")
gate = SpendGate(token, TrailWriter(), MockExecutor())

outcome = gate.spend(SpendIntent(
    merchant="api.openai.com",
    amount=Decimal("4.20"),
    currency="EUR",
    category="saas",
    memo="embeddings for task X",
))
print(outcome.executor_ref)
```

## License

Apache-2.0 — see [LICENSE](LICENSE).
