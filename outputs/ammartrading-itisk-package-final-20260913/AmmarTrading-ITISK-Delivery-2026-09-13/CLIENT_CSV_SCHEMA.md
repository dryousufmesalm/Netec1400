# AGOLD basket CSV — schema v3 (Itsik / Netec1400)

**CsvSchemaVersion** is `3` for rows written by the latest **AmmarTradingGoldEA V3 MQ4** reporting build. V2 and MQ5 are not changed by this delivery. Existing schema-v2 CSVs stay readable by the workbook, but should be backed up and reset while flat before deploying schema v3.

## Migration from v1

- **Removed:** `MaxExposure` (was a duplicate of peak lots in some builds).
- **Renamed:** `MaxFloatingLoss` → **`MaxFloatingDrawdownAbs`** (still **positive** magnitude of worst in-basket floating loss).
- **Added (trailing columns):** `TradeDate` (`YYYY-MM-DD` server date from `StartTime`), `CsvSchemaVersion`.

## Field definitions (one line each)

| Column | Meaning |
|--------|---------|
| **OrdersCount** | Number of basket positions **at close** (symbol + magic, basket direction). |
| **TotalLots** | Sum of lot sizes **at close**. |
| **FixedLots** | `FixedLots` input snapshot **at basket start**. |
| **MaxOrdersConcurrent** | Peak concurrent managed order count **during** the basket (not the same as `OrdersCount` if counts changed before exit). |
| **MaxTotalLots** | Peak sum of basket lots **during** the basket. |
| **MaxFloatingDrawdownAbs** | Largest in-basket floating **loss magnitude** (account currency), **positive** number. |
| **MaxFloatingProfit** | Largest floating profit observed during the basket. |
| **HeadroomAtEntry** | `equity - (balance - KillEquityLevel)` at basket start — **not** raw equity (see below). |
| **MinHeadroom** | Minimum of that headroom formula **during** the basket. |
| **ExposureBlocks** | Count of grid **add** attempts blocked by the **exposure cap** while the basket was active. |
| **MaxOrdersInBasket** / **MaxTotalLotsInBasket** | Snapshots of the **input limits** at basket start (`0` = disabled). |

**Equity** is reported separately in **EquityAtEntry** and **EquityAtExit**.

## CloseReason (exported)

Normalized to: **`TP`**, **`KILL`**, **`OTHER`**.

## OutcomeClass (computed when empty)

**`KILL`** | **`NORMAL_PROFIT`** | **`RECOVERY_PROFIT`** (profitable close after drawdown) | **`OTHER`**

## Headroom formula

`Headroom = Equity - (Balance - KillEquityLevel)` (account currency).

## Schema v3 additions

Each closed basket now carries a reporting-only snapshot of the run and active EA configuration:

| Group | Added columns |
|---|---|
| Run metadata | `RunID`, `RunStartTime`, `RunStartBalance`, `EAName`, `EAVersion` |
| Core inputs | `Magic`, `PointsPerPip`, `Tral`, `TralStart`, `MaxSpread`, `TimeStart`, `TimeEnd`, `OpenTime`, `NewBasketDelaySeconds`, `SpeedEA` |
| Basket exit | `UseBasketTrailingTP`, `TrailingStart`, `TrailingStep` |
| Protection | `KillSwitchEnable`, `KillCooldownMinutes` |
| Regime | `RegimeEnable`, `RegimeAction`, `RegimeADXPeriod`, `RegimeADXLevel`, `RegimeADXBars`, `RegimeRangeBars`, `RegimeRecoveryBars` |
| Trading days | `EnableTradingDaysFilter`, `TradeMonday`, `TradeTuesday`, `TradeWednesday`, `TradeThursday`, `TradeFriday` |
| Recovery | `EnableRecoveryStepUp`, `RecoveryWaitMinutes`, `RecoveryMaxTotalLotsInBasket` |

The existing snapshots of `FixedLots`, `PipsStep`, `TakeProfit`, `KillEquityLevel`, `MaxOrdersInBasket`, and `MaxTotalLotsInBasket` remain unchanged.

## Run lifecycle and reset safety

- A new reporting run starts only when `AGOLD___Baskets.csv` is missing while the account is flat.
- At that point the EA records `AccountBalance()` and server time as `RunStartBalance` and `RunStartTime`, creates the v3 header immediately, and persists the run context in terminal globals.
- The same context is recovered after restart from terminal globals, or from the existing v3 CSV if required.
- A throttled reporting check detects a deleted CSV. If a basket is active, the EA logs a warning and defers the new run until flat. The old basket is never written into the new CSV.
- A schema-v2 CSV is never mixed with v3 rows. Back up the old file and reset it while flat before upgrading.

## TimesNearKill and Kill Count

`TimesNearKill` counts separate entries into the near-kill zone, not ticks. The zone starts when headroom is at or below 12% of `KillEquityLevel`; the counter re-arms only after headroom recovers by a further 2% hysteresis. `Kill Count` is separate and is calculated in Excel as the number of rows with `CloseReason=KILL`.
