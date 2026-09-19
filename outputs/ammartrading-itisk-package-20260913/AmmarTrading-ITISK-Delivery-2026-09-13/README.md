# Netec1400 XAUUSD Grid / Recovery EA

## Overview

This Expert Advisor (EA) implements a grid/recovery trading system specifically designed for XAUUSD (Gold) on MetaTrader 4. The EA prioritizes **survivability over profit**, with comprehensive risk controls and drawdown management.

**Priority Order:** Survivability > Control > Stability > Profit

## Files Delivered

- **Netec1400_XAUUSD_Grid.mq4** - Full MQ4 source code
- **Netec1400_XAUUSD_Grid.ex4** - Compiled executable (compile via MetaEditor)
- **README.md** - This documentation

## Core Features

### 1. Entry Logic (Phase-1: Manual and Semi-Auto Only)

Phase-1 entry is **controllable only**; no autonomous indicator-based entry. The EA supports:

- **Mode 0 (Manual – Adopt)**: The EA does **not** open the first trade. You place the first order(s) in MT4 (same symbol, EA MagicNumber). The EA detects them and **adopts** them as the basket start, then manages grid/recovery. Single direction only; mixed BUY/SELL orders are rejected.
- **Mode 1 (Semi-Auto)**: The EA can show a **suggested** direction (e.g. from MA, display only). You set `OpenBasketDirection` to BUY or SELL to confirm. When filters pass, the EA opens the first trade in that direction. No automatic opening from indicators.

Indicator-based entry (MA/RSI/Time) is **out of scope for Phase-1** and deferred to a later phase; that code remains in source but is not used for opening trades in Phase-1.

### 2. Grid Logic

- **Single Direction Basket**: All orders in a basket are the same direction (BUY or SELL)
- **Fixed Grid Distance**: Adds new grid level when price moves against basket by `GridDistancePoints`
- **Dynamic Grid Expansion**: When basket drawdown reaches `IncreaseGridDistanceAtDDPercent`, grid distance increases by `DynamicGridMultiplier`
- **Maximum Levels**: Enforces `MaxGridLevels` to prevent unlimited grid expansion
- **Controlled Lot Sizing**: Uses fixed lots by default; optional controlled progression via `MaxLotMultiplier` (no aggressive martingale)
- **Phase-1 legacy cadence**: By default (`UseDDBasedGridPause = false`), grid opening speed is driven by price movement and market conditions only, not by drawdown depth or number of open trades

### 3. Risk & Drawdown Control (ProtectionMode / EmergencyExit)

The EA implements multiple layers of risk protection:

#### ProtectionMode (when limits are approached)
- **DD-based (optional)**: When `UseDDBasedGridPause = true`, pause new grid at `PauseNewTradesAtDDPercent` and increase grid distance at `IncreaseGridDistanceAtDDPercent`. Phase-1 default is **false** (legacy: cadence by price/market only).
- **Exposure-based pause**: When `UseExposureBasedPause = true` and Free Margin < `MinRemainingExposureMoney` (account currency), the EA stops opening any new trades (no new basket, no new grid level). No TP or recovery logic change; reaching a kill condition is an accepted outcome.
- No blind liquidation; behavior is controlled and configurable

#### EmergencyExit
- **Emergency Close**: When basket DD ≥ `EmergencyCloseAtDDPercent`, closes entire basket in a **controlled** way (slippage limit, retries)
- **EmergencyExit** is configurable and designed to minimize damage, not force liquidation

#### Account-Level Controls
- **Equity Drawdown Limit**: Blocks new baskets when equity DD ≥ `MaxEquityDrawdownPercent`
- **Margin Protection**: Requires free margin ≥ `MinFreeMarginPercent` before any order
- **Emergency Margin Close**: Triggers EmergencyExit if free margin drops below 50% of minimum

### 4. Market Protection Filters

- **Spread Filter**: Blocks trading when spread > `MaxSpreadPoints`
- **Volatility Filter**: Uses ATR to detect abnormal volatility
  - Blocks new baskets when ATR > (20-period average × `ATR_MultiplierThreshold`)
  - Pauses grid expansion during high volatility
- **Impulse Filter**: Detects sharp/impulsive price moves (current bar range vs. average range). When `UseImpulseFilter` is true, can pause grid (`PauseGridOnImpulse`) and block new basket (`BlockNewBasketOnImpulse`) during impulsive moves even when ATR is not yet elevated.
- **Trading Hours**: Optional session filter via `StartHour` and `EndHour`

### 5. Exit Logic

- **Basket Take Profit**: Closes entire basket when total profit ≥ `BasketTakeProfitMoney`
- **Trailing Basket TP** (optional): Locks in profit by trailing the basket's highest profit level
  - Activates when profit reaches `TrailingStart`
  - Closes basket if profit falls back by `TrailingStep`
- **EmergencyExit**: Controlled, configurable basket closure with slippage limits during extreme conditions; minimizes damage, no blind liquidation

### 6. Recovery & State Management

- **Auto-Recovery**: Restores basket state on EA restart if orders exist
- **State Consistency**: Automatically detects and resets state if orders are manually closed
- **Clean Restart**: After basket closure (normal or emergency), EA cleanly returns to "no basket" state

## Key Input Parameters

### Essential Settings

| Parameter | Default | Description |
|-----------|---------|-------------|
| `MagicNumber` | 100140 | Unique identifier for EA orders |
| `EntryMode` | 0 | Phase-1: 0 = Manual (adopt user order), 1 = Semi-Auto (user confirms via input) |
| `OpenBasketDirection` | 0 | Semi-Auto only: 0 = None, 1 = BUY, 2 = SELL (confirm to open basket) |
| `LotSize` | 0.01 | Initial lot size |
| `MaxGridLevels` | 10 | Maximum grid depth |
| `GridDistancePoints` | 500 | Distance between grid levels (points) |
| `BasketTakeProfitMoney` | 10.0 | Basket TP in account currency |

### Risk Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `MaxBasketDrawdownMoney` | 100.0 | Maximum basket DD in account currency |
| `MaxEquityDrawdownPercent` | 20.0 | Maximum account equity DD (%) |
| `PauseNewTradesAtDDPercent` | 50.0 | Pause grid at this basket DD (%) |
| `IncreaseGridDistanceAtDDPercent` | 30.0 | Expand grid at this basket DD (%) |
| `EmergencyCloseAtDDPercent` | 80.0 | Emergency close at this basket DD (%) |
| `MinFreeMarginPercent` | 30.0 | Minimum free margin required (%) |

### Filter Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `MaxSpreadPoints` | 50 | Maximum allowed spread (points) |
| `UseVolatilityFilter` | true | Enable ATR volatility filter |
| `ATR_Period` | 14 | ATR calculation period |
| `ATR_MultiplierThreshold` | 2.0 | Volatility threshold multiplier |

## Implementation Details

### Basket Identification

- All orders with the same `MagicNumber` and same order type (OP_BUY or OP_SELL) belong to one basket
- Only one basket can be active at a time
- No mixed-direction baskets (all BUY or all SELL)

### Order of Safety Checks

Before opening any order, the EA checks in this order:

1. Symbol must be XAUUSD
2. Spread ≤ `MaxSpreadPoints`
3. Volatility acceptable (if filter enabled)
4. Within trading hours (if filter enabled)
5. Equity drawdown < limit
6. Free margin ≥ minimum
7. Basket drawdown < pause threshold (for grid levels)
8. Maximum grid levels not reached (for grid levels)

### Emergency Close Behavior

Emergency close is **controlled**, not a blind liquidation:

- Closes orders one by one with retry logic (up to 3 attempts)
- Respects `MaxBasketSlippagePoints` slippage limit
- Logs all actions for review
- Resets basket state after closure

### Edge Case Handling

- **Requotes**: Retries OrderSend with delay
- **Manual Close**: Detects and resets state when orders are manually closed
- **Broker Digits**: Uses `MarketInfo()` and `Point` for proper point/pip calculations
- **Weekend Gaps**: No new orders outside market hours; exit logic can still run

## Installation & Usage

### Installation

1. Copy `Netec1400_XAUUSD_Grid.mq4` to `[MT4 Data Folder]/MQL4/Experts/`
2. Open MetaEditor (F4 in MT4)
3. Open the MQ4 file and click "Compile" (F7)
4. Verify `Netec1400_XAUUSD_Grid.ex4` is created in the same folder

### Attaching to Chart

1. Open an XAUUSD chart in MT4
2. Drag the EA from Navigator onto the chart
3. Configure input parameters
4. Enable "Allow live trading" and "Allow DLL imports" (if needed)
5. Click OK

### Testing Workflow

**IMPORTANT**: Follow this sequence before live trading:

1. **Strategy Tester** (MT4 built-in):
   - Test on XAUUSD M1 or H1 timeframe
   - Use quality data (99% modeling quality)
   - Test various market conditions (trending, ranging, volatile)
   - Verify all risk controls activate correctly

2. **Demo Account**:
   - Run on demo for at least 1-2 weeks
   - Monitor basket behavior, grid expansion, and exits
   - Verify emergency close works as expected
   - Check that DD limits are respected

3. **Live Account** (only after approval):
   - Start with minimum lot sizes
   - Monitor closely for first few baskets
   - Gradually increase lot size if behavior is stable

## Configuration Recommendations

### Conservative Settings (Recommended for Start)

```
LotSize = 0.01
MaxGridLevels = 5
GridDistancePoints = 800
BasketTakeProfitMoney = 5.0
MaxBasketDrawdownMoney = 50.0
MaxEquityDrawdownPercent = 10.0
PauseNewTradesAtDDPercent = 40.0
EmergencyCloseAtDDPercent = 70.0
```

### Moderate Settings

```
LotSize = 0.01
MaxGridLevels = 10
GridDistancePoints = 500
BasketTakeProfitMoney = 10.0
MaxBasketDrawdownMoney = 100.0
MaxEquityDrawdownPercent = 20.0
PauseNewTradesAtDDPercent = 50.0
EmergencyCloseAtDDPercent = 80.0
```

### Aggressive Settings (Higher Risk)

```
LotSize = 0.02
MaxGridLevels = 15
GridDistancePoints = 300
BasketTakeProfitMoney = 20.0
MaxBasketDrawdownMoney = 200.0
MaxEquityDrawdownPercent = 30.0
PauseNewTradesAtDDPercent = 60.0
EmergencyCloseAtDDPercent = 90.0
```

## Monitoring & Logs

### On-Chart Display

The EA displays real-time information via `Comment()`:

- Magic number
- Current basket direction (BUY/SELL/NONE)
- Number of open orders vs maximum
- Current basket profit
- Basket drawdown percentage
- Equity drawdown percentage
- Current spread
- Free margin percentage

### Log Messages

The EA logs all important events to the Experts log:

- Basket opened (direction, price, lot)
- Grid level added (level number, price, DD%)
- Basket closed (reason, profit)
- Emergency close triggered (reason)
- Blocked actions (spread, volatility, DD, margin)

**Always review logs** after testing and during live operation.

## Troubleshooting

### EA Not Opening Trades

Check in order:
1. Symbol is XAUUSD
2. Spread is acceptable (check `MaxSpreadPoints`)
3. Volatility filter not blocking (check ATR vs threshold)
4. Within trading hours (if `UseTradingHours = true`)
5. Equity DD below limit
6. Free margin above minimum
7. Entry signal present (check `EntryMode` and indicator values)

### Grid Not Expanding

Check:
1. Basket DD < `PauseNewTradesAtDDPercent`
2. Spread acceptable
3. Volatility acceptable (if filter enabled)
4. Free margin sufficient
5. Current orders < `MaxGridLevels`
6. Price has moved >= `GridDistancePoints` from last level

### Emergency Close Triggered Unexpectedly

Review logs for trigger reason:
- Basket DD ≥ `EmergencyCloseAtDDPercent`
- Equity DD ≥ `MaxEquityDrawdownPercent`
- Free margin < 50% of `MinFreeMarginPercent`

Adjust parameters if triggers are too sensitive.

## Important Notes

### What This EA Does NOT Do

- ❌ Trade symbols other than XAUUSD
- ❌ Support MT5 (MT4 only)
- ❌ Use aggressive martingale (doubling lots)
- ❌ Set per-trade TP/SL on grid legs
- ❌ Manage multiple baskets simultaneously
- ❌ Mix BUY and SELL in one basket

### Risk Disclaimer

Grid/recovery systems can experience significant drawdowns during strong trending markets. While this EA includes comprehensive risk controls, **no EA can guarantee profits or prevent all losses**. 

- Always test thoroughly on demo first
- Never risk more than you can afford to lose
- Monitor the EA regularly, especially during news events
- Understand that past performance does not guarantee future results

## Support & Modifications

This EA is delivered as-is with full source code. You may modify the code as needed, but ensure you understand the implications of any changes to risk management logic.

For questions about the implementation or to request modifications, refer back to the original requirements document (`requirments.txt`).

## Version History

**v1.0** (Initial Release)
- Complete grid/recovery implementation
- Three entry modes (MA, RSI, Time-based)
- Basket-level management
- Multi-layer risk controls
- Dynamic grid expansion
- Emergency close with slippage control
- Volatility and spread filters
- Trading hours filter
- Optional trailing basket TP
- Full logging and on-chart display

---

**Developed according to Netec1400 specifications**  
**Priority: Survivability > Control > Stability > Profit**
