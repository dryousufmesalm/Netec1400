# Full Master audit — 2026-10-10

## Scope
Multi-account Excel COM audit of Account Analysis vs latest Baskets.csv ground truth (6 accounts / 1251 baskets), plus formula-pattern scan and PQ latest-file-per-account check.

## Defects fixed in this pass
1. **LOOKUP / AGGREGATE "latest field" and first-row helpers** still used bare `AccountNumber=$A` / `RunID=$B` array equals (same class as DD bug). Switched to RunKey + `&""` text coercion.
2. **Win/loss/kill/depth COUNTIFS+SUMIFS** switched to RunKey criteria for consistency.
3. **Trading Days** SUMPRODUCT unique-count could display as 5.999999; wrapped with `ROUND(...,0)`.

## Checked OK
- Net Profit, Total Baskets, Max/2nd/3rd DD, Avg DD top-10, win/loss counts, win rate, avg basket, kill/near-kill for all 6 groups
- Latest-file-per-account (VPS preferred over stale flat); Basket rows == CSV sum (1251)
- Data Quality coverage/duplicates OK
- SyncStatus already had latest-per-account Group/FirstN
- No residual bare AccountNumber=$A5 / RunID=$B5 array equals in Account Analysis formulas

## Accounts validated
18335349, 36097370, 892525830, 892525831, 892525833, 892525834
