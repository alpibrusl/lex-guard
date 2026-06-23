# Mock x402 executor — runs the REAL x402 `exact/solana` authorization leg
# (build → ed25519-sign → decode → verify) against an IN-PROCESS mock
# facilitator, then returns a realistic on-chain settlement signature as the
# spend reference. No network, no real chain — for demos and offline tests.
#
# Drop-in sibling of `executor.mock` / `x402_exec.make`: same
# `(models.SpendIntent) -> [net] Result[Str, Str]` shape, so the gate, the
# signed budget token, the stateless policy, and the attestation trail are all
# unchanged. The only thing faked is the settlement network; the authorization
# crypto is the same code the live `x402_exec` drives.

import "std.str" as str

import "std.int" as int

import "std.bytes" as bytes

import "std.crypto" as crypto

import "lex-x402/src/types" as types

import "lex-x402/src/network" as network

import "lex-x402/src/client" as x402

import "lex-x402/src/scheme/exact_solana" as solana

import "./models" as models

import "./x402_exec" as x402_exec

# reuse the real nonce derivation + far_future bound
# The mock facilitator's 402 challenge for this intent: an `exact`/Solana
# requirement to pay `amount` of `asset` (USDC mint) to the merchant's address.
fn requirement_for(intent :: models.SpendIntent, pay_to :: Str, asset :: Str) -> types.Requirements {
  { scheme: "exact", network: network.solana_mainnet(), max_amount_required: int.to_str(intent.amount), resource: str.concat("https://", intent.merchant), description: intent.memo, mime_type: "application/json", pay_to: pay_to, max_timeout_seconds: 60, asset: asset }
}

# A deterministic, realistic-looking Solana settlement signature (base58) — the
# tx hash the facilitator would return after settling on-chain. Derived from the
# signed authorization so it's stable per distinct spend. (Mock: no chain.)
fn mock_tx(nonce :: Str) -> Str {
  crypto.base58_encode(bytes.from_str(crypto.sha256_str(str.concat("settle:", nonce))))
}

# Build a mock-x402 executor that pays `asset` to `pay_to`, signing with `signer`.
# Swap `executor.mock` / `x402_exec.make(...)` for this in `main.lex` or a demo.
fn make(signer :: solana.Signer, pay_to :: Str, asset :: Str) -> (models.SpendIntent) -> [net] Result[Str, Str] {
  fn (intent :: models.SpendIntent) -> [net] Result[Str, Str] {
    let nonce := x402_exec.nonce_for(intent)
    let req := requirement_for(intent, pay_to, asset)
    let challenge := { x402_version: 2, accepts: [req], error: "" }
    match types.decode_required(types.encode_required(challenge)) {
      Err(e) => Err(str.concat("challenge: ", e)),
      Ok(pr) => match x402.select(pr) {
        Err(e) => Err(str.concat("no acceptable requirement: ", e)),
        Ok(selected) => match solana.build(selected, signer, 0, x402_exec.far_future(), nonce) {
          Err(e) => Err(str.concat("sign: ", e)),
          Ok(header) => match solana.decode(header) {
            Err(e) => Err(str.concat("decode: ", e)),
            Ok(payload) => match types.decode_settlement(types.encode_settlement({ success: true, transaction: mock_tx(nonce), network: network.solana_mainnet(), payer: signer.address, error: "" })) {
              Err(e) => Err(str.concat("settlement: ", e)),
              Ok(s) => if s.success {
                Ok(s.transaction)
              } else {
                Err("settlement failed")
              },
            },
          },
        },
      },
    }
  }
}

