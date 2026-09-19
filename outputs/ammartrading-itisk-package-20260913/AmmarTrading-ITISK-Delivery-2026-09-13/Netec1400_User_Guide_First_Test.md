# Netec1400 XAUUSD Grid EA – User Guide (First Testing Version)

This guide is for the **first testing version** of the Netec1400 XAUUSD Grid Expert Advisor (EA). The EA is a grid/recovery trading system for **XAUUSD (Gold)** on **MetaTrader 4**. You received only the **.ex4 file** (no source code). This document explains how to install it, how it works, and how to use it.

---

## What You Received

- **Netec1400_XAUUSD_Grid.ex4** – The EA, ready to use. No compilation needed.
- **This guide** – The only other file. It contains everything you need.

*If you received a PDF, it is the same as this User Guide. You can also export this guide to PDF for printing or offline reading.*

---

## Installation (EX4 Only)

1. Open **MetaTrader 4**.
2. Click **File** → **Open Data Folder**.
3. In the folder that opens, go to **MQL4** → **Experts**.
4. Copy **Netec1400_XAUUSD_Grid.ex4** into this **Experts** folder.
5. Restart MT4, or in MT4 press **Ctrl+N** to open the Navigator, then right‑click **Expert Advisors** and choose **Refresh**.

You do **not** need MetaEditor or any .mq4 file. The .ex4 file is ready to run.

---

## How to Attach and Enable

1. In MT4, open a **XAUUSD** chart (any timeframe: M1, M5, H1, etc.).
2. Open the **Navigator** (Ctrl+N) and expand **Expert Advisors**.
3. Drag **Netec1400_XAUUSD_Grid** onto the XAUUSD chart.
4. In the window that appears, tick **Allow live trading**. If your broker requires it, also tick **Allow DLL imports**.
5. Click **OK**.
6. Check the **top-right corner** of the chart: you should see a **smiley face**. That means the EA is attached and AutoTrading is on. If you see a sad face, click the **AutoTrading** button in the MT4 toolbar so it turns green.

---

## How It Works (Simple Explanation)

**What the EA does**

The EA manages **one “basket”** of XAUUSD orders at a time. All orders in that basket are either **BUY** or **SELL** (never both). It can **add more orders** at fixed price steps (the “grid”) and **close the whole basket** when a profit target is reached or when safety limits are hit.

**How the first trade starts**

- **Manual (default):** The EA does **not** open the first trade. You open one or more XAUUSD orders yourself (with the same Magic Number as the EA), or you use the **BUY** / **SELL** buttons on the chart if they are visible. The EA “adopts” those orders as the basket and then manages the grid and exit.
- **Semi-Auto:** You choose BUY or SELL in the EA settings. When conditions are OK (spread, volatility, etc.), the EA opens the first trade, then manages the grid and exit.

**Grid**

When price moves **against** the basket by the distance you set (e.g. 50 pips), the EA can add another order in the same direction. It keeps adding levels until a maximum number (e.g. 10) is reached.

**Exit**

The basket closes when the **total profit** reaches your target (e.g. 10 in your account currency). Optional “trailing” can lock in profit. If drawdown or margin limits are hit, the EA can close the whole basket (emergency exit).

**Safety**

The EA uses filters (spread, volatility, sharp moves) to block or pause new trades when the market is unfavourable. Emergency exit closes the whole basket in a controlled way if limits are exceeded.

---

## What You See on the Chart

The EA shows a **panel** on the left side of the chart with live information:

- **Magic** – The EA’s magic number (used to identify its orders).
- **Entry** – “Manual (adopt)” or “Semi-Auto”.
- **Basket** – NONE (no basket yet), BUY, or SELL.
- **Orders** – Number of open orders in the basket and the maximum allowed (e.g. “3 / 10”).
- **Profit** – Current basket profit in your account currency.
- **Basket DD** – Basket drawdown in percent.
- **Equity DD** – Account equity drawdown in percent.
- **Spread** – Current spread in pips.
- **Free Margin** – Free margin as a percent of equity.

In **Semi-Auto** mode, when there is no basket yet, you may also see **“Suggested: BUY (set OpenBasketDirection to open)”** or **“To open: set OpenBasketDirection to BUY or SELL”**.

**BUY / SELL buttons**

If **Show manual buttons** is turned on, you will see **BUY** and **SELL** buttons on the chart. Clicking one opens **one** XAUUSD order with the EA’s magic number. In Manual mode, that order (or orders you place yourself with the same magic) can be adopted as the basket start.

---

## How to Use It – Step by Step

### Manual mode (Entry mode = 0)

1. Attach the EA to a **XAUUSD** chart and enable **AutoTrading** (smiley face).
2. Start the basket in one of these ways:
   - **Option A:** Place one or more XAUUSD orders yourself in MT4, using the **same Magic Number** as the EA (see EA inputs).
   - **Option B:** Click the **BUY** or **SELL** button on the chart (if visible).
3. The EA detects your order(s) and adopts them as the basket. All must be the same direction (all BUY or all SELL). Mixed BUY and SELL are not allowed.
4. After that, the EA adds grid levels when price moves against the basket and closes the basket when your profit target or safety rules are met.

### Semi-Auto mode (Entry mode = 1)

1. Attach the EA to a **XAUUSD** chart and enable **AutoTrading**.
2. Open the EA settings (right‑click chart → Expert Advisors → Properties → Inputs).
3. Set **OpenBasketDirection** to **BUY** or **SELL** (not None).
4. When spread, volatility, and other filters allow it, the EA opens the first trade and then manages the grid and exit.

### Stopping the EA

- **Stop the EA but keep orders open:** Right‑click the chart → **Expert Advisors** → **Remove**. The EA is removed; open orders stay.
- **Stop the EA and close all orders:** Turn off **AutoTrading** (toolbar button gray). Then in **Terminal** → **Trade**, close each order manually if you want.

---

## Main Settings (Plain Language)

Use **actual default values** from the EA. Grouped by what you use them for.

**Identity**

- **Magic Number** (default: 0) – Identifies the EA’s orders. Use a unique value if you run several EAs or other scripts on the same account.

**Lots and grid**

- **Lot size** (default: 0.01) – Lot size per order.
- **Use fixed lot** (default: true) – If true, every grid level uses the same lot; if false, lot can progress within limits.
- **Max grid levels** (default: 10) – Maximum number of orders in the basket.
- **Grid distance (pips)** (default: 50) – How far price must move against the basket before the EA adds another order.
- **Use dynamic grid** (default: true) – Allows the EA to increase grid distance under stress (when enabled).
- **Dynamic grid multiplier** (default: 1.5) – Multiplier used when grid distance is increased.
- **Max lot multiplier** (default: 1.0) – Cap on lot progression when not using fixed lot (1.0 = no increase).

**Entry**

- **Entry mode** (default: 0) – 0 = Manual (you open first trade or use buttons; EA adopts). 1 = Semi-Auto (you set direction; EA opens first trade when filters allow).
- **Open basket direction** (default: 0) – For Semi-Auto only: 0 = None, 1 = BUY, 2 = SELL. Set to BUY or SELL to allow the EA to open the first trade.
- **Suggested direction source** (default: 0) – 0 = None, 1 = MA. Only affects the “Suggested” text on chart; does not open trades.
- **MA period** (default: 50) – Used only for the suggestion display when Suggested direction source = MA.

**Exit**

- **Basket take profit (money)** (default: 10.0) – Close the whole basket when total profit reaches this amount in your account currency.
- **Use trailing basket TP** (default: false) – If true, basket TP can trail to lock in profit.
- **Trailing start** (default: 15.0) – Profit level at which trailing starts (account currency).
- **Trailing step** (default: 5.0) – How much profit can pull back before the basket is closed (account currency).

**Risk**

- **Max basket drawdown (money)** (default: 100.0) – Reference amount in account currency used for basket drawdown percent.
- **Max equity drawdown (%)** (default: 20.0) – Blocks new baskets when account equity drawdown exceeds this percent.
- **Pause new trades at DD (%)** (default: 50.0) – When DD-based pause is enabled, new grid levels are paused at this basket DD percent.
- **Increase grid distance at DD (%)** (default: 30.0) – When DD-based options are enabled, grid distance can increase at this basket DD percent.
- **Emergency close at DD (%)** (default: 80.0) – Closes the whole basket when basket drawdown reaches this percent.
- **Min free margin (%)** (default: 30.0) – EA will not open new trades if free margin falls below this percent of equity.
- **Use DD-based grid pause** (default: false) – If true, pause and grid expansion can be tied to basket drawdown percent; if false, grid behaviour is driven by price and market filters only.

**Emergency**

- **Use emergency exit** (default: true) – Enable automatic emergency close when limits are hit.
- **Max basket slippage (pips)** (default: 5) – Maximum slippage allowed when closing the basket in pips.

**Filters**

- **Max spread (pips)** (default: 5) – No new trades if spread is above this.
- **Use volatility filter** (default: true) – Blocks or pauses trading when volatility is high (ATR-based).
- **ATR period** (default: 14) – Period for ATR in the volatility filter.
- **ATR multiplier threshold** (default: 2.0) – Volatility threshold multiplier.
- **Block new basket above volatility** (default: true) – Do not open a new basket when volatility is high.
- **Pause grid above volatility** (default: true) – Do not add grid levels when volatility is high.
- **Use impulse filter** (default: true) – Detects sharp price moves and can block or pause.
- **Impulse lookback bars** (default: 5) – Bars used to measure “normal” range for impulse.
- **Impulse range multiplier** (default: 2.0) – Current range above average × this = impulse.
- **Pause grid on impulse** (default: true) – Do not add grid levels during impulse.
- **Block new basket on impulse** (default: true) – Do not open a new basket during impulse.
- **Use exposure-based pause** (default: true) – Pause new trades when free margin is below threshold.
- **Min remaining exposure (money)** (default: 100.0) – Minimum free margin in account currency to allow new trades.

**Session**

- **Use trading hours** (default: false) – If true, trading is only allowed between start and end hour.
- **Start hour** (default: 0) – Start of allowed trading (broker time).
- **End hour** (default: 23) – End of allowed trading (broker time).

**Manual buttons**

- **Show manual buttons** (default: true) – Show BUY/SELL buttons on the chart (useful in Manual mode and in Strategy Tester).

### Recommended for first test

| Setting            | Suggested value | Note                          |
|--------------------|-----------------|-------------------------------|
| Lot size           | 0.01            | Keep small for testing        |
| Max grid levels    | 5–10            | Limit exposure                |
| Grid distance      | 50 pips         | Default is fine to start      |
| Basket take profit | 10 (or less)    | In your account currency      |
| Emergency close at DD (%) | 70–80   | So emergency closes before extreme loss |
| Max equity drawdown (%)   | 10–20   | Conservative                  |
| Use demo account   | Yes             | Always for first testing      |

---

## First Testing – What to Expect

- Use a **demo account** and **conservative settings** (e.g. small lot, limited max grid levels, modest take profit and drawdown limits).
- **Normal behaviour:**  
  - **Basket: NONE** until you open an order (Manual) or set direction (Semi-Auto).  
  - Then **Orders** may increase (grid) as price moves against the basket.  
  - When total profit reaches your target (or trailing/emergency rules apply), the basket closes and resets to NONE.
- In the **Experts** tab you will see messages such as “Basket adopted”, “Basket closed”, “Emergency close”, etc. Check this tab regularly.
- Test for **at least several days** so you see different market conditions (ranging, trending, volatile). The EA may not open or may pause when spread or volatility is high; that is normal protection.

---

## Safety and Emergency

**Emergency exit**

When **Use emergency exit** is on, the EA will close the **whole basket** in a controlled way if:

- Basket drawdown reaches **Emergency close at DD (%)**, or  
- Equity drawdown or free margin limits are breached.

It uses the **Max basket slippage (pips)** setting so that closure is not at any price. This is to limit damage, not to force blind liquidation.

**How to stop the EA**

- **Remove EA only:** Right‑click chart → **Expert Advisors** → **Remove**. Orders stay open.
- **Stop all trading:** Click **AutoTrading** in the toolbar (turn it off). Then close orders manually in **Terminal** → **Trade** if you want.

**Risk disclaimer**

Grid systems can have **large drawdowns** in strong trending markets. This EA includes risk controls, but **no EA can guarantee profits or prevent all losses**. Always test on demo first. Do not risk more than you can afford to lose. Monitor the EA regularly, especially around news. Past performance does not guarantee future results.

---

## Troubleshooting

**EA does nothing / no basket**

- Chart must be **XAUUSD** (Gold). The EA does not work on other symbols.
- **AutoTrading** must be **on** (green button, smiley face on chart).
- **Manual mode:** Did you open an XAUUSD order with the **same Magic Number** as the EA, or click **BUY** or **SELL** on the chart?
- **Semi-Auto mode:** Did you set **OpenBasketDirection** to **BUY** or **SELL** (not None)?
- Check **Experts** tab for messages (e.g. “Spread too high”, “Volatility too high”, “Exposure pause”). Filters may be blocking new trades.

**No new grid levels**

- Spread may be above **Max spread (pips)**.
- Volatility or impulse filters may be pausing the grid.
- **Max grid levels** may already be reached.
- Free margin may be below **Min remaining exposure** or **Min free margin (%)**.

**Errors in the log**

- **“This EA only works on XAUUSD”** – Attach the EA to a **XAUUSD** chart.
- **“LotSize must be > 0”** – In EA inputs, set **Lot size** to e.g. **0.01**.
- **“Mixed direction; cannot adopt”** – In Manual mode, use only BUY or only SELL for the basket, not both.

---

## Summary – Quick Reference

1. **Install:** Copy **Netec1400_XAUUSD_Grid.ex4** into **MT4 Data Folder → MQL4 → Experts**. Refresh Navigator if needed.
2. **Attach:** Open a **XAUUSD** chart and drag the EA onto it. Enable **Allow live trading**. Click OK.
3. **Enable:** Ensure **AutoTrading** is on (smiley face on chart).
4. **Choose mode:** **Manual (0)** – you open the first trade or use BUY/SELL buttons; **Semi-Auto (1)** – set **OpenBasketDirection** to BUY or SELL.
5. **Set risk and exit:** Use conservative values for first test (e.g. small lot, 5–10 max levels, modest basket take profit and emergency close).
6. **Monitor:** Watch the **on-chart panel** (Basket, Orders, Profit, DD%, Spread, Free Margin) and the **Experts** tab for messages.

---

**Version:** First testing version  
**Symbol:** XAUUSD (Gold) only  
**Platform:** MetaTrader 4  
**File:** Netec1400_XAUUSD_Grid.ex4
