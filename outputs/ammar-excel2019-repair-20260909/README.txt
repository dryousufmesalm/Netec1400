AmarTrading Excel 2019 compatibility repair

Workbook: AmarTrading_Excel2019_Compatible.xlsx

Account Analysis was rewritten with Excel 2019-compatible formulas. The
Power Query import layer was preserved: AmarTrading_Baskets and
AmarTrading_SyncStatus remain embedded, with two workbook connections.

The workbook was refreshed, recalculated, saved, and reopened in Excel 16.0
build 20326 with 1,062 Basket Data rows and four account/run groups. The
available Windows installation identifies as O365ProPlusRetail, not Office
Professional Plus 2019. Formula compatibility was checked against the Excel
2019 function set; the exact client installation should still be opened once
for final user acceptance. Account totals matched the existing source
verification: 323 / -2127.49, 327 / 794.31, 261 / -3328.87, and 151 / 223.81.

The analysis area is prefilled for the current four account/run groups. If a
future refresh introduces a new account/run pair, add a new analysis row by
copying an existing formula row before reviewing it.
