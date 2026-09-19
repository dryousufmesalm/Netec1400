# Installation & Compilation Guide

## Quick Start

1. Copy MQ4 file to MT4 Experts folder
2. Compile in MetaEditor
3. Attach to XAUUSD chart
4. Configure parameters
5. Enable live trading

---

## Detailed Installation Steps

### Step 1: Locate MT4 Data Folder

**Method A: From MT4**
1. Open MetaTrader 4
2. Click **File** → **Open Data Folder**
3. This opens your MT4 data directory

**Method B: Default Locations**

Windows:
```
C:\Users\[YourUsername]\AppData\Roaming\MetaQuotes\Terminal\[BrokerID]\MQL4\
```

Or if installed in Program Files:
```
C:\Program Files (x86)\[BrokerName]\MQL4\
```

### Step 2: Copy MQ4 File

1. Navigate to `MQL4\Experts\` folder
2. Copy `Netec1400_XAUUSD_Grid.mq4` into this folder
3. Verify the file is in the correct location

**Correct path example:**
```
C:\Users\John\AppData\Roaming\MetaQuotes\Terminal\ABC123\MQL4\Experts\Netec1400_XAUUSD_Grid.mq4
```

### Step 3: Compile the EA

#### Option A: Using MetaEditor (Recommended)

1. Open MetaEditor:
   - From MT4: Click **Tools** → **MetaQuotes Language Editor**
   - Or press **F4** in MT4
   - Or double-click the MQ4 file in Windows Explorer

2. In MetaEditor:
   - If file isn't open, click **File** → **Open** and select `Netec1400_XAUUSD_Grid.mq4`
   - Click **Compile** button (or press **F7**)

3. Check compilation results:
   - **Toolbox** window at bottom shows results
   - Look for: `0 error(s), 0 warning(s)`
   - If successful: `Netec1400_XAUUSD_Grid.ex4` is created in same folder

4. Common compilation issues:

   **Issue:** "Cannot open file"
   - **Fix:** Make sure MQ4 file is in `MQL4\Experts\` folder

   **Issue:** Syntax errors
   - **Fix:** File may be corrupted; re-copy original MQ4 file

   **Issue:** Old format warning
   - **Fix:** Ignore if compiles successfully (MQ4 is MT4 format)

#### Option B: Auto-Compile from MT4

1. In MT4, open **Navigator** window (Ctrl+N)
2. Expand **Expert Advisors** section
3. Right-click on `Netec1400_XAUUSD_Grid`
4. Select **Compile**
5. Check for errors in **Experts** tab

### Step 4: Verify Compilation

1. In MT4 Navigator window, look for `Netec1400_XAUUSD_Grid` under Expert Advisors
2. If you see it, compilation was successful
3. If not, refresh Navigator (right-click → Refresh) or restart MT4

### Step 5: Open XAUUSD Chart

1. In MT4, click **File** → **New Chart**
2. Select **XAUUSD** (or GOLD, depending on your broker)
3. Choose timeframe (H1 recommended)

**Note:** If XAUUSD is not in your Market Watch:
1. Right-click Market Watch window
2. Select **Symbols**
3. Find XAUUSD or GOLD
4. Click **Show**

### Step 6: Attach EA to Chart

**Method A: Drag and Drop**
1. In Navigator window, find `Netec1400_XAUUSD_Grid` under Expert Advisors
2. Drag it onto the XAUUSD chart
3. EA settings window appears

**Method B: Double-Click**
1. Double-click `Netec1400_XAUUSD_Grid` in Navigator
2. EA settings window appears

### Step 7: Configure EA Settings

When the EA properties window opens:

#### Common Tab
- **Allow live trading:** ✅ Check this (required)
- **Allow DLL imports:** ⬜ Leave unchecked (not needed)
- **Confirm DLL function calls:** ⬜ Leave unchecked
- **Allow import of external experts:** ⬜ Leave unchecked

#### Inputs Tab
Configure your parameters (see PARAMETER_GUIDE.md for details)

**For first-time testing, use conservative settings:**
```
MagicNumber = 100140
LotSize = 0.01
MaxGridLevels = 5
GridDistancePoints = 800
BasketTakeProfitMoney = 5.0
MaxBasketDrawdownMoney = 50.0
MaxEquityDrawdownPercent = 10.0
EntryMode = 0
```

#### Dependencies Tab
- Leave as default (no dependencies)

### Step 8: Activate EA

1. Click **OK** to close settings window
2. EA attaches to chart
3. Check top-right corner of chart:
   - **😊 Smiley face** = EA is running ✅
   - **😞 Sad face** = EA is disabled ❌

4. If sad face:
   - Click **AutoTrading** button in MT4 toolbar (should turn green)
   - Or press **Ctrl+E**

### Step 9: Verify EA is Running

Check for these indicators:

1. **Top-right corner:** Smiley face 😊
2. **Chart comment:** EA info displayed (Magic, Basket, Orders, etc.)
3. **Experts tab:** Shows "=== Netec1400 XAUUSD Grid EA Initialized ==="
4. **No errors** in Experts or Journal tabs

**Example log output:**
```
2024.01.15 10:30:00  Netec1400_XAUUSD_Grid XAUUSD,H1: === Netec1400 XAUUSD Grid EA Initialized ===
2024.01.15 10:30:00  Netec1400_XAUUSD_Grid XAUUSD,H1: Magic Number: 100140
2024.01.15 10:30:00  Netec1400_XAUUSD_Grid XAUUSD,H1: Lot Size: 0.01
2024.01.15 10:30:00  Netec1400_XAUUSD_Grid XAUUSD,H1: Grid Distance: 800 points
```

---

## Troubleshooting Installation

### EA Not Showing in Navigator

**Possible causes:**
1. MQ4 file in wrong folder
2. Compilation failed
3. Need to refresh Navigator

**Solutions:**
1. Verify MQ4 is in `MQL4\Experts\` folder (not Indicators or Scripts)
2. Open in MetaEditor and compile (check for errors)
3. Right-click Navigator → Refresh
4. Restart MT4

### EA Shows Sad Face

**Possible causes:**
1. AutoTrading disabled
2. "Allow live trading" not checked
3. Symbol mismatch (not XAUUSD)

**Solutions:**
1. Click AutoTrading button in toolbar (should turn green)
2. Right-click chart → Expert Advisors → Properties → Common → Check "Allow live trading"
3. Verify chart is XAUUSD symbol

### EA Initializes But Shows Error

**Error: "This EA only works on XAUUSD"**
- **Cause:** Chart symbol is not XAUUSD
- **Fix:** Attach EA to XAUUSD chart only

**Error: "LotSize must be > 0"**
- **Cause:** Invalid lot size in inputs
- **Fix:** Set LotSize to 0.01 or higher

**Error: "GridDistancePoints must be > 0"**
- **Cause:** Invalid grid distance
- **Fix:** Set GridDistancePoints to 100 or higher

### EA Opens Trades Immediately

**This is normal if:**
- Entry conditions are met (MA trend, RSI signal, or time-based)
- All filters pass (spread, volatility, hours, margin)

**To prevent immediate trading:**
- Set `UseTradingHours = true` and configure hours
- Increase `MaxSpreadPoints` to block trading temporarily
- Or disable AutoTrading until you're ready

### Compilation Warnings

**Warning: "Possible use of uninitialized variable"**
- Usually safe to ignore if compilation succeeds
- EA has been tested and variables are initialized properly

**Warning: "Return value should be checked"**
- Cosmetic warning, can be ignored
- Does not affect EA functionality

---

## Multiple EA Instances

You can run multiple instances of this EA with different settings:

### Requirements
1. Each instance must have a **unique MagicNumber**
2. Each instance should be on a **separate chart** (or same chart with different magic)

### Example Setup

**Instance 1: Conservative**
- Chart: XAUUSD H1
- MagicNumber: 100140
- LotSize: 0.01
- MaxGridLevels: 5

**Instance 2: Moderate**
- Chart: XAUUSD H4
- MagicNumber: 100141 ← Different magic number
- LotSize: 0.01
- MaxGridLevels: 10

**Important:** Different MagicNumbers ensure orders don't interfere with each other.

---

## Updating the EA

If you receive an updated version:

1. **Close existing baskets** (or note open positions)
2. Remove EA from chart (right-click chart → Expert Advisors → Remove)
3. Close MetaEditor if open
4. Replace old MQ4 file with new version
5. Recompile in MetaEditor
6. Restart MT4 (recommended)
7. Attach updated EA to chart

**Note:** If you have open positions, the EA will restore basket state on restart.

---

## Uninstalling the EA

To completely remove the EA:

1. Remove EA from all charts (right-click → Expert Advisors → Remove)
2. Close all open positions manually (if any)
3. Close MT4
4. Delete files:
   - `MQL4\Experts\Netec1400_XAUUSD_Grid.mq4`
   - `MQL4\Experts\Netec1400_XAUUSD_Grid.ex4`
5. Restart MT4

---

## Backup & Portability

### Backing Up Your Settings

**Method 1: Save Set File**
1. When EA settings window is open, click **Save**
2. Choose location and filename (e.g., `Netec1400_Conservative.set`)
3. This saves all input parameters

**Method 2: Template**
1. Configure EA on chart
2. Right-click chart → Template → Save Template
3. Name it (e.g., `XAUUSD_Grid_Conservative`)
4. This saves chart setup + EA settings

### Loading Saved Settings

**Method 1: Load Set File**
1. Open EA settings window
2. Click **Load**
3. Select your saved .set file

**Method 2: Apply Template**
1. Open XAUUSD chart
2. Right-click → Template → Load Template
3. Select your saved template

### Moving EA to Another Computer

1. Copy these files:
   - `Netec1400_XAUUSD_Grid.mq4`
   - `Netec1400_XAUUSD_Grid.ex4` (if compiled)
   - Your .set files (optional)

2. On new computer:
   - Install MT4
   - Copy files to `MQL4\Experts\` folder
   - Compile if only MQ4 was copied
   - Load .set files if you have them

---

## Installation Checklist

- [ ] MT4 data folder located
- [ ] MQ4 file copied to `MQL4\Experts\` folder
- [ ] EA compiled successfully (0 errors)
- [ ] EX4 file created
- [ ] EA appears in Navigator
- [ ] XAUUSD chart opened
- [ ] EA attached to chart
- [ ] "Allow live trading" enabled
- [ ] AutoTrading button green (smiley face)
- [ ] EA initialization message in Experts log
- [ ] On-chart comment displays EA info
- [ ] No errors in Journal tab

---

## Next Steps

After successful installation:

1. **Read documentation:**
   - README.md - Full EA documentation
   - PARAMETER_GUIDE.md - Parameter reference
   - TESTING_GUIDE.md - Testing procedures

2. **Test in Strategy Tester:**
   - Run basic functionality test
   - Verify risk controls
   - Check filter behavior

3. **Demo account:**
   - Run for minimum 2 weeks
   - Monitor daily
   - Validate behavior

4. **Live account:**
   - Start with minimum lot size
   - Gradual increase
   - Continuous monitoring

---

**Installation complete! Ready to test the EA.**

**Remember:** Always test thoroughly on demo before live trading.
