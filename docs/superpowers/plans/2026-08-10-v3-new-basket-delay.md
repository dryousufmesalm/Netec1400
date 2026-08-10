# V3 New-Basket Entry Delay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a deterministic, revalidated delay before every new V3 basket while preserving byte-for-byte-equivalent trading decisions when the delay input is zero.

**Architecture:** Keep the feature inside the MQL5 V3 first-entry path using three small state variables and two focused helpers: one resets pending state and one starts/restarts/checks the timer for the current signal direction. Existing gate, signal, order-send, and basket-management code remains authoritative.

**Tech Stack:** MQL5, MetaEditor 5 command-line compiler, PowerShell regression checks, MetaTrader 5 Strategy Tester.

## Global Constraints

- Modify only `AmmarTradingGoldEA - ref reset every bar - V3.mq5` in production code.
- Do not modify V2 or MQ4 files.
- `NewBasketDelaySeconds` defaults to `0` and must preserve current V3 behavior.
- Re-check all existing entry and safety conditions on every tick during a pending delay.
- Never execute a stale signal.

---

### Task 1: Lock the V3 source contract

**Files:**
- Create: `tests/Test-V3NewBasketDelay.ps1`
- Test: `AmmarTradingGoldEA - ref reset every bar - V3.mq5`

**Interfaces:**
- Consumes: the authoritative V3 source path.
- Produces: a failing-before/passing-after regression command for the delay integration and V2 isolation.

- [ ] **Step 1: Write the failing regression check**

Assert the zero-default input, pending state helpers, reset behavior, unchanged grid path, and absence of the new input in all V2 sources.

- [ ] **Step 2: Run the check and verify RED**

Run: `powershell -ExecutionPolicy Bypass -File tests/Test-V3NewBasketDelay.ps1`

Expected: FAIL because `NewBasketDelaySeconds` is absent from V3.

### Task 2: Add the minimal pending-entry state machine

**Files:**
- Modify: `AmmarTradingGoldEA - ref reset every bar - V3.mq5`
- Test: `tests/Test-V3NewBasketDelay.ps1`

**Interfaces:**
- Consumes: existing `OpenAutoEntry()`, `CoreOpenGatesPass(true)`, BUY/SELL direction constants, and `TimeCurrent()`.
- Produces: `ResetPendingNewBasketEntry()` and `NewBasketDelayElapsed(int direction)`.

- [ ] **Step 1: Add input and state**

Add `NewBasketDelaySeconds = 0`, a pending flag, start time, and direction.

- [ ] **Step 2: Integrate cancellation and expiry checks**

Reset pending state when gates or the signal fail, restart it when direction changes, wait while elapsed seconds are below the input, and clear it after successful entry.

- [ ] **Step 3: Run the regression check and verify GREEN**

Run: `powershell -ExecutionPolicy Bypass -File tests/Test-V3NewBasketDelay.ps1`

Expected: PASS with every contract check satisfied.

### Task 3: Compile and prove compatibility

**Files:**
- Verify: `AmmarTradingGoldEA - ref reset every bar - V3.mq5`

**Interfaces:**
- Consumes: modified V3 source and the locally installed MetaEditor 5 compiler.
- Produces: a compile log and, where available, a zero-delay Strategy Tester parity comparison.

- [ ] **Step 1: Compile V3**

Run MetaEditor 5 with `/compile:` and `/log:` against the V3 source.

Expected: zero errors.

- [ ] **Step 2: Run zero-delay parity test**

Use identical symbol, timeframe, dates, tick model, spread, deposit, and existing V3 inputs for pre-change and post-change builds, with `NewBasketDelaySeconds=0` in the post-change build.

Expected: matching deal timestamps, directions, volumes, and results.

- [ ] **Step 3: Review scope**

Run `git diff -- "AmmarTradingGoldEA - ref reset every bar - V3.mq5" tests/Test-V3NewBasketDelay.ps1` and confirm no V2 or MQ4 source changed.
