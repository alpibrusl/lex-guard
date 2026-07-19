# tests/test_release.lex — the evidence-gated spend path (gate.spend_gated).
#
# The budget is fixed and permissive so the ONLY thing deciding approval is the
# fulfilment evidence: no evidence gate ⇒ pays; evidence that verifies ⇒ pays;
# missing evidence or a domain spec that denies the recorded outcome ⇒ blocked
# (executor never runs).

import "std.str" as str

import "std.list" as list

import "lex-trail/log" as trail

import "lex-trail/kinds" as kinds

import "lex-schema/json_value" as jv

import "lex-spec/spec" as sp

import "../src/models" as models

import "../src/gate" as gate

import "../src/release" as release

import "../src/executor" as executor

# Permissive budget: amount <= 5000, no total/velocity caps.
fn a_policy() -> models.Policy {
  { token_id: "tok_rel", agent_id: "agent", currency: "EUR", cap_total: 0, cap_per_day: 0, cap_per_transaction: 5000, merchants_allow: [], categories_allow: [], max_tx_per_hour: 0, expires_at: 0, require_memo: false, policy_version: 1 }
}

fn an_intent() -> models.SpendIntent {
  { merchant: "seller.bazaar", amount: 2000, currency: "EUR", category: "goods", memo: "buy" }
}

# "outcome.delivered == true" — the host's fulfilment predicate.
fn requires_delivered() -> sp.Spec {
  { name: "fulfilled", quantifiers: [QRecord({ name: "outcome", fields: [{ name: "delivered", ty: TBool }] })], predicate: EBinop({ op: "==", lhs: EField({ binding: "outcome", field: "delivered" }), rhs: EConst(VBool(true)) }) }
}

fn completed_trail(log :: trail.Log, delivered :: Bool) -> [sql, time] Result[Str, Str] {
  match trail.append(log, kinds.cap_completed(), None, jv.stringify(JObj([("delivered", JBool(delivered))]))) {
    Err(e) => Err(str.concat("record fulfilment: ", e)),
    Ok(cev) => Ok(cev.id),
  }
}

fn evidence(trail_id :: Str) -> release.Evidence {
  { trail_id: trail_id, spec: Some(requires_delivered()), binding: "outcome" }
}

fn ungated_pays() -> [sql, fs_write, time, net] Result[Unit, Str] {
  match trail.open_memory() {
    Err(e) => Err(str.concat("open: ", e)),
    Ok(log) => match gate.spend_gated(a_policy(), log, executor.mock, an_intent(), None) {
      Err(e) => Err(str.concat("spend: ", e)),
      Ok(out) => if out.approved {
        Ok(())
      } else {
        Err(str.concat("ungated spend blocked: ", out.denial_reason))
      },
    },
  }
}

fn blocks_when_evidence_absent() -> [sql, fs_write, time, net] Result[Unit, Str] {
  match trail.open_memory() {
    Err(e) => Err(str.concat("open: ", e)),
    Ok(log) => match gate.spend_gated(a_policy(), log, executor.mock, an_intent(), Some(evidence("no-such-trail"))) {
      Err(e) => Err(str.concat("spend: ", e)),
      Ok(out) => if out.approved {
        Err("spend approved with no fulfilment evidence")
      } else {
        Ok(())
      },
    },
  }
}

fn pays_when_evidence_verifies() -> [sql, fs_write, time, net] Result[Unit, Str] {
  match trail.open_memory() {
    Err(e) => Err(str.concat("open: ", e)),
    Ok(log) => match completed_trail(log, true) {
      Err(e) => Err(e),
      Ok(tid) => match gate.spend_gated(a_policy(), log, executor.mock, an_intent(), Some(evidence(tid))) {
        Err(e) => Err(str.concat("spend: ", e)),
        Ok(out) => if out.approved {
          Ok(())
        } else {
          Err(str.concat("verified fulfilment was blocked: ", out.denial_reason))
        },
      },
    },
  }
}

fn blocks_when_spec_denies() -> [sql, fs_write, time, net] Result[Unit, Str] {
  match trail.open_memory() {
    Err(e) => Err(str.concat("open: ", e)),
    Ok(log) => match completed_trail(log, false) {
      Err(e) => Err(e),
      Ok(tid) => match gate.spend_gated(a_policy(), log, executor.mock, an_intent(), Some(evidence(tid))) {
        Err(e) => Err(str.concat("spend: ", e)),
        Ok(out) => if out.approved {
          Err("spend approved though the fulfilment spec denied the outcome")
        } else {
          Ok(())
        },
      },
    },
  }
}

fn run_all() -> [sql, fs_write, time, net] Unit {
  let results := [ungated_pays(), blocks_when_evidence_absent(), pays_when_evidence_verifies(), blocks_when_spec_denies()]
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

