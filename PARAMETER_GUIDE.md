# EA Parameter Quick Reference Guide

## Parameter Categories

### 🔢 Symbol & Identity

| Parameter | Type | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| `MagicNumber` | int | 100140 | 1-999999 | Unique identifier for this EA's orders. Change if running multiple EAs. |

---

### 📊 Lots & Grid

| Parameter | Type | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| `LotSize` | double | 0.01 | 0.01-100 | Initial lot size for first trade and grid levels |
| `UseFixedLot` | bool | true | true/false | If true, all grid levels use same lot. If false, allows progression. |
| `MaxGridLevels` | int | 10 | 1-50 | Maximum number of grid levels (orders) in basket |
| `GridDistancePoints` | int | 500 | 100-5000 | Distance in points between grid levels |
| `UseDynamicGrid` | bool | true | true/false | Enable dynamic grid expansion during stress |
| `DynamicGridMultiplier` | double | 1.5 | 1.0-3.0 | Multiplier for grid distance when DD threshold reached |
| `MaxLotMultiplier` | double | 1.0 | 1.0-3.0 | Maximum lot multiplier (1.0 = no progression) |

**Notes:**
- 1 point = 0.01 for XAUUSD on most brokers (check your broker's point size)
- 500 points = $5 move in gold price
- Dynamic grid helps survive strong trends by spacing out new levels

---

### 🚪 Entry (Phase-1: Manual and Semi-Auto Only)

| Parameter | Type | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| `EntryMode` | int | 0 | 0-1 | Phase-1: 0 = Manual (adopt user order), 1 = Semi-Auto (user confirms via input) |
| `OpenBasketDirection` | int | 0 | 0-2 | Semi-Auto only: 0 = None, 1 = BUY, 2 = SELL (confirm to open basket) |
| `SuggestedDirectionSource` | int | 0 | 0-1 | Semi-Auto display: 0 = None, 1 = MA (suggestion only; no auto-open) |
| `MA_Period` | int | 50 | 5-200 | MA period (for suggestion display only in Phase-1) |
| `RSI_Period` | int | 14 | 5-50 | RSI period (Phase-2; not used for entry in Phase-1) |
| `RSI_Oversold` | double | 30 | 10-40 | RSI oversold (Phase-2) |
| `RSI_Overbought` | double | 70 | 60-90 | RSI overbought (Phase-2) |
| `SessionStartHour` | int | 0 | 0-23 | Session start hour (Phase-2) |

**Phase-1 Entry Mode Details:**
- **Mode 0 (Manual – Adopt)**: EA does **not** open the first trade. You place order(s) in MT4 with the EA’s MagicNumber; the EA adopts them as the basket start and manages grid/recovery. Single direction only.
- **Mode 1 (Semi-Auto)**: EA can show a **suggested** direction (e.g. from MA if `SuggestedDirectionSource = 1`). You set `OpenBasketDirection` to BUY or SELL to confirm; when filters pass, the EA opens the first trade in that direction.

**Phase-2 (future):** Indicator-based entry (MA/RSI/Time) is out of scope for Phase-1; code is present for later phases (EntryMode 2=MA, 3=RSI, 4=Time).

---

### 🎯 Exit

| Parameter | Type | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| `BasketTakeProfitMoney` | double | 10.0 | 1.0-10000 | Basket TP in account currency (e.g., USD) |
| `UseTrailingBasketTP` | bool | false | true/false | Enable trailing basket take profit |
| `TrailingStart` | double | 15.0 | 5.0-10000 | Profit level where trailing activates |
| `TrailingStep` | double | 5.0 | 1.0-1000 | Trail by this amount (closes if profit drops by this) |

**Example:**
- `BasketTakeProfitMoney = 10.0` → closes basket when profit reaches $10
- With trailing: if profit reaches $15, then drops to $10 ($15 - $5 step), basket closes

---

### ⚠️ Risk

| Parameter | Type | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| `MaxBasketDrawdownMoney` | double | 100.0 | 10-10000 | Maximum basket DD in account currency (reference for % calculations) |
| `MaxEquityDrawdownPercent` | double | 20.0 | 5-50 | Maximum account equity DD % (blocks new baskets) |
| `PauseNewTradesAtDDPercent` | double | 50.0 | 10-90 | Basket DD % to pause grid expansion |
| `IncreaseGridDistanceAtDDPercent` | double | 30.0 | 10-80 | Basket DD % to activate dynamic grid expansion |
| `EmergencyCloseAtDDPercent` | double | 80.0 | 50-100 | Basket DD % to trigger emergency close |
| `MinFreeMarginPercent` | double | 30.0 | 10-80 | Minimum free margin % required |
| `UseDDBasedGridPause` | bool | false | true/false | Phase-1 legacy default: false = cadence by price/market only; when true, DD-based pause and dynamic grid apply |

**Risk Flow (ProtectionMode / EmergencyExit):**
- When **UseDDBasedGridPause = true**: At 30% basket DD → dynamic grid; at 50% → grid pause; at 80% → EmergencyExit.
- When **UseDDBasedGridPause = false** (Phase-1 default): Grid cadence is driven only by price move, MaxGridLevels, spread, volatility, impulse, and exposure.
- **Exposure-based pause**: When Free Margin < `MinRemainingExposureMoney` (account currency), EA stops opening any new trades (no new basket, no new grid level).

**Important:** 
- `MaxBasketDrawdownMoney` is the reference for calculating basket DD%
- If basket loss = $50 and `MaxBasketDrawdownMoney = 100`, basket DD = 50%

---

### 🚨 Emergency (EmergencyExit)

| Parameter | Type | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| `UseEmergencyExit` | bool | true | true/false | Enable EmergencyExit (controlled, configurable; minimizes damage) |
| `MaxBasketSlippagePoints` | int | 50 | 10-200 | Maximum slippage allowed when closing basket |

**EmergencyExit Triggers:**
- Basket DD ≥ `EmergencyCloseAtDDPercent`
- Equity DD ≥ `MaxEquityDrawdownPercent`
- Free margin < 50% of `MinFreeMarginPercent`

---

### 🛡️ Filters

| Parameter | Type | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| `MaxSpreadPoints` | int | 50 | 10-200 | Maximum spread allowed for trading (points) |
| `UseVolatilityFilter` | bool | true | true/false | Enable ATR-based volatility filter |
| `ATR_Period` | int | 14 | 5-50 | ATR calculation period |
| `ATR_MultiplierThreshold` | double | 2.0 | 1.5-5.0 | ATR multiplier threshold for high volatility |
| `BlockNewBasketAboveVolatility` | bool | true | true/false | Block new basket creation during high volatility |
| `PauseGridAboveVolatility` | bool | true | true/false | Pause grid expansion during high volatility |
| `UseImpulseFilter` | bool | true | true/false | Detect sharp/impulsive moves (range vs. average range) |
| `ImpulseLookbackBars` | int | 5 | 1-100 | Bars for average range (impulse) |
| `ImpulseRangeMultiplier` | double | 2.0 | 1.0-5.0 | Current range > avg range × this = impulse |
| `PauseGridOnImpulse` | bool | true | true/false | Pause grid when impulse detected |
| `BlockNewBasketOnImpulse` | bool | true | true/false | Block new basket when impulse detected |
| `UseExposureBasedPause` | bool | true | true/false | Pause when free margin below threshold |
| `MinRemainingExposureMoney` | double | 100.0 | 0-10000 | Min free margin (account currency) to allow new trades |

**Volatility Logic:**
- EA calculates 20-period average ATR
- If current ATR > (average ATR × `ATR_MultiplierThreshold`), volatility is "high"
- High volatility blocks new baskets and/or pauses grid (based on settings)

**Impulse Logic (Phase-1 legacy alignment):**
- Current bar range (or max of last 2 bars) vs. average range over `ImpulseLookbackBars`
- If current range > average × `ImpulseRangeMultiplier`, impulse is detected; can pause grid and/or block new basket
- Works alongside ATR volatility (both can block when enabled)

---

### 🕐 Session

| Parameter | Type | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| `UseTradingHours` | bool | false | true/false | Enable trading hours filter |
| `StartHour` | int | 0 | 0-23 | Trading start hour (broker server time) |
| `EndHour` | int | 23 | 0-23 | Trading end hour (broker server time) |

**Notes:**
- Hours are in broker server time (check MT4 Market Watch time)
- If `StartHour > EndHour`, assumes overnight session (e.g., 22-6)
- Filter only blocks NEW basket creation, not management of existing basket

---

## Preset Configurations

### 🟢 Conservative (Low Risk)

```
LotSize = 0.01
MaxGridLevels = 5
GridDistancePoints = 800
BasketTakeProfitMoney = 5.0
MaxBasketDrawdownMoney = 50.0
MaxEquityDrawdownPercent = 10.0
PauseNewTradesAtDDPercent = 40.0
IncreaseGridDistanceAtDDPercent = 25.0
EmergencyCloseAtDDPercent = 70.0
MinFreeMarginPercent = 40.0
MaxSpreadPoints = 30
```

**Best for:** Small accounts, beginners, high-risk aversion

---

### 🟡 Moderate (Balanced)

```
LotSize = 0.01
MaxGridLevels = 10
GridDistancePoints = 500
BasketTakeProfitMoney = 10.0
MaxBasketDrawdownMoney = 100.0
MaxEquityDrawdownPercent = 20.0
PauseNewTradesAtDDPercent = 50.0
IncreaseGridDistanceAtDDPercent = 30.0
EmergencyCloseAtDDPercent = 80.0
MinFreeMarginPercent = 30.0
MaxSpreadPoints = 50
```

**Best for:** Standard accounts, tested strategies, moderate risk tolerance

---

### 🔴 Aggressive (Higher Risk)

```
LotSize = 0.02
MaxGridLevels = 15
GridDistancePoints = 300
BasketTakeProfitMoney = 20.0
MaxBasketDrawdownMoney = 200.0
MaxEquityDrawdownPercent = 30.0
PauseNewTradesAtDDPercent = 60.0
IncreaseGridDistanceAtDDPercent = 40.0
EmergencyCloseAtDDPercent = 90.0
MinFreeMarginPercent = 25.0
MaxSpreadPoints = 80
```

**Best for:** Larger accounts, experienced traders, higher risk tolerance

⚠️ **Warning:** Aggressive settings can lead to significant drawdowns. Only use if you understand the risks.

---

## Optimization Tips

### For Ranging Markets
- Decrease `GridDistancePoints` (300-400)
- Increase `MaxGridLevels` (12-15)
- Lower `BasketTakeProfitMoney` for quicker exits

### For Trending Markets
- Increase `GridDistancePoints` (600-1000)
- Decrease `MaxGridLevels` (5-8)
- Enable `UseDynamicGrid` with higher multiplier (2.0-2.5)
- Tighten `PauseNewTradesAtDDPercent` (30-40%)

### For Volatile Markets (News Events)
- Increase `MaxSpreadPoints` (80-100) or avoid trading
- Enable `UseVolatilityFilter = true`
- Lower `ATR_MultiplierThreshold` (1.5-1.8) to be more sensitive
- Use `UseTradingHours` to avoid news times

### For Low Margin Accounts
- Decrease `LotSize` (0.01 or less)
- Decrease `MaxGridLevels` (5-7)
- Increase `MinFreeMarginPercent` (40-50%)
- Tighten `MaxEquityDrawdownPercent` (10-15%)

---

## Common Parameter Mistakes

❌ **Too many grid levels with small distance**
- Problem: Rapid grid filling, high exposure
- Fix: Either increase `GridDistancePoints` OR decrease `MaxGridLevels`

❌ **Emergency close too close to pause level**
- Problem: Emergency triggers before pause has effect
- Fix: Ensure `EmergencyCloseAtDDPercent` is at least 20-30% higher than `PauseNewTradesAtDDPercent`

❌ **Basket TP smaller than expected DD**
- Problem: Basket rarely reaches TP, often hits DD limits
- Fix: Increase `BasketTakeProfitMoney` or tighten grid to reduce DD

❌ **Spread filter too tight**
- Problem: EA never trades due to spread rejection
- Fix: Check typical XAUUSD spread on your broker, set `MaxSpreadPoints` accordingly (usually 30-80)

❌ **Lot size too large for account**
- Problem: Margin call risk, emergency closes
- Fix: Use 0.01 lot per $1000-2000 account balance as starting point

---

## Testing Checklist

Before going live, verify these scenarios in Strategy Tester:

- [ ] Basket opens correctly in both directions (BUY and SELL)
- [ ] Grid levels add at correct distances
- [ ] Dynamic grid activates at DD threshold
- [ ] Grid pauses at pause threshold
- [ ] Basket closes at TP
- [ ] Emergency close triggers at DD limit
- [ ] Spread filter blocks trades during high spread
- [ ] Volatility filter blocks trades during high ATR
- [ ] Trading hours filter works correctly
- [ ] Margin check prevents over-leveraging
- [ ] EA recovers state after restart with open positions

---

**Remember:** Start conservative, test thoroughly, and only increase risk after confirming stable behavior.
