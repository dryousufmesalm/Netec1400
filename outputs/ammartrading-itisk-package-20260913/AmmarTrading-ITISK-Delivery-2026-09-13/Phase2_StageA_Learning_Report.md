# Phase 2 Stage A – Commercial EA Learning Report

**Project:** Gold XAUUSD Grid / Recovery EA (MT4)  
**Stage:** A – Commercial EA Learning (Mandatory Gate)  
**Status:** Draft – in progress

---

## Revision log

| Date       | Note |
|------------|------|
| *(add date)* | Initial structure created. Add findings under each section below. |

---

## 1. Executive summary

*Fill in after all other sections are drafted.*

- **Overall replication confidence:** *(High / Medium / Low)*
- **Summary (2–3 sentences):** *(Brief assessment of observed behavior and readiness for Stage B.)*

---

## 2. Entry behavior

*What triggers the first trade; when entry is delayed or skipped; character (structural / reactive / timing-based). Use bullet points and short notes.*

- *(Add your findings here.)*

---

## 3. Trade expansion

*How extra trades are added as price moves; cadence in different volatility regimes; spacing and aggressiveness. Include timestamps or example scenarios if you have them.*

- *(Add your findings here.)*

---

## 4. Basket management

*Typical basket lifetime; drawdown tolerance before action; patience vs action thresholds.*

- *(Add your findings here.)*

---

## 5. Exit behavior

*How baskets close in profit; relation between basket size, duration, and exit; repeating exit patterns.*

- *(Add your findings here.)*

---

## 6. Failure conditions

*Market conditions where the EA struggles or fails; observable limits of the strategy.*

- *(Add your findings here.)*

---

## 7. Strong repeating patterns and open questions

### Strong repeating patterns

*List patterns you see consistently (from sections 2–6).*

- *(Add here.)*

### Open questions and uncertainties

*What is unclear or needs more observation.*

- *(Add here.)*

---

## 8. Gap analysis (Phase 1 EA vs commercial EA)

*Specific differences between the Phase 1 EA (Netec1400_XAUUSD_Grid.mq4) and the commercial EA, by behavior area.*

| Area           | Phase 1 behavior        | Commercial EA behavior   | Gap / change needed |
|----------------|-------------------------|--------------------------|---------------------|
| *(e.g. Entry)* | *(brief)*               | *(brief)*                | *(brief)*           |
| *(add rows)*   |                         |                          |                     |

---

## 9. Key insights for replication

*Main takeaways for Stage B; what must be replicated first; non-intrusive improvement ideas (if any).*

- *(Add here.)*

---

## 10. Materials used

*Short list of what you used for this analysis (trade history, screenshots, parameter sets, logs, etc.) for traceability.*

- **Commercial EA inputs (observation setup)**  
  - EA name/variant: `GOLD-STANDART Tamir (7)`  
  - Source: MT4 Inputs tab screenshot (`Testing` → `Inputs`) – stored in project assets.  
  - Key parameters for this observation session:  
    - `FixedLots = 0.01`  
    - `LotAssignment = FixedLots`  
    - `TakeProfit = 3000`  
    - `Tral = 2000.0`  
    - `TralStart = 1000.0`  
    - `TimeStart = 2.0`  
    - `TimeEnd = 23.0`  
    - `MaxSpread = 400.0`  
    - `PipsStep = 100.0`  
    - `OpenTime = 1`  
    - `Magic = 2021`  
    - `Info = true`  
    - `TextColor = White`, `InfoDataColor = Yellow`, `FonColor = Black`, `FontSizeInfo = 8`  
    - `SpeedEA = 10`  
    - `CloseTradesAtPercentageDrawdown = false`, `PercentageDrawdown = 5.0`  
    - `CloseTradesAtFixedDrawdown = false`, `FixedDrawdown = 1000.0`  
    - `ResumeTradingAtNextDayAfter... = false`

---

*End of Stage A Learning Report. Update as you observe the commercial EA; finalize Executive summary and do a last pass before delivery.*
