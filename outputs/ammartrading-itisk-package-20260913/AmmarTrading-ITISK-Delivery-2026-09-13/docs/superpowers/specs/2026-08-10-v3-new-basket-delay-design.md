# V3 New-Basket Entry Delay Design

## Scope

Add one deterministic delay input to the latest MQL5 V3 source only:

`AmmarTradingGoldEA - ref reset every bar - V3.mq5`

Do not modify V2, MQ4, grid additions, basket management, exits, trailing, lot sizing, telemetry, or existing safety rules.

## Input

```mql5
input int NewBasketDelaySeconds = 0; // seconds to confirm each new-basket signal
```

`0` bypasses all new pending-entry behavior and follows the existing V3 entry path immediately.

## Behavior

When V3 is flat, a pending timer starts only after the existing new-basket gates pass and the existing price logic produces a BUY or SELL signal. The EA records the signal direction and server time but does not place an order while the configured delay remains.

Every subsequent tick re-runs the existing gates and price/direction calculation. If a gate fails, the signal disappears, or the direction changes, the current pending attempt is cancelled. A currently valid different direction may begin a fresh timer on that tick.

When the timer expires, the existing gates and signal have already been freshly evaluated on that tick. The EA opens the basket through the unchanged order-send and post-open path only if the direction still matches the pending direction. A successful first order clears the pending state.

Pending state is also cleared whenever a basket exists or the EA enters kill/cooldown or exposure-blocked state while flat. Grid additions never consult the new timer.

## Compatibility Invariants

- `NewBasketDelaySeconds = 0` executes the current V3 first-entry path without waiting.
- `OpenTime` retains its current minutes-based cooldown semantics.
- `SpeedEA` retains its current any-open cooldown semantics.
- `CoreOpenGatesPass(false)` and `HandleGrid()` are unchanged.
- All existing entry calculations and order parameters remain unchanged.
- The timer uses `TimeCurrent()` and is therefore deterministic for the same tick stream and input value.

## Verification

- A source-contract regression check confirms the input defaults to zero, pending state is isolated to V3, invalid signals and failed gates reset pending state, direction changes restart the timer, successful entry clears it, and grid logic does not reference the delay.
- Compile the modified V3 with MetaEditor and require zero compilation errors.
- Compare a Strategy Tester run at `NewBasketDelaySeconds = 0` against the pre-change V3 baseline using identical data and settings; deal timestamps, directions, sizes, and results must match.
