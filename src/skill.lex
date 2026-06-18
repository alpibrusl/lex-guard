# The `authorize_spend` Skill — lex-guard exposed as a lex-agent capability,
# served over MCP by lex-mcp (see main.lex). The stateless policy rides as the
# capability's lex-spec precondition; the handler closes over the policy, trail,
# and executor and runs the full gate.

import "std.str" as str

import "std.list" as list

import "lex-schema/schema" as sch

import "lex-schema/json_value" as jv

import "lex-spec/capability" as cap

import "lex-agent/src/message" as msg

import "lex-agent/src/server" as srv

import "lex-agent/src/agent_card" as card

import "lex-agent/src/task" as tk

import "lex-trail/log" as trail

import "./models" as models

import "./policy" as policy

import "./gate" as gate

# ---- capability ---------------------------------------------------
fn authorize_spend_cap(pol :: models.Policy) -> cap.Capability {
  let base := cap.inbound("authorize_spend", "Authorize an agent spend against its budget token.", { title: "SpendIntent", description: "merchant + amount (minor units) + currency + category + memo", fields: [sch.required_str("merchant", []), sch.required_int("amount", []), sch.required_str("currency", []), sch.required_str("category", []), sch.required_str("memo", [])] })
  cap.with_precondition(base, policy.policy_to_spec(pol))
}

# ---- request parsing (MCP args arrive as a DataPart(Json)) --------
fn parse_intent(m :: msg.Message) -> Result[models.SpendIntent, Str] {
  match first_data(m.parts) {
    None => Err("no data part in message"),
    Some(j) => build_intent(j),
  }
}

fn first_data(parts :: List[msg.Part]) -> Option[jv.Json] {
  list.fold(parts, None, fn (acc :: Option[jv.Json], p :: msg.Part) -> Option[jv.Json] {
    match acc {
      Some(_) => acc,
      None => match p {
        DataPart(j) => Some(j),
        _ => None,
      },
    }
  })
}

fn build_intent(j :: jv.Json) -> Result[models.SpendIntent, Str] {
  match field_str(j, "merchant") {
    Err(e) => Err(e),
    Ok(merchant) => match field_int(j, "amount") {
      Err(e) => Err(e),
      Ok(amount) => match field_str(j, "currency") {
        Err(e) => Err(e),
        Ok(currency) => match field_str(j, "category") {
          Err(e) => Err(e),
          Ok(category) => Ok({ merchant: merchant, amount: amount, currency: currency, category: category, memo: opt_str(j, "memo") }),
        },
      },
    },
  }
}

fn field_str(j :: jv.Json, key :: Str) -> Result[Str, Str] {
  match jv.get_field(j, key) {
    None => Err(str.concat("missing field: ", key)),
    Some(v) => match jv.as_str(v) {
      None => Err(str.concat("field not a string: ", key)),
      Some(s) => Ok(s),
    },
  }
}

fn field_int(j :: jv.Json, key :: Str) -> Result[Int, Str] {
  match jv.get_field(j, key) {
    None => Err(str.concat("missing field: ", key)),
    Some(v) => match jv.as_int(v) {
      None => Err(str.concat("field not an integer: ", key)),
      Some(n) => Ok(n),
    },
  }
}

fn opt_str(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    None => "",
    Some(v) => match jv.as_str(v) {
      None => "",
      Some(s) => s,
    },
  }
}

# ---- handler ------------------------------------------------------
fn handle_spend(pol :: models.Policy, log :: trail.Log, exec :: (models.SpendIntent) -> [net] Result[Str, Str], m :: msg.Message) -> [sql, time, net] srv.HandlerOutcome {
  match parse_intent(m) {
    Err(e) => reply(TSFailed, str.concat("bad request: ", e)),
    Ok(intent) => match gate.spend(pol, log, exec, intent) {
      Err(e) => reply(TSFailed, str.concat("error: ", e)),
      Ok(out) => if out.approved {
        reply(TSCompleted, str.concat("approved: ", out.executor_ref))
      } else {
        reply(TSCompleted, str.concat("denied: ", out.denial_reason))
      },
    },
  }
}

fn reply(state :: tk.TaskState, text :: Str) -> srv.HandlerOutcome {
  { next_state: state, reply: Some(msg.agent_text(text)), artifacts: [] }
}

# ---- assembly -----------------------------------------------------
fn make_skill(pol :: models.Policy, log :: trail.Log, exec :: (models.SpendIntent) -> [net] Result[Str, Str]) -> srv.Skill {
  { capability: authorize_spend_cap(pol), handle: fn (m :: msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] srv.HandlerOutcome {
    handle_spend(pol, log, exec, m)
  } }
}

fn make_agent(pol :: models.Policy, log :: trail.Log, exec :: (models.SpendIntent) -> [net] Result[Str, Str]) -> srv.AgentDef {
  let c := card.make("lex-guard", "Agent spending guardrails", "0.2.0", "http://localhost:7000", [authorize_spend_cap(pol)])
  srv.make_agent_def(c, [make_skill(pol, log, exec)])
}

