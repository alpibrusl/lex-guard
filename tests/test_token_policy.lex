# Round-trip + policy tests for the lex-guard core:
#   - Ed25519 token issue → verify round-trips and recovers the policy
#   - a tampered token is rejected
#   - the stateless policy Spec allows compliant intents and denies violations

import "std.str" as str

import "std.list" as list

import "std.bytes" as bytes

import "lex-spec/spec" as sp

import "../src/models" as models

import "../src/token" as token

import "../src/policy" as policy

# 32-byte Ed25519 secret seed (test only).
fn seed() -> Bytes {
  bytes.from_str("0123456789abcdef0123456789abcdef")
}

fn sample_policy() -> models.Policy {
  { token_id: "tok_test01", agent_id: "research-agent", currency: "EUR", cap_total: 20000, cap_per_day: 5000, cap_per_transaction: 2500, merchants_allow: ["api.openai.com", "aws.amazon.com"], categories_allow: ["saas", "cloud"], max_tx_per_hour: 0, expires_at: 0, require_memo: true, policy_version: 1 }
}

fn intent(merchant :: Str, amount :: Int, currency :: Str, category :: Str, memo :: Str) -> models.SpendIntent {
  { merchant: merchant, amount: amount, currency: currency, category: category, memo: memo }
}

fn expect_deny(label :: Str, i :: models.SpendIntent) -> Result[Unit, Str] {
  if sp.verdict_is_allow(policy.check_stateless(sample_policy(), i)) {
    Err(str.concat(label, ": expected deny, got allow"))
  } else {
    Ok(())
  }
}

# ---- tests --------------------------------------------------------
fn roundtrip_recovers_policy() -> Result[Unit, Str] {
  match token.issue(seed(), sample_policy()) {
    Err(e) => Err(str.concat("issue failed: ", e)),
    Ok(tok) => match token.public_key(seed()) {
      Err(e) => Err(str.concat("public_key failed: ", e)),
      Ok(pk) => match token.verify(pk, tok) {
        Err(e) => Err(str.concat("verify failed: ", e)),
        Ok(bt) => if bt.policy.token_id == "tok_test01" {
          Ok(())
        } else {
          Err("recovered policy has wrong token_id")
        },
      },
    },
  }
}

fn tampered_token_rejected() -> Result[Unit, Str] {
  match token.issue(seed(), sample_policy()) {
    Err(e) => Err(str.concat("issue failed: ", e)),
    Ok(tok) => match token.public_key(seed()) {
      Err(e) => Err(str.concat("public_key failed: ", e)),
      Ok(pk) => match token.verify(pk, str.concat(tok, "x")) {
        Ok(_) => Err("tampered token verified"),
        Err(_) => Ok(()),
      },
    },
  }
}

fn wrong_key_rejected() -> Result[Unit, Str] {
  match token.issue(seed(), sample_policy()) {
    Err(e) => Err(str.concat("issue failed: ", e)),
    Ok(tok) => match token.public_key(bytes.from_str("ffffffffffffffffffffffffffffffff")) {
      Err(e) => Err(str.concat("public_key failed: ", e)),
      Ok(other_pk) => match token.verify(other_pk, tok) {
        Ok(_) => Err("token verified under wrong key"),
        Err(_) => Ok(()),
      },
    },
  }
}

fn allows_compliant_intent() -> Result[Unit, Str] {
  let v := policy.check_stateless(sample_policy(), intent("api.openai.com", 2000, "EUR", "saas", "embeddings call"))
  if sp.verdict_is_allow(v) {
    Ok(())
  } else {
    Err(str.concat("expected allow, got: ", sp.verdict_reason(v)))
  }
}

fn denies_over_cap() -> Result[Unit, Str] {
  expect_deny("over_cap", intent("api.openai.com", 9999, "EUR", "saas", "big spend"))
}

fn denies_bad_merchant() -> Result[Unit, Str] {
  expect_deny("bad_merchant", intent("evil.example.com", 100, "EUR", "saas", "sneaky"))
}

fn denies_wrong_currency() -> Result[Unit, Str] {
  expect_deny("wrong_currency", intent("api.openai.com", 100, "USD", "saas", "fx"))
}

fn denies_missing_memo() -> Result[Unit, Str] {
  expect_deny("missing_memo", intent("api.openai.com", 100, "EUR", "saas", ""))
}

fn run_all() -> Unit {
  let results := [roundtrip_recovers_policy(), tampered_token_rejected(), wrong_key_rejected(), allows_compliant_intent(), denies_over_cap(), denies_bad_merchant(), denies_wrong_currency(), denies_missing_memo()]
  let failures := list.fold(results, 0, fn (n :: Int, r :: Result[Unit, Str]) -> Int {
    match r {
      Ok(_) => n,
      Err(_) => n + 1,
    }
  })
  if failures == 0 {
    ()
  } else {
    let __discard := 1 / 0
    ()
  }
}

