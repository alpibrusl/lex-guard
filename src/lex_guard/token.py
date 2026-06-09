"""Budget token: signed JWT carrying a spending policy."""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from decimal import Decimal
from typing import Optional

import jwt


@dataclass
class TokenPolicy:
    token_id: str
    agent_id: str
    currency: str
    cap_total: Decimal
    cap_per_day: Decimal
    cap_per_transaction: Decimal
    merchants_allow: list[str] = field(default_factory=list)
    categories_allow: list[str] = field(default_factory=list)
    max_tx_per_hour: int = 0          # 0 = unlimited
    expires_at: int = 0               # unix timestamp; 0 = no expiry
    require_memo: bool = False
    policy_version: int = 1


@dataclass
class BudgetToken:
    raw: str
    policy: TokenPolicy


def load_token(raw: str, public_key: str, algorithms: Optional[list[str]] = None) -> BudgetToken:
    """Decode and verify a signed JWT budget token.

    Raises jwt.InvalidTokenError on bad signature, expiry, or missing claims.
    """
    algos = algorithms or ["RS256", "ES256"]
    claims = jwt.decode(raw, public_key, algorithms=algos)
    policy = _claims_to_policy(claims)
    return BudgetToken(raw=raw, policy=policy)


def load_token_unsafe(raw: str) -> BudgetToken:
    """Decode WITHOUT verification — for testing only."""
    claims = jwt.decode(raw, options={"verify_signature": False})
    return BudgetToken(raw=raw, policy=_claims_to_policy(claims))


def _claims_to_policy(c: dict) -> TokenPolicy:
    caps = c.get("caps", {})
    merchants = c.get("merchants", {})
    categories = c.get("categories", {})
    velocity = c.get("velocity", {})

    return TokenPolicy(
        token_id=c["jti"],
        agent_id=c.get("agent_id", ""),
        currency=c.get("currency", "EUR"),
        cap_total=Decimal(str(caps.get("total", "0"))),
        cap_per_day=Decimal(str(caps.get("per_day", "0"))),
        cap_per_transaction=Decimal(str(caps.get("per_transaction", "0"))),
        merchants_allow=merchants.get("allow", []),
        categories_allow=categories.get("allow", []),
        max_tx_per_hour=velocity.get("max_tx_per_hour", 0),
        expires_at=c.get("exp", 0),
        require_memo=c.get("require_memo", False),
        policy_version=c.get("policy_version", 1),
    )
