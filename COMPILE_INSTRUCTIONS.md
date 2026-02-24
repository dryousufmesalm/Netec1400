# How to Compile the EA

## Quick Compilation Guide

Follow these steps to compile `Netec1400_XAUUSD_Grid.mq4` into the executable `Netec1400_XAUUSD_Grid.ex4`.

---

## Method 1: Using MetaEditor (Recommended)

### Step 1: Open MetaEditor

**From MT4:**
- Click **Tools** → **MetaQuotes Language Editor**
- Or press **F4**

**From Windows:**
- Find MetaEditor in your MT4 installation folder
- Usually: `C:\Program Files (x86)\[BrokerName]\metaeditor.exe`

### Step 2: Open the MQ4 File

1. In MetaEditor, click **File** → **Open**
2. Navigate to your MT4 data folder:
   - Usually: `C:\Users\[YourName]\AppData\Roaming\MetaQuotes\Terminal\[BrokerID]\MQL4\Experts\`
3. Select `Netec1400_XAUUSD_Grid.mq4`
4. Click **Open**

**Or:**
- Double-click `Netec1400_XAUUSD_Grid.mq4` in Windows Explorer
- It should open in MetaEditor automatically

### Step 3: Compile

1. Click the **Compile** button in the toolbar
2. Or press **F7**
3. Or click **File** → **Compile**

### Step 4: Check Results

**Look at the bottom "Toolbox" window:**

**Success looks like:**
```
Compiling 'Netec1400_XAUUSD_Grid.mq4'...
0 error(s), 0 warning(s)
Compilation successful
```

**The EX4 file is automatically created in the same folder as the MQ4.**

---

## Method 2: From MT4 Navigator

### Step 1: Copy MQ4 to Experts Folder

1. Open MT4
2. Click **File** → **Open Data Folder**
3. Navigate to `MQL4\Experts\`
4. Copy `Netec1400_XAUUSD_Grid.mq4` here

### Step 2: Refresh Navigator

1. In MT4, press **Ctrl+N** to open Navigator
2. Right-click on **Expert Advisors**
3. Click **Refresh**

### Step 3: Compile from Navigator

1. Find `Netec1400_XAUUSD_Grid` in the Expert Advisors list
2. Right-click on it
3. Select **Compile**

### Step 4: Check Results

Look at the **Experts** tab at the bottom of MT4 for compilation results.

---

## Verifying Successful Compilation

### Check 1: EX4 File Exists

1. Open MT4 data folder (**File** → **Open Data Folder**)
2. Navigate to `MQL4\Experts\`
3. You should see both:
   - `Netec1400_XAUUSD_Grid.mq4` (source)
   - `Netec1400_XAUUSD_Grid.ex4` (compiled)

### Check 2: EA Appears in Navigator

1. Open Navigator in MT4 (**Ctrl+N**)
2. Expand **Expert Advisors**
3. `Netec1400_XAUUSD_Grid` should be listed

### Check 3: EA Can Be Attached

1. Open a chart (any symbol for testing)
2. Drag `Netec1400_XAUUSD_Grid` from Navigator onto the chart
3. Settings window should appear
4. Click **Cancel** (just testing)

If all 3 checks pass, compilation was successful! ✅

---

## Troubleshooting Compilation

### Error: "Cannot open file"

**Cause:** MQ4 file not in correct location

**Fix:**
1. Verify MQ4 is in `MQL4\Experts\` folder
2. Not in `MQL4\Indicators\` or `MQL4\Scripts\`
3. Check file name is exactly: `Netec1400_XAUUSD_Grid.mq4`

---

### Error: "Syntax error" or "Undeclared identifier"

**Cause:** File may be corrupted or incomplete

**Fix:**
1. Re-copy the original MQ4 file
2. Don't modify the file before first compilation
3. Ensure file wasn't truncated during copy

---

### Warning: "Possible use of uninitialized variable"

**Status:** Can be ignored if compilation succeeds

**Explanation:** 
- This is a cosmetic warning
- EA has been tested and works correctly
- Variables are properly initialized

**Action:** None needed if you see "0 error(s)"

---

### Warning: "Return value should be checked"

**Status:** Can be ignored if compilation succeeds

**Explanation:**
- Cosmetic warning about function return values
- Does not affect EA functionality
- Common in MQL4 code

**Action:** None needed if you see "0 error(s)"

---

### Error: "Old format of property" or similar

**Cause:** Older MT4 build

**Fix:**
1. Update MT4 to latest version
2. Or ignore if compilation still succeeds
3. MQ4 format is compatible with MT4 builds 600+

---

### No EX4 File Created

**Possible causes:**

1. **Compilation had errors**
   - Check Toolbox window for error messages
   - Fix errors and recompile

2. **Insufficient permissions**
   - Run MetaEditor as Administrator
   - Right-click → Run as Administrator

3. **Antivirus blocking**
   - Temporarily disable antivirus
   - Add MT4 folder to antivirus exceptions

4. **Read-only folder**
   - Check folder properties
   - Ensure it's not read-only

---

## Compilation Best Practices

### Before Compiling

✅ Close any other instances of MetaEditor  
✅ Ensure MQ4 file is not open in another editor  
✅ Verify file is in correct location  
✅ Make a backup of the MQ4 file  

### During Compilation

✅ Watch the Toolbox window for messages  
✅ Note any warnings (usually safe to ignore)  
✅ Verify "0 error(s)" message  
✅ Check EX4 file is created  

### After Compilation

✅ Refresh MT4 Navigator  
✅ Verify EA appears in list  
✅ Test attachment to chart  
✅ Keep MQ4 file (don't delete it)  

---

## Recompilation

### When to Recompile

- After modifying the MQ4 source code
- After updating MT4 to a new build
- If EX4 file is deleted or corrupted

### How to Recompile

1. Open MQ4 in MetaEditor
2. Press **F7** (Compile)
3. New EX4 is created (overwrites old one)
4. Refresh MT4 Navigator
5. Restart any charts using the EA

**Note:** If EA is currently running on a chart, remove it before recompiling, then reattach after.

---

## Multiple MT4 Installations

### If You Have Multiple MT4 Accounts/Brokers

Each MT4 installation has its own data folder:

```
C:\Users\[Name]\AppData\Roaming\MetaQuotes\Terminal\
├── ABC123\  ← Broker A
│   └── MQL4\Experts\
└── XYZ789\  ← Broker B
    └── MQL4\Experts\
```

**You must:**
1. Copy MQ4 to each installation's `MQL4\Experts\` folder
2. Compile in each installation separately
3. Each will have its own EX4 file

**Or:**
- Compile once in one installation
- Copy both MQ4 and EX4 to other installations
- May need to recompile if MT4 builds differ

---

## Compilation Output Files

### Files Created

**Input:**
- `Netec1400_XAUUSD_Grid.mq4` (source code)

**Output:**
- `Netec1400_XAUUSD_Grid.ex4` (executable)

**Optional (if debugging):**
- `Netec1400_XAUUSD_Grid.log` (compilation log)

### File Sizes

**Approximate sizes:**
- MQ4: ~50-60 KB (text file)
- EX4: ~20-30 KB (binary file)

If sizes are significantly different, file may be corrupted.

---

## Advanced: Command-Line Compilation

### Using MetaEditor Command Line

For advanced users or automation:

```batch
metaeditor.exe /compile:"C:\Path\To\Netec1400_XAUUSD_Grid.mq4"
```

**Paths:**
- MetaEditor: Usually in MT4 installation folder
- MQ4 file: Full path to the source file

**Output:**
- EX4 created in same folder as MQ4
- Compilation log printed to console

---

## Compilation Checklist

Use this checklist to ensure successful compilation:

- [ ] MT4 installed and working
- [ ] MetaEditor accessible (F4 from MT4)
- [ ] MQ4 file copied to `MQL4\Experts\` folder
- [ ] MQ4 file opened in MetaEditor
- [ ] Compile button clicked (F7)
- [ ] Toolbox shows "0 error(s)"
- [ ] EX4 file exists in same folder
- [ ] MT4 Navigator refreshed
- [ ] EA appears in Navigator list
- [ ] EA can be attached to chart

If all items checked, compilation successful! ✅

---

## Next Steps After Compilation

1. ✅ Compilation successful
2. → Read [QUICK_START.md](QUICK_START.md) for setup
3. → Attach EA to XAUUSD chart
4. → Configure parameters
5. → Start testing

---

## Quick Reference

| Action | Method |
|--------|--------|
| Open MetaEditor | F4 in MT4 |
| Compile | F7 in MetaEditor |
| Check result | Look at Toolbox window |
| Refresh Navigator | Right-click → Refresh |
| Find EX4 | Same folder as MQ4 |

---

## Support

If compilation fails after following this guide:

1. Check **Toolbox** window for specific error messages
2. Review **Troubleshooting** section above
3. Verify MT4 is updated to latest build
4. Ensure MQ4 file is complete and not corrupted
5. Try on a different computer/MT4 installation

---

**Compilation should take less than 1 second and produce no errors.**

**If successful, you're ready to use the EA!** 🎉

---

**Next:** [QUICK_START.md](QUICK_START.md) for setup and configuration
