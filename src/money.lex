# Money boundary.
#
# The gate works in integer MINOR units for exact, currency-matched comparisons
# (see models.lex). lex-money is used at the human / executor edge — receipts,
# display, and anywhere a typed Money value is wanted. These helpers convert a
# policy/intent amount + ISO code into a lex-money Money and format it.

import "std.str" as str

import "std.int" as int

import "lex-money/money" as money

import "lex-money/currency" as currency

import "lex-money/decimal" as decimal

import "./models" as models

# Minor units + ISO code → typed Money (unknown codes become Unknown(code)).
fn to_money(minor :: Int, code :: Str) -> money.Money {
  let cur := match currency.from_code(code) {
    Some(c) => c,
    None => Unknown(code),
  }
  money.money(minor, cur, money.canonical_exponent(cur))
}

fn intent_money(i :: models.SpendIntent) -> money.Money {
  to_money(i.amount, i.currency)
}

# Human display, e.g. "EUR 42.00" (formatted from the Money's minor units +
# exponent — lex-money is arithmetic-only, so we render here).
fn format(m :: money.Money) -> Str {
  let decimals := 0 - m.exponent
  if decimals <= 0 {
    str.concat(currency.code(m.currency), str.concat(" ", int.to_str(m.amount)))
  } else {
    let div := decimal.pow10(decimals)
    let whole := m.amount / div
    let frac := m.amount - whole * div
    str.concat(currency.code(m.currency), str.concat(" ", str.concat(int.to_str(whole), str.concat(".", pad_left(int.to_str(frac), decimals)))))
  }
}

fn pad_left(s :: Str, width :: Int) -> Str {
  if str.len(s) >= width {
    s
  } else {
    pad_left(str.concat("0", s), width)
  }
}

