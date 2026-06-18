# Money boundary tests: minor-unit → typed Money → human format, including
# fractional padding and a zero-exponent currency (JPY).

import "std.str" as str

import "std.list" as list

import "../src/money" as money_b

fn check(label :: Str, got :: Str, want :: Str) -> Result[Unit, Str] {
  if got == want {
    Ok(())
  } else {
    Err(str.concat(label, str.concat(": got ", str.concat(got, str.concat(", want ", want)))))
  }
}

fn eur_whole() -> Result[Unit, Str] {
  check("eur_whole", money_b.format(money_b.to_money(4200, "EUR")), "EUR 42.00")
}

fn eur_padded_frac() -> Result[Unit, Str] {
  check("eur_padded", money_b.format(money_b.to_money(4205, "EUR")), "EUR 42.05")
}

fn eur_small() -> Result[Unit, Str] {
  check("eur_small", money_b.format(money_b.to_money(500, "EUR")), "EUR 5.00")
}

fn jpy_zero_exponent() -> Result[Unit, Str] {
  check("jpy", money_b.format(money_b.to_money(4200, "JPY")), "JPY 4200")
}

fn run_all() -> Unit {
  let results := [eur_whole(), eur_padded_frac(), eur_small(), jpy_zero_exponent()]
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

