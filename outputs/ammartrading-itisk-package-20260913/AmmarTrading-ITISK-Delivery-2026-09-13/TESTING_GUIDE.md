# EA Testing & Validation Guide

## Testing Workflow

```
Strategy Tester → Demo Account → Live Account
    (Days)            (Weeks)        (Gradual)
```

**NEVER skip to live without completing Strategy Tester and Demo testing.**

---

## Phase 1: Strategy Tester (MT4 Built-in)

### Setup

1. Open MT4 Strategy Tester (View → Strategy Tester or Ctrl+R)
2. Select `Netec1400_XAUUSD_Grid` from Expert Advisor dropdown
3. Configure:
   - **Symbol:** XAUUSD
   - **Period:** H1 (recommended) or M15
   - **Model:** Every tick (most accurate)
   - **Date Range:** At least 3-6 months of recent data
   - **Optimization:** Disabled (for initial test)

### Test Scenarios

#### Test 1: Basic Functionality
**Goal:** Verify EA opens, manages, and closes baskets correctly

**Settings:**
```
LotSize = 0.01
MaxGridLevels = 5
GridDistancePoints = 500
BasketTakeProfitMoney = 10.0
MaxBasketDrawdownMoney = 100.0
EntryMode = 0 (MA)
UseEmergencyExit = true
```

**What to Check:**
- [ ] EA initializes without errors
- [ ] First trade opens based on entry logic
- [ ] Grid levels add when price moves against basket
- [ ] Grid spacing matches `GridDistancePoints`
- [ ] Basket closes when profit reaches TP
- [ ] No errors in "Journal" tab

**Expected Result:** Multiple complete basket cycles (open → grid → close)

---

#### Test 2: Risk Controls
**Goal:** Verify drawdown limits and emergency exits work

**Settings:**
```
LotSize = 0.01
MaxGridLevels = 10
GridDistancePoints = 300  ← Smaller to trigger DD faster
BasketTakeProfitMoney = 10.0
MaxBasketDrawdownMoney = 50.0  ← Lower to trigger DD faster
PauseNewTradesAtDDPercent = 40.0
EmergencyCloseAtDDPercent = 70.0
```

**What to Check:**
- [ ] Grid expansion pauses when basket DD reaches 40%
- [ ] Emergency close triggers when basket DD reaches 70%
- [ ] EA logs "Grid paused - basket DD: X%" messages
- [ ] EA logs "EMERGENCY CLOSE TRIGGERED" messages
- [ ] After emergency close, EA resets and can open new basket

**Expected Result:** At least one emergency close during test period

---

#### Test 3: Dynamic Grid Expansion
**Goal:** Verify dynamic grid increases spacing during stress

**Settings:**
```
LotSize = 0.01
MaxGridLevels = 10
GridDistancePoints = 400
UseDynamicGrid = true
DynamicGridMultiplier = 2.0
IncreaseGridDistanceAtDDPercent = 30.0
```

**What to Check:**
- [ ] Initial grid levels at 400 points apart
- [ ] When basket DD reaches 30%, log shows "Dynamic grid active - distance: 800 points"
- [ ] Subsequent grid levels are 800 points apart (400 × 2.0)
- [ ] Dynamic grid helps reduce grid filling speed

**Expected Result:** Grid spacing increases during drawdown periods

---

#### Test 4: Filter Effectiveness
**Goal:** Verify spread and volatility filters block trades appropriately

**Settings:**
```
MaxSpreadPoints = 20  ← Very tight to test blocking
UseVolatilityFilter = true
ATR_MultiplierThreshold = 1.5  ← Sensitive to test blocking
BlockNewBasketAboveVolatility = true
PauseGridAboveVolatility = true
```

**What to Check:**
- [ ] EA logs "Spread too high" messages when spread > 20 points
- [ ] EA logs "Volatility too high" messages during volatile periods
- [ ] No new baskets open during high volatility (if BlockNewBasket = true)
- [ ] Grid expansion pauses during high volatility (if PauseGrid = true)

**Expected Result:** Filters prevent trading during unfavorable conditions

---

#### Test 5: Entry Modes
**Goal:** Test all three entry modes work correctly

**Test 5a: MA Mode**
```
EntryMode = 0
MA_Period = 50
```
- [ ] BUY opens when price > MA
- [ ] SELL opens when price < MA

**Test 5b: RSI Mode**
```
EntryMode = 1
RSI_Period = 14
RSI_Oversold = 30
RSI_Overbought = 70
```
- [ ] BUY opens when RSI < 30
- [ ] SELL opens when RSI > 70

**Test 5c: Time Mode**
```
EntryMode = 2
SessionStartHour = 9
MA_Period = 50
```
- [ ] Basket opens only at hour 9 (broker time)
- [ ] Direction determined by MA
- [ ] Only one basket per day at that hour

---

### Analyzing Strategy Tester Results

After each test, review:

#### 1. Graph Tab
- Look for smooth equity curve (survivability)
- Check drawdown depth and recovery
- Identify periods of stress

#### 2. Results Tab
Key metrics to check:

| Metric | Good | Warning | Bad |
|--------|------|---------|-----|
| **Total Trades** | >20 | 10-20 | <10 (insufficient data) |
| **Profit Factor** | >1.2 | 1.0-1.2 | <1.0 |
| **Max Drawdown** | <20% | 20-40% | >40% |
| **Max Drawdown %** | <15% | 15-30% | >30% |

**Remember:** Goal is survivability, not high profit. Acceptable drawdown with recovery is success.

#### 3. Journal Tab
- Check for errors (red text)
- Verify log messages match expected behavior
- Look for "Failed to open order" messages (may indicate broker issues)

#### 4. Report Tab
- Review all trades
- Check grid level spacing
- Verify basket closures (TP vs emergency)
- Confirm lot sizes match settings

---

## Phase 2: Demo Account Testing

### Setup

1. Open demo account with realistic balance (e.g., $1000-10000)
2. Attach EA to XAUUSD chart
3. Use **conservative settings** for first demo run
4. Enable "Allow live trading" in EA properties

### Demo Testing Duration

**Minimum:** 1-2 weeks  
**Recommended:** 3-4 weeks  
**Ideal:** 1-2 months

### What to Monitor Daily

#### Morning Check (5 minutes)
- [ ] EA is running (smiley face in top-right corner)
- [ ] Check on-chart comment for current status
- [ ] Review any open basket (direction, orders, profit, DD%)
- [ ] Check free margin percentage

#### Evening Check (10 minutes)
- [ ] Review Experts log for the day
- [ ] Check if any baskets closed (TP or emergency)
- [ ] Verify no errors in Journal
- [ ] Note any filter activations (spread, volatility)

#### Weekly Review (30 minutes)
- [ ] Calculate total profit/loss for the week
- [ ] Review maximum drawdown reached
- [ ] Count baskets opened vs closed
- [ ] Check average basket duration
- [ ] Verify emergency closes (if any) were appropriate
- [ ] Review largest basket (max orders, max DD)

### Demo Test Scenarios

#### Week 1: Conservative Settings
```
LotSize = 0.01
MaxGridLevels = 5
GridDistancePoints = 800
BasketTakeProfitMoney = 5.0
```
**Goal:** Verify basic stability and survivability

#### Week 2: Moderate Settings
```
LotSize = 0.01
MaxGridLevels = 10
GridDistancePoints = 500
BasketTakeProfitMoney = 10.0
```
**Goal:** Test with more typical settings

#### Week 3: Stress Test (Optional)
```
LotSize = 0.02
MaxGridLevels = 15
GridDistancePoints = 300
```
**Goal:** Push limits to see how risk controls perform

#### Week 4: Final Configuration
```
[Your chosen settings for live]
```
**Goal:** Final validation before live

---

## Phase 3: Live Account Testing

### Pre-Live Checklist

Before going live, ensure:

- [ ] Strategy Tester shows acceptable results
- [ ] Demo account ran successfully for minimum 2 weeks
- [ ] No critical errors or unexpected behavior observed
- [ ] You understand all EA parameters
- [ ] You know how to manually close baskets if needed
- [ ] You have reviewed and accepted the risk
- [ ] Account balance is appropriate for lot size
- [ ] Broker spread and slippage are acceptable

### Live Account Approach

#### Stage 1: Micro Testing (Week 1-2)
```
LotSize = 0.01 (minimum)
MaxGridLevels = 5
Conservative settings
```
**Goal:** Verify EA works on live broker feed with real execution

**Monitor:** DAILY, multiple times per day

#### Stage 2: Gradual Increase (Week 3-4)
```
LotSize = 0.01-0.02
MaxGridLevels = 8-10
Moderate settings
```
**Goal:** Increase exposure gradually while monitoring

**Monitor:** Daily

#### Stage 3: Target Settings (Week 5+)
```
[Your final configuration]
```
**Goal:** Run at intended lot size and settings

**Monitor:** Daily initially, then can reduce to every 2-3 days once stable

---

## Emergency Procedures

### How to Stop the EA

**Method 1: Disable EA**
1. Right-click chart
2. Expert Advisors → Remove
3. EA stops, existing orders remain open

**Method 2: Disable AutoTrading**
1. Click "AutoTrading" button in toolbar (turns gray)
2. All EAs stop, existing orders remain open

### How to Manually Close Basket

**If EA is not closing and you need to exit:**

1. Open "Terminal" window (Ctrl+T)
2. Go to "Trade" tab
3. For each order with your MagicNumber:
   - Right-click order
   - Select "Close Order"
   - Confirm
4. After all orders closed, EA will reset automatically

### When to Manually Intervene

**Intervene immediately if:**
- Account equity drops >30% unexpectedly
- Free margin drops below 20%
- Broker issues (requotes, connection loss)
- Major news event you forgot to account for
- EA shows errors in Journal

**Do NOT intervene if:**
- Basket is in normal drawdown (within limits)
- Grid is expanding as designed
- EA is paused due to filters (spread, volatility)
- Basket is trailing toward TP

---

## Testing Checklist Summary

### Strategy Tester
- [ ] Basic functionality test passed
- [ ] Risk controls test passed
- [ ] Dynamic grid test passed
- [ ] Filters test passed
- [ ] All entry modes tested
- [ ] No critical errors in Journal
- [ ] Results acceptable (profit factor, drawdown)

### Demo Account
- [ ] Ran for minimum 2 weeks
- [ ] Multiple basket cycles completed
- [ ] Emergency close tested (if triggered)
- [ ] Filters activated appropriately
- [ ] No unexpected behavior
- [ ] Comfortable with EA behavior

### Live Account
- [ ] Started with minimum lot size
- [ ] Monitored daily for first 2 weeks
- [ ] Gradually increased to target settings
- [ ] Emergency procedures understood
- [ ] Acceptable results maintained

---

## Common Testing Issues

### Issue: EA opens too many trades too fast
**Cause:** Grid distance too small or entry too frequent  
**Fix:** Increase `GridDistancePoints` or adjust entry mode

### Issue: EA never reaches TP
**Cause:** TP too high relative to typical basket profit  
**Fix:** Lower `BasketTakeProfitMoney` or widen grid

### Issue: Emergency close triggers too often
**Cause:** DD limits too tight for grid settings  
**Fix:** Increase `EmergencyCloseAtDDPercent` or decrease `MaxGridLevels`

### Issue: EA never opens trades
**Cause:** Filters too strict or no entry signal  
**Fix:** Check spread, volatility, trading hours, and entry mode settings

### Issue: Basket gets too large (many orders)
**Cause:** Strong trend against basket direction  
**Fix:** This is expected behavior; dynamic grid and pause should limit it. If not, tighten `PauseNewTradesAtDDPercent`

---

## Testing Log Template

Use this template to track your testing:

```
=== EA TESTING LOG ===

Date: _______________
Phase: [ ] Strategy Tester  [ ] Demo  [ ] Live
Account Balance: _______________

Settings:
- LotSize: _____
- MaxGridLevels: _____
- GridDistancePoints: _____
- BasketTakeProfitMoney: _____
- MaxBasketDrawdownMoney: _____

Results:
- Baskets Opened: _____
- Baskets Closed (TP): _____
- Baskets Closed (Emergency): _____
- Total Profit/Loss: _____
- Max Drawdown: _____%
- Max Orders in Basket: _____

Observations:
_________________________________
_________________________________
_________________________________

Issues Found:
_________________________________
_________________________________

Next Steps:
_________________________________
_________________________________
```

---

**Remember:** Thorough testing is the difference between a surviving EA and a blown account. Take your time, be methodical, and never skip phases.
