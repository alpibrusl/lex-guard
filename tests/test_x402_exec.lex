# x402 executor tests (pure — no network).
#
# The live executor's network leg (`x402.pay`) can't run offline, so we
# exercise the same 402 -> sign -> 200 handshake the executor drives, at
# the pure boundary, against a mock facilitator's header bytes — using
# the executor's own per-intent nonce derivation so the test tracks what
# `x402_exec.make` actually sends:
#   - derive the authorization nonce from a SpendIntent (deterministic)
#   - build + sign a Solana `exact` payload, decode it, verify the
#     ed25519 signature against the payer's public key
#   - decode a mock PAYMENT-RESPONSE settlement into a spend reference

import "std.str" as str

import "std.list" as list

import "std.bytes" as bytes

import "std.crypto" as crypto

import "lex-x402/src/types" as types

import "lex-x402/src/network" as network

import "lex-x402/src/client" as x402

import "lex-x402/src/scheme/exact_solana" as solana

import "../src/models" as models

import "../src/x402_exec" as x402_exec

fn seed_b64url() -> Str {
  crypto.base64url_encode(bytes.from_str("0123456789abcdef0123456789abcdef"))
}

fn signer() -> solana.Signer {
  { secret_b64url: seed_b64url(), address: "PayerSoLAddr1111111111111111111111111111111" }
}

fn public_b64url() -> Result[Str, Str] {
  match crypto.base64url_decode(seed_b64url()) {
    Err(e) => Err(e),
    Ok(secret) => match crypto.ed25519_public_key(secret) {
      Err(e) => Err(e),
      Ok(pk) => Ok(crypto.base64url_encode(pk)),
    },
  }
}

fn intent() -> models.SpendIntent {
  { merchant: "api.openai.com", amount: 4200, currency: "USDC", category: "saas", memo: "embeddings" }
}

fn other_intent() -> models.SpendIntent {
  { merchant: "api.openai.com", amount: 9900, currency: "USDC", category: "saas", memo: "embeddings" }
}

fn requirement() -> types.Requirements {
  { scheme: "exact", network: network.solana_mainnet(), max_amount_required: "4200", resource: "https://api.openai.com/v1/embeddings", description: "embeddings", mime_type: "application/json", pay_to: "MerchantSoLAddr2222222222222222222222222222", max_timeout_seconds: 60, asset: "EPjFWdd5USDCmintxxxxxxxxxxxxxxxxxxxxxxxxxxxx" }
}

# The per-intent nonce is deterministic and distinguishes distinct spends.
fn t_nonce_deterministic() -> Result[Unit, Str] {
  if x402_exec.nonce_for(intent()) == x402_exec.nonce_for(intent()) {
    if x402_exec.nonce_for(intent()) == x402_exec.nonce_for(other_intent()) {
      Err("distinct intents produced the same nonce")
    } else {
      Ok(())
    }
  } else {
    Err("nonce derivation is not deterministic")
  }
}

# Build + sign with the executor's nonce, decode, and verify the
# signature — the sign leg of the executor's handshake.
fn t_sign_with_intent_nonce() -> Result[Unit, Str] {
  let nonce := x402_exec.nonce_for(intent())
  match solana.build(requirement(), signer(), 0, x402_exec.far_future(), nonce) {
    Err(e) => Err(str.concat("build: ", e)),
    Ok(header) => match solana.decode(header) {
      Err(e) => Err(str.concat("decode: ", e)),
      Ok(payload) => check_sig(payload, nonce),
    },
  }
}

fn check_sig(payload :: solana.Payload, nonce :: Str) -> Result[Unit, Str] {
  match public_b64url() {
    Err(e) => Err(str.concat("pubkey: ", e)),
    Ok(pub) => if solana.verify(pub, payload.payload.authorization, payload.payload.signature) {
      if payload.payload.authorization.nonce == nonce and payload.payload.authorization.value == "4200" {
        Ok(())
      } else {
        Err("decoded authorization carried wrong nonce/value")
      }
    } else {
      Err("signature did not verify")
    },
  }
}

# A mock 200 PAYMENT-RESPONSE decodes into the settlement reference the
# executor would return as Ok(ref).
fn t_settlement_ref() -> Result[Unit, Str] {
  let s := { success: true, transaction: "5xTxHashSoLana", network: network.solana_mainnet(), payer: "PayerSoLAddr1111111111111111111111111111111", error: "" }
  match types.decode_settlement(types.encode_settlement(s)) {
    Err(e) => Err(str.concat("decode_settlement: ", e)),
    Ok(got) => if got.transaction == "5xTxHashSoLana" and got.success {
      Ok(())
    } else {
      Err("settlement reference round-trip mismatch")
    },
  }
}

# The full challenge -> select path the executor takes on a 402.
fn t_select_from_challenge() -> Result[Unit, Str] {
  let challenge := { x402_version: 2, accepts: [requirement()], error: "" }
  match types.decode_required(types.encode_required(challenge)) {
    Err(e) => Err(str.concat("decode_required: ", e)),
    Ok(pr) => match x402.select(pr) {
      Err(e) => Err(str.concat("select: ", e)),
      Ok(req) => if req.network == network.solana_mainnet() {
        Ok(())
      } else {
        Err("selected the wrong requirement")
      },
    },
  }
}

fn run_all() -> Unit {
  let results := [t_nonce_deterministic(), t_sign_with_intent_nonce(), t_settlement_ref(), t_select_from_challenge()]
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
