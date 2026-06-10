"""lex-guard MCP server — exposes the spend gate as an MCP tool.

Any MCP client (Claude Code, Cursor, Copilot, Codex, Claude Desktop) can
call `authorize_spend`; the gate enforces the budget token's policy in-process
and writes an attestation trail before any charge is attempted.

Run:
    lex-guard-mcp                # installed entry point
    python -m lex_guard.mcp_server

Configuration (environment variables):
    LEX_GUARD_TOKEN       Budget token JWT (raw). Required.
    LEX_GUARD_PUBLIC_KEY  PEM public key to verify the token signature.
                          If unset, the token is decoded WITHOUT verification
                          (test/dev only — emits a warning).
    LEX_GUARD_EXECUTOR    "mock" (default) | "http" | "stripe"
    LEX_GUARD_HTTP_URL    Endpoint for the http executor.
    LEX_GUARD_CURRENCY    Default currency for intents (default: token currency).
"""

from __future__ import annotations

import os
import sys
from decimal import Decimal, InvalidOperation

from .token import load_token, load_token_unsafe
from .gate import SpendGate, DeniedError
from .models import SpendIntent
from .trail import TrailWriter
from .executor import MockExecutor, HTTPExecutor


def _build_executor():
    kind = os.environ.get("LEX_GUARD_EXECUTOR", "mock").lower()
    if kind == "mock":
        return MockExecutor()
    if kind == "http":
        url = os.environ.get("LEX_GUARD_HTTP_URL")
        if not url:
            raise SystemExit("LEX_GUARD_EXECUTOR=http requires LEX_GUARD_HTTP_URL")
        return HTTPExecutor(url)
    if kind == "stripe":
        try:
            from .executor_stripe import StripeIssuingExecutor
        except ImportError as e:
            raise SystemExit(f"stripe executor unavailable: {e} (pip install lex-guard[stripe])")
        return StripeIssuingExecutor()
    raise SystemExit(f"unknown LEX_GUARD_EXECUTOR: {kind}")


def _build_gate() -> SpendGate:
    raw = os.environ.get("LEX_GUARD_TOKEN")
    if not raw:
        raise SystemExit("LEX_GUARD_TOKEN is required (the budget token JWT)")

    public_key = os.environ.get("LEX_GUARD_PUBLIC_KEY")
    if public_key:
        token = load_token(raw, public_key)
    else:
        print("WARNING: LEX_GUARD_PUBLIC_KEY unset — token signature NOT verified "
              "(dev/test only)", file=sys.stderr)
        token = load_token_unsafe(raw)

    return SpendGate(token, TrailWriter(), _build_executor())


def main() -> None:
    try:
        from mcp.server.fastmcp import FastMCP
    except ImportError:
        raise SystemExit("MCP support not installed. Run: pip install lex-guard[mcp]")

    gate = _build_gate()
    default_currency = os.environ.get("LEX_GUARD_CURRENCY", gate._token.policy.currency)

    server = FastMCP("lex-guard")

    @server.tool()
    def authorize_spend(merchant: str, amount: float, category: str, memo: str) -> str:
        """Authorize a payment before calling a paid API, tool, or service.

        Always call this BEFORE spending money. If it returns a denial, do not
        attempt the purchase — the charge was never made and the denial is logged.

        Args:
            merchant: Domain or name of the merchant, e.g. "api.openai.com".
            amount:   Amount to spend, in the configured currency.
            category: One of: saas, cloud, data, media, marketplace, other.
            memo:     Short reason for the spend (may be required by policy).
        """
        try:
            value = Decimal(str(amount))
        except (InvalidOperation, ValueError):
            return f"Denied: invalid amount '{amount}'"

        try:
            outcome = gate.spend(SpendIntent(
                merchant=merchant,
                amount=value,
                currency=default_currency,
                category=category,
                memo=memo,
            ))
            return f"Approved. Transaction ref: {outcome.executor_ref}"
        except DeniedError as e:
            return f"Denied: {e.reason}. Do not attempt this purchase."

    @server.tool()
    def spend_trail() -> str:
        """Return the attestation trail of all spend attempts so far (JSONL)."""
        return gate.trail.export_jsonl() or "(no events yet)"

    server.run()


if __name__ == "__main__":
    main()
