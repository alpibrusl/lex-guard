# lex-guard

[![CI](https://github.com/alpibrusl/lex-guard/actions/workflows/ci.yml/badge.svg)](https://github.com/alpibrusl/lex-guard/actions/workflows/ci.yml)

**Part of the [Lex](https://lexlang.org) project** — Agents · [Manifesto](https://lexlang.org/manifesto) · [All packages](https://lexlang.org)

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

## Integrating with AI agents

The gate is a plain function call — drop it wherever your agent tries to pay for something.

### Claude (Anthropic tool use)

Define `authorize_spend` as a tool in your Claude API call. Claude will call it before any paid action; the result tells it whether to proceed or stop.

```python
import anthropic
from decimal import Decimal
from lex_guard import SpendGate, SpendIntent, DeniedError

client = anthropic.Anthropic()

tools = [
    {
        "name": "authorize_spend",
        "description": "Authorize a payment before calling a paid API or service. Always call this before spending money.",
        "input_schema": {
            "type": "object",
            "properties": {
                "merchant":   {"type": "string", "description": "Domain or name of the merchant, e.g. api.openai.com"},
                "amount_eur": {"type": "number", "description": "Amount in EUR"},
                "category":   {"type": "string", "description": "Category: saas, cloud, data, media, marketplace, other"},
                "memo":       {"type": "string", "description": "Why this spend is needed"},
            },
            "required": ["merchant", "amount_eur", "category", "memo"],
        },
    }
]

def handle_tool_call(gate: SpendGate, tool_input: dict) -> str:
    try:
        outcome = gate.spend(SpendIntent(
            merchant=tool_input["merchant"],
            amount=Decimal(str(tool_input["amount_eur"])),
            currency="EUR",
            category=tool_input["category"],
            memo=tool_input["memo"],
        ))
        return f"Approved. Transaction ref: {outcome.executor_ref}"
    except DeniedError as e:
        return f"Denied: {e.reason}. Do not attempt this purchase."

# In your agent loop, when Claude returns a tool_use block:
# result = handle_tool_call(gate, tool_use_block.input)
```

### OpenAI / Codex (tool calling)

```python
from openai import OpenAI
from decimal import Decimal
from lex_guard import SpendGate, SpendIntent, DeniedError
import json

client = OpenAI()

tools = [
    {
        "type": "function",
        "function": {
            "name": "authorize_spend",
            "description": "Authorize a payment before calling a paid API or service.",
            "parameters": {
                "type": "object",
                "properties": {
                    "merchant":   {"type": "string"},
                    "amount_eur": {"type": "number"},
                    "category":   {"type": "string", "enum": ["saas", "cloud", "data", "media", "marketplace", "other"]},
                    "memo":       {"type": "string"},
                },
                "required": ["merchant", "amount_eur", "category", "memo"],
            },
        },
    }
]

def handle_tool_call(gate: SpendGate, tool_call) -> str:
    args = json.loads(tool_call.function.arguments)
    try:
        outcome = gate.spend(SpendIntent(
            merchant=args["merchant"],
            amount=Decimal(str(args["amount_eur"])),
            currency="EUR",
            category=args["category"],
            memo=args["memo"],
        ))
        return json.dumps({"approved": True, "ref": outcome.executor_ref})
    except DeniedError as e:
        return json.dumps({"approved": False, "reason": e.reason})

# In your agent loop, when the model returns tool_calls:
# for tc in response.choices[0].message.tool_calls:
#     result = handle_tool_call(gate, tc)
```

### LangChain

```python
from langchain_core.tools import tool
from decimal import Decimal
from lex_guard import SpendGate, SpendIntent, DeniedError

def make_spend_tool(gate: SpendGate):
    @tool
    def authorize_spend(merchant: str, amount_eur: float, category: str, memo: str) -> str:
        """Authorize a payment before calling a paid API or service."""
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
    return authorize_spend

# agent = initialize_agent([make_spend_tool(gate), ...], llm, ...)
```

### MCP server

Expose `authorize_spend` as an MCP tool so any MCP-compatible agent (Claude Desktop, custom clients) can call it.

```python
from mcp.server.fastmcp import FastMCP
from decimal import Decimal
from lex_guard import SpendGate, SpendIntent, DeniedError

mcp = FastMCP("lex-guard")

def register_spend_tool(gate: SpendGate):
    @mcp.tool()
    def authorize_spend(merchant: str, amount_eur: float, category: str, memo: str) -> str:
        """Authorize a payment. Returns approval confirmation or denial reason."""
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
```

---

## How lex-guard fits in the agentic payments landscape

The market has converged on three distinct layers. lex-guard occupies the governance layer; the others are mostly complementary, not competing.

| Layer | What it solves | Examples |
|---|---|---|
| **Trust / authorization** | Prove to a merchant that a real user authorized this agent to act | AP2 (Google → FIDO Alliance), Visa TAP, Mastercard Verifiable Intent |
| **Payment rails** | Give the agent a way to actually move money | Stripe MPP, x402 (crypto/stablecoin via Coinbase) |
| **Governance** | Limit what the agent is allowed to spend, with proof | **lex-guard**, Stripe MPP (partial — see below) |

### lex-guard vs Stripe MPP

Stripe's [Machine Payments Protocol](https://stripe.com/blog/machine-payments-protocol) is the most direct comparison. It has real spending controls: per-transaction limits, rolling daily/weekly budgets, MCC category blocks, and merchant allowlists. If you're already on Stripe and happy with server-side enforcement, MPP may be all you need.

lex-guard is the right choice when:

| | Stripe MPP | lex-guard |
|---|---|---|
| Per-transaction cap | ✓ | ✓ |
| Per-day / rolling window cap | ✓ | ✓ |
| Category allowlist | ✓ (MCCs) | ✓ |
| Merchant allowlist | ✓ | ✓ |
| Velocity limit (tx/hour) | — | ✓ |
| Enforcement location | Stripe servers (network call) | in-process, offline |
| Works without Stripe | — | ✓ (any executor) |
| Attestation trail (intent before charge, hash-chained) | — | ✓ |

The key differences: enforcement happens **inside your process** before any network call (no Stripe hot-path dependency, no latency, no uptime SLA to worry about), and the audit trail is **content-addressed** — every `spend.intent` event is recorded before the charge and cryptographically linked to its `spend.outcome`, so you can prove to an auditor exactly what was authorized and when, independent of any payment processor's logs.

The two can be combined: use lex-guard as the governance layer with `StripeIssuingExecutor` underneath — you get lex-guard's offline enforcement and trail on top of Stripe's card network.

### lex-guard vs x402

[x402](https://docs.cdp.coinbase.com/x402/welcome) is a crypto/stablecoin micropayment protocol (Base, Solana). If your agent pays for APIs with on-chain tokens, x402 is your payment rail. AWS Bedrock's AgentCore wraps it with some policy controls. lex-guard is payment-method agnostic and fiat-first — use an `x402Executor` when that executor exists.

### AP2 and Visa TAP

[AP2](https://github.com/google-agentic-commerce/AP2) and [Visa TAP](https://developer.visa.com/capabilities/trusted-agent-protocol) solve a different problem: proving to a merchant that the agent is legitimate and the user authorized it. They don't cap what the agent can spend. They're complementary — a future lex-guard token could carry an AP2 verifiable credential as an additional claim.

*Comparison current as of June 2026. This space moves fast.*

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
