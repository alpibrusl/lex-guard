# x402 payment demo — lex-guard authorizes spends against a signed budget policy,
# settles the approved ones via the (mock) x402 Solana exact rail, and records
# every step to the hash-chained attestation trail.
#
# Real authorization crypto (ed25519 Solana `exact`), mocked settlement network —
# so it runs offline yet looks like the real flow. Swap x402_mock_exec.make for
# x402_exec.make (live facilitator URL) and nothing else changes.
#
#   lex run --allow-effects crypto,fs_write,io,net,sql,time examples/x402_pay_demo.lex run

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.bytes" as bytes

import "std.crypto" as crypto

import "lex-trail/log" as trail

import "lex-trail/event" as ev

import "../src/models" as models

import "../src/gate" as gate

import "../src/x402_mock_exec" as x402m

fn usdc_policy() -> models.Policy {
  { token_id: "tok_demo", agent_id: "shopper-bot", currency: "USDC", cap_total: 100000, cap_per_day: 50000, cap_per_transaction: 5000, merchants_allow: ["api.openai.com", "MerchantSoLAddr2222222222222222222222222222"], categories_allow: ["saas", "goods"], max_tx_per_hour: 20, expires_at: 0, require_memo: true, policy_version: 1 }
}

fn signer() -> { secret_b64url :: Str, address :: Str } {
  { secret_b64url: crypto.base64url_encode(bytes.from_str("0123456789abcdef0123456789abcdef")), address: "PayerSoLAddr1111111111111111111111111111111" }
}

fn intent(merchant :: Str, amount :: Int, category :: Str, memo :: Str) -> models.SpendIntent {
  { merchant: merchant, amount: amount, currency: "USDC", category: category, memo: memo }
}

fn show(label :: Str, r :: Result[models.SpendOutcome, Str]) -> [io] Unit {
  match r {
    Err(e) => io.print(str.join(["  ", label, "  → ERROR ", e], "")),
    Ok(o) => if o.approved {
      io.print(str.join(["  ", label, "  → ✓ APPROVED — x402 settled, tx=", o.executor_ref], ""))
    } else {
      io.print(str.join(["  ", label, "  → ✗ DENIED — ", o.denial_reason], ""))
    },
  }
}

fn run() -> [io, sql, fs_write, time, net, crypto] Nil {
  let __lex_discard_1 := io.print("=== lex-guard × x402 — gated agent payments (mock settlement) ===")
  match trail.open_memory() {
    Err(e) => io.print(str.concat("trail open failed: ", e)),
    Ok(log) => {
      let pol := usdc_policy()
      let exec := x402m.make(signer(), "MerchantSoLAddr2222222222222222222222222222", "EPjFWdd5USDCmintxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
      let _h := io.print(str.join(["policy: agent=", pol.agent_id, " currency=", pol.currency, " per-tx cap=", int.to_str(pol.cap_per_transaction), " merchants=", str.join(pol.merchants_allow, ",")], ""))
      let _b := io.print("")
      let _1 := show("4200 USDC → api.openai.com  (embeddings)", gate.spend(pol, log, exec, intent("api.openai.com", 4200, "saas", "embeddings")))
      let _2 := show("9000 USDC → api.openai.com  (over 5000 cap) ", gate.spend(pol, log, exec, intent("api.openai.com", 9000, "saas", "bulk")))
      let _3 := show("100 USDC  → evil.example.com (not allowed)  ", gate.spend(pol, log, exec, intent("evil.example.com", 100, "saas", "sketchy")))
      let _4 := show("2500 USDC → api.openai.com  (completions) ", gate.spend(pol, log, exec, intent("api.openai.com", 2500, "saas", "completions")))
      let _b2 := io.print("\n── attestation trail (hash-chained lex-trail) ──")
      match trail.range(log, 0, 9999999999999) {
        Err(e) => io.print(str.concat("trail read failed: ", e)),
        Ok(evs) => {
          let __lex_discard_2 := list.fold(evs, 0, fn (n :: Int, e :: ev.Event) -> [io] Int {
            let _p := io.print(str.join(["  ", int.to_str(n + 1), ". ", e.kind, "  ", e.payload_json], ""))
            n + 1
          })
          ()
        },
      }
    },
  }
}

