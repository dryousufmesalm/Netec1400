# Netec1400 XAUUSD Grid EA – Input Review

All **non-group** inputs are **implemented** in the code. Group-title inputs (`InpGrp_*`) are display-only and not used in logic.

---

## Symbol & Identity
| Input | Implemented | Where used |
|-------|-------------|------------|
| MagicNumber | Yes | Order identification, RestoreBasketState, GetBasketOrderCount, OrderSend/OrderClose, TryAdoptUserBasket, etc. |

---

## Lots & Grid
| Input | Implemented | Where used |
|-------|-------------|------------|
| LotSize | Yes | OpenManualOrder, HandleEntry, HandleGrid (lot calculation) |
| UseFixedLot | Yes | HandleGrid – lot progression (line ~939) |
| MaxGridLevels | Yes | HandleGrid – max levels check; comment display |
| GridDistancePips | Yes | OnInit → g_GridDistancePoints; HandleGrid – grid distance |
| UseDynamicGrid | Yes | HandleGrid – dynamic grid when UseDDBasedGridPause (line ~914) |
| DynamicGridMultiplier | Yes | HandleGrid – multiplies grid distance under stress |
| MaxLotMultiplier | Yes | HandleGrid – cap on lot multiplier when !UseFixedLot (line ~942) |

---

## Entry
| Input | Implemented | Where used |
|-------|-------------|------------|
| EntryMode | Yes | OnTick (TryAdoptUserBasket vs HandleEntry); HandleEntry; UpdateComment; OpenManualOrder checks |
| OpenBasketDirection | Yes | HandleEntry – direction for Semi-Auto; UpdateComment text |
| SuggestedDirectionSource | Yes | GetSuggestedDirectionForDisplay – MA vs None |
| MA_Period | Yes | GetSuggestedDirectionForDisplay (MA mode) |

---

## Exit
| Input | Implemented | Where used |
|-------|-------------|------------|
| BasketTakeProfitMoney | Yes | HandleExit – basket TP close |
| UseTrailingBasketTP | Yes | HandleExit (line ~992) |
| TrailingStart | Yes | HandleExit – profit level to start trailing |
| TrailingStep | Yes | HandleExit – trail step |

---

## Risk
| Input | Implemented | Where used |
|-------|-------------|------------|
| MaxBasketDrawdownMoney | Yes | BasketDrawdownPercent(); emergency logic |
| MaxEquityDrawdownPercent | Yes | HandleEntry, HandleGrid – equity DD check; CheckEmergencyClose |
| PauseNewTradesAtDDPercent | Yes | HandleGrid – pause new levels when UseDDBasedGridPause (line ~885) |
| IncreaseGridDistanceAtDDPercent | Yes | HandleGrid – dynamic grid when UseDDBasedGridPause (line ~914) |
| EmergencyCloseAtDDPercent | Yes | CheckEmergencyClose (line ~1019) |
| MinFreeMarginPercent | Yes | HandleEntry, HandleGrid – margin check; CheckEmergencyClose (line ~787, 1038) |
| UseDDBasedGridPause | Yes | HandleGrid – enables DD-based pause and dynamic grid |

---

## Emergency
| Input | Implemented | Where used |
|-------|-------------|------------|
| UseEmergencyExit | Yes | OnTick – calls CheckEmergencyClose when true |
| MaxBasketSlippagePips | Yes | OnInit → g_MaxBasketSlippagePoints; OrderSend, OrderClose |

---

## Filters
| Input | Implemented | Where used |
|-------|-------------|------------|
| MaxSpreadPips | Yes | OnInit → g_MaxSpreadPoints; CurrentSpreadOK |
| UseVolatilityFilter | Yes | VolatilityOK |
| ATR_Period | Yes | VolatilityOK – ATR calculation |
| ATR_MultiplierThreshold | Yes | VolatilityOK – volatility threshold |
| BlockNewBasketAboveVolatility | Yes | VolatilityOK – for new basket (line ~695) |
| PauseGridAboveVolatility | Yes | VolatilityOK – for grid (line ~700) |
| UseImpulseFilter | Yes | ImpulseDetected; HandleEntry; HandleGrid |
| ImpulseLookbackBars | Yes | ImpulseDetected |
| ImpulseRangeMultiplier | Yes | ImpulseDetected |
| PauseGridOnImpulse | Yes | HandleGrid (line ~898) |
| BlockNewBasketOnImpulse | Yes | HandleEntry (line ~834) |
| UseExposureBasedPause | Yes | RemainingExposureOK |
| MinRemainingExposureMoney | Yes | RemainingExposureOK; OpenManualOrder, HandleEntry, HandleGrid |

---

## Session
| Input | Implemented | Where used |
|-------|-------------|------------|
| UseTradingHours | Yes | WithinTradingHours (line ~760) |
| StartHour | Yes | WithinTradingHours |
| EndHour | Yes | WithinTradingHours |

---

## Manual Buttons
| Input | Implemented | Where used |
|-------|-------------|------------|
| ShowManualButtons | Yes | OnInit (CreateManualButtons); OnTick (button poll); OnChartEvent; CreateManualButtons/DeleteManualButtons |

---

## Summary

- **Total non-group inputs:** 38  
- **Implemented:** 38  
- **Not implemented:** 0  

All inputs are wired into the EA logic. Conditional inputs (e.g. PauseNewTradesAtDDPercent, IncreaseGridDistanceAtDDPercent) only apply when their parent switch is on (e.g. UseDDBasedGridPause).
