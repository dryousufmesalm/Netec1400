# EA Logic Flowcharts

This document provides visual flowcharts to understand the EA's decision-making process.

---

## Main OnTick Flow

```mermaid
flowchart TD
    Start[OnTick Called] --> UpdateDisplay[Update Chart Comment]
    UpdateDisplay --> CheckState[Check Basket State Consistency]
    CheckState --> EmergencyCheck{UseEmergencyExit?}
    
    EmergencyCheck -->|Yes| EmergencyLogic[Check Emergency Conditions]
    EmergencyCheck -->|No| BasketCheck{Basket Exists?}
    EmergencyLogic --> BasketCheck
    
    BasketCheck -->|No| EntryLogic[Handle Entry Logic]
    BasketCheck -->|Yes| ExitLogic[Handle Exit Logic]
    
    ExitLogic --> GridLogic[Handle Grid Logic]
    GridLogic --> End[Wait for Next Tick]
    EntryLogic --> End
```

---

## Entry Logic Flow

```mermaid
flowchart TD
    Start[Entry Logic] --> SymbolCheck{Symbol = XAUUSD?}
    SymbolCheck -->|No| BlockEntry[Block Entry]
    SymbolCheck -->|Yes| SpreadCheck{Spread OK?}
    
    SpreadCheck -->|No| BlockEntry
    SpreadCheck -->|Yes| VolatilityCheck{Volatility OK?}
    
    VolatilityCheck -->|No| BlockEntry
    VolatilityCheck -->|Yes| HoursCheck{Within Hours?}
    
    HoursCheck -->|No| BlockEntry
    HoursCheck -->|Yes| MarginCheck{Margin OK?}
    
    MarginCheck -->|No| BlockEntry
    MarginCheck -->|Yes| EquityDDCheck{Equity DD OK?}
    
    EquityDDCheck -->|No| BlockEntry
    EquityDDCheck -->|Yes| EntrySignal[Determine Entry Direction]
    
    EntrySignal --> SignalValid{Signal Valid?}
    SignalValid -->|No| BlockEntry
    SignalValid -->|Yes| OpenTrade[Open First Trade]
    
    OpenTrade --> Success{Order Opened?}
    Success -->|Yes| SetBasket[Set Basket State]
    Success -->|No| LogError[Log Error]
    
    SetBasket --> End[Entry Complete]
    LogError --> End
    BlockEntry --> End
```

---

## Entry Mode Decision

```mermaid
flowchart TD
    Start[Determine Entry Direction] --> ModeCheck{Entry Mode?}
    
    ModeCheck -->|0 MA| MALogic[Calculate MA]
    ModeCheck -->|1 RSI| RSILogic[Calculate RSI]
    ModeCheck -->|2 Time| TimeLogic[Check Hour]
    
    MALogic --> MACompare{Price vs MA?}
    MACompare -->|Price > MA| ReturnBuy[Return BUY]
    MACompare -->|Price < MA| ReturnSell[Return SELL]
    
    RSILogic --> RSICompare{RSI Level?}
    RSICompare -->|RSI < Oversold| ReturnBuy
    RSICompare -->|RSI > Overbought| ReturnSell
    RSICompare -->|Between| NoSignal[Return No Signal]
    
    TimeLogic --> HourCheck{Hour = SessionStart?}
    HourCheck -->|No| NoSignal
    HourCheck -->|Yes| MAForTime[Use MA for Direction]
    MAForTime --> MACompare
    
    ReturnBuy --> End[Direction Determined]
    ReturnSell --> End
    NoSignal --> End
```

---

## Grid Logic Flow

```mermaid
flowchart TD
    Start[Grid Logic] --> BasketDDCheck[Calculate Basket DD]
    BasketDDCheck --> PauseCheck{DD >= Pause Threshold?}
    
    PauseCheck -->|Yes| BlockGrid[Block Grid Expansion]
    PauseCheck -->|No| SpreadCheck{Spread OK?}
    
    SpreadCheck -->|No| BlockGrid
    SpreadCheck -->|Yes| VolatilityCheck{Volatility OK?}
    
    VolatilityCheck -->|No| BlockGrid
    VolatilityCheck -->|Yes| MarginCheck{Margin OK?}
    
    MarginCheck -->|No| BlockGrid
    MarginCheck -->|Yes| LevelCheck{Orders < MaxLevels?}
    
    LevelCheck -->|No| BlockGrid
    LevelCheck -->|Yes| DynamicCheck{DD >= Dynamic Threshold?}
    
    DynamicCheck -->|Yes| IncreaseDistance[Grid Distance × Multiplier]
    DynamicCheck -->|No| NormalDistance[Normal Grid Distance]
    
    IncreaseDistance --> DistanceCheck{Price Moved Enough?}
    NormalDistance --> DistanceCheck
    
    DistanceCheck -->|No| BlockGrid
    DistanceCheck -->|Yes| LotCalc[Calculate Lot Size]
    
    LotCalc --> OpenGrid[Open Grid Level]
    OpenGrid --> Success{Order Opened?}
    
    Success -->|Yes| UpdateState[Update Last Grid Price]
    Success -->|No| LogError[Log Error]
    
    UpdateState --> End[Grid Complete]
    LogError --> End
    BlockGrid --> End
```

---

## Exit Logic Flow

```mermaid
flowchart TD
    Start[Exit Logic] --> CalcProfit[Calculate Basket Profit]
    CalcProfit --> UpdateHigh[Update Highest Profit]
    UpdateHigh --> TPCheck{Profit >= TP?}
    
    TPCheck -->|Yes| CloseTP[Close Basket - TP Reached]
    TPCheck -->|No| TrailingCheck{Trailing Enabled?}
    
    TrailingCheck -->|No| End[Exit Complete]
    TrailingCheck -->|Yes| TrailingActive{Highest >= TrailingStart?}
    
    TrailingActive -->|No| End
    TrailingActive -->|Yes| TrailingCalc[Calculate Trail Threshold]
    
    TrailingCalc --> TrailingTrigger{Profit <= Threshold?}
    TrailingTrigger -->|Yes| CloseTrail[Close Basket - Trailing TP]
    TrailingTrigger -->|No| End
    
    CloseTP --> End
    CloseTrail --> End
```

---

## Emergency Close Logic

```mermaid
flowchart TD
    Start[Emergency Check] --> BasketCheck{Basket Exists?}
    BasketCheck -->|No| End[No Action]
    
    BasketCheck -->|Yes| BasketDDCheck[Calculate Basket DD]
    BasketDDCheck --> BasketDDLimit{DD >= Emergency Limit?}
    
    BasketDDLimit -->|Yes| TriggerEmergency[Trigger Emergency]
    BasketDDLimit -->|No| EquityDDCheck[Calculate Equity DD]
    
    EquityDDCheck --> EquityDDLimit{DD >= Equity Limit?}
    EquityDDLimit -->|Yes| TriggerEmergency
    EquityDDLimit -->|No| MarginCheck[Calculate Free Margin %]
    
    MarginCheck --> MarginLimit{Margin < Critical Level?}
    MarginLimit -->|Yes| TriggerEmergency
    MarginLimit -->|No| End
    
    TriggerEmergency --> LogReason[Log Emergency Reason]
    LogReason --> CloseBasket[Close All Basket Orders]
    CloseBasket --> End
```

---

## Basket Close Process

```mermaid
flowchart TD
    Start[Close Basket] --> LogStart[Log Closure Reason & Profit]
    LogStart --> InitAttempts[attempts = 0]
    
    InitAttempts --> LoopStart{Orders Remain?}
    LoopStart -->|No| ResetState[Reset Basket State]
    LoopStart -->|Yes| AttemptsCheck{attempts < 3?}
    
    AttemptsCheck -->|No| ResetState
    AttemptsCheck -->|Yes| IncrementAttempts[attempts++]
    
    IncrementAttempts --> LoopOrders[Loop Through Orders]
    LoopOrders --> SelectOrder{Order Selected?}
    
    SelectOrder -->|No| NextOrder[Next Order]
    SelectOrder -->|Yes| CheckMagic{Magic = EA Magic?}
    
    CheckMagic -->|No| NextOrder
    CheckMagic -->|Yes| CloseOrder[Close Order]
    
    CloseOrder --> CloseSuccess{Closed?}
    CloseSuccess -->|Yes| LogSuccess[Log Success]
    CloseSuccess -->|No| LogFail[Log Failure]
    
    LogSuccess --> NextOrder
    LogFail --> Sleep1[Sleep 1s]
    Sleep1 --> NextOrder
    
    NextOrder --> MoreOrders{More Orders?}
    MoreOrders -->|Yes| SelectOrder
    MoreOrders -->|No| Sleep2[Sleep 2s]
    
    Sleep2 --> LoopStart
    
    ResetState --> LogComplete[Log Completion]
    LogComplete --> End[Basket Closed]
```

---

## Filter Decision Tree

```mermaid
flowchart TD
    Start[Check Filters] --> SpreadCalc[Calculate Current Spread]
    SpreadCalc --> SpreadCompare{Spread <= Max?}
    
    SpreadCompare -->|No| FailSpread[Fail: Spread Too High]
    SpreadCompare -->|Yes| VolatilityEnabled{Volatility Filter?}
    
    VolatilityEnabled -->|No| HoursEnabled{Hours Filter?}
    VolatilityEnabled -->|Yes| ATRCalc[Calculate ATR]
    
    ATRCalc --> ATRAvg[Calculate 20-period ATR Avg]
    ATRAvg --> ATRCompare{ATR > Avg × Threshold?}
    
    ATRCompare -->|Yes| VolatilityType{For New Basket?}
    ATRCompare -->|No| HoursEnabled
    
    VolatilityType -->|Yes| BlockBasket{Block New Basket?}
    VolatilityType -->|No| PauseGrid{Pause Grid?}
    
    BlockBasket -->|Yes| FailVolatility[Fail: Volatility Too High]
    BlockBasket -->|No| HoursEnabled
    
    PauseGrid -->|Yes| FailVolatility
    PauseGrid -->|No| HoursEnabled
    
    HoursEnabled -->|No| MarginCalc[Calculate Free Margin %]
    HoursEnabled -->|Yes| HourCheck{Within Hours?}
    
    HourCheck -->|No| FailHours[Fail: Outside Hours]
    HourCheck -->|Yes| MarginCalc
    
    MarginCalc --> MarginCompare{Margin >= Min?}
    MarginCompare -->|No| FailMargin[Fail: Margin Too Low]
    MarginCompare -->|Yes| PassFilters[Pass: All Filters OK]
    
    FailSpread --> End[Filters Failed]
    FailVolatility --> End
    FailHours --> End
    FailMargin --> End
    PassFilters --> Success[Filters Passed]
```

---

## Risk Level Decision Tree

```mermaid
flowchart TD
    Start[Calculate Risk Levels] --> BasketDD[Calculate Basket DD %]
    BasketDD --> Level1{DD >= Increase Grid?}
    
    Level1 -->|No| NormalRisk[Risk Level: NORMAL]
    Level1 -->|Yes| Level2{DD >= Pause Trades?}
    
    Level2 -->|No| IncreasedRisk[Risk Level: INCREASED]
    Level2 -->|Yes| Level3{DD >= Emergency?}
    
    Level3 -->|No| PausedRisk[Risk Level: PAUSED]
    Level3 -->|Yes| EmergencyRisk[Risk Level: EMERGENCY]
    
    NormalRisk --> Actions1[Actions: Normal grid expansion]
    IncreasedRisk --> Actions2[Actions: Increase grid distance]
    PausedRisk --> Actions3[Actions: No new grid levels]
    EmergencyRisk --> Actions4[Actions: Close basket immediately]
    
    Actions1 --> End[Risk Assessment Complete]
    Actions2 --> End
    Actions3 --> End
    Actions4 --> End
```

---

## State Machine

```mermaid
stateDiagram-v2
    [*] --> NoBasket: EA Initialized
    
    NoBasket --> CheckingEntry: OnTick
    CheckingEntry --> NoBasket: Filters Failed
    CheckingEntry --> BasketOpen: Entry Signal + Order Opened
    
    BasketOpen --> ManagingBasket: OnTick
    ManagingBasket --> AddingGrid: Price Moved + Filters OK
    ManagingBasket --> CheckingExit: Check Exit Conditions
    
    AddingGrid --> ManagingBasket: Grid Level Added
    
    CheckingExit --> ManagingBasket: No Exit Condition
    CheckingExit --> ClosingBasket: TP Reached
    CheckingExit --> ClosingBasket: Trailing TP Triggered
    CheckingExit --> EmergencyClose: Emergency Condition
    
    ClosingBasket --> NoBasket: All Orders Closed
    EmergencyClose --> NoBasket: All Orders Closed
    
    NoBasket --> [*]: EA Removed
```

---

## Lot Size Calculation

```mermaid
flowchart TD
    Start[Calculate Lot Size] --> FixedCheck{UseFixedLot?}
    
    FixedCheck -->|Yes| ReturnFixed[Return LotSize]
    FixedCheck -->|No| GetOrderCount[Get Current Order Count]
    
    GetOrderCount --> CalcMultiplier[multiplier = 1.0 + count - 1 × 0.1]
    CalcMultiplier --> CheckMax{multiplier > MaxLotMultiplier?}
    
    CheckMax -->|Yes| CapMultiplier[multiplier = MaxLotMultiplier]
    CheckMax -->|No| ApplyMultiplier[lot = LotSize × multiplier]
    
    CapMultiplier --> ApplyMultiplier
    ApplyMultiplier --> Normalize[Normalize to 2 decimals]
    Normalize --> ReturnLot[Return Calculated Lot]
    
    ReturnFixed --> End[Lot Size Determined]
    ReturnLot --> End
```

---

## Basket State Recovery

```mermaid
flowchart TD
    Start[Restore Basket State] --> InitVars[count = 0, direction = -1]
    InitVars --> LoopOrders[Loop Through Open Orders]
    
    LoopOrders --> SelectOrder{Order Selected?}
    SelectOrder -->|No| NextOrder[Next Order]
    SelectOrder -->|Yes| CheckMagic{Magic = EA Magic?}
    
    CheckMagic -->|No| NextOrder
    CheckMagic -->|Yes| CheckSymbol{Symbol = Current?}
    
    CheckSymbol -->|No| NextOrder
    CheckSymbol -->|Yes| IncrementCount[count++]
    
    IncrementCount --> FirstOrder{First Order?}
    FirstOrder -->|Yes| SetDirection[direction = OrderType]
    FirstOrder -->|No| UpdatePrice[Update Last Grid Price]
    
    SetDirection --> UpdatePrice
    UpdatePrice --> NextOrder
    
    NextOrder --> MoreOrders{More Orders?}
    MoreOrders -->|Yes| SelectOrder
    MoreOrders -->|No| CheckCount{count > 0?}
    
    CheckCount -->|No| NoBasket[Set: No Basket]
    CheckCount -->|Yes| RestoreBasket[Set: Basket Exists]
    
    RestoreBasket --> LogRestore[Log Basket Restored]
    NoBasket --> End[State Restored]
    LogRestore --> End
```

---

## Understanding the Flowcharts

### Symbols Used

- **Rectangle:** Process or action
- **Diamond:** Decision point (yes/no)
- **Rounded Rectangle:** Start/end point
- **Arrows:** Flow direction

### Color Coding (if viewing in color)

- **Green paths:** Success/continue
- **Red paths:** Failure/block
- **Blue:** Information/calculation
- **Orange:** Warning/emergency

### How to Use These Flowcharts

1. **For understanding:** Follow the flow to see how decisions are made
2. **For debugging:** Trace the path to find where EA is blocking
3. **For modification:** Identify where to add/change logic
4. **For testing:** Verify EA follows these flows during testing

### Key Takeaways

1. **Multiple safety checks:** EA checks many conditions before acting
2. **Sequential filters:** Each filter must pass before proceeding
3. **State-based logic:** EA behavior depends on basket state
4. **Emergency priority:** Emergency checks happen before normal logic
5. **Graceful failure:** EA logs and continues when operations fail

---

## Typical Execution Paths

### Path 1: Successful Entry
```
OnTick → Check State → No Basket → Entry Logic →
All Filters Pass → Entry Signal Valid → Order Opens →
Basket State Set → Wait for Next Tick
```

### Path 2: Grid Expansion
```
OnTick → Check State → Basket Exists → Exit Logic (no exit) →
Grid Logic → DD Below Pause → Filters Pass → Price Moved →
Grid Order Opens → Update Last Price → Wait for Next Tick
```

### Path 3: Normal TP Close
```
OnTick → Check State → Basket Exists → Exit Logic →
Calculate Profit → Profit >= TP → Close All Orders →
Reset State → Wait for Next Tick (No Basket)
```

### Path 4: Emergency Close
```
OnTick → Check State → Emergency Check → Basket DD High →
Trigger Emergency → Log Reason → Close All Orders →
Reset State → Wait for Next Tick (No Basket)
```

### Path 5: Blocked by Filters
```
OnTick → Check State → No Basket → Entry Logic →
Spread Check Fails → Block Entry → Wait for Next Tick
```

---

These flowcharts represent the complete logic of the EA. Use them as a reference when configuring, testing, or troubleshooting the EA.
