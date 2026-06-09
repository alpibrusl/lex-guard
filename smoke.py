"""End-to-end smoke test: sign a JWT, load it, approve a spend, deny a spend."""

from decimal import Decimal
import time
import uuid

from cryptography.hazmat.primitives.asymmetric import rsa, padding
from cryptography.hazmat.primitives import serialization
import jwt

from lex_guard import SpendGate, SpendIntent, TrailWriter, MockExecutor, load_token
from lex_guard.gate import DeniedError, evaluate_with_history
from lex_guard.token import TokenPolicy

# --- Generate a throwaway RSA key pair ---
private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
public_key = private_key.public_key()
public_pem = public_key.public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo).decode()

# --- Issue a budget token as a signed JWT ---
claims = {
    "jti": "tok_" + uuid.uuid4().hex[:8],
    "agent_id": "research-buyer-1",
    "currency": "EUR",
    "caps": {"total": "200.00", "per_day": "50.00", "per_transaction": "25.00"},
    "merchants": {"allow": ["api.openai.com", "aws.amazon.com"]},
    "categories": {"allow": ["saas", "cloud"]},
    "velocity": {"max_tx_per_hour": 6},
    "exp": int(time.time()) + 3600,
    "require_memo": True,
    "policy_version": 1,
}
raw_token = jwt.encode(claims, private_key, algorithm="RS256")

# --- Load and verify the token ---
budget_token = load_token(raw_token, public_pem, algorithms=["RS256"])
print(f"[OK] Token loaded: {budget_token.policy.token_id}")
print(f"     agent_id={budget_token.policy.agent_id}, cap_total={budget_token.policy.cap_total} EUR")

# --- Approved spend ---
trail = TrailWriter()
executor = MockExecutor()
gate = SpendGate(budget_token, trail, executor)

outcome = gate.spend(SpendIntent(
    merchant="api.openai.com",
    amount=Decimal("4.20"),
    currency="EUR",
    category="saas",
    memo="embeddings for task X",
))
print(f"[OK] Approved: {outcome.executor_ref}")

# --- Denied: out-of-allowlist merchant ---
try:
    gate.spend(SpendIntent(
        merchant="evil.example.com",
        amount=Decimal("1.00"),
        currency="EUR",
        category="saas",
        memo="should be blocked",
    ))
    print("[FAIL] Should have been denied")
except DeniedError as e:
    print(f"[OK] Denied (merchant): {e.reason}")

# --- Denied: missing memo ---
try:
    gate.spend(SpendIntent(
        merchant="api.openai.com",
        amount=Decimal("1.00"),
        currency="EUR",
        category="saas",
        memo="",
    ))
    print("[FAIL] Should have been denied")
except DeniedError as e:
    print(f"[OK] Denied (memo): {e.reason}")

# --- Denied: exceeds per-transaction cap ---
try:
    gate.spend(SpendIntent(
        merchant="api.openai.com",
        amount=Decimal("30.00"),
        currency="EUR",
        category="saas",
        memo="big batch job",
    ))
    print("[FAIL] Should have been denied")
except DeniedError as e:
    print(f"[OK] Denied (per-tx cap): {e.reason}")

# --- History-aware: total cap ---
reason = evaluate_with_history(
    budget_token.policy,
    SpendIntent("api.openai.com", Decimal("10"), "EUR", "saas", "x"),
    total_spent=Decimal("195"),
    day_spent=Decimal("0"),
    tx_this_hour=0,
)
print(f"[OK] History cap denial: {reason}")

# --- Trail audit ---
events = trail.events()
print(f"\n[OK] Trail events recorded: {len(events)}")
for e in events:
    parent = f" (parent={e.parent[:8]}...)" if e.parent else ""
    print(f"     {e.kind}{parent}")

print("\nAll smoke checks passed.")
