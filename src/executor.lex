# Executor: performs the actual charge once the gate approves a spend, and
# returns a reference id. An executor is a function value, so the gate stays
# decoupled from any payment backend.
#
# `mock` is for tests/dev. The Stripe executor (std.http POST to the Stripe
# Issuing API) is a later module — it has the same shape: SpendIntent -> ref.

import "std.str" as str

import "./models" as models

# A deterministic no-op executor that never touches a payment network.
fn mock(intent :: models.SpendIntent) -> [net] Result[Str, Str] {
  Ok(str.concat("mock_ref:", intent.merchant))
}

