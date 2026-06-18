# HTTP executor — POST a spend to a payment endpoint over std.http and read back
# the charge / authorization id. This is the generic executor; a Stripe Issuing
# executor is just `make(stripe_url, api_key, "id")` — the Stripe REST API is an
# authenticated JSON POST, so no SDK is needed.
#
# Returns a function value with the same shape as executor.mock, so the gate is
# unchanged: swap mock for this in main.lex for real charges.

import "std.http" as http

import "std.str" as str

import "std.int" as int

import "std.json" as json

import "std.bytes" as bytes

import "std.map" as map

import "lex-schema/json_value" as jv

import "./models" as models

type ChargeBody = { merchant :: Str, amount :: Int, currency :: Str, category :: Str, memo :: Str }

fn charge_body(intent :: models.SpendIntent) -> Str {
  json.stringify(({ merchant: intent.merchant, amount: intent.amount, currency: intent.currency, category: intent.category, memo: intent.memo } :: ChargeBody))
}

# Build an executor bound to a URL, optional Bearer token (pass "" for none),
# and the JSON field that carries the id in the response.
fn make(url :: Str, token :: Str, id_field :: Str) -> (models.SpendIntent) -> [net] Result[Str, Str] {
  fn (intent :: models.SpendIntent) -> [net] Result[Str, Str] {
    let req0 := { method: "POST", url: url, headers: map.new(), body: Some(bytes.from_str(charge_body(intent))), timeout_ms: Some(30000) }
    let req1 := http.with_header(req0, "Content-Type", "application/json")
    let req2 := if token == "" {
      req1
    } else {
      http.with_auth(req1, "Bearer", token)
    }
    match http.send(req2) {
      Err(_) => Err("payment request failed"),
      Ok(resp) => if resp.status >= 200 and resp.status < 300 {
        match http.text_body(resp) {
          Err(_) => Err("could not read response body"),
          Ok(text) => extract_id(text, id_field),
        }
      } else {
        Err(str.concat("payment endpoint returned status ", int.to_str(resp.status)))
      },
    }
  }
}

fn extract_id(text :: Str, id_field :: Str) -> Result[Str, Str] {
  match jv.parse(text) {
    Err(_) => Err("response is not JSON"),
    Ok(j) => match jv.get_field(j, id_field) {
      None => Err(str.concat("response missing id field: ", id_field)),
      Some(v) => match jv.as_str(v) {
        None => Err("id field is not a string"),
        Some(s) => Ok(s),
      },
    },
  }
}

