from dataclasses import dataclass
from decimal import Decimal


@dataclass
class SpendIntent:
    merchant: str
    amount: Decimal
    currency: str
    category: str
    memo: str = ""


@dataclass
class SpendOutcome:
    intent: SpendIntent
    approved: bool
    executor_ref: str = ""
    denial_reason: str = ""
