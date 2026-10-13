# Account Analysis drawdown metrics — diagnosis

## Symptom
- Basket Data `MaxFloatingDrawdownAbs` populated for 18335349
- Account Analysis Max DD / 2nd DD / 3rd DD blank
- Avg DD Biggest 10 ~$2.24 (inconsistent with top basket DDs)
- Net Profit correct ($210.14)

## Root cause
Ranked DD helpers (BP:BY) used:
`AGGREGATE(14,6, MaxFloatingDrawdownAbs / ((AccountNumber=$A)*(RunID=$B)), k)`

Array equality inside AGGREGATE does **not** coerce text↔number the way SUMIFS/COUNTIFS do. After PQ refresh, AccountNumber/RunID typing or manual Account Analysis entry can diverge → criteria never match → helpers blank → Max/2nd/3rd blank. AVERAGE of blank/text helpers (or leftover tiny ranks / stale run contamination) produced a misleading Avg DD (~2.24 matches typical stale-flat DD magnitudes).

Definition (unchanged intent, now enforced): Max / 2nd / 3rd / Avg Biggest 10 are **largest individual basket** `MaxFloatingDrawdownAbs` values for the Account Analysis **Account# + Run ID** only — not account-level equity drawdown.

## Fix
- Match via `RunKey` (`AccountNumber|RunID`) with `&""` text coercion; fallback to coerced AccountNumber×RunID
- Net Profit / Total Baskets via `SUMIF`/`COUNTIF` on RunKey
- Avg DD = `SUM(BP:BY)/COUNT(BP:BY)` (only retrieved ranks)
- PQ types `RunID` as text for stable RunKey
- Repair rebuilds Account Analysis groups from current Basket Data

## Validation (Windows Excel COM)
Fixture top-3 486.79 / 93.94 / 56.71, net 210.14 → Actual match (see verification.json).
