# The spend gate — the hot path.
#
# For each intent:
#   1. attest `spend.intent` BEFORE anything (audit contract: a failed write halts)
#   2. stateless policy check (lex-spec, via policy.check_stateless)
#   3. stateful history caps (total / daily / velocity) from the lex-trail log
#   4. if allowed, run the executor and attest `spend.outcome`
#      otherwise attest `spend.denied`
#
# `Ok(outcome)` with `approved=false` is a policy denial (a normal result).
# `Err(_)` is a system failure (trail write or executor error).

import "std.str" as str

import "std.json" as json

import "std.list" as list

import "std.int" as int

import "std.time" as time

import "lex-trail/log" as trail

import "lex-trail/event" as ev

import "lex-spec/spec" as sp

import "./models" as models

import "./policy" as policy

# Payloads we write to the trail (and parse back, for history caps).
type IntentPayload = { token_id :: Str, merchant :: Str, amount :: Int, currency :: Str, category :: Str, memo :: Str }

type DenialPayload = { merchant :: Str, amount :: Int, reason :: Str }

type OutcomePayload = { amount :: Int, merchant :: Str, approved :: Bool, executor_ref :: Str }

fn k_intent() -> Str {
  "spend.intent"
}

fn k_denied() -> Str {
  "spend.denied"
}

fn k_outcome() -> Str {
  "spend.outcome"
}

# Evaluate + (if allowed) execute a spend, attesting every step to the trail.
fn spend(pol :: models.Policy, log :: trail.Log, exec :: (models.SpendIntent) -> [net] Result[Str, Str], intent :: models.SpendIntent) -> [sql, time, net] Result[models.SpendOutcome, Str] {
  match trail.append(log, k_intent(), None, intent_json(intent, pol.token_id)) {
    Err(e) => Err(str.concat("trail write failed (intent): ", e)),
    Ok(iev) => after_intent(pol, log, exec, intent, iev.id),
  }
}

fn after_intent(pol :: models.Policy, log :: trail.Log, exec :: (models.SpendIntent) -> [net] Result[Str, Str], intent :: models.SpendIntent, parent_id :: Str) -> [sql, time, net] Result[models.SpendOutcome, Str] {
  match policy.check_stateless(pol, intent) {
    Deny(reason) => deny(log, parent_id, intent, reason),
    Inconclusive(why) => deny(log, parent_id, intent, str.concat("inconclusive: ", why)),
    Allow => match history_denial(pol, log, intent) {
      Err(e) => Err(e),
      Ok(maybe_reason) => match maybe_reason {
        Some(reason) => deny(log, parent_id, intent, reason),
        None => execute_and_record(log, exec, intent, parent_id),
      },
    },
  }
}

# ---- denial / execution ------------------------------------------
fn deny(log :: trail.Log, parent_id :: Str, intent :: models.SpendIntent, reason :: Str) -> [sql, time] Result[models.SpendOutcome, Str] {
  match trail.append(log, k_denied(), Some(parent_id), denial_json(intent, reason)) {
    Err(e) => Err(str.concat("trail write failed (denied): ", e)),
    Ok(_) => Ok({ intent: intent, approved: false, executor_ref: "", denial_reason: reason }),
  }
}

fn execute_and_record(log :: trail.Log, exec :: (models.SpendIntent) -> [net] Result[Str, Str], intent :: models.SpendIntent, parent_id :: Str) -> [sql, time, net] Result[models.SpendOutcome, Str] {
  match exec(intent) {
    Err(e) => Err(str.concat("executor failed: ", e)),
    Ok(ref) => match trail.append(log, k_outcome(), Some(parent_id), outcome_json(intent, ref)) {
      Err(e) => Err(str.concat("trail write failed (outcome): ", e)),
      Ok(_) => Ok({ intent: intent, approved: true, executor_ref: ref, denial_reason: "" }),
    },
  }
}

# ---- stateful history caps ---------------------------------------
# Rolling windows: total = all time, daily = last 24h, velocity = last 1h.
fn history_denial(pol :: models.Policy, log :: trail.Log, intent :: models.SpendIntent) -> [sql, time] Result[Option[Str], Str] {
  let now := time.now_ms()
  match sum_outcomes(log, 0, now) {
    Err(e) => Err(e),
    Ok(total) => match sum_outcomes(log, now - 86400000, now) {
      Err(e) => Err(e),
      Ok(day) => match count_outcomes(log, now - 3600000, now) {
        Err(e) => Err(e),
        Ok(hour) => Ok(eval_caps(pol, intent, total, day, hour)),
      },
    },
  }
}

fn eval_caps(pol :: models.Policy, intent :: models.SpendIntent, total :: Int, day :: Int, hour :: Int) -> Option[Str] {
  if pol.cap_total > 0 {
    if total + intent.amount > pol.cap_total {
      Some(str.concat("exceeds total cap: ", int.to_str(pol.cap_total)))
    } else {
      eval_caps_day(pol, intent, day, hour)
    }
  } else {
    eval_caps_day(pol, intent, day, hour)
  }
}

fn eval_caps_day(pol :: models.Policy, intent :: models.SpendIntent, day :: Int, hour :: Int) -> Option[Str] {
  if pol.cap_per_day > 0 {
    if day + intent.amount > pol.cap_per_day {
      Some(str.concat("exceeds daily cap: ", int.to_str(pol.cap_per_day)))
    } else {
      eval_caps_hour(pol, hour)
    }
  } else {
    eval_caps_hour(pol, hour)
  }
}

fn eval_caps_hour(pol :: models.Policy, hour :: Int) -> Option[Str] {
  if pol.max_tx_per_hour > 0 {
    if hour >= pol.max_tx_per_hour {
      Some(str.concat("velocity limit: max tx/hour ", int.to_str(pol.max_tx_per_hour)))
    } else {
      None
    }
  } else {
    None
  }
}

fn sum_outcomes(log :: trail.Log, from_ms :: Int, to_ms :: Int) -> [sql] Result[Int, Str] {
  match trail.range(log, from_ms, to_ms) {
    Err(e) => Err(e),
    Ok(events) => Ok(list.fold(events, 0, fn (acc :: Int, e :: ev.Event) -> Int {
      if e.kind == "spend.outcome" {
        acc + outcome_amount(e.payload_json)
      } else {
        acc
      }
    })),
  }
}

fn count_outcomes(log :: trail.Log, from_ms :: Int, to_ms :: Int) -> [sql] Result[Int, Str] {
  match trail.range(log, from_ms, to_ms) {
    Err(e) => Err(e),
    Ok(events) => Ok(list.fold(events, 0, fn (acc :: Int, e :: ev.Event) -> Int {
      if e.kind == "spend.outcome" {
        acc + 1
      } else {
        acc
      }
    })),
  }
}

fn outcome_amount(payload_json :: Str) -> Int {
  match (json.parse(payload_json) :: Result[OutcomePayload, Str]) {
    Err(_) => 0,
    Ok(p) => p.amount,
  }
}

# ---- payload builders --------------------------------------------
fn intent_json(intent :: models.SpendIntent, token_id :: Str) -> Str {
  json.stringify(({ token_id: token_id, merchant: intent.merchant, amount: intent.amount, currency: intent.currency, category: intent.category, memo: intent.memo } :: IntentPayload))
}

fn denial_json(intent :: models.SpendIntent, reason :: Str) -> Str {
  json.stringify(({ merchant: intent.merchant, amount: intent.amount, reason: reason } :: DenialPayload))
}

fn outcome_json(intent :: models.SpendIntent, ref :: Str) -> Str {
  json.stringify(({ amount: intent.amount, merchant: intent.merchant, approved: true, executor_ref: ref } :: OutcomePayload))
}

