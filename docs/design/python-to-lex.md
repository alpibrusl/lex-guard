# Design: port lex-guard from Python to Lex

Status: **implemented** · 2026-06-17 (port complete on branch `port/lex`; Python removed; `lex ci` green, 5 test files)

## Why

lex-guard is the Lex thesis applied to money: capability-gated budget tokens
plus an attestation trail (`spend.intent` before, `spend.outcome` after) =
typed effects checked before run, with a tamper-evident record. It is one of
the strongest manifesto showcases in the catalog — yet it is the only **library**
in the `lex-*` family written in Python. Every other `lex-*` library is Lex;
only `lex-lang` and `lex-os` (the Rust compiler and runtime) are host-language
exceptions, and those are foundational, not libraries.

It is also currently *reimplementing* packages we already own:

- `trail.py` — its own header says it "mirrors the lex-trail format". → **lex-trail**
- decimal money math on `Decimal` strings. → **lex-money**
- the stateless policy checks (`gate.evaluate`). → **lex-spec** does this natively.

So the port is mostly assembly of packages we already have, not new logic.

## Target architecture

```
lex-guard (Lex)
 ├─ authorize_spend : lex-agent Skill   ── exposed over MCP by lex-mcp (mcp.server.run)
 │    capability.params       → lex-schema ModelSchema {merchant, amount, currency, category, memo}
 │    capability.precondition → lex-spec Spec  (the STATELESS policy — verifiable)
 │    handle()                → verify token · eval policy · execute · attest
 ├─ budget token              → lex-crypto  (Ed25519-signed claims)   [wire-format change, see D1]
 ├─ policy → Spec             → lex-spec  (eval + check_random + to_smt_lib)
 ├─ money / caps              → lex-money  (Money, integer minor units)
 ├─ attestation trail         → lex-trail  (delete trail.py)
 └─ executor (Stripe/HTTP)    → std.http   (http.send POST; lex-web is server-only)
```

No Python required. Python AI agents reach the gate over MCP (language-agnostic),
which is exactly what MCP is for. A `pip install lex-guard` SDK becomes optional
— ship it later only if a customer needs in-process enforcement without the MCP
round-trip.

## Module-by-module mapping

| Python (`src/lex_guard/`) | Becomes | Notes |
|---|---|---|
| `models.py` `SpendIntent` | lex-schema `ModelSchema` = the capability `params` | becomes the MCP tool input schema for free |
| `gate.py` `evaluate()` (memo, currency, per-tx cap, merchant/category allowlist) | **lex-spec `Spec`** as `capability.precondition`; eval via `cap.gate(cap, bindings) -> Verdict` | the policy becomes a typed, verifiable artifact |
| `gate.py` `evaluate_with_history()` (total/day/velocity) | handler logic over `lex-trail` range queries + `lex-money.compare` | stateful — cannot live in the pure Spec |
| `token.py` (JWT policy) | `lex-crypto` sign/verify; claims → policy params → `policy_to_spec()` | RS256/ES256 unsupported — see D1 |
| `trail.py` | **deleted** → `lex-trail` `log.append(kind, parent, payload_json)` | SQLite-backed, content-addressed; was a reimplementation |
| `executor.py` (Mock/HTTP/Stripe) | `std.http` `http.send` POST to Stripe Issuing REST | Stripe SDK was convenience only |
| `mcp_server.py` | **deleted** → `lex-mcp` `mcp.server.run(agent_def)` | the reason no Python is needed |

## Package APIs this builds on (verified)

- **lex-agent** `src/server.lex:76` — `type Skill = { capability :: cap.Capability, handle :: (msg.Message) -> [..] HandlerOutcome }`; `AgentDef = { card, skills, store, trail :: Option[trail.Log] }` (the agent already carries a trail).
- **lex-spec** `capability.lex:46` — `Capability` has `precondition :: Option[sp.Spec]`; `eval.lex:26` `eval(spec, bindings) -> Verdict`; `check.lex:39` `check_random(spec, n, seed)`; `smt.lex:34` `to_smt_lib(spec) -> Str`; `capability.lex:72` `gate(cap, bindings) -> Verdict`.
- **lex-mcp** `src/server.lex:160` — `run(agent :: srv.AgentDef) -> [..] Nil`; `tool.lex:23` `skill_to_mcp_tool` maps `capability.params` → JSON schema via `sch.to_json_schema`.
- **lex-trail** `log.lex:68` — `append(log, kind, parent, payload_json) -> [sql,time] Result[Event,Str]`; `append_at(..., ts_ms)` deterministic; `open(path)`/`open_memory()`; `Event = { id, kind, parent, payload_json, ts_ms }`.
- **lex-money** `money.lex` — `Money = { amount::Int, currency, exponent }`; `from_major`, `add -> Result`, `compare -> Result[Int]`.
- **lex-crypto** — HS256/HS512 + **Ed25519** + HMAC-SHA256. **No RS256/ES256.** `jwt.sign_hs256` / `verify_hs256`; `ed25519.sign` / `verify`.
- **std.http** — `http.send(req) -> [net] Result[HttpResponse,Str]` with custom headers (bearer auth) for the Stripe call. lex-web is server-only.

## The spend gate as a Skill (sketch)

```lex
fn authorize_spend_cap(pol :: Policy) -> cap.Capability {
  let base := cap.inbound("authorize_spend",
    "Authorize an agent spend against its budget token.",
    { title: "SpendIntent", description: "",
      fields: [ sch.required_str("merchant", [StrNonEmpty]),
                sch.required_str("amount",   [StrNonEmpty]),
                sch.required_str("currency", [StrNonEmpty]),
                sch.required_str("category", [StrNonEmpty]),
                sch.required_str("memo",     []) ] })
  cap.with_precondition(base, policy_to_spec(pol))   # policy as typed Spec
}

fn authorize_spend_handler(tok :: BudgetToken, trail :: trail.Log, m :: msg.Message)
  -> [net, sql, time, crypto] srv.HandlerOutcome {
  let intent := parse_intent(m.parts)
  let iev := log.append(trail, "spend.intent", None, intent_json(intent, tok.policy.token_id))
  match cap.gate(authorize_spend_cap(tok.policy), bindings_of(intent)) {
    Deny(reason)      => deny(trail, iev, intent, reason)
    Inconclusive(why) => deny(trail, iev, intent, why)
    Allow => match history_check(tok.policy, trail, intent) {     # total/day/velocity from trail
      Some(reason) => deny(trail, iev, intent, reason)
      None => {
        let ref := stripe_execute(intent)                        # std.http POST
        let _ := log.append(trail, "spend.outcome", Some(iev.id), outcome_json(intent, ref))
        { next_state: TSCompleted, reply: Some(approved_reply(ref)), artifacts: [] }
      }
    }
  }
}

# main: mcp.server.run(make_agent())  → authorize_spend is now an MCP tool, zero Python.
```

## Decisions

### D1 — Budget-token signature scheme (the only wire-format change)

lex-crypto has no RS256/ES256 (today's prod algorithms). It offers HS256/HS512
(symmetric) and Ed25519 (asymmetric).

**Recommendation: Ed25519.** Control plane holds the signing seed; agents/verifiers
hold only the public key, so a compromised agent cannot mint tokens — same
asymmetric guarantee as RS256, smaller and faster. A deliberate upgrade.
HS256 is the lower-effort fallback but symmetric (any verifier can forge), so
not recommended for production budget tokens.

Open: existing issued tokens and the control-plane signer must adopt the new format.

### D2 — Stateless vs stateful policy split

Per-transaction checks (cap, allowlists, currency, memo) become a lex-spec `Spec`
→ gains `check_random` (replaces the Python Hypothesis property tests) and
`to_smt_lib` (formal proof, which the Python version cannot do). History caps
(total/day/velocity) need trail state and stay in `handle()`. The *verifiable*
part is the stateless policy.

### D3 — Amount representation

Caps are decimal strings today (`"25.00"`); lex-money uses integer minor units.
Carry amounts as integer minor units internally (better financial practice);
parse decimal strings only at the tool boundary.

## Sequencing

1. Token + `policy_to_spec` (lex-crypto + lex-spec) — gated on D1.
2. Gate + trail (lex-spec eval + lex-trail) — delete `trail.py`, wire history checks.
3. Skill + MCP (lex-agent + lex-mcp) — the sketch above.
4. Executors (std.http) — Mock trivial; Stripe one REST mapping.
5. Money (lex-money) — minor-units boundary parsing.

Genuinely new work: the Stripe `std.http` adapter and the D1 token-signing change.
Everything else is wiring packages we already own.

## Open questions

- D1: Ed25519 (recommended) or HS256?
- Is there a control plane issuing tokens today? If so it adopts the new signer —
  the only cross-system ripple.
