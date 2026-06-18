# HTTP executor tests (pure — no network): response id extraction and that the
# request body round-trips back to the intent fields.

import "std.str" as str

import "std.list" as list

import "lex-schema/json_value" as jv

import "../src/models" as models

import "../src/http_exec" as http_exec

fn intent() -> models.SpendIntent {
  { merchant: "api.openai.com", amount: 4200, currency: "EUR", category: "saas", memo: "embeddings", idempotency_key: "idem-abc123" }
}

fn extract_id_ok() -> Result[Unit, Str] {
  match http_exec.extract_id("{\"id\":\"ch_123\",\"status\":\"ok\"}", "id") {
    Err(e) => Err(str.concat("expected id, got err: ", e)),
    Ok(id) => if id == "ch_123" {
      Ok(())
    } else {
      Err(str.concat("wrong id: ", id))
    },
  }
}

fn extract_id_missing_field() -> Result[Unit, Str] {
  match http_exec.extract_id("{\"status\":\"ok\"}", "id") {
    Ok(_) => Err("expected error for missing id field"),
    Err(_) => Ok(()),
  }
}

fn extract_id_not_json() -> Result[Unit, Str] {
  match http_exec.extract_id("not json at all", "id") {
    Ok(_) => Err("expected error for non-JSON response"),
    Err(_) => Ok(()),
  }
}

fn charge_body_roundtrips() -> Result[Unit, Str] {
  match jv.parse(http_exec.charge_body(intent())) {
    Err(_) => Err("charge body is not valid JSON"),
    Ok(j) => match jv.get_field(j, "amount") {
      None => Err("charge body missing amount"),
      Some(v) => match jv.as_int(v) {
        None => Err("amount not an int"),
        Some(n) => if n == 4200 {
          Ok(())
        } else {
          Err("amount mismatch")
        },
      },
    },
  }
}

fn run_all() -> Unit {
  let results := [extract_id_ok(), extract_id_missing_field(), extract_id_not_json(), charge_body_roundtrips()]
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

