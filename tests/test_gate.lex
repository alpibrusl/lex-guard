# Gate tests: approval, policy denial, stateful caps accumulated across spends
# from the trail (total + velocity), and that every spend is attested.

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "lex-trail/log" as trail

import "../src/models" as models

import "../src/gate" as gate

import "../src/executor" as executor

fn policy_caps(cap_total :: Int, cap_tx :: Int, max_hour :: Int) -> models.Policy {
  { token_id: "tok_gate", agent_id: "agent", currency: "EUR", cap_total: cap_total, cap_per_day: 0, cap_per_transaction: cap_tx, merchants_allow: [], categories_allow: [], max_tx_per_hour: max_hour, expires_at: 0, require_memo: false, policy_version: 1 }
}

fn intent(amount :: Int) -> models.SpendIntent {
  { merchant: "api.openai.com", amount: amount, currency: "EUR", category: "saas", memo: "call" }
}

fn approves_compliant() -> [sql, fs_write, time, net] Result[Unit, Str] {
  match trail.open_memory() {
    Err(e) => Err(str.concat("open: ", e)),
    Ok(log) => match gate.spend(policy_caps(0, 5000, 0), log, executor.mock, intent(2000)) {
      Err(e) => Err(str.concat("spend: ", e)),
      Ok(out) => if out.approved {
        Ok(())
      } else {
        Err(str.concat("expected approved, got denial: ", out.denial_reason))
      },
    },
  }
}

fn denies_over_tx_cap() -> [sql, fs_write, time, net] Result[Unit, Str] {
  match trail.open_memory() {
    Err(e) => Err(str.concat("open: ", e)),
    Ok(log) => match gate.spend(policy_caps(0, 2500, 0), log, executor.mock, intent(9999)) {
      Err(e) => Err(str.concat("spend: ", e)),
      Ok(out) => if out.approved {
        Err("over-tx-cap spend was approved")
      } else {
        Ok(())
      },
    },
  }
}

# Two 2000 spends under a 3000 total cap: first approved, second must be denied
# because the gate sums prior outcomes from the trail.
fn enforces_total_cap_across_spends() -> [sql, fs_write, time, net] Result[Unit, Str] {
  match trail.open_memory() {
    Err(e) => Err(str.concat("open: ", e)),
    Ok(log) => match gate.spend(policy_caps(3000, 0, 0), log, executor.mock, intent(2000)) {
      Err(e) => Err(str.concat("first spend: ", e)),
      Ok(first) => if first.approved {
        match gate.spend(policy_caps(3000, 0, 0), log, executor.mock, intent(2000)) {
          Err(e) => Err(str.concat("second spend: ", e)),
          Ok(second) => if second.approved {
            Err("total cap not enforced: second spend approved")
          } else {
            Ok(())
          },
        }
      } else {
        Err("first spend unexpectedly denied")
      },
    },
  }
}

# max 1 tx/hour: first approved, second denied on velocity.
fn enforces_velocity() -> [sql, fs_write, time, net] Result[Unit, Str] {
  match trail.open_memory() {
    Err(e) => Err(str.concat("open: ", e)),
    Ok(log) => match gate.spend(policy_caps(0, 0, 1), log, executor.mock, intent(100)) {
      Err(e) => Err(str.concat("first spend: ", e)),
      Ok(_) => match gate.spend(policy_caps(0, 0, 1), log, executor.mock, intent(100)) {
        Err(e) => Err(str.concat("second spend: ", e)),
        Ok(second) => if second.approved {
          Err("velocity limit not enforced")
        } else {
          Ok(())
        },
      },
    },
  }
}

# An approved spend attests both spend.intent and spend.outcome.
fn attests_intent_and_outcome() -> [sql, fs_write, time, net] Result[Unit, Str] {
  match trail.open_memory() {
    Err(e) => Err(str.concat("open: ", e)),
    Ok(log) => match gate.spend(policy_caps(0, 5000, 0), log, executor.mock, intent(2000)) {
      Err(e) => Err(str.concat("spend: ", e)),
      Ok(_) => match trail.range(log, 0, 9999999999999) {
        Err(e) => Err(str.concat("range: ", e)),
        Ok(events) => if list.len(events) == 2 {
          Ok(())
        } else {
          Err(str.concat("expected 2 trail events, got ", int.to_str(list.len(events))))
        },
      },
    },
  }
}

# Human oversight (Art. 14): a spend below the review threshold still executes.
fn reviewed_below_threshold_executes() -> [sql, fs_write, time, net] Result[Unit, Str] {
  match trail.open_memory() {
    Err(e) => Err(str.concat("open: ", e)),
    Ok(log) => match gate.spend_reviewed(policy_caps(0, 10000, 0), log, executor.mock, intent(2000), 5000, None) {
      Err(e) => Err(str.concat("spend: ", e)),
      Ok(out) => if out.approved {
        Ok(())
      } else {
        Err(str.concat("below-threshold should execute, got: ", out.denial_reason))
      },
    },
  }
}

# At/above the threshold with NO approval: escalated, executor NOT run.
fn reviewed_above_threshold_no_approval_escalates() -> [sql, fs_write, time, net] Result[Unit, Str] {
  match trail.open_memory() {
    Err(e) => Err(str.concat("open: ", e)),
    Ok(log) => match gate.spend_reviewed(policy_caps(0, 10000, 0), log, executor.mock, intent(2000), 1000, None) {
      Err(e) => Err(str.concat("spend: ", e)),
      Ok(out) => if out.approved {
        Err("above-threshold spend executed without human approval")
      } else {
        if str.is_empty(out.executor_ref) {
          Ok(())
        } else {
          Err("executor ran despite escalation")
        }
      },
    },
  }
}

# A valid approval bound to this intent unlocks execution.
fn reviewed_valid_approval_executes() -> [sql, fs_write, time, net] Result[Unit, Str] {
  match trail.open_memory() {
    Err(e) => Err(str.concat("open: ", e)),
    Ok(log) => match gate.spend_reviewed(policy_caps(0, 10000, 0), log, executor.mock, intent(2000), 1000, Some(({ approver: "ops-lead", decision: "approve", amount: 2000, merchant: "api.openai.com", ref: "sig-1" } :: models.HumanApproval))) {
      Err(e) => Err(str.concat("spend: ", e)),
      Ok(out) => if out.approved {
        Ok(())
      } else {
        Err(str.concat("valid approval should execute, got: ", out.denial_reason))
      },
    },
  }
}

# An approval for a different amount must NOT unlock the spend (anti-replay).
fn reviewed_wrong_amount_approval_escalates() -> [sql, fs_write, time, net] Result[Unit, Str] {
  match trail.open_memory() {
    Err(e) => Err(str.concat("open: ", e)),
    Ok(log) => match gate.spend_reviewed(policy_caps(0, 10000, 0), log, executor.mock, intent(2000), 1000, Some(({ approver: "ops-lead", decision: "approve", amount: 100, merchant: "api.openai.com", ref: "sig-2" } :: models.HumanApproval))) {
      Err(e) => Err(str.concat("spend: ", e)),
      Ok(out) => if out.approved {
        Err("approval for a different amount unlocked the spend")
      } else {
        Ok(())
      },
    },
  }
}

fn run_all() -> [sql, fs_write, time, net] Unit {
  let results := [approves_compliant(), denies_over_tx_cap(), enforces_total_cap_across_spends(), enforces_velocity(), attests_intent_and_outcome(), reviewed_below_threshold_executes(), reviewed_above_threshold_no_approval_escalates(), reviewed_valid_approval_executes(), reviewed_wrong_amount_approval_escalates()]
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

