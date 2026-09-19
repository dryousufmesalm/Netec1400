# Frequently Asked Questions (FAQ)

## General Questions

### Q: What is a grid/recovery EA?

**A:** A grid/recovery EA opens an initial trade, then adds additional trades (grid levels) at fixed intervals when price moves against the position. The goal is to "recover" from drawdown by averaging the entry price and closing the entire basket when it reaches profit.

**Key characteristics:**
- Multiple orders in one direction (all BUY or all SELL)
- Orders added at fixed distances (the "grid")
- All orders close together as one "basket"
- Aims to profit from price retracements

---

### Q: Why XAUUSD only?

**A:** This EA is specifically designed and optimized for gold (XAUUSD) characteristics:
- Gold's typical volatility patterns
- Gold's spread and point size
- Gold's margin requirements
- Gold's tendency to retrace (good for grid systems)

Using on other symbols may produce unexpected results and is not supported.

---

### Q: Can I use this on MT5?

**A:** No. This EA is written in MQL4 for MetaTrader 4 only. MT5 uses a different language (MQL5) and different order management system. A complete rewrite would be needed for MT5.

---

### Q: Is this a "set and forget" EA?

**A:** No. While the EA has comprehensive risk controls, you should:
- Monitor it daily (at minimum)
- Check drawdown levels regularly
- Be aware of major news events
- Verify it's working as expected
- Be ready to intervene if needed

No EA can guarantee profits or prevent all losses. Active monitoring is essential.

---

## Trading Logic Questions

### Q: How does Phase-1 entry work (Manual vs Semi-Auto)?

**A:** Phase-1 entry is **controllable only**; there is no autonomous indicator-based entry.

- **Manual (EntryMode = 0):** The EA does **not** open the first trade. You place the first order(s) in MT4 (same symbol, EA MagicNumber). The EA detects them and **adopts** them as the basket start, then manages grid/recovery. Single direction only; mixed BUY/SELL orders are rejected.
- **Semi-Auto (EntryMode = 1):** The EA can show a **suggested** direction (e.g. from MA if `SuggestedDirectionSource = 1`; display only). You set `OpenBasketDirection` to BUY (1) or SELL (2) to confirm. When all filters pass, the EA opens the first trade in that direction. No automatic opening from indicators.

Indicator-based entry (MA/RSI/Time) is out of scope for Phase-1 and deferred to a later phase.

---

### Q: How does the EA decide to open the first trade (BUY or SELL)? (Phase-1)

**A:** In Phase-1, the EA does **not** decide on its own:

- **Manual:** You open the first trade(s) in MT4; the EA adopts them.
- **Semi-Auto:** You set `OpenBasketDirection` to BUY or SELL; the EA opens the first trade in that direction when filters pass. Optional suggestion (e.g. from MA) is display only.

---

### Q: Why does the EA sometimes not open trades?

**A:** The EA has multiple filters that must all pass before opening:

1. **Symbol check:** Must be XAUUSD
2. **Spread filter:** Spread must be ≤ MaxSpreadPoints
3. **Volatility filter:** ATR must be below threshold (if enabled)
4. **Trading hours:** Must be within configured hours (if enabled)
5. **Equity DD:** Account drawdown must be below limit
6. **Margin:** Free margin must be above minimum
7. **Entry signal:** Must have valid entry signal from chosen mode

Check the Experts log to see which filter is blocking trades.

---

### Q: How far apart are grid levels?

**A:** Initial spacing is set by `GridDistancePoints` parameter.

**Example:** If `GridDistancePoints = 500`:
- First trade at $2000.00
- Second trade at $1995.00 (BUY basket) or $2005.00 (SELL basket)
- Third trade at $1990.00 or $2010.00
- And so on...

**Dynamic grid:** If enabled, spacing increases by `DynamicGridMultiplier` when basket DD reaches `IncreaseGridDistanceAtDDPercent`.

---

### Q: What is "basket drawdown" vs "equity drawdown"?

**A:** Two different measurements:

**Basket Drawdown:**
- Loss on current open basket only
- Calculated as: (basket loss / MaxBasketDrawdownMoney) × 100%
- Example: Basket losing $40, MaxBasketDrawdownMoney = 100 → 40% basket DD

**Equity Drawdown:**
- Loss on entire account from starting equity
- Calculated as: ((initial equity - current equity) / initial equity) × 100%
- Example: Started with $1000, now $900 → 10% equity DD

Both are monitored and have separate limits.

---

### Q: When does the basket close?

**A:** Basket closes when any of these conditions are met:

1. **Normal TP:** Total basket profit ≥ `BasketTakeProfitMoney`
2. **Trailing TP:** Profit reached `TrailingStart` then fell back by `TrailingStep` (if enabled)
3. **EmergencyExit:** Basket DD ≥ `EmergencyCloseAtDDPercent`
4. **EmergencyExit:** Equity DD ≥ `MaxEquityDrawdownPercent`
5. **EmergencyExit:** Free margin < 50% of `MinFreeMarginPercent`

**ProtectionMode** (when limits are approached): EA pauses new grid additions, may expand grid spacing; no blind liquidation. **EmergencyExit**: controlled, configurable close; minimizes damage, does not force liquidation.

After closure, EA resets and can open a new basket.

---

### Q: Can the EA trade both BUY and SELL at the same time?

**A:** No. The EA only manages one basket at a time, and all orders in a basket are the same direction. This is by design for:
- Simpler risk management
- Clearer basket profit calculation
- Avoiding conflicting positions

---

## Risk & Money Management

### Q: What lot size should I use?

**A:** Conservative guideline:

| Account Balance | Suggested LotSize | MaxGridLevels |
|-----------------|-------------------|---------------|
| $500 - $1000 | 0.01 | 5 |
| $1000 - $2000 | 0.01 | 8 |
| $2000 - $5000 | 0.01 - 0.02 | 10 |
| $5000 - $10000 | 0.02 - 0.03 | 10-12 |

**Rule of thumb:** 0.01 lot per $1000-2000 balance

**Important:** Always test on demo first with your intended lot size.

---

### Q: How much drawdown should I expect?

**A:** Depends on settings and market conditions:

**Conservative settings:** 10-20% typical, 30-40% maximum stress
**Moderate settings:** 20-30% typical, 40-60% maximum stress
**Aggressive settings:** 30-50% typical, 60-80% maximum stress

Grid systems inherently experience drawdown during trends. The EA's risk controls are designed to limit and recover from drawdown, not eliminate it.

---

### Q: What if I hit margin call?

**A:** The EA has multiple protections to prevent margin call:

1. **MinFreeMarginPercent:** Blocks new orders if free margin too low
2. **Emergency close:** Triggers if free margin drops to critical level
3. **MaxGridLevels:** Limits total exposure

However, no system is foolproof. To minimize risk:
- Use conservative lot sizes
- Set appropriate `MinFreeMarginPercent` (30-40%)
- Don't run multiple EAs that compete for margin
- Monitor during volatile periods

---

### Q: Should I use fixed lots or lot progression?

**A:** **Recommended: Fixed lots** (`UseFixedLot = true`)

**Fixed lots:**
- ✅ More predictable risk
- ✅ Easier to calculate exposure
- ✅ Safer during trends
- ❌ Slower recovery

**Lot progression:**
- ✅ Faster recovery from drawdown
- ❌ Higher risk if trend continues
- ❌ Can reach margin limits faster

If you use progression, keep `MaxLotMultiplier` low (1.2-1.5 maximum).

---

### Q: What is a safe MaxGridLevels setting?

**A:** Depends on account size and lot size:

**Small accounts ($500-1000):** 5-7 levels
**Medium accounts ($1000-5000):** 8-10 levels
**Large accounts ($5000+):** 10-15 levels

**Formula:** Ensure (LotSize × MaxGridLevels × $1000) < 30% of account balance

**Example:** 0.01 lot × 10 levels × $1000 = $100 exposure per $1 move
- Safe for $1000+ account
- Risky for $500 account

---

## Technical Questions

### Q: What are "points" vs "pips" for XAUUSD?

**A:** Depends on your broker's quote format:

**5-digit quotes (e.g., 2000.50):**
- 1 point = 0.01 (smallest price change)
- 10 points = 1 pip = $0.10 move
- 500 points = 50 pips = $5.00 move

**3-digit quotes (e.g., 2000.5):**
- 1 point = 0.1
- 10 points = 1 pip = $1.00 move
- 500 points = 50 pips = $50.00 move

The EA uses "points" for all distance calculations. Check your broker's format and adjust `GridDistancePoints` accordingly.

---

### Q: How do I check my broker's point size?

**A:** In MT4:
1. Open Market Watch (Ctrl+M)
2. Right-click XAUUSD → Specification
3. Check "Digits" field:
   - Digits = 2 → 1 point = 0.01
   - Digits = 1 → 1 point = 0.1

Or check current price format in Market Watch:
- 2000.50 → 2 digits
- 2000.5 → 1 digit

---

### Q: What is the MagicNumber for?

**A:** The MagicNumber is a unique identifier that:
- Distinguishes this EA's orders from other EAs or manual trades
- Allows the EA to identify which orders belong to its basket
- Prevents interference if you run multiple EA instances

**Default:** 100140

**Change if:**
- Running multiple instances of this EA
- Running other EAs on the same account
- Want to separate orders for tracking

---

### Q: Can I manually close some orders in a basket?

**A:** You can, but it's not recommended:

**What happens:**
- EA continues managing remaining orders
- Basket profit calculation includes only remaining orders
- If you close all orders, EA resets and can open new basket

**Better approach:**
- Let EA manage the basket
- If you want to exit, close entire basket (all orders)
- Or remove EA and manually close all

---

### Q: What if my internet disconnects?

**A:** The EA handles disconnections gracefully:

**During disconnect:**
- Existing orders remain open on broker server
- No new orders can be placed
- TP/SL (if any) still work on server side

**After reconnect:**
- EA restores basket state from existing orders
- Continues managing basket normally
- Logs "Basket restored: X orders"

**Important:** The EA doesn't set per-trade TP/SL, so basket won't auto-close during disconnect. Consider this risk during volatile periods.

---

## Filter & Protection Questions

### Q: What is the spread filter for?

**A:** Blocks trading when spread is abnormally high:

**Why high spread is bad:**
- Worse entry prices (higher cost)
- Harder to reach profit
- Often indicates low liquidity or news events

**When spread spikes:**
- Market open/close
- Major news releases
- Low liquidity periods
- Broker issues

**Setting:** `MaxSpreadPoints` - typical XAUUSD spread is 20-50 points. Set to 50-80 to allow normal trading but block extreme spreads.

---

### Q: What is the volatility filter for?

**A:** Uses ATR (Average True Range) to detect abnormal volatility:

**How it works:**
- Calculates current ATR vs 20-period average
- If current ATR > (average × threshold), volatility is "high"
- Can block new baskets and/or pause grid expansion

**Why it's useful:**
- Prevents entering during wild price swings
- Reduces risk of rapid grid filling
- Protects during news events

**Settings:**
- `ATR_MultiplierThreshold = 2.0` → blocks when ATR is 2× normal
- Lower = more sensitive (1.5-1.8)
- Higher = less sensitive (2.5-3.0)

---

### Q: What is the impulse filter for?

**A:** Detects **sharp, impulsive** price moves (large bar range vs. recent average range), even when ATR (statistical volatility) is not yet elevated. Phase-1 legacy alignment: the EA can pause grid and/or block new basket during impulsive moves.

**How it works:**
- Compares current bar range (or max of last 2 bars) to average range over `ImpulseLookbackBars`
- If current range > average × `ImpulseRangeMultiplier`, impulse is detected
- When enabled: `PauseGridOnImpulse` pauses grid; `BlockNewBasketOnImpulse` blocks new basket

**Why it's useful:**
- Covers fast spikes and acceleration that ATR may lag
- Works alongside the ATR volatility filter (both can block when enabled)

---

### Q: What is exposure-based pause (MinRemainingExposureMoney)?

**A:** Stops the EA from opening **any new trade** (new basket or new grid level) when Free Margin in account currency falls below `MinRemainingExposureMoney`. No change to TP, grid logic, or recovery; the EA simply stops adding. Reaching a kill condition (e.g. margin call) is an accepted outcome.

**How it works:**
- When `UseExposureBasedPause = true` and `AccountFreeMargin() < MinRemainingExposureMoney`, no new basket and no new grid level
- Manual button opens also respect this (no manual open when below threshold)

---

### Q: Should I use trading hours filter?

**A:** Optional, but can be useful:

**Use if:**
- You want to avoid certain sessions (e.g., Asian session for lower volatility)
- You want to avoid market open/close spreads
- You want predictable entry times

**Don't use if:**
- You want 24/5 trading
- Your strategy doesn't depend on session characteristics

**Note:** Filter only blocks NEW basket creation. Existing baskets continue to be managed outside hours.

---

## Troubleshooting Questions

### Q: EA is not opening any trades. Why?

**A:** Check in this order:

1. **AutoTrading enabled?** Green button in toolbar, smiley face on chart
2. **Symbol is XAUUSD?** Check chart symbol
3. **Spread acceptable?** Check current spread vs `MaxSpreadPoints`
4. **Volatility OK?** Check if ATR filter is blocking
5. **Within trading hours?** Check if hours filter is blocking
6. **Entry signal present?** Check MA/RSI/time conditions
7. **Margin sufficient?** Check free margin percentage
8. **Equity DD OK?** Check account drawdown

Review Experts log for specific block reasons.

---

### Q: Grid is not expanding. Why?

**A:** Check:

1. **Basket DD too high?** Grid pauses at `PauseNewTradesAtDDPercent`
2. **Max levels reached?** Check orders vs `MaxGridLevels`
3. **Price hasn't moved enough?** Must move `GridDistancePoints` from last order
4. **Spread too high?** Spread filter applies to grid levels too
5. **Volatility too high?** Volatility filter may be pausing grid
6. **Margin too low?** Margin check applies to all orders

---

### Q: Emergency close triggered unexpectedly. Why?

**A:** Review log for trigger reason:

**Common causes:**
1. **Basket DD reached limit** → Adjust `EmergencyCloseAtDDPercent` or reduce `MaxGridLevels`
2. **Equity DD reached limit** → Adjust `MaxEquityDrawdownPercent` or use smaller lots
3. **Margin too low** → Increase account balance or reduce lot size

Emergency close is working as designed to protect your account. If triggering too often, settings may be too aggressive for your account size.

---

### Q: EA closed basket at loss. Is this a bug?

**A:** No, this is emergency close protection:

**Reasons EA closes at loss:**
1. **Emergency DD limit reached** → Prevents larger loss
2. **Margin protection** → Prevents margin call
3. **Manual close** → You or someone else closed it

Check Experts log for "EMERGENCY CLOSE TRIGGERED" message and reason.

**This is a feature, not a bug.** It's designed to protect your account from catastrophic loss.

---

### Q: Basket profit shows positive but EA hasn't closed. Why?

**A:** Profit must reach `BasketTakeProfitMoney` to close:

**Example:**
- `BasketTakeProfitMoney = 10.0`
- Current profit = $8.50
- EA waits for $10.00 before closing

**If profit keeps fluctuating around TP:**
- This is normal price movement
- EA will close when profit reaches and stays at TP level
- Consider using trailing TP to lock in profit earlier

---

## Performance Questions

### Q: What profit should I expect?

**A:** This EA prioritizes survivability over profit:

**Realistic expectations:**
- **Conservative settings:** 2-5% per month
- **Moderate settings:** 5-10% per month
- **Aggressive settings:** 10-20% per month (with higher risk)

**Important:** Past performance doesn't guarantee future results. Grid systems can have:
- Months with good profit
- Months with drawdown and small profit/loss
- Occasional larger drawdowns during strong trends

Focus on long-term survivability, not short-term gains.

---

### Q: How long does a typical basket stay open?

**A:** Highly variable:

**Quick baskets:** 1-4 hours (price retraces quickly, hits TP)
**Normal baskets:** 4-24 hours (typical ranging market)
**Long baskets:** 1-7 days (strong trend against basket, waiting for retracement)

**Factors:**
- Market conditions (ranging vs trending)
- Grid settings (tighter grid = faster TP, but more risk)
- TP setting (lower TP = faster close, but more frequent trading)

---

### Q: Can I optimize the EA for better profit?

**A:** You can optimize, but be careful:

**Can optimize:**
- Entry mode and indicator parameters
- Grid distance for your typical market conditions
- TP level for your profit targets

**Should NOT optimize:**
- Risk limits (these protect your account)
- Emergency close levels (these prevent catastrophic loss)
- Margin requirements (these prevent margin call)

**Warning:** Over-optimization leads to curve-fitting. Settings that worked perfectly in past may fail in future. Always test optimized settings on demo first.

---

## Advanced Questions

### Q: Can I modify the source code?

**A:** Yes, full MQ4 source is provided:

**You can:**
- Modify entry logic
- Add custom indicators
- Adjust risk calculations
- Add features

**Be careful with:**
- Risk management code (ensure you don't break protections)
- Basket management logic (ensure consistency)
- Order handling (ensure proper error handling)

**Recommendation:** Make backups before modifying. Test thoroughly after any changes.

---

### Q: Can I add stop loss to individual orders?

**A:** Not recommended:

**Why EA doesn't use per-trade SL:**
- Grid/recovery strategy relies on basket-level management
- Individual SLs would break basket logic
- Would prevent recovery from drawdown

**If you add SLs:**
- Basket management will break
- EA may not track orders correctly
- Risk controls may not work as designed

**Better approach:** Use basket-level DD limits (already implemented).

---

### Q: Can I run this with other EAs?

**A:** Yes, but with caution:

**Requirements:**
- Each EA must have unique MagicNumber
- Ensure sufficient margin for all EAs
- Monitor total account risk

**Risks:**
- Multiple EAs compete for margin
- Combined drawdown can be severe
- Harder to track overall risk

**Recommendation:** Run one EA at a time until you're very experienced.

---

### Q: What data does the EA need?

**A:** The EA needs:

**Price data:**
- Current bid/ask prices (real-time)
- Historical bars for indicators (MA, RSI, ATR)
- Minimum: 200 bars of history (for ATR average calculation)

**Account data:**
- Current equity and balance
- Free margin
- Open orders

**No external data required** (no news feeds, no external APIs).

---

## Support Questions

### Q: Where can I get help?

**A:** Resources provided:

1. **README.md** - Full documentation
2. **PARAMETER_GUIDE.md** - Parameter reference
3. **TESTING_GUIDE.md** - Testing procedures
4. **INSTALLATION_GUIDE.md** - Installation steps
5. **FAQ.md** - This file

**For issues:**
- Check Experts log for error messages
- Review relevant documentation section
- Verify settings are correct
- Test on demo to isolate issue

---

### Q: Can you add feature X?

**A:** The EA is delivered as-is with full source code. You can:
- Modify the code yourself
- Hire a developer to add features
- Request modifications from original developer

**Note:** Adding features may affect stability and risk controls. Test thoroughly after any modifications.

---

### Q: Is there a newer version?

**A:** Check with the provider who delivered this EA. Version info is in:
- EA properties window (Version field)
- Source code header (#property version)
- README.md (Version History section)

Current version: **1.0** (Initial Release)

---

## Still Have Questions?

If your question isn't answered here:

1. **Check the documentation** - Most topics are covered in detail in README.md and other guides
2. **Review the source code** - Full MQ4 source is provided with comments
3. **Test on demo** - Many questions can be answered by observing EA behavior
4. **Check the log** - Experts tab often shows why EA is doing (or not doing) something

**Remember:** Understanding how the EA works is essential for using it successfully. Take time to read the documentation and test thoroughly.
