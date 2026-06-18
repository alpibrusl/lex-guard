# lex-guard data model.
#
# Money amounts are integer MINOR units (e.g. cents) in a single currency per
# token — caps and intents share the currency, so policy checks are exact integer
# comparisons. lex-money is used only at the formatting / executor boundary.
# A spending policy. Carried inside a signed budget token (see token.lex).

type Policy = { token_id :: Str, agent_id :: Str, currency :: Str, cap_total :: Int, cap_per_day :: Int, cap_per_transaction :: Int, merchants_allow :: List[Str], categories_allow :: List[Str], max_tx_per_hour :: Int, expires_at :: Int, require_memo :: Bool, policy_version :: Int }

# A requested spend, evaluated against a policy.
type SpendIntent = { merchant :: Str, amount :: Int, currency :: Str, category :: Str, memo :: Str }

# The result of evaluating + (if allowed) executing a spend.
type SpendOutcome = { intent :: SpendIntent, approved :: Bool, executor_ref :: Str, denial_reason :: Str }

