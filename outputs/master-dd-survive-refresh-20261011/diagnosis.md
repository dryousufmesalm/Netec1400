# DD formulas empty after Refresh All — diagnosis

## Client report
After opening audited Master and Data → Refresh All, Max/2nd/3rd DD and Avg DD Biggest 10 were empty. Client believed PQ overwrite deleted formulas.

## Reproduction
Excel COM on the FullAudit Master:
1. Formulas on Account Analysis **were not deleted** by Refresh All (AGGREGATE helpers remained).
2. After refresh against a different OneDrive root, Basket Data keys changed while Account Analysis still held **static** Account#/RunID values from repair time → COUNTIF/AGGREGATE matched nothing → DD cells blank (AO=0).

So the durable bug is structural: **Account Analysis keys were not refreshed with Basket Data**, while metrics correctly reference live BasketDataTable.

## Fix
1. New PQ query `AmarTrading_AccountRuns` → hidden sheet **Account Runs** / `AccountRunsTable` (AccountNumber, RunID, RunKey only).
2. Account Analysis A:B = INDEX formulas into AccountRunsTable (outside any query table).
3. All DD/metric formulas stay on Account Analysis only (no ListObject / query table on that sheet).
4. Prefill 100 formula rows; empty keys stay blank.
5. Avoid Text (`@`) number format on formula key cells (Excel was storing formulas as literal text).

## Validation
`Verify-DdFormulasSurviveRefresh.ps1`: two Refresh All passes; 18335349 Max/2nd/3rd/Avg = 486.79 / 93.94 / 56.71 / 78.294; helper formulas still present.
