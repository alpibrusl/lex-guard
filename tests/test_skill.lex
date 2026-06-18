# Skill tests: an MCP-style DataPart message flows through parse → gate → reply,
# a malformed request fails cleanly, and a denied spend is still attested.

import "std.str" as str

import "std.list" as list

import "lex-trail/log" as trail

import "lex-trail/event" as ev

import "lex-agent/src/message" as msg

import "lex-agent/src/server" as srv

import "lex-schema/json_value" as jv

import "../src/models" as models

import "../src/skill" as skill

import "../src/executor" as executor

fn policy() -> models.Policy {
  { token_id: "tok_skill", agent_id: "agent", currency: "EUR", cap_total: 0, cap_per_day: 0, cap_per_transaction: 2500, merchants_allow: ["api.openai.com"], categories_allow: ["saas"], max_tx_per_hour: 0, expires_at: 0, not_before: 0, require_memo: false, policy_version: 1 }
}

fn intent_msg(merchant :: Str, amount :: Int) -> msg.Message {
  { message_id: "m1", role: RoleUser, parts: [DataPart(JObj([("merchant", JStr(merchant)), ("amount", JInt(amount)), ("currency", JStr("EUR")), ("category", JStr("saas")), ("memo", JStr("call"))]))] }
}

fn reply_text(o :: srv.HandlerOutcome) -> Str {
  match o.reply {
    None => "",
    Some(m) => list.fold(m.parts, "", fn (acc :: Str, p :: msg.Part) -> Str {
      if acc == "" {
        match p {
          TextPart(s) => s,
          _ => acc,
        }
      } else {
        acc
      }
    }),
  }
}

fn is_completed(o :: srv.HandlerOutcome) -> Bool {
  match o.next_state {
    TSCompleted => true,
    _ => false,
  }
}

fn handler_approves_compliant() -> [sql, fs_write, time, net] Result[Unit, Str] {
  match trail.open_memory() {
    Err(e) => Err(str.concat("open: ", e)),
    Ok(log) => {
      let out := skill.handle_spend(policy(), log, executor.mock, intent_msg("api.openai.com", 2000))
      if is_completed(out) {
        if reply_text(out) == "approved: mock_ref:api.openai.com" {
          Ok(())
        } else {
          Err(str.concat("unexpected reply: ", reply_text(out)))
        }
      } else {
        Err("expected completed state")
      }
    },
  }
}

fn handler_rejects_bad_request() -> [sql, fs_write, time, net] Result[Unit, Str] {
  match trail.open_memory() {
    Err(e) => Err(str.concat("open: ", e)),
    Ok(log) => {
      let bad := { message_id: "m2", role: RoleUser, parts: [DataPart(JObj([("merchant", JStr("api.openai.com"))]))] }
      let out := skill.handle_spend(policy(), log, executor.mock, bad)
      if is_completed(out) {
        Err("malformed request did not fail")
      } else {
        Ok(())
      }
    },
  }
}

fn handler_attests_denial() -> [sql, fs_write, time, net] Result[Unit, Str] {
  match trail.open_memory() {
    Err(e) => Err(str.concat("open: ", e)),
    Ok(log) => {
      let __lex_discard_1 := skill.handle_spend(policy(), log, executor.mock, intent_msg("api.openai.com", 9999))
      match trail.range(log, 0, 9999999999999) {
        Err(e) => Err(str.concat("range: ", e)),
        Ok(events) => if has_kind(events, "spend.denied") {
          Ok(())
        } else {
          Err("over-cap spend was not attested as denied")
        },
      }
    },
  }
}

fn has_kind(events :: List[ev.Event], kind :: Str) -> Bool {
  list.fold(events, false, fn (acc :: Bool, e :: ev.Event) -> Bool {
    if acc {
      acc
    } else {
      e.kind == kind
    }
  })
}

fn run_all() -> [sql, fs_write, time, net] Unit {
  let results := [handler_approves_compliant(), handler_rejects_bad_request(), handler_attests_denial()]
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

