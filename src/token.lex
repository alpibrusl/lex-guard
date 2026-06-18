# Budget token: an Ed25519-signed spending policy.
#
# Format:  base64url(policy_json) "." base64url(signature)
#
# The issuer (control plane) holds the 32-byte secret seed and signs the policy.
# Agents and verifiers hold only the base64url public key, so a compromised agent
# cannot mint tokens — the asymmetric guarantee. (lex-crypto has no RS256/ES256;
# Ed25519 is the asymmetric primitive, and a deliberate upgrade over RSA.)

import "std.str" as str

import "std.json" as json

import "std.bytes" as bytes

import "std.crypto" as crypto

import "std.list" as list

import "lex-crypto/ed25519" as ed

import "./models" as models

type BudgetToken = { raw :: Str, policy :: models.Policy }

# Issue a token: sign `policy` with a 32-byte Ed25519 secret seed.
# (Lives here so the package is self-contained; a control plane calls the same fn.)
fn issue(secret :: Bytes, policy :: models.Policy) -> Result[Str, Str] {
  let payload := json.stringify(policy)
  let payload_b64 := crypto.base64url_encode(bytes.from_str(payload))
  match ed.sign_text(secret, payload) {
    Err(e) => Err(e),
    Ok(sig_b64) => Ok(str.concat(payload_b64, str.concat(".", sig_b64))),
  }
}

# Verify a token against the issuer's base64url public key.
# Returns the decoded BudgetToken, or an error describing the failure.
fn verify(public_b64 :: Str, token :: Str) -> Result[BudgetToken, Str] {
  let parts := str.split(token, ".")
  if list.len(parts) == 2 {
    match list.head(parts) {
      None => Err("malformed token"),
      Some(payload_b64) => match list.head(list.tail(parts)) {
        None => Err("malformed token"),
        Some(sig_b64) => decode_verified(public_b64, token, payload_b64, sig_b64),
      },
    }
  } else {
    Err("malformed token: expected payload.signature")
  }
}

fn decode_verified(public_b64 :: Str, raw :: Str, payload_b64 :: Str, sig_b64 :: Str) -> Result[BudgetToken, Str] {
  match crypto.base64url_decode(payload_b64) {
    Err(_) => Err("bad payload encoding"),
    Ok(payload_bytes) => match bytes.to_str(payload_bytes) {
      Err(_) => Err("payload is not valid UTF-8"),
      Ok(payload) => if ed.verify_text(public_b64, payload, sig_b64) {
        match (json.parse(payload) :: Result[models.Policy, Str]) {
          Err(e) => Err(str.concat("bad policy json: ", e)),
          Ok(pol) => Ok({ raw: raw, policy: pol }),
        }
      } else {
        Err("invalid signature")
      },
    },
  }
}

# The issuer's public key (base64url) derived from its secret seed — what
# verifiers are configured with.
fn public_key(secret :: Bytes) -> Result[Str, Str] {
  ed.public_key_b64(secret)
}

