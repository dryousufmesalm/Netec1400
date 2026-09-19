# Quick Start Guide

Get the EA running in 10 minutes.

---

## 1. Install (2 minutes)

### Copy File
1. Open MT4
2. Click **File → Open Data Folder**
3. Navigate to `MQL4\Experts\`
4. Copy `Netec1400_XAUUSD_Grid.mq4` here

### Compile
1. Press **F4** to open MetaEditor
2. Open `Netec1400_XAUUSD_Grid.mq4`
3. Press **F7** to compile
4. Check for "0 error(s)" at bottom
5. Close MetaEditor

---

## 2. Attach to Chart (1 minute)

1. In MT4, open a **XAUUSD** chart (any timeframe)
2. Press **Ctrl+N** to open Navigator
3. Expand **Expert Advisors**
4. Drag `Netec1400_XAUUSD_Grid` onto XAUUSD chart
5. Settings window appears

---

## 3. Configure (3 minutes)

### Common Tab
- ✅ Check **"Allow live trading"**
- Click **OK**

### For First Test - Use These Settings

**Copy these into the Inputs tab:**

```
=== ESSENTIAL ===
MagicNumber = 100140
LotSize = 0.01
MaxGridLevels = 5
GridDistancePoints = 800
BasketTakeProfitMoney = 5.0

=== RISK (Conservative) ===
MaxBasketDrawdownMoney = 50.0
MaxEquityDrawdownPercent = 10.0
PauseNewTradesAtDDPercent = 40.0
EmergencyCloseAtDDPercent = 70.0
MinFreeMarginPercent = 40.0

=== ENTRY ===
EntryMode = 0
MA_Period = 50

=== FILTERS ===
MaxSpreadPoints = 50
UseVolatilityFilter = true
UseTradingHours = false

=== EMERGENCY ===
UseEmergencyExit = true
MaxBasketSlippagePoints = 50
```

Click **OK** to apply.

---

## 4. Verify (1 minute)

Check these 4 things:

1. **Top-right corner:** 😊 Smiley face (not sad face)
2. **Chart:** Shows EA info (Magic, Basket, Orders, etc.)
3. **Experts tab:** Shows "Netec1400 XAUUSD Grid EA Initialized"
4. **No errors** in Journal tab

✅ If all 4 are good, EA is running!

---

## 5. Monitor (3 minutes)

### What to Watch

**On Chart Comment:**
```
=== Netec1400 XAUUSD Grid EA ===
Magic: 100140
Basket: NONE (or BUY/SELL if opened)
Orders: 0 / 5
Profit: 0.00 USD
Basket DD: 0.0%
Equity DD: 0.0%
Spread: 25 pts
Free Margin: 95.0%
```

**In Experts Tab:**
- Watch for "NEW BASKET OPENED" message
- Watch for "GRID LEVEL ADDED" messages
- Watch for "BASKET CLOSED" messages

---

## What Happens Next?

### Phase 1: Waiting for Entry
EA checks every tick for entry conditions:
- Spread must be acceptable
- Volatility must be OK
- Entry signal must be present (price vs MA)

**This can take minutes to hours.** Be patient.

### Phase 2: Basket Opens
When conditions are met:
- EA opens first trade (BUY or SELL)
- Log shows "NEW BASKET OPENED"
- Chart comment shows basket direction

### Phase 3: Grid May Expand
If price moves against basket:
- EA adds grid levels at 800-point intervals
- Maximum 5 levels (in conservative settings)
- Each level logged

### Phase 4: Basket Closes
When profit reaches $5.00:
- EA closes all orders
- Log shows "BASKET CLOSED"
- EA resets and waits for next entry

---

## Quick Troubleshooting

### EA Not Opening Trades?

**Check:**
1. Spread (must be < 50 points) - check Market Watch
2. AutoTrading enabled (green button in toolbar)
3. Symbol is XAUUSD (not EURUSD or other)
4. Wait longer (entry conditions may not be met yet)

### EA Shows Sad Face?

**Fix:**
1. Click **AutoTrading** button in MT4 toolbar
2. Should turn green, smiley face appears

### EA Shows Error?

**Common errors:**
- "This EA only works on XAUUSD" → Attach to XAUUSD chart
- "LotSize must be > 0" → Set LotSize to 0.01 in inputs

---

## First Day Expectations

### Normal Behavior

**Scenario A: Ranging Market**
- Opens 1-2 baskets
- Each basket has 2-4 grid levels
- Closes at profit within hours
- Small profit ($5-15)

**Scenario B: Trending Market**
- Opens 1 basket
- Expands to 4-5 grid levels
- May stay open for hours/days
- Waits for retracement to close

**Scenario C: Volatile Market**
- May not open any basket
- Filters block due to spread or volatility
- This is normal protection

### What's NOT Normal

❌ Opening 10+ orders immediately
❌ Constant errors in log
❌ Basket never closing after days
❌ EA disabling itself

If you see these, check settings or contact support.

---

## Next Steps

### After First Successful Basket

1. **Review the cycle:**
   - Check Experts log for full sequence
   - Verify profit matched TP setting
   - Check maximum DD reached

2. **Let it run:**
   - Allow 3-5 basket cycles
   - Monitor daily
   - Take notes on behavior

3. **Read full documentation:**
   - README.md - Complete guide
   - PARAMETER_GUIDE.md - All settings explained
   - TESTING_GUIDE.md - Proper testing procedure

### After First Week

1. **Evaluate results:**
   - Total profit/loss
   - Maximum drawdown
   - Number of baskets
   - Any issues encountered

2. **Adjust if needed:**
   - Too slow? Decrease GridDistancePoints
   - Too risky? Decrease MaxGridLevels
   - Too many baskets? Adjust entry mode

3. **Continue demo testing:**
   - Minimum 2 weeks before live
   - Preferably 1 month
   - Must see various market conditions

---

## Settings Cheat Sheet

### More Conservative (Lower Risk)
```
LotSize = 0.01
MaxGridLevels = 3
GridDistancePoints = 1000
BasketTakeProfitMoney = 3.0
EmergencyCloseAtDDPercent = 60.0
```

### More Aggressive (Higher Risk)
```
LotSize = 0.02
MaxGridLevels = 10
GridDistancePoints = 500
BasketTakeProfitMoney = 15.0
EmergencyCloseAtDDPercent = 85.0
```

### For Ranging Markets
```
GridDistancePoints = 400
MaxGridLevels = 8
BasketTakeProfitMoney = 8.0
```

### For Trending Markets
```
GridDistancePoints = 800
MaxGridLevels = 5
UseDynamicGrid = true
DynamicGridMultiplier = 2.0
```

---

## Emergency: How to Stop

### Stop EA But Keep Orders Open
1. Right-click chart
2. **Expert Advisors → Remove**
3. Orders remain, EA stops

### Stop EA And Close All Orders
1. Click **AutoTrading** button (turns gray)
2. Go to **Terminal → Trade** tab
3. Right-click each order → **Close Order**
4. Confirm each closure

---

## Quick Reference Commands

| Action | How To |
|--------|--------|
| Enable EA | Click AutoTrading button (green) |
| Disable EA | Click AutoTrading button (gray) |
| Remove EA | Right-click chart → Expert Advisors → Remove |
| Change Settings | Right-click chart → Expert Advisors → Properties |
| View Log | View → Terminal → Experts tab |
| Check Orders | View → Terminal → Trade tab |

---

## Important Reminders

⚠️ **This is a DEMO test** - Not for live trading yet
⚠️ **Grid systems have drawdown** - This is normal
⚠️ **Monitor daily** - Don't set and forget
⚠️ **Read full docs** - This is just a quick start
⚠️ **Test for weeks** - Not days

---

## Support Resources

- **README.md** - Full documentation
- **PARAMETER_GUIDE.md** - All settings explained
- **TESTING_GUIDE.md** - How to test properly
- **FAQ.md** - Common questions answered
- **LOGIC_FLOWCHARTS.md** - Visual logic diagrams

---

## Quick Start Checklist

- [ ] MQ4 file copied to MQL4\Experts folder
- [ ] EA compiled successfully (0 errors)
- [ ] XAUUSD chart opened
- [ ] EA attached to chart
- [ ] "Allow live trading" enabled
- [ ] Conservative settings configured
- [ ] Smiley face showing (EA active)
- [ ] Chart comment displaying
- [ ] No errors in Experts log
- [ ] Monitoring plan in place

---

**You're ready! Let the EA run and observe its behavior.**

**Remember:** Patience is key. Grid systems work over time, not instantly.

Good luck with your testing! 🎯
