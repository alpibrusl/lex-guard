# Mock x402 executor tests — the real exact/Solana sign leg + a mocked settlement,
# driven through the gate so policy + attestation are exercised. Runs offline
# (the mock facilitator is in-process).

import "std.str" as str

import "std.list" as list

import "std.bytes" as bytes

import "std.crypto" as crypto

import "lex-trail/log" as trail

import "../src/models" as models

import "../src/gate" as gate

import "../src/x402_mock_exec" as x402m

fn signer() -> { secret_b64url :: Str, address :: Str } {
  { secret_b64url: crypto.base64url_encode(bytes.from_str("0123456789abcdef0123456789abcdef")), address: "PayerSoLAddr1111111111111111111111111111111" }
}

fn policy() -> models.Policy {
  { token_id: "t", agent_id: "a", currency: "USDC", cap_total: 0, cap_per_day: 0, cap_per_transaction: 5000, merchants_allow: ["api.openai.com"], categories_allow: ["saas"], max_tx_per_hour: 0, expires_at: 0, require_memo: true, policy_version: 1 }
}

fn intent(amount :: Int) -> models.SpendIntent {
  { merchant: "api.openai.com", amount: amount, currency: "USDC", category: "saas", memo: "m" }
}

# The executor settles a valid intent into a realistic (long base58) tx signature,
# and is deterministic per distinct intent.
fn t_settles_deterministic() -> [net] Result[Unit, Str] {
  let ex := x402m.make(signer(), "MerchantSoLAddr2222222222222222222222222222", "EPjFWdd5USDCmintxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
  match ex(intent(4200)) {
    Err(e) => Err(str.concat("executor: ", e)),
    Ok(a) => if str.len(a) <= 40 {
      Err(str.concat("tx ref too short: ", a))
    } else {
      match ex(intent(4200)) {
        Err(e) => Err(e),
        Ok(b) => match ex(intent(2500)) {
          Err(e) => Err(e),
          Ok(c) => if a == b {
            if a == c {
              Err("distinct intents settled to the same tx")
            } else {
              Ok(())
            }
          } else {
            Err("settlement not deterministic")
          },
        },
      }
    },
  }
}

# Through the gate: an allowed spend is approved with the tx as executor_ref.
fn t_gate_approves() -> [sql, fs_write, time, net] Result[Unit, Str] {
  let ex := x402m.make(signer(), "MerchantSoLAddr2222222222222222222222222222", "EPjFWdd5USDCmintxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
  match trail.open_memory() {
    Err(e) => Err(e),
    Ok(log) => match gate.spend(policy(), log, ex, intent(4200)) {
      Err(e) => Err(e),
      Ok(o) => if o.approved and str.len(o.executor_ref) > 40 {
        Ok(())
      } else {
        Err("expected approved with a tx ref")
      },
    },
  }
}

# An over-cap spend is denied and never settles (empty executor_ref).
fn t_gate_denies_no_settlement() -> [sql, fs_write, time, net] Result[Unit, Str] {
  let ex := x402m.make(signer(), "MerchantSoLAddr2222222222222222222222222222", "EPjFWdd5USDCmintxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
  match trail.open_memory() {
    Err(e) => Err(e),
    Ok(log) => match gate.spend(policy(), log, ex, intent(9000)) {
      Err(e) => Err(e),
      Ok(o) => if o.approved {
        Err("over-cap spend was approved")
      } else {
        if o.executor_ref == "" {
          Ok(())
        } else {
          Err("denied spend should not settle")
        }
      },
    },
  }
}

fn run_all() -> [sql, fs_write, time, net] Unit {
  let results := [t_settles_deterministic(), t_gate_approves(), t_gate_denies_no_settlement()]
  let failures := list.fold(results, 0, fn (n :: Int, r :: Result[Unit, Str]) -> Int {
    match r {
      Ok(_) => n,
      Err(_) => n + 1,
    }
  })
  if failures == 0 {
    ()
  } else {
    let __ := 1 / 0
    ()
  }
}

