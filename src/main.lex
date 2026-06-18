# lex-guard MCP server entry.
#
# Opens the attestation trail and serves the `authorize_spend` Skill over MCP
# stdio via lex-mcp — no Python. A real deployment loads the policy from a
# verified budget token (see token.verify); this demo policy is for `lex run`.

import "lex-trail/log" as trail

import "lex-mcp/src/server" as mcpsrv

import "./models" as models

import "./skill" as skill

import "./executor" as executor

fn demo_policy() -> models.Policy {
  { token_id: "tok_demo", agent_id: "demo-agent", currency: "EUR", cap_total: 20000, cap_per_day: 5000, cap_per_transaction: 2500, merchants_allow: ["api.openai.com", "aws.amazon.com"], categories_allow: ["saas", "cloud"], max_tx_per_hour: 10, expires_at: 0, require_memo: true, policy_version: 1 }
}

fn main() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Nil {
  match trail.open("lex-guard-trail.db") {
    Err(_) => (),
    Ok(log) => mcpsrv.run(skill.make_agent(demo_policy(), log, executor.mock)),
  }
}

