# x402 executor — settle a gate-approved spend by running the x402
# 402 -> sign -> retry handshake against the resource, returning the
# on-chain settlement tx hash as the spend reference.
#
# Drop-in sibling of `executor.mock` / `http_exec.make`: same
# `(models.SpendIntent) -> [net] Result[Str, Str]` shape, so the gate,
# budget token, stateless policy, and attestation trail are all
# unchanged — only the executor module is new. The x402 protocol itself
# lives in the `lex-x402` package (lex-lang #656); guard composes it
# rather than carrying a payments stack, mirroring the AP2-via-lex-jose
# split on the roadmap.

import "std.str" as str

import "std.int" as int

import "std.crypto" as crypto

import "lex-x402/src/client" as x402

import "lex-x402/src/scheme/exact_solana" as solana

import "./models" as models

# `validBefore` sentinel: 2100-01-01 UTC. The executor runs under `[net]`
# only (the gate's executor effect row), so it can't read the clock to
# compute a real deadline; a far-future bound keeps the authorization
# valid for the spend without widening the effect row. A deployment that
# wants a tight deadline builds the executor with a clock-derived bound.
fn far_future() -> Int
  examples {
    far_future() => 4102444800
  }
{
  4102444800
}

# Build an x402 executor bound to a resource URL and an ed25519 signer.
# Swap `executor.mock` / `http_exec.make(...)` for this in `main.lex`;
# `spend.intent` / `spend.outcome` attestations record the x402
# settlement reference unchanged.
fn make(resource_url :: Str, signer :: solana.Signer) -> (models.SpendIntent) -> [net] Result[Str, Str] {
  fn (intent :: models.SpendIntent) -> [net] Result[Str, Str] {
    x402.pay({ resource_url: resource_url, signer: signer, nonce: nonce_for(intent), valid_after: 0, valid_before: far_future() })
  }
}

# Deterministic per-intent authorization nonce: hex(sha256) over the
# intent's identifying fields. The executor row is `[net]`-only, so a
# fresh random nonce (which needs `[random]`) isn't available here;
# deriving it from the intent keeps it unique per distinct spend without
# widening the effect row.
fn nonce_for(intent :: models.SpendIntent) -> Str {
  crypto.sha256_str(str.concat(intent.merchant, str.concat("|", str.concat(int.to_str(intent.amount), str.concat("|", intent.memo)))))
}
