# Policy → lex-spec Spec.
#
# The STATELESS half of a budget policy (currency, per-transaction cap, memo
# requirement, merchant/category allowlists) compiles to a `lex-spec` Spec.
# That makes it a typed, verifiable artifact: the same value the agent evaluates
# at spend time can be property-checked (lex-spec/check) and exported to SMT-LIB
# (lex-spec/smt). History caps (total/day/velocity) are stateful and live in the
# gate, not here.
#
# The intent is quantified as a single record binding "intent".

import "std.list" as list

import "std.str" as str

import "lex-spec/spec" as sp

import "lex-spec/eval" as speval

import "./models" as models

# ---- SpecExpr builders --------------------------------------------
fn field(binding :: Str, name :: Str) -> sp.SpecExpr {
  EField({ binding: binding, field: name })
}

fn binop(op :: Str, lhs :: sp.SpecExpr, rhs :: sp.SpecExpr) -> sp.SpecExpr {
  EBinop({ op: op, lhs: lhs, rhs: rhs })
}

fn eq_const(binding :: Str, name :: Str, v :: sp.SpecValue) -> sp.SpecExpr {
  binop("==", field(binding, name), EConst(v))
}

# Conjoin a list of predicates (empty ⇒ trivially true).
fn and_all(es :: List[sp.SpecExpr]) -> sp.SpecExpr {
  list.fold(es, EConst(VBool(true)), fn (acc :: sp.SpecExpr, e :: sp.SpecExpr) -> sp.SpecExpr {
    EAnd(acc, e)
  })
}

# Disjoin a list of predicates (empty ⇒ trivially false). Allowlists become
# an OR-chain of equalities — lex-spec has no membership operator.
fn or_all(es :: List[sp.SpecExpr]) -> sp.SpecExpr {
  list.fold(es, EConst(VBool(false)), fn (acc :: sp.SpecExpr, e :: sp.SpecExpr) -> sp.SpecExpr {
    EOr(acc, e)
  })
}

# ---- Policy → Spec ------------------------------------------------
fn policy_clauses(p :: models.Policy) -> List[sp.SpecExpr] {
  let base := [eq_const("intent", "currency", VStr(p.currency))]
  let c1 := if p.cap_per_transaction > 0 {
    list.concat(base, [binop("<=", field("intent", "amount"), EConst(VInt(p.cap_per_transaction)))])
  } else {
    base
  }
  let c2 := if p.require_memo {
    list.concat(c1, [binop("!=", field("intent", "memo"), EConst(VStr("")))])
  } else {
    c1
  }
  let c3 := if list.len(p.merchants_allow) > 0 {
    list.concat(c2, [or_all(list.map(p.merchants_allow, fn (m :: Str) -> sp.SpecExpr {
      eq_const("intent", "merchant", VStr(m))
    }))])
  } else {
    c2
  }
  if list.len(p.categories_allow) > 0 {
    list.concat(c3, [or_all(list.map(p.categories_allow, fn (c :: Str) -> sp.SpecExpr {
      eq_const("intent", "category", VStr(c))
    }))])
  } else {
    c3
  }
}

# The stateless policy as a named Spec.
fn policy_to_spec(p :: models.Policy) -> sp.Spec {
  { name: str.concat("budget:", p.token_id), quantifiers: [QRecord({ name: "intent", fields: [{ name: "amount", ty: TInt }, { name: "currency", ty: TStr }, { name: "merchant", ty: TStr }, { name: "category", ty: TStr }, { name: "memo", ty: TStr }] })], predicate: and_all(policy_clauses(p)) }
}

# Bind a SpendIntent for spec evaluation.
fn intent_bindings(i :: models.SpendIntent) -> List[(Str, sp.SpecValue)] {
  [("intent", VRecord({ name: "SpendIntent", fields: [("amount", VInt(i.amount)), ("currency", VStr(i.currency)), ("merchant", VStr(i.merchant)), ("category", VStr(i.category)), ("memo", VStr(i.memo))] }))]
}

# Evaluate the stateless policy against an intent.
fn check_stateless(p :: models.Policy, i :: models.SpendIntent) -> sp.Verdict {
  speval.eval(policy_to_spec(p), intent_bindings(i))
}

