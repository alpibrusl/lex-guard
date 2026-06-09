# lex-guard

Your AI agent gets an allowance, not your card — and you can prove what it spent.

lex-guard wraps any payment method behind a **budget token**: a signed policy that caps what an agent can spend (per transaction, per day, per merchant, total). The SDK enforces the policy in-process before any charge is attempted, and writes an attestation trail — `spend.intent` before, `spend.outcome` after — so you can audit every decision.

```
Agent calls gate.spend(intent)
  → SDK checks policy (offline, no network call)
      → denied?  raises DeniedError + writes denial to trail. Charge never attempted.
      → allowed? calls your payment executor, writes outcome to trail.
```

---

## Install

```bash
pip install lex-guard
```

---

## 5-minute walkthrough

### 1. Create a budget token (for testing)

A budget token is a signed JWT carrying the spending policy. In production you issue tokens from the control plane UI. For tests and local dev, build one directly:

```python
from lex_guard.token import build_test_token

token = build_test_token(
    agent_id="research-agent",
    currency="EUR",
    cap_total="200.00",
    cap_per_day="50.00",
    cap_per_transaction="25.00",
    merchants_allow=["api.openai.com", "aws.amazon.com"],
    categories_allow=["saas", "cloud"],
    require_memo=True,
)
```

### 2. Create a gate

```python
from lex_guard import SpendGate, TrailWriter, MockExecutor

# MockExecutor records calls but never touches a payment network.
# Swap for StripeIssuingExecutor in production.
gate = SpendGate(token, TrailWriter(), MockExecutor())
```

### 3. Let your agent spend

```python
from decimal import Decimal
from lex_guard import SpendIntent, DeniedError

# Approved — within all caps, merchant and category on the allowlist
outcome = gate.spend(SpendIntent(
    merchant="api.openai.com",
    amount=Decimal("4.20"),
    currency="EUR",
    category="saas",
    memo="embeddings for research task",
))
print(outcome.executor_ref)   # "mock_a3f9..."

# Denied — merchant not on the allowlist
try:
    gate.spend(SpendIntent(
        merchant="sketchy-vendor.io",
        amount=Decimal("9.99"),
        currency="EUR",
        category="saas",
        memo="some purchase",
    ))
except DeniedError as e:
    print(e.reason)   # "merchant not in allowlist: sketchy-vendor.io"
    # The charge was never attempted. Trail records the denial.
```

### 4. Read the audit trail

Every spend attempt — approved or denied — writes two trail events linked by a parent ID.

```python
for event in gate.trail.events():
    print(event.kind, event.id[:8], f"(parent={event.parent[:8]})" if event.parent else "")

# spend.intent  eaa6c8d4
# spend.outcome b18536d3 (parent=eaa6c8d4)
# spend.intent  0a02c82b
# spend.denied  e63a6e3c (parent=0a02c82b)
```

Export as JSONL for compliance:

```python
print(gate.trail.export_jsonl())
```

---

## Integrating with an AI agent

The gate is just a function call — drop it anywhere your agent tries to pay for something.

### Plain Python agent

```python
def agent_loop(task: str, gate: SpendGate):
    # ... agent decides it needs to call an API ...
    try:
        outcome = gate.spend(SpendIntent(
            merchant="api.openai.com",
            amount=Decimal("0.50"),
            currency="EUR",
            category="saas",
            memo=f"API call for: {task}",
        ))
        # proceed with the call
    except DeniedError as e:
        # tell the agent it can't spend here
        return f"Spend blocked: {e.reason}"
```

### LangChain tool

```python
from langchain.tools import tool
from decimal import Decimal
from lex_guard import SpendGate, SpendIntent, DeniedError

def make_spend_tool(gate: SpendGate):
    @tool
    def spend(merchant: str, amount_eur: float, category: str, memo: str) -> str:
        """Authorize a spend before calling a paid API or service."""
        try:
            outcome = gate.spend(SpendIntent(
                merchant=merchant,
                amount=Decimal(str(amount_eur)),
                currency="EUR",
                category=category,
                memo=memo,
            ))
            return f"Approved. ref={outcome.executor_ref}"
        except DeniedError as e:
            return f"Denied: {e.reason}"
    return spend
```

---

## Policy reference

All caps are optional — omit a field to leave it unlimited.

```python
build_test_token(
    agent_id="my-agent",
    currency="EUR",

    # Spending caps
    cap_total="200.00",           # lifetime of the token
    cap_per_day="50.00",
    cap_per_transaction="25.00",

    # Allowlists (empty list = allow all)
    merchants_allow=["api.openai.com", "aws.amazon.com"],
    categories_allow=["saas", "cloud"],

    # Velocity
    max_tx_per_hour=6,            # 0 = unlimited

    # Memo
    require_memo=True,            # every intent must include a reason
)
```

Standard category values: `saas`, `cloud`, `data`, `media`, `marketplace`, `other`.

---

## Executors

| Executor | Use case |
|---|---|
| `MockExecutor` | Tests and local dev — records calls, never charges |
| `HTTPExecutor(url)` | Generic: POST intent JSON to your own endpoint |
| `StripeIssuingExecutor` | Stripe virtual cards with caps mirrored as Stripe spending controls (defense in depth) — `pip install lex-guard[stripe]` |

Bring your own by subclassing `Executor`:

```python
from lex_guard import Executor, SpendIntent

class MyExecutor(Executor):
    def execute(self, intent: SpendIntent) -> str:
        # call your PSP, return a transaction reference
        ref = my_psp.charge(intent.merchant, intent.amount)
        return ref
```

---

## What the gate stops / doesn't stop

**Stops:**
- Runaway agent loops (daily and total caps)
- Prompt-injected purchases from unlisted merchants
- Cap creep (each token is immutable; new caps require a new token)
- Spending without a memo (when `require_memo=True`)

**Does not stop:**
- A malicious *executor* — that's customer code running outside the SDK
- Fraud at the payment network layer

The policy evaluator is pure and has no I/O — you can read and property-test it independently of any executor.

---

## License

Apache-2.0 — see [LICENSE](LICENSE).
