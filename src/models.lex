# lex-guard data model.
#
# Money amounts are integer MINOR units (e.g. cents) in a single currency per
# token — caps and intents share the currency, so policy checks are exact integer
# comparisons. lex-money is used only at the formatting / executor boundary.
# A spending policy. Carried inside a signed budget token (see token.lex).

# expires_at / not_before are epoch-ms validity bounds on the token (0 = unset,
# i.e. no bound). The gate enforces both before any charge.
type Policy = { token_id :: Str, agent_id :: Str, currency :: Str, cap_total :: Int, cap_per_day :: Int, cap_per_transaction :: Int, merchants_allow :: List[Str], categories_allow :: List[Str], max_tx_per_hour :: Int, expires_at :: Int, not_before :: Int, require_memo :: Bool, policy_version :: Int }

# A requested spend, evaluated against a policy.
# idempotency_key (optional, "" = unset) is a client-supplied key that the
# executor forwards to the payment backend so retries of the same logical charge
# do not double-spend.
type SpendIntent = { merchant :: Str, amount :: Int, currency :: Str, category :: Str, memo :: Str, idempotency_key :: Str }

# The result of evaluating + (if allowed) executing a spend.
type SpendOutcome = { intent :: SpendIntent, approved :: Bool, executor_ref :: Str, denial_reason :: Str }

