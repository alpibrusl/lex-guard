# lex-guard

[![CI](https://github.com/alpibrusl/lex-guard/actions/workflows/lex.yml/badge.svg)](https://github.com/alpibrusl/lex-guard/actions/workflows/lex.yml)

**Part of the [Lex](https://lexlang.org) project** — [Manifesto](https://www.alpibru.com/manifesto) · [All packages](https://lexlang.org)

Agent spending guardrails: **capability-gated budget tokens with an attestation trail.** Your AI agent gets an allowance, not your card — and you can prove what it spent.

An agent presents a signed **budget token** (an Ed25519-signed policy: caps, allowlists, currency). The gate enforces the policy *before any charge*, in-process, and writes a tamper-evident trail — `spend.intent` before, `spend.outcome` (or `spend.denied`) after — so every decision is auditable.

```
authorize_spend(intent)
  → attest spend.intent
  → stateless policy check (lex-spec)         — currency, per-tx cap, allowlists, memo
  → stateful caps from the trail (lex-trail)  — total / daily / velocity
      → denied?  attest spend.denied
      → allowed? run executor, attest spend.outcome
```

It's the Lex thesis applied to money: typed effects checked before they run, with a tamper-evident record.

## This is the Lex implementation

lex-guard was ported from Python to pure Lex. It composes packages from the Lex ecosystem rather than reimplementing them:

| Concern | Package |
|---|---|
| Budget token (Ed25519-signed policy) | `std.crypto` ed25519 |
| Stateless policy as a typed, verifiable spec | `lex-spec` |
| Attestation trail (content-addressed, parent-linked) | `lex-trail` |
| Exact money at the display/executor edge | `lex-money` |
| `authorize_spend` exposed as an MCP tool | `lex-agent` + `lex-mcp` |

Python AI agents reach the gate over **MCP** (`lex-mcp` stdio) — no Python package required.

## Modules

- **`token`** — issue / verify Ed25519 budget tokens (the policy is the signed payload).
- **`policy`** — compile the stateless policy to a `lex-spec` Spec (so it's property-checkable and SMT-exportable).
- **`gate`** — the hot path: attest → stateless check → stateful caps → execute → attest.
- **`skill`** — the `authorize_spend` lex-agent Skill; `make_agent` builds the served agent.
- **`executor`** / **`http_exec`** — pluggable executors; `mock` for tests, `http_exec.make(url, token, id_field)` for a real payment endpoint (Stripe Issuing is `make(stripe_url, api_key, "id")`).
- **`money`** — minor-unit ↔ typed Money + human formatting.
- **`main`** — the MCP server entry (`lex run src/main.lex main`).

## Design notes

- **Amounts are integer minor units** in a single currency per token, so policy checks are exact integer comparisons. lex-money is used only at the human/executor boundary.
- **Daily / velocity caps use rolling windows** (last 24h / 1h), summed back from the trail — state lives in the attestation log, not in memory.
- **Token signing is Ed25519** (the issuer holds the seed, agents hold only the public key — a compromised agent can't mint tokens).
- **Validity window is enforced before any charge.** The gate denies an expired (`expires_at`) or not-yet-valid (`not_before`) token and attests the `spend.denied` — bounds are epoch-ms, `0` = unset.
- **Idempotency.** A client-supplied `idempotency_key` on the intent rides through to the executor as an `Idempotency-Key` header, so a retried charge is deduped by the payment backend. The gate retries the `spend.outcome` write once and, if it still fails, returns an error carrying the `executor_ref` — a charged-but-unrecorded spend is always recoverable rather than lost.
- **`main` verifies the token.** With `LEX_GUARD_TOKEN` + `LEX_GUARD_ISSUER_PUBKEY` set, the server verifies the budget token's signature and enforces the embedded policy; a token that fails to verify is rejected (no silent fallback). With neither set, it runs the demo policy.

## Roadmap

- **AP2 ([ap2-protocol.org](https://ap2-protocol.org)) interop** via [lex-jose](https://github.com/alpibrusl/lex-jose): consume Intent/Cart Mandates → `Policy`; later mint SD-JWT mandates once `std.crypto` P-256 / ES256 ships in a release. See [docs/design/python-to-lex.md](docs/design/python-to-lex.md).
- **A real PSP adapter** — `http_exec` is a generic JSON POST; a production Stripe/issuing executor must build that backend's request/response shape.

## Develop

```bash
lex pkg install
lex ci          # check --strict + fmt --check + test
```

## License

[EUPL-1.2](https://eupl.eu/).
