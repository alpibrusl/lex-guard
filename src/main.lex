# lex-guard MCP server entry.
#
# Opens the attestation trail and serves the `authorize_spend` Skill over MCP
# stdio via lex-mcp — no Python. A real deployment loads the policy from a
# verified budget token (see token.verify); this demo policy is for `lex run`.

import "std.env" as env

import "std.str" as str

import "lex-trail/log" as trail

import "lex-mcp/src/server" as mcpsrv

import "./models" as models

import "./skill" as skill

import "./executor" as executor

import "./token" as token

fn demo_policy() -> models.Policy {
  { token_id: "tok_demo", agent_id: "demo-agent", currency: "EUR", cap_total: 20000, cap_per_day: 5000, cap_per_transaction: 2500, merchants_allow: ["api.openai.com", "aws.amazon.com"], categories_allow: ["saas", "cloud"], max_tx_per_hour: 10, expires_at: 0, not_before: 0, require_memo: true, policy_version: 1 }
}

# Resolve the policy the gate enforces. A real deployment supplies a signed budget
# token (LEX_GUARD_TOKEN) and the issuer's public key (LEX_GUARD_ISSUER_PUBKEY);
# we verify the signature and use the embedded policy. With neither set (e.g. a
# bare `lex run`) we fall back to the demo policy. A token that fails to verify is
# rejected — we do NOT silently fall back, so a forged/garbled token cannot run.
fn resolve_policy() -> [env] Result[models.Policy, Str] {
  match env.get("LEX_GUARD_TOKEN") {
    None => Ok(demo_policy()),
    Some(tok) => match env.get("LEX_GUARD_ISSUER_PUBKEY") {
      None => Err("LEX_GUARD_TOKEN set but LEX_GUARD_ISSUER_PUBKEY missing"),
      Some(pubkey) => match token.verify(pubkey, tok) {
        Err(e) => Err(str.concat("budget token rejected: ", e)),
        Ok(bt) => Ok(bt.policy),
      },
    },
  }
}

fn main() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Nil {
  match resolve_policy() {
    Err(_) => (),
    Ok(pol) => match trail.open("lex-guard-trail.db") {
      Err(_) => (),
      Ok(log) => mcpsrv.run(skill.make_agent(pol, log, executor.mock)),
    },
  }
}

