# release.lex — evidence-of-fulfilment check for the spend gate.
#
# The spend gate answers "is this purchase within budget?". This answers the
# other half a settlement needs: "did the thing being paid for actually happen?".
# It re-derives a verdict OVER A TRAIL, trusting nothing the payer reported:
#   intact — every event's content hash recomputes (nothing tampered)
#   linked — the tip→root chain is unbroken (each event's parent is the next id)
#   legal  — a host-supplied lex-spec predicate holds over the recorded outcome
# When `verified`, the gate may release funds; otherwise the spend is blocked.
#
# This is the reusable core of lex-soft's verdict.verify, lifted into lex-guard so
# both the settlement packs and the Magentic Bazaar gate on proof from one place.

import "std.list" as list

import "lex-schema/json_value" as jv

import "lex-trail/event" as ev

import "lex-trail/log" as tlog

import "lex-trail/replay" as replay

import "lex-trail/export" as txport

import "lex-trail/kinds" as kinds

import "lex-spec/spec" as sp

import "lex-spec/eval" as speval

type Verdict = { intact :: Bool, linked :: Bool, legal :: Bool, verified :: Bool, score :: Int, reason :: Str }

# A release condition supplied to the gate: the fulfilment trail to re-derive, the
# host's domain predicate (None = integrity only), and the record the predicate
# quantifies over (e.g. "outcome").
type Evidence = { trail_id :: Str, spec :: Option[sp.Spec], binding :: Str }

# ---- JSON → SpecValue (a recorded outcome becomes spec bindings) ----
fn to_specvalue(j :: jv.Json) -> sp.SpecValue {
  match j {
    JNull => VNull,
    JBool(b) => VBool(b),
    JInt(n) => VInt(n),
    JFloat(f) => VFloat(f),
    JStr(s) => VStr(s),
    JList(xs) => VList(list.map(xs, fn (x :: jv.Json) -> sp.SpecValue {
      to_specvalue(x)
    })),
    JObj(fields) => VRecord({ name: "outcome", fields: list.map(fields, fn (kv :: (Str, jv.Json)) -> (Str, sp.SpecValue) {
      match kv {
        (k, v) => (k, to_specvalue(v)),
      }
    }) }),
  }
}

# ---- chain integrity: parent of each event equals the next event's id ----
fn linked_go(events :: List[ev.Event]) -> Bool {
  match list.head(events) {
    None => true,
    Some(h) => match list.head(list.tail(events)) {
      None => true,
      Some(next) => match h.parent {
        Some(pid) => if pid == next.id {
          linked_go(list.tail(events))
        } else {
          false
        },
        None => false,
      },
    },
  }
}

fn linked(events :: List[ev.Event]) -> Bool {
  if list.is_empty(events) {
    false
  } else {
    linked_go(events)
  }
}

# ---- recorded outcome: the payload of the completed event ----
fn find_kind(events :: List[ev.Event], k :: Str) -> Option[ev.Event] {
  list.fold(events, None, fn (acc :: Option[ev.Event], e :: ev.Event) -> Option[ev.Event] {
    match acc {
      Some(_) => acc,
      None => if e.kind == k {
        Some(e)
      } else {
        None
      },
    }
  })
}

fn outcome_of(events :: List[ev.Event]) -> sp.SpecValue {
  match find_kind(events, kinds.cap_completed()) {
    None => VNull,
    Some(e) => match jv.parse(e.payload_json) {
      Ok(j) => to_specvalue(j),
      Err(_) => VNull,
    },
  }
}

# ---- legality: a host domain spec over the recorded outcome ----
fn legal(spec :: Option[sp.Spec], binding :: Str, outcome :: sp.SpecValue) -> Bool {
  match spec {
    None => true,
    Some(s) => match speval.eval(s, [(binding, outcome)]) {
      Allow => true,
      _ => false,
    },
  }
}

fn reason_of(i :: Bool, l :: Bool, lg :: Bool) -> Str {
  if not i {
    "tampered: an event's content hash does not recompute"
  } else {
    if not l {
      "broken chain: a parent link is missing or wrong"
    } else {
      if not lg {
        "illegal: the fulfilment spec denied the recorded outcome"
      } else {
        "verified"
      }
    }
  }
}

# Re-derive a verdict over a fulfilment trail. `spec` is the host's domain
# precondition (domain data); `binding` names the record it quantifies over.
fn check(log :: tlog.Log, trail_id :: Str, spec :: Option[sp.Spec], binding :: Str) -> [sql] Verdict {
  let events := replay.walk_chain(log, trail_id)
  let i := if list.is_empty(events) {
    false
  } else {
    txport.all_valid(events)
  }
  let l := linked(events)
  let lg := legal(spec, binding, outcome_of(events))
  let v := i and l and lg
  let sc := if v {
    1
  } else {
    0
  }
  { intact: i, linked: l, legal: lg, verified: v, score: sc, reason: reason_of(i, l, lg) }
}

fn verdict_json(v :: Verdict) -> Str {
  jv.stringify(JObj([("intact", JBool(v.intact)), ("linked", JBool(v.linked)), ("legal", JBool(v.legal)), ("verified", JBool(v.verified)), ("score", JInt(v.score)), ("reason", JStr(v.reason))]))
}

