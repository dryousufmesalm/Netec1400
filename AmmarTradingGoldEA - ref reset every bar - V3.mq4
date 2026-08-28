      //+------------------------------------------------------------------+
      //|                                        Netec1400_XAUUSD_Grid.mq4 |
      //|                                   Netec1400 Stage B v3.0         |
      //|                                                                  |
      //+------------------------------------------------------------------+
      #property copyright "Ammar Trading"
      #property version   "3.00"
      #property description "Ammar Trading Gold EA V3 — basket fixed TP, optional basket profit trailing, per-order trailing"
      #property strict

      //+------------------------------------------------------------------+
      //| EA DESCRIPTION                                                    |
      //+------------------------------------------------------------------+
      /* Stage B / V3 exit model (all supported together):
         1) Per-order trailing — unchanged: Tral / TralStart in POINTS; runs only when exactly ONE
            market order belongs to the basket (single-trade scalps). Uses OrderModify stop loss.
         2) Fixed basket take-profit — TakeProfit in account currency; when sum basket profit >=
            TakeProfit, the entire basket is closed (UseBasketTrailingTP on or off).
         3) Optional basket-level profit trailing — UseBasketTrailingTP: when true, after basket
            profit reaches TrailingStart ($), close all if profit falls by TrailingStep ($) from the
            basket's highest profit since open (independent of per-order SL). Does not remove (2).
         - Tick-based reversal entry/add from tracked reference extreme (PipsStep)
         - One direction per basket
         - Protection hierarchy from Phase-2 requirements
      */

      //+------------------------------------------------------------------+
      //| ENUMS                                                             |
      //+------------------------------------------------------------------+

      enum ENUM_SYSTEM_STATE
      {
         STATE_NORMAL = 0,
         STATE_EXPOSURE_BLOCK = 1,
         STATE_KILL_COOLDOWN = 2
      };

      enum ENUM_REGIME_ACTION
      {
         REGIME_OFF = 0,
         REGIME_LOCK = 1
      };

      //+------------------------------------------------------------------+
      //| INPUT PARAMETERS                                                  |
      //+------------------------------------------------------------------+

      // --- Legacy Phase-1 Inputs (disabled) ---
      int          INTERNAL_CloseSlippagePips = 5;

      // --- Stage B Core (Commercial Replication) ---
      input string InpGrp_StageB_Core = "=== Stage B Core (Commercial) ===";
      input double FixedLots = 0.01;
      input int    PointsPerPip = 0;              // How many price points = 1 pip for PipsStep/MaxSpread (0=auto)
      input int    PipsStep = 10;                 // pipsStep
      input double TakeProfit = 30.0;             // basket target (account currency in this implementation)
      input int    Tral = 20;                     // trailing distance (points)
      input int    TralStart = 5;                 // trailing activation (points)
      input int    MaxSpread = 40;                // Max Spread in Pips
      input int    TimeStart = 0;
      input int    TimeEnd = 23;
      input int    OpenTime = 0;                  
      input int    NewBasketDelaySeconds = 0;     // seconds to confirm each new-basket signal
      input int    SpeedEA = 0;                   
      input int    Magic = 1400;

      // --- Basket Exit (fixed basket TP + optional basket profit trailing; per-order trailing separate) ---
      input string InpGrp_BasketExit = "=== Basket Exit ===";
      input bool   UseBasketTrailingTP = false;   // true: enable basket-level profit trailing (full basket); false: fixed TP only for basket
      input double TrailingStart = 15.0;          // basket profit ($) must reach this before retracement rule applies
      input double TrailingStep = 5.0;            // close basket if profit ($) drops this far below peak since open

      // --- Kill Switch ---
      input string InpGrp_Kill = "=== Kill Switch ===";
      input bool   KillSwitchEnable = true;
      input double KillEquityLevel = 100.0;
      input int    KillCooldownMinutes = 60;

      // --- Exposure ---
      input string InpGrp_ExposureCap = "=== Exposure Cap ===";
      input int    MaxOrdersInBasket = 0;
      input double MaxTotalLotsInBasket = 0.0;

      // --- Regime filter (closed bars only; gates first basket trade only) ---
      input string InpGrp_Regime = "=== Regime Filter ===";
      input bool   RegimeEnable = false;
      input ENUM_REGIME_ACTION RegimeAction = REGIME_OFF;
      input int    RegimeADXPeriod = 14;
      input double RegimeADXLevel = 25.0;
      input int    RegimeADXBars = 3;
      input int    RegimeRangeBars = 8;
      input int    RegimeRecoveryBars = 3;

      // --- Trading Days ---
      input string InpGrp_TradingDays = "=== Trading Days ===";
      input bool   EnableTradingDaysFilter = false;
      input bool   TradeMonday = true;
      input bool   TradeTuesday = true;
      input bool   TradeWednesday = true;
      input bool   TradeThursday = true;
      input bool   TradeFriday = true;

      // --- Recovery Step-Up ---
      input string InpGrp_Recovery = "=== Recovery Step-Up ===";
      input bool   EnableRecoveryStepUp = false;
      input int    RecoveryWaitMinutes = 60;
      input double RecoveryMaxTotalLotsInBasket = 0.0;

      //+------------------------------------------------------------------+
      //| GLOBAL VARIABLES                                                  |
      //+------------------------------------------------------------------+

      #define BTN_BUY_NAME    "AmmarTradingGoldEA_BtnBUY"
      #define BTN_SELL_NAME   "AmmarTradingGoldEA_BtnSELL"
      #define COMMENT_LABEL  "AmmarTradingGoldEA_Comment"
      #define COMMENT_FONTSIZE 9    // on-chart comment label font size (larger = bigger text)
      #define COMMENT_MAX_LINES 25  // max lines for on-chart comment (OBJ_LABEL does not support \n)
      #define COMMENT_LINE_HEIGHT 16  // pixels per line

      // Cockpit (On-Chart UI) object prefix
      #define COCKPIT_PREFIX "AG_COCKPIT_"
      #define COCKPIT_X 14
      #define COCKPIT_Y 52
      #define COCKPIT_W 800
      #define COCKPIT_H 432
      #define COCKPIT_PAD_L 40
      #define COCKPIT_COL_GAP 20
      #define COCKPIT_BAR_H 48   // kill / headroom proximity bar (+30 px)
      #define COCKPIT_MARK_FS 16 // down-arrow marker on risk bar (Marlett)
      #define COCKPIT_DY_TITLE 26
      #define COCKPIT_DY_SYM 60
      #define COCKPIT_DY_DIVIDER 100   // +10px padding above divider vs prior layout
      #define COCKPIT_DIV_H 2
      #define COCKPIT_DY_STATE 114    // +10px padding below divider (2px line) vs prior layout
      #define COCKPIT_DY_DIVIDER2 158 // full-bleed rule below STATE/CTRL (same style as DIV_SYM)
      #define COCKPIT_DY_HR 190       // +22px vs old: room for divider + 10px pad below it
      #define COCKPIT_DY_BAR 226
      #define COCKPIT_DY_REASON 292   // below taller bar (+30)
      #define COCKPIT_DY_ROW1 328
      #define COCKPIT_DY_DIVIDER3 380 // full-bleed rule above SPREAD / WINDOW row (+10 px)
      #define COCKPIT_DY_ROW2 390     // +20px padding above SPREAD vs prior
      #define COCKPIT_GRID_CELL 10
      #define COCKPIT_GRID_GAP 2
      #define COCKPIT_HDR_ICON_PAD 40 // inset from panel right for grid icon

      string   g_Symbol = "";
      int      g_PointsPerPip = 1;
      int      g_BasketDirection = -1;     // -1=none, OP_BUY=0, OP_SELL=1
      bool     g_BasketExists = false;
      int      g_GridDistancePoints = 0;
      int      g_MaxBasketSlippagePoints = 0;
      int      g_MaxSpreadPoints = 0;
      double   g_LastGridPrice = 0.0;
      double   g_BasketHighestProfit = 0.0;
      datetime g_LastBarTime = 0;
      datetime g_LastGridAddTime = 0;    // Trade density limit
      double   g_InitialEquity = 0.0;

      double   g_RefHigh = 0.0;
      double   g_RefLow = 0.0;
      datetime g_LastAnyOpenTime = 0;
      datetime g_LastFirstOpenTime = 0;
      bool     g_NewBasketEntryPending = false;
      datetime g_NewBasketEntryPendingSince = 0;
      int      g_NewBasketEntryPendingDirection = -1;
      datetime g_KillCooldownUntil = 0;
      double   g_BasketWorstProfit = 0.0;
      bool     g_KillActive = false;
      bool     g_ExposureLatched = false;
      ENUM_SYSTEM_STATE g_SystemState = STATE_NORMAL;
      datetime g_RecoveryBaseCapReachedAt = 0;

      bool     g_CockpitCreated = false;
      int      g_CockpitLastUpdateMs = 0;
      long     g_ChartSaved_ShowGrid = 1;

      bool     g_RegimeBlocked = false;
      int      g_RegimeRecoveryCount = 0;
      datetime g_RegimeLastBarTime = 0;

      void     CockpitUpdate();
      int      ComputePointsPerPip();
      bool     ValidateSymbolAndLots();
      bool     TradingDayAllowsNewBasket();
      bool     TryOpenRecoveryAdd(double currentPrice);
      void     RefreshRecoveryBaseCapTimer(double currentLots);
      void     RegimeOnNewBarIfNeeded();
      void     RegimeEvaluateClosedBar();

      //+------------------------------------------------------------------+
      //| Section 6 Telemetry (AGOLD___Baskets.csv)                         |
      //+------------------------------------------------------------------+
      #define TELEMETRY_FILE_NAME "AGOLD___Baskets.csv"

      bool     g_LastOpenBlockedByExposureCap = false;

      // Active basket telemetry state (no per-trade logging)
      bool     g_Telemetry_BasketActive = false;
      bool     g_Telemetry_WroteRowForActiveBasket = false;
      int      g_Telemetry_BasketID = 0;
      datetime g_Telemetry_StartTime = 0;
      datetime g_Telemetry_EndTime = 0;
      string   g_Telemetry_Direction = "";

      int      g_Telemetry_MaxOrdersConcurrent = 0;
      double   g_Telemetry_MaxTotalLots = 0.0;

      double   g_Telemetry_MaxFloatingDrawdownAbs = 0.0;   // positive magnitude (worst basket floating loss during life)
      double   g_Telemetry_MaxFloatingProfit = 0.0; // positive number
      double   g_Telemetry_ClosePL = 0.0;

      double   g_Telemetry_SpreadAtEntry = -1.0;
      double   g_Telemetry_EquityAtEntry = -1.0;
      double   g_Telemetry_HeadroomAtEntry = -1.0;

      double   g_Telemetry_MinHeadroom = 0.0;
      int      g_Telemetry_TimesNearKill = 0;
      bool     g_Telemetry_HeadroomPrevAboveNearKill = true;

      int      g_Telemetry_ExposureBlocks = 0;

      // Last-known basket snapshot while active (used if basket closes externally via SL).
      int      g_Telemetry_LastOrders = 0;
      double   g_Telemetry_LastLots = 0.0;
      double   g_Telemetry_LastProfit = 0.0;

      // Configuration snapshot (captured at basket start)
      double   g_Telemetry_FixedLotsSnap = 0.0;
      int      g_Telemetry_PipsStepSnap = 0;
      double   g_Telemetry_TakeProfitSnap = 0.0;
      double   g_Telemetry_KillEquityLevelSnap = 0.0;
      int      g_Telemetry_MaxOrdersInBasketSnap = 0;
      double   g_Telemetry_MaxTotalLotsInBasketSnap = 0.0;

      // Reporting-only run context. It is intentionally separate from all trading state.
      datetime g_Telemetry_RunStartTime = 0;
      double   g_Telemetry_RunStartBalance = 0.0;
      string   g_Telemetry_RunID = "";
      bool     g_Telemetry_RunResetDeferred = false;
      bool     g_Telemetry_SchemaBlocked = false;
      uint     g_Telemetry_LastRunFileCheckTick = 0;

      // Complete input snapshot captured when each basket starts.
      int      g_Telemetry_MagicSnap = 0;
      int      g_Telemetry_PointsPerPipSnap = 0;
      int      g_Telemetry_TralSnap = 0;
      int      g_Telemetry_TralStartSnap = 0;
      int      g_Telemetry_MaxSpreadSnap = 0;
      int      g_Telemetry_TimeStartSnap = 0;
      int      g_Telemetry_TimeEndSnap = 0;
      int      g_Telemetry_OpenTimeSnap = 0;
      int      g_Telemetry_NewBasketDelaySecondsSnap = 0;
      int      g_Telemetry_SpeedEASnap = 0;
      bool     g_Telemetry_UseBasketTrailingTPSnap = false;
      double   g_Telemetry_TrailingStartSnap = 0.0;
      double   g_Telemetry_TrailingStepSnap = 0.0;
      bool     g_Telemetry_KillSwitchEnableSnap = false;
      int      g_Telemetry_KillCooldownMinutesSnap = 0;
      bool     g_Telemetry_RegimeEnableSnap = false;
      int      g_Telemetry_RegimeActionSnap = 0;
      int      g_Telemetry_RegimeADXPeriodSnap = 0;
      double   g_Telemetry_RegimeADXLevelSnap = 0.0;
      int      g_Telemetry_RegimeADXBarsSnap = 0;
      int      g_Telemetry_RegimeRangeBarsSnap = 0;
      int      g_Telemetry_RegimeRecoveryBarsSnap = 0;
      bool     g_Telemetry_EnableTradingDaysFilterSnap = false;
      bool     g_Telemetry_TradeMondaySnap = false;
      bool     g_Telemetry_TradeTuesdaySnap = false;
      bool     g_Telemetry_TradeWednesdaySnap = false;
      bool     g_Telemetry_TradeThursdaySnap = false;
      bool     g_Telemetry_TradeFridaySnap = false;
      bool     g_Telemetry_EnableRecoveryStepUpSnap = false;
      int      g_Telemetry_RecoveryWaitMinutesSnap = 0;
      double   g_Telemetry_RecoveryMaxTotalLotsInBasketSnap = 0.0;

      // Kill-switch: capture close PL at trigger time (before positions close)
      bool     g_Telemetry_KillClosePL_Stored = false;
      double   g_Telemetry_KillClosePL = 0.0;
      int      g_Telemetry_KillOrdersAtClose = 0;
      double   g_Telemetry_KillLotsAtClose = 0.0;

      //+------------------------------------------------------------------+
      //| Expert initialization function                                    |
      //+------------------------------------------------------------------+
      int OnInit()
      {
         g_Symbol = Symbol();
         if(!IsTradeAllowed())
         {
            Print("ERROR: Trading not allowed (auto-trading off or disconnected).");
            return(INIT_FAILED);
         }

         if(FixedLots <= 0)
         {
            Print("ERROR: FixedLots must be > 0");
            return(INIT_PARAMETERS_INCORRECT);
         }

         if(PipsStep <= 0)
         {
            Print("ERROR: PipsStep must be > 0");
            return(INIT_PARAMETERS_INCORRECT);
         }
         if(UseBasketTrailingTP)
         {
            if(TrailingStart <= 0.0 || TrailingStep <= 0.0)
            {
               Print("ERROR: UseBasketTrailingTP requires TrailingStart > 0 and TrailingStep > 0 (account currency).");
               return(INIT_PARAMETERS_INCORRECT);
            }
         }
         if(EnableRecoveryStepUp)
         {
            if(RecoveryWaitMinutes <= 0)
            {
               Print("ERROR: EnableRecoveryStepUp requires RecoveryWaitMinutes > 0.");
               return(INIT_PARAMETERS_INCORRECT);
            }
            if(MaxTotalLotsInBasket <= 0.0)
            {
               Print("ERROR: EnableRecoveryStepUp requires MaxTotalLotsInBasket > 0.");
               return(INIT_PARAMETERS_INCORRECT);
            }
            if(RecoveryMaxTotalLotsInBasket <= MaxTotalLotsInBasket)
            {
               Print("ERROR: EnableRecoveryStepUp requires RecoveryMaxTotalLotsInBasket > MaxTotalLotsInBasket.");
               return(INIT_PARAMETERS_INCORRECT);
            }
         }

         if(!ValidateSymbolAndLots())
            return(INIT_PARAMETERS_INCORRECT);

         g_PointsPerPip = ComputePointsPerPip();
         if(g_PointsPerPip <= 0)
         {
            Print("ERROR: PointsPerPip / auto pip scale invalid.");
            return(INIT_PARAMETERS_INCORRECT);
         }

         if(RegimeEnable)
         {
            if(RegimeADXPeriod <= 0 || RegimeADXBars <= 0 || RegimeRangeBars <= 0 || RegimeRecoveryBars <= 0)
            {
               Print("ERROR: Regime filter enabled: RegimeADXPeriod, RegimeADXBars, RegimeRangeBars, RegimeRecoveryBars must be > 0");
               return(INIT_PARAMETERS_INCORRECT);
            }
         }

         g_GridDistancePoints = PipsStep * g_PointsPerPip;
         g_MaxBasketSlippagePoints = INTERNAL_CloseSlippagePips * g_PointsPerPip;
         g_MaxSpreadPoints = MaxSpread * g_PointsPerPip;
         if(g_GridDistancePoints <= 0) g_GridDistancePoints = 1;
         if(g_MaxBasketSlippagePoints <= 0) g_MaxBasketSlippagePoints = 1;
         if(g_MaxSpreadPoints <= 0) g_MaxSpreadPoints = 1;

         int stopLvl = (int)MarketInfo(Symbol(), MODE_STOPLEVEL);
         int freezeLvl = (int)MarketInfo(Symbol(), MODE_FREEZELEVEL);
         Print("Symbol: ", Symbol(), " Digits=", Digits, " Point=", Point, " PointsPerPip=", g_PointsPerPip,
               " MODE_STOPLEVEL=", stopLvl, " MODE_FREEZELEVEL=", freezeLvl);

         // Store initial equity
         g_InitialEquity = AccountEquity();
         
         // Check for existing basket
         RestoreBasketState();

         // Reporting-only run lifecycle. This never gates or changes trading decisions.
         TelemetryEnsureRunContext(true);
         
         if(Bars > 0) { g_RefHigh = High[0]; g_RefLow = Low[0]; }
         else { g_RefHigh = Bid; g_RefLow = Ask; }

         g_RegimeBlocked = false;
         g_RegimeRecoveryCount = 0;
         g_RegimeLastBarTime = 0;

         Print("=== Ammar Trading Gold EA Initialized ===");
         Print("Magic: ", Magic);
         Print("FixedLots: ", FixedLots);
         Print("PipsStep(pips): ", PipsStep, " (grid step in points: ", g_GridDistancePoints, ")");
         Print("MaxSpread: ", MaxSpread, " pips => ", g_MaxSpreadPoints, " points");
         Print("TakeProfit: ", TakeProfit);
         Print("Basket exit: ", (UseBasketTrailingTP ? "Fixed TP + basket profit trailing" : "Fixed basket TP only"));
         if(UseBasketTrailingTP)
            Print("  TrailingStart=$", TrailingStart, " TrailingStep=$", TrailingStep);
         Print("Per-order trailing: Tral=", Tral, " pts, TralStart=", TralStart, " pts (single order only)");
         Print("Recovery Step-Up: ", (EnableRecoveryStepUp ? "ON" : "OFF"));
         if(EnableRecoveryStepUp)
            Print("  RecoveryWaitMinutes=", RecoveryWaitMinutes, " RecoveryMaxTotalLotsInBasket=", DoubleToString(RecoveryMaxTotalLotsInBasket, 2));
         Print("KillSwitch: ", (KillSwitchEnable ? "ON" : "OFF"));

         g_ChartSaved_ShowGrid = ChartGetInteger(0, CHART_SHOW_GRID);
         ChartSetInteger(0, CHART_SHOW_GRID, false);
         ChartRedraw(0);
         
         return(INIT_SUCCEEDED);
      }

      //+------------------------------------------------------------------+
      //| Expert deinitialization function                                  |
      //+------------------------------------------------------------------+
      void OnDeinit(const int reason)
      {
         ChartSetInteger(0, CHART_SHOW_GRID, g_ChartSaved_ShowGrid);
         ChartRedraw(0);

         CockpitDestroy();
         for(int i = 0; i < COMMENT_MAX_LINES; i++)
            ObjectDelete(0, COMMENT_LABEL + "_" + IntegerToString(i));
         Comment("");
         Print("EA stopped. Reason: ", reason);
      }

      //+------------------------------------------------------------------+
      //| Expert tick function                                              |
      //+------------------------------------------------------------------+
      void OnTick()
      {
         // Throttled file-reset detection is deliberately before telemetry observation only;
         // it has no return path into entry, grid, exit, trailing, or risk logic.
         TelemetryEnsureRunContext();
         CheckBasketStateConsistency();
         UpdateReferenceExtremes();
         RegimeOnNewBarIfNeeded();

         if(HandleKillSwitchAndCooldown())
         {
            if(!g_BasketExists)
               ResetPendingNewBasketEntry();
            CockpitUpdate();
            return;
         }

         if(g_BasketExists)
         {
            ResetPendingNewBasketEntry();

            // Section 6 telemetry: update basket lifecycle stats continuously
            TelemetryUpdateBasketStats();

            HandleExit();  // includes per-order trailing + basket TP

            if(IsExposureBlockedForOpen())
            {
               g_SystemState = STATE_EXPOSURE_BLOCK;
               CockpitUpdate();
               return;
            }

            g_SystemState = STATE_NORMAL;
            HandleGrid();
            CockpitUpdate();
            return;
         }

         ResetLatchesWhenFlat();

         if(IsExposureBlockedForOpen())
         {
            ResetPendingNewBasketEntry();
            g_SystemState = STATE_EXPOSURE_BLOCK;
            CockpitUpdate();
            return;
         }

         g_SystemState = STATE_NORMAL;
         OpenAutoEntry();
         CockpitUpdate();
      }

      //+------------------------------------------------------------------+
      //| Chart event                                                       |
      //+------------------------------------------------------------------+
      void OnChartEvent(const int id, const long& lparam, const double& dparam, const string& sparam)
      {
         // Reserved (Stage B: no chart buttons).
      }

      //+------------------------------------------------------------------+
      //| Create BUY and SELL buttons on chart                             |
      //+------------------------------------------------------------------+
      void CreateManualButtons()
      {
         // Removed in Stage B.
      }

      //+------------------------------------------------------------------+
      //| Delete BUY/SELL buttons                                           |
      //+------------------------------------------------------------------+
      void DeleteManualButtons()
      {
         // Removed in Stage B.
      }

      //+------------------------------------------------------------------+
      //| Open one manual order (BUY or SELL) with EA MagicNumber          |
      //+------------------------------------------------------------------+
      void OpenManualOrder(int orderType)
      {
         // Removed in Stage B.
      }

      //+------------------------------------------------------------------+
      //| Get error description                                             |
      //+------------------------------------------------------------------+
      string ErrorDescription(int error_code){ return IntegerToString(error_code); }

      //+------------------------------------------------------------------+
      //| Cockpit (On-Chart UI)                                             |
      //+------------------------------------------------------------------+
      string CockpitObj(string suffix) { return COCKPIT_PREFIX + suffix; }

      // Down-arrow for risk marker: Unicode (▼) shows "?" in MT4; Marlett "u" is the standard scrollbar down-arrow glyph (ANSI).
      string CockpitRiskMarkerGlyph() { return "u"; }

      // OBJ_RECTANGLE_LABEL: OBJPROP_COLOR = border, OBJPROP_BGCOLOR = fill (unset fill = gray).
      void CockpitSetRect(string name, int x, int y, int w, int h, color borderClr, color fillClr, bool back)
      {
         if(ObjectFind(0, name) < 0)
         {
            ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
            ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
            ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
            ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
         }
         ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
         ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
         ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
         ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
         ObjectSetInteger(0, name, OBJPROP_COLOR, borderClr);
         ObjectSetInteger(0, name, OBJPROP_BGCOLOR, fillClr);
         ObjectSetInteger(0, name, OBJPROP_BACK, back);
      }

      void CockpitSetLabel(string name, int x, int y, string text, int fontSize, color clr, string font, int anchor)
      {
         if(ObjectFind(0, name) < 0)
         {
            ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
            ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
            ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
            ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
         }
         ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
         ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
         ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor);
         ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
         ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
         if(font != "") ObjectSetString(0, name, OBJPROP_FONT, font);
         ObjectSetString(0, name, OBJPROP_TEXT, text);
      }

      bool CockpitSpreadOk()
      {
         double spread = (Ask - Bid) / Point;
         return (spread <= g_MaxSpreadPoints);
      }

      string CockpitStateText()
      {
         if(g_KillActive) return "KILLED";
         if(g_KillCooldownUntil > 0 && TimeCurrent() < g_KillCooldownUntil) return "COOLDOWN";
         if(g_BasketExists) return "MANAGING_BASKET";
         if(WithinTradingHours() && CockpitSpreadOk()) return "TRADING";
         return "WAITING_ENTRY";
      }

      string CockpitControlText()
      {
         if(g_KillActive) return "KILL";
         if(g_KillCooldownUntil > 0 && TimeCurrent() < g_KillCooldownUntil) return "KILL";
         if(!WithinTradingHours()) return "SESSION BLOCK";
         if(!CockpitSpreadOk()) return "SPREAD BLOCK";
         if(IsExposureBlockedForOpen()) return "EXPOSURE BLOCK";
         if(RegimeEnable && RegimeAction == REGIME_LOCK && g_RegimeBlocked && !g_BasketExists) return "REGIME BLOCK";
         return "NORMAL";
      }

      double CockpitHeadroom()
      {
         return GetHeadroomValue(AccountEquity(), AccountBalance());
      }

      double CockpitRiskFrac()
      {
         double hr = CockpitHeadroom();
         if(KillEquityLevel <= 0.0) return 0.0;
         double frac = 1.0 - (hr / KillEquityLevel);
         if(frac < 0.0) frac = 0.0;
         if(frac > 1.0) frac = 1.0;
         return frac;
      }

      string CockpitTimeframeText()
      {
         int p = Period();
         if(p == PERIOD_M1) return "M1";
         if(p == PERIOD_M5) return "M5";
         if(p == PERIOD_M15) return "M15";
         if(p == PERIOD_M30) return "M30";
         if(p == PERIOD_H1) return "H1";
         if(p == PERIOD_H4) return "H4";
         if(p == PERIOD_D1) return "D1";
         if(p == PERIOD_W1) return "W1";
         if(p == PERIOD_MN1) return "MN1";
         return "M" + IntegerToString(p);
      }

      void CockpitLayoutHeaderIcons(int x, int y, int w, int headerTopY)
      {
         int cell = COCKPIT_GRID_CELL;
         int gap = COCKPIT_GRID_GAP;
         int gridW = 3 * cell + 2 * gap;
         int padR = COCKPIT_HDR_ICON_PAD;
         int gx0 = x + w - padR - gridW;
         int gy0 = headerTopY;
         int r, c, idx;
         for(r = 0; r < 3; r++)
         {
            for(c = 0; c < 3; c++)
            {
               idx = r * 3 + c;
               CockpitSetRect(CockpitObj("GRID_" + IntegerToString(idx)), gx0 + c * (cell + gap), gy0 + r * (cell + gap), cell, cell, clrSilver, clrSilver, false);
            }
         }
      }

      void CockpitEnsureCreated()
      {
         if(g_CockpitCreated) return;

         // Legacy: MARK was OBJ_RECTANGLE_LABEL; now OBJ_LABEL (▼). Remove old object once.
         if(ObjectFind(0, CockpitObj("MARK")) >= 0)
            ObjectDelete(0, CockpitObj("MARK"));
         if(ObjectFind(0, CockpitObj("HDR_MIN")) >= 0)
            ObjectDelete(0, CockpitObj("HDR_MIN"));

         int x = COCKPIT_X;
         int y = COCKPIT_Y;
         int w = COCKPIT_W;
         int h = COCKPIT_H;

         color bg = clrPurple;
         color border = clrMediumPurple;
         CockpitSetRect(CockpitObj("BG"), x, y, w, h, bg, bg, true);
         CockpitSetRect(CockpitObj("BDR"), x, y, w, h, border, bg, false);

         int barX = x + COCKPIT_PAD_L;
         int barY = y + COCKPIT_DY_BAR;
         int barW = w - COCKPIT_PAD_L * 2;
         int barH = COCKPIT_BAR_H;
         int segW = barW / 4;
         CockpitSetRect(CockpitObj("SEG0"), barX + segW * 0, barY, segW, barH, clrGreen, clrGreen, false);
         CockpitSetRect(CockpitObj("SEG1"), barX + segW * 1, barY, segW, barH, clrGold, clrGold, false);
         CockpitSetRect(CockpitObj("SEG2"), barX + segW * 2, barY, segW, barH, clrOrange, clrOrange, false);
         CockpitSetRect(CockpitObj("SEG3"), barX + segW * 3, barY, barW - segW * 3, barH, clrRed, clrRed, false);
         // MARK: down-arrow label (▼), positioned in CockpitUpdate

         // Full-bleed: left edge of panel to right edge (width = COCKPIT_W, e.g. 800 px)
         CockpitSetRect(CockpitObj("DIV_SYM"), x, y + COCKPIT_DY_DIVIDER, w, COCKPIT_DIV_H, clrMediumPurple, clrMediumPurple, false);
         CockpitSetRect(CockpitObj("DIV_STATE"), x, y + COCKPIT_DY_DIVIDER2, w, COCKPIT_DIV_H, clrMediumPurple, clrMediumPurple, false);
         CockpitSetRect(CockpitObj("DIV_SPREAD"), x, y + COCKPIT_DY_DIVIDER3, w, COCKPIT_DIV_H, clrMediumPurple, clrMediumPurple, false);

         g_CockpitCreated = true;
      }

      void CockpitUpdate()
      {
         int nowMs = GetTickCount();
         if(g_CockpitLastUpdateMs > 0 && (nowMs - g_CockpitLastUpdateMs) < 250) return;
         g_CockpitLastUpdateMs = nowMs;

         CockpitEnsureCreated();

         int x = COCKPIT_X;
         int y = COCKPIT_Y;
         int w = COCKPIT_W;
         color bg = clrPurple;
         color border = clrMediumPurple;
         CockpitSetRect(CockpitObj("BG"), x, y, w, COCKPIT_H, bg, bg, true);
         CockpitSetRect(CockpitObj("BDR"), x, y, w, COCKPIT_H, border, bg, false);

         string title = "AMAR GOLD EA";
         string symTf = Symbol() + " (" + TelemetryNormalizeSymbol(Symbol()) + ") " + CockpitTimeframeText();

         string state = CockpitStateText();
         string control = CockpitControlText();

         double hr = CockpitHeadroom();
         string headroomStr = "HEADROOM: $" + DoubleToString(hr, 0);

         double exposureLots = g_BasketExists ? GetBasketTotalLots() : 0.0;
         double floating = g_BasketExists ? BasketProfit() : 0.0;
         double spread = (Ask - Bid) / Point;
         string winStr = WithinTradingHours() ? "OPEN" : "CLOSED";

         int col2 = x + w / 2 + COCKPIT_COL_GAP + 100;
         CockpitSetLabel(CockpitObj("TITLE"), x + COCKPIT_PAD_L, y + COCKPIT_DY_TITLE, title, 12, clrWhite, "", ANCHOR_LEFT_UPPER);
         CockpitSetLabel(CockpitObj("SYMTF"), x + COCKPIT_PAD_L, y + COCKPIT_DY_SYM, symTf, 9, clrSilver, "", ANCHOR_LEFT_UPPER);
         CockpitSetLabel(CockpitObj("STATE"), x + COCKPIT_PAD_L, y + COCKPIT_DY_STATE, "STATE: " + state, 9, clrSilver, "", ANCHOR_LEFT_UPPER);
         CockpitSetLabel(CockpitObj("CTRL"), col2, y + COCKPIT_DY_STATE, "CONTROL: " + control, 9, clrSilver, "", ANCHOR_LEFT_UPPER);
         CockpitSetLabel(CockpitObj("HR"), x + w / 2, y + COCKPIT_DY_HR, headroomStr, 12, clrWhite, "", ANCHOR_CENTER);

         string reason = "";
         if(IsExposureBlockedForOpen()) reason = "REASON: Exposure cap";
         CockpitSetLabel(CockpitObj("RSN"), x + COCKPIT_PAD_L, y + COCKPIT_DY_REASON, reason, 8, clrGold, "", ANCHOR_LEFT_UPPER);

         CockpitSetLabel(CockpitObj("EXP"), x + COCKPIT_PAD_L, y + COCKPIT_DY_ROW1, "EXPOSURE: " + DoubleToString(exposureLots, 2), 9, clrSilver, "", ANCHOR_LEFT_UPPER);
         CockpitSetLabel(CockpitObj("FLT"), col2, y + COCKPIT_DY_ROW1, "FLOATING: " + DoubleToString(floating, 0) + " " + AccountCurrency(), 9, clrSilver, "", ANCHOR_LEFT_UPPER);
         CockpitSetLabel(CockpitObj("SPD"), x + COCKPIT_PAD_L, y + COCKPIT_DY_ROW2, "SPREAD (points): " + DoubleToString(spread, 1), 9, clrSilver, "", ANCHOR_LEFT_UPPER);
         CockpitSetLabel(CockpitObj("WIN"), col2, y + COCKPIT_DY_ROW2, "WINDOW: " + winStr, 9, clrSilver, "", ANCHOR_LEFT_UPPER);

         double frac = CockpitRiskFrac();
         int barX = x + COCKPIT_PAD_L;
         int barW = w - COCKPIT_PAD_L * 2;
         int barY = y + COCKPIT_DY_BAR;
         int barH = COCKPIT_BAR_H;
         int segW = barW / 4;
         int seg3W = barW - segW * 3;
         int barMidY = barY + barH / 2;
         CockpitSetLabel(CockpitObj("BAR_TX0"), barX + segW / 2, barMidY, "SAFE", 9, clrWhite, "", ANCHOR_CENTER);
         CockpitSetLabel(CockpitObj("BAR_TX1"), barX + segW + segW / 2, barMidY, "CAUTION", 9, clrBlack, "", ANCHOR_CENTER);
         CockpitSetLabel(CockpitObj("BAR_TX2"), barX + 2 * segW + segW / 2, barMidY, "BLOCK", 9, clrBlack, "", ANCHOR_CENTER);
         CockpitSetLabel(CockpitObj("BAR_TX3"), barX + 3 * segW + seg3W / 2, barMidY, "KILL", 9, clrWhite, "", ANCHOR_CENTER);
         int markX = barX + (int)(frac * (barW - 1));
         CockpitSetLabel(CockpitObj("MARK"), markX, barY, CockpitRiskMarkerGlyph(), COCKPIT_MARK_FS, clrWhite, "Marlett", ANCHOR_BOTTOM);

         CockpitLayoutHeaderIcons(x, y, w, y + COCKPIT_DY_TITLE);

         ChartRedraw(0);
      }

      void CockpitDestroy()
      {
         for(int gi = 0; gi < 32; gi++)
         {
            string gn = COCKPIT_PREFIX + "GG" + IntegerToString(gi);
            if(ObjectFind(0, gn) >= 0) ObjectDelete(0, gn);
         }

         string names[];
         ArrayResize(names, 33);
         names[0] = CockpitObj("BG");
         names[1] = CockpitObj("BDR");
         names[2] = CockpitObj("TITLE");
         names[3] = CockpitObj("SYMTF");
         names[4] = CockpitObj("DIV_SYM");
         names[5] = CockpitObj("STATE");
         names[6] = CockpitObj("CTRL");
         names[7] = CockpitObj("DIV_STATE");
         names[8] = CockpitObj("HR");
         names[9] = CockpitObj("SEG0");
         names[10] = CockpitObj("SEG1");
         names[11] = CockpitObj("SEG2");
         names[12] = CockpitObj("SEG3");
         names[13] = CockpitObj("MARK");
         names[14] = CockpitObj("BAR_TX0");
         names[15] = CockpitObj("BAR_TX1");
         names[16] = CockpitObj("BAR_TX2");
         names[17] = CockpitObj("BAR_TX3");
         names[18] = CockpitObj("EXP");
         names[19] = CockpitObj("FLT");
         names[20] = CockpitObj("DIV_SPREAD");
         names[21] = CockpitObj("SPD");
         names[22] = CockpitObj("WIN");
         names[23] = CockpitObj("RSN");
         names[24] = CockpitObj("GRID_0");
         names[25] = CockpitObj("GRID_1");
         names[26] = CockpitObj("GRID_2");
         names[27] = CockpitObj("GRID_3");
         names[28] = CockpitObj("GRID_4");
         names[29] = CockpitObj("GRID_5");
         names[30] = CockpitObj("GRID_6");
         names[31] = CockpitObj("GRID_7");
         names[32] = CockpitObj("GRID_8");

         for(int i = 0; i < ArraySize(names); i++)
            if(ObjectFind(0, names[i]) >= 0) ObjectDelete(0, names[i]);
         g_CockpitCreated = false;
      }

      //+------------------------------------------------------------------+
      //| Points per 1 pip for this symbol (input override or Digits heuristic) |
      //+------------------------------------------------------------------+
      int ComputePointsPerPip()
      {
         if(PointsPerPip > 0)
            return PointsPerPip;
         int d = (int)MarketInfo(Symbol(), MODE_DIGITS);
         if(d == 3 || d == 5)
            return 10;
         if(d == 2)
         {
            string s = Symbol();
            if(StringFind(s, "XAU") >= 0 || StringFind(s, "GOLD") >= 0 ||
               StringFind(s, "xau") >= 0 || StringFind(s, "gold") >= 0)
               return 10;
         }
         return 1;
      }

      //+------------------------------------------------------------------+
      //| Lot / symbol constraints at init                                 |
      //+------------------------------------------------------------------+
      bool ValidateSymbolAndLots()
      {
         double minLot = MarketInfo(Symbol(), MODE_MINLOT);
         double maxLot = MarketInfo(Symbol(), MODE_MAXLOT);
         double step = MarketInfo(Symbol(), MODE_LOTSTEP);
         if(minLot <= 0.0 || maxLot <= 0.0 || step <= 0.0)
         {
            Print("ERROR: Invalid MODE_MINLOT/MODE_MAXLOT/MODE_LOTSTEP for ", Symbol());
            return false;
         }
         if(FixedLots < minLot - 1.0e-8 || FixedLots > maxLot + 1.0e-8)
         {
            Print("ERROR: FixedLots ", FixedLots, " out of range [", minLot, ", ", maxLot, "] for ", Symbol());
            return false;
         }
         double n = (FixedLots - minLot) / step;
         if(MathAbs(n - MathRound(n)) > 1.0e-6)
         {
            Print("ERROR: FixedLots ", FixedLots, " not aligned to lot step ", step, " (min ", minLot, ")");
            return false;
         }
         return true;
      }

      //+------------------------------------------------------------------+
      //| Regime: first tick of new bar only (closed-bar evaluation)         |
      //+------------------------------------------------------------------+
      void RegimeOnNewBarIfNeeded()
      {
         if(Time[0] == g_RegimeLastBarTime)
            return;
         g_RegimeLastBarTime = Time[0];
         if(!RegimeEnable)
            return;
         RegimeEvaluateClosedBar();
      }

      //+------------------------------------------------------------------+
      //| Regime conditions on last completed bar (shift 1)                 |
      //+------------------------------------------------------------------+
      void RegimeEvaluateClosedBar()
      {
         if(RegimeAction == REGIME_OFF)
         {
            g_RegimeBlocked = false;
            g_RegimeRecoveryCount = 0;
            return;
         }

         bool adxPersist = false;
         bool rangeBreak = false;

         int needBars = (int)MathMax(RegimeADXBars + 1, RegimeRangeBars + 2);
         if(Bars < needBars)
         {
            adxPersist = false;
            rangeBreak = false;
         }
         else
         {
            adxPersist = true;
            for(int sh = 1; sh <= RegimeADXBars; sh++)
            {
               double adxv = iADX(Symbol(), PERIOD_CURRENT, RegimeADXPeriod, PRICE_CLOSE, MODE_MAIN, sh);
               if(adxv == EMPTY_VALUE || adxv <= RegimeADXLevel)
               {
                  adxPersist = false;
                  break;
               }
            }

            double c = iClose(Symbol(), PERIOD_CURRENT, 1);
            double hh = iHigh(Symbol(), PERIOD_CURRENT, 2);
            double ll = iLow(Symbol(), PERIOD_CURRENT, 2);
            for(int s = 3; s <= RegimeRangeBars + 1; s++)
            {
               hh = MathMax(hh, iHigh(Symbol(), PERIOD_CURRENT, s));
               ll = MathMin(ll, iLow(Symbol(), PERIOD_CURRENT, s));
            }
            if(c > hh || c < ll)
               rangeBreak = true;
         }

         bool cond = (adxPersist || rangeBreak);

         if(cond)
         {
            g_RegimeBlocked = true;
            g_RegimeRecoveryCount = 0;
         }
         else
         {
            if(g_RegimeBlocked)
            {
               g_RegimeRecoveryCount++;
               if(g_RegimeRecoveryCount >= RegimeRecoveryBars)
               {
                  g_RegimeBlocked = false;
                  g_RegimeRecoveryCount = 0;
               }
            }
            else
               g_RegimeRecoveryCount = 0;
         }
      }

      //+------------------------------------------------------------------+
      //| Restore basket state from existing orders                        |
      //+------------------------------------------------------------------+
      void RestoreBasketState()
      {
         int count = 0;
         int direction = -1;
         double minPrice = 0.0;
         double maxPrice = 0.0;
         datetime earliestOpen = 0;
         
         for(int i = OrdersTotal() - 1; i >= 0; i--)
         {
            if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
            {
               if(OrderMagicNumber() == Magic && OrderSymbol() == Symbol())
               {
                  count++;
                  if(direction == -1)
                  {
                     direction = OrderType();
                  }
                  double op = OrderOpenPrice();
                  if(minPrice == 0.0 || op < minPrice) minPrice = op;
                  if(maxPrice == 0.0 || op > maxPrice) maxPrice = op;

                  datetime t = OrderOpenTime();
                  if(earliestOpen == 0 || t < earliestOpen) earliestOpen = t;
               }
            }
         }
         
         if(count > 0)
         {
            g_BasketExists = true;
            g_BasketDirection = direction;
            g_BasketHighestProfit = 0.0;
            // BUY basket: next grid below = use min open price; SELL: next grid above = use max
            g_LastGridPrice = (direction == OP_BUY) ? minPrice : maxPrice;
            Print("Basket restored: ", count, " orders, Direction: ", 
                  (direction == OP_BUY ? "BUY" : "SELL"));

            // Section 6 telemetry: restore basket lifecycle state.
            TelemetryResetLocal();
            datetime startTime = (earliestOpen > 0) ? earliestOpen : TimeCurrent();
            TelemetryOnBasketStart(startTime);
         }
         else
         {
            g_BasketExists = false;
            g_BasketDirection = -1;
            g_LastGridPrice = 0.0;

            TelemetryResetLocal();
         }
      }

      //+------------------------------------------------------------------+
      //| Try to adopt user-placed order(s) as basket (Phase-1 Manual mode) |
      //+------------------------------------------------------------------+
      void TryAdoptUserBasket()
      {
         // Removed in Stage B.
      }

      //+------------------------------------------------------------------+
      //| Check basket state consistency                                    |
      //+------------------------------------------------------------------+
      void CheckBasketStateConsistency()
      {
         if(g_BasketExists)
         {
            int count = GetBasketOrderCount();
            if(count == 0)
            {
               // Basket flattened outside our explicit close path (e.g., trailing SL hit).
               // Telemetry spec: write exactly one row at basket close.
               if(g_Telemetry_BasketActive && !g_Telemetry_WroteRowForActiveBasket)
               {
                  TelemetryWriteBasketCSVRow("OTHER", "", g_Telemetry_LastProfit,
                                             g_Telemetry_LastOrders, g_Telemetry_LastLots,
                                             TimeCurrent());
               }
               Print("Basket state reset - no orders found");
               ResetBasketState();
            }
         }
      }

      //+------------------------------------------------------------------+
      //| Reset basket state                                                |
      //+------------------------------------------------------------------+
      void ResetBasketState()
      {
         g_BasketExists = false;
         g_BasketDirection = -1;
         g_LastGridPrice = 0.0;
         g_BasketHighestProfit = 0.0;
         if(Bars > 0) { g_RefHigh = High[0]; g_RefLow = Low[0]; }
         else { g_RefHigh = Bid; g_RefLow = Ask; }
      }

      //+------------------------------------------------------------------+
      //| Get count of basket orders                                        |
      //+------------------------------------------------------------------+
      int GetBasketOrderCount()
      {
         int count = 0;
         for(int i = OrdersTotal() - 1; i >= 0; i--)
         {
            if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
            {
               if(OrderMagicNumber() == Magic && OrderSymbol() == Symbol())
               {
                  if(!g_BasketExists || OrderType() == g_BasketDirection)
                  {
                     count++;
                  }
               }
            }
         }
         return count;
      }

      //+------------------------------------------------------------------+
      //| Get total lots of basket orders                                 |
      //+------------------------------------------------------------------+
      double GetBasketTotalLots()
      {
         double lots = 0.0;
         for(int i = OrdersTotal() - 1; i >= 0; i--)
         {
            if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
            if(OrderMagicNumber() != Magic) continue;
            if(OrderSymbol() != Symbol()) continue;
            if(g_BasketExists && OrderType() != g_BasketDirection) continue;
            lots += OrderLots();
         }
         return lots;
      }

      //+------------------------------------------------------------------+
      //| Calculate basket profit                                           |
      //+------------------------------------------------------------------+
      double BasketProfit()
      {
         double profit = 0.0;
         for(int i = OrdersTotal() - 1; i >= 0; i--)
         {
            if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
            {
               if(OrderMagicNumber() == Magic && OrderSymbol() == Symbol())
               {
                  if(!g_BasketExists || OrderType() == g_BasketDirection)
                  {
                     profit += OrderProfit() + OrderSwap() + OrderCommission();
                  }
               }
            }
         }
         return profit;
      }

      //+------------------------------------------------------------------+
      //| Section 6 Telemetry helpers                                      |
      //+------------------------------------------------------------------+
      string TelemetryLastIDKey()
      {
         return "AGOLD___Baskets_LastID_" + IntegerToString(Magic) + "_" + Symbol();
      }

      string TelemetryActiveIDKey()
      {
         return "AGOLD___Baskets_ActiveID_" + IntegerToString(Magic) + "_" + Symbol();
      }

      string TelemetryRunBaseKey()
      {
         return "AGOLD___Baskets_Run_" + IntegerToString(AccountNumber()) + "_" + IntegerToString(Magic) + "_" + TelemetryNormalizeSymbol(Symbol());
      }

      string TelemetryRunStartTimeKey()    { return TelemetryRunBaseKey() + "_StartTime"; }
      string TelemetryRunStartBalanceKey() { return TelemetryRunBaseKey() + "_StartBalance"; }
      string TelemetryRunIDKey()           { return TelemetryRunBaseKey() + "_ID"; }

      string TelemetryBuildRunID(datetime runStartTime)
      {
         return IntegerToString(AccountNumber()) + "_" + IntegerToString(Magic) + "_" +
                TelemetryNormalizeSymbol(Symbol()) + "_" + IntegerToString((int)runStartTime);
      }

      string TelemetrySchemaV3Header()
      {
         return "AccountNumber,BrokerName,BasketID,Symbol,SymbolNormalized,Timeframe,StartTime,EndTime,DurationSeconds,Direction,OrdersCount,TotalLots,FixedLots,MaxOrdersConcurrent,MaxTotalLots,MaxFloatingDrawdownAbs,MaxFloatingProfit,ClosePL,CloseReason,OutcomeClass,SpreadAtEntry,EquityAtEntry,HeadroomAtEntry,MinHeadroom,TimesNearKill,ExposureBlocks,PipsStep,TakeProfit,KillEquityLevel,MaxOrdersInBasket,MaxTotalLotsInBasket,EquityAtExit,BalanceAfter,TradeDate,RunID,RunStartTime,RunStartBalance,EAName,EAVersion,Magic,PointsPerPip,Tral,TralStart,MaxSpread,TimeStart,TimeEnd,OpenTime,NewBasketDelaySeconds,SpeedEA,UseBasketTrailingTP,TrailingStart,TrailingStep,KillSwitchEnable,KillCooldownMinutes,RegimeEnable,RegimeAction,RegimeADXPeriod,RegimeADXLevel,RegimeADXBars,RegimeRangeBars,RegimeRecoveryBars,EnableTradingDaysFilter,TradeMonday,TradeTuesday,TradeWednesday,TradeThursday,TradeFriday,EnableRecoveryStepUp,RecoveryWaitMinutes,RecoveryMaxTotalLotsInBasket,CsvSchemaVersion";
      }

      bool TelemetryHeaderIsSchemaV3(string header)
      {
         return StringFind(header, "RunID") >= 0 &&
                StringFind(header, "RunStartTime") >= 0 &&
                StringFind(header, "RunStartBalance") >= 0 &&
                StringFind(header, "CsvSchemaVersion") >= 0;
      }

      bool TelemetryReadHeader(string &header)
      {
         header = "";
         int fh = FileOpen(TELEMETRY_FILE_NAME, FILE_READ | FILE_TXT | FILE_ANSI, 0, CP_UTF8);
         if(fh < 0) return false;
         header = FileReadString(fh);
         FileClose(fh);
         return header != "";
      }

      bool TelemetryFileIsSchemaV3()
      {
         string header = "";
         return TelemetryReadHeader(header) && TelemetryHeaderIsSchemaV3(header);
      }

      string TelemetryBool(bool value)
      {
         return value ? "1" : "0";
      }

      string TelemetryCsvEscape(string value)
      {
         bool quote = StringFind(value, ",") >= 0 ||
                      StringFind(value, "\"") >= 0 ||
                      StringFind(value, "\r") >= 0 ||
                      StringFind(value, "\n") >= 0;
         if(!quote) return value;
         StringReplace(value, "\"", "\"\"");
         return "\"" + value + "\"";
      }

      int TelemetryHeaderColumnIndex(string header, string columnName)
      {
         string columns[];
         int count = StringSplit(header, ',', columns);
         for(int i = 0; i < count; i++)
         {
            if(columns[i] == columnName)
               return i;
         }
         return -1;
      }

      void TelemetryPersistRunContext()
      {
         if(g_Telemetry_RunStartTime <= 0 || g_Telemetry_RunID == "") return;
         GlobalVariableSet(TelemetryRunStartTimeKey(), (double)g_Telemetry_RunStartTime);
         GlobalVariableSet(TelemetryRunStartBalanceKey(), g_Telemetry_RunStartBalance);
         GlobalVariableSet(TelemetryRunIDKey(), (double)g_Telemetry_RunStartTime);
      }

      bool TelemetryRestoreRunContextFromGlobals()
      {
         if(!GlobalVariableCheck(TelemetryRunStartTimeKey()) ||
            !GlobalVariableCheck(TelemetryRunStartBalanceKey()) ||
            !GlobalVariableCheck(TelemetryRunIDKey()))
            return false;

         g_Telemetry_RunStartTime = (datetime)GlobalVariableGet(TelemetryRunStartTimeKey());
         g_Telemetry_RunStartBalance = GlobalVariableGet(TelemetryRunStartBalanceKey());
         g_Telemetry_RunID = TelemetryBuildRunID(g_Telemetry_RunStartTime);
         return g_Telemetry_RunStartTime > 0 && g_Telemetry_RunID != "";
      }

      bool TelemetryRestoreRunContextFromCSV()
      {
         int fh = FileOpen(TELEMETRY_FILE_NAME, FILE_READ | FILE_TXT | FILE_ANSI, 0, CP_UTF8);
         if(fh < 0) return false;

         string header = FileReadString(fh);
         string row = FileReadString(fh);
         FileClose(fh);
         if(!TelemetryHeaderIsSchemaV3(header) || row == "") return false;

         int runIdIndex = TelemetryHeaderColumnIndex(header, "RunID");
         int runStartIndex = TelemetryHeaderColumnIndex(header, "RunStartTime");
         int runBalanceIndex = TelemetryHeaderColumnIndex(header, "RunStartBalance");
         if(runIdIndex < 0 || runStartIndex < 0 || runBalanceIndex < 0) return false;

         string values[];
         int valueCount = StringSplit(row, ',', values);
         if(valueCount <= runBalanceIndex) return false;

         datetime runStart = StringToTime(values[runStartIndex]);
         double runBalance = StringToDouble(values[runBalanceIndex]);
         string runId = values[runIdIndex];
         if(runStart <= 0 || runId == "") return false;

         g_Telemetry_RunStartTime = runStart;
         g_Telemetry_RunStartBalance = runBalance;
         g_Telemetry_RunID = runId;
         TelemetryPersistRunContext();
         return true;
      }

      bool TelemetryRunContextIsValid()
      {
         return g_Telemetry_RunStartTime > 0 && g_Telemetry_RunID != "";
      }

      void TelemetryClearRunContext()
      {
         g_Telemetry_RunStartTime = 0;
         g_Telemetry_RunStartBalance = 0.0;
         g_Telemetry_RunID = "";
         g_Telemetry_RunResetDeferred = false;
         g_Telemetry_SchemaBlocked = false;
         if(GlobalVariableCheck(TelemetryRunStartTimeKey())) GlobalVariableDel(TelemetryRunStartTimeKey());
         if(GlobalVariableCheck(TelemetryRunStartBalanceKey())) GlobalVariableDel(TelemetryRunStartBalanceKey());
         if(GlobalVariableCheck(TelemetryRunIDKey())) GlobalVariableDel(TelemetryRunIDKey());
      }

      bool TelemetryEnsureSchemaV3Header()
      {
         if(FileIsExist(TELEMETRY_FILE_NAME))
         {
            if(TelemetryFileIsSchemaV3()) return true;
            return false;
         }

         int fh = FileOpen(TELEMETRY_FILE_NAME, FILE_WRITE | FILE_TXT | FILE_ANSI, 0, CP_UTF8);
         if(fh < 0)
         {
            Print("Telemetry: unable to create schema-v3 CSV err=", GetLastError());
            return false;
         }
         FileWrite(fh, TelemetrySchemaV3Header());
         FileClose(fh);
         return true;
      }

      void TelemetryBeginRun(datetime runStartTime, double runStartBalance)
      {
         if(runStartTime <= 0) runStartTime = TimeCurrent();
         if(runStartBalance < 0.0) runStartBalance = AccountBalance();

         g_Telemetry_RunStartTime = runStartTime;
         g_Telemetry_RunStartBalance = runStartBalance;
         g_Telemetry_RunID = TelemetryBuildRunID(runStartTime);
         g_Telemetry_RunResetDeferred = false;
         g_Telemetry_SchemaBlocked = !TelemetryEnsureSchemaV3Header();
         if(g_Telemetry_SchemaBlocked)
         {
            Print("Telemetry: existing CSV is not schema v3. Back it up and reset it while flat before using this EA version.");
            return;
         }
         TelemetryPersistRunContext();
         Print("Telemetry: new reporting run started ID=", g_Telemetry_RunID,
               " balance=", DoubleToString(g_Telemetry_RunStartBalance, 2));
      }

      void TelemetryEnsureRunContext(bool forceCheck = false)
      {
         uint tickNow = GetTickCount();
         if(!forceCheck && g_Telemetry_LastRunFileCheckTick > 0 &&
            (tickNow - g_Telemetry_LastRunFileCheckTick) < 5000)
            return;
         g_Telemetry_LastRunFileCheckTick = tickNow;

         bool csvExists = FileIsExist(TELEMETRY_FILE_NAME);
         bool basketActive = g_BasketExists || g_Telemetry_BasketActive || GetBasketOrderCount() > 0;
         if(!csvExists)
         {
            if(basketActive)
            {
               if(!g_Telemetry_RunResetDeferred)
                  Print("Telemetry: CSV reset detected while a basket is active; new run deferred until flat.");
               g_Telemetry_RunResetDeferred = true;
               return;
            }

            TelemetryClearRunContext();
            TelemetryBeginRun(TimeCurrent(), AccountBalance());
            return;
         }

         if(!TelemetryFileIsSchemaV3())
         {
            if(!g_Telemetry_SchemaBlocked)
               Print("Telemetry: schema-v2 CSV detected. Back up/reset it while flat; no schema-v3 rows will be appended.");
            g_Telemetry_SchemaBlocked = true;
            return;
         }

         g_Telemetry_SchemaBlocked = false;
         if(TelemetryRunContextIsValid()) return;
         if(TelemetryRestoreRunContextFromGlobals()) return;
         if(TelemetryRestoreRunContextFromCSV()) return;

         if(!basketActive)
            TelemetryBeginRun(TimeCurrent(), AccountBalance());
      }

      double TelemetryNearKillFraction()
      {
         // NearKill threshold is specified as 10–15% above the kill point.
         // Kill point corresponds to headroom=0; threshold is headroom <= KillEquityLevel*frac.
         return 0.12;
      }

      double TelemetryNearKillResetFraction()
      {
         // Require headroom to recover beyond the near-kill edge before re-arming.
         // This hysteresis avoids noisy multi-counting on threshold oscillation.
         return 0.02;
      }

      string FormatServerTime(datetime t)
      {
         MqlDateTime dt;
         TimeToStruct(t, dt);
         return StringFormat("%04d-%02d-%02d %02d:%02d:%02d",
                              dt.year, dt.mon, dt.day,
                              dt.hour, dt.min, dt.sec);
      }

      string FormatTradeDate(datetime t)
      {
         MqlDateTime dt;
         TimeToStruct(t, dt);
         return StringFormat("%04d-%02d-%02d", dt.year, dt.mon, dt.day);
      }

      string TelemetrySymbolToUpper(string s)
      {
         string r = "";
         int n = StringLen(s);
         for(int i = 0; i < n; i++)
         {
            int ch = StringGetChar(s, i);
            if(ch >= 97 && ch <= 122)
               ch = ch - 32;
            r = r + CharToStr((uchar)ch);
         }
         return r;
      }

      string TelemetryNormalizeSymbol(string sym)
      {
         int plusPos = StringFind(sym, "+");
         if(plusPos > 0)
            sym = StringSubstr(sym, 0, plusPos);
         int dotPos = StringFind(sym, ".");
         if(dotPos > 0)
            sym = StringSubstr(sym, 0, dotPos);

         return TelemetrySymbolToUpper(sym);
      }

      double GetHeadroomValue(double equity, double balance)
      {
         // Spec alignment (matches updated kill math for V2/V3):
         // Headroom = Equity - (Balance - KillEquityLevel)
         return equity - (balance - KillEquityLevel);
      }

      void TelemetryResetLocal()
      {
         g_Telemetry_BasketActive = false;
         g_Telemetry_WroteRowForActiveBasket = false;
         g_Telemetry_BasketID = 0;
         g_Telemetry_StartTime = 0;
         g_Telemetry_EndTime = 0;
         g_Telemetry_Direction = "";
         g_Telemetry_MaxOrdersConcurrent = 0;
         g_Telemetry_MaxTotalLots = 0.0;
         g_Telemetry_MaxFloatingDrawdownAbs = 0.0;
         g_Telemetry_MaxFloatingProfit = 0.0;
         g_Telemetry_ClosePL = 0.0;
         g_Telemetry_SpreadAtEntry = -1.0;
         g_Telemetry_EquityAtEntry = -1.0;
         g_Telemetry_HeadroomAtEntry = -1.0;
         g_Telemetry_MinHeadroom = 0.0;
         g_Telemetry_TimesNearKill = 0;
         g_Telemetry_HeadroomPrevAboveNearKill = true;
         g_Telemetry_ExposureBlocks = 0;
         g_Telemetry_KillClosePL_Stored = false;
         g_Telemetry_KillOrdersAtClose = 0;
         g_Telemetry_KillLotsAtClose = 0.0;
         g_Telemetry_LastOrders = 0;
         g_Telemetry_LastLots = 0.0;
         g_Telemetry_LastProfit = 0.0;
      }

      int TelemetryEnsureActiveBasketID()
      {
         string activeKey = TelemetryActiveIDKey();
         string lastKey = TelemetryLastIDKey();

         if(GlobalVariableCheck(activeKey))
         {
            double existing = GlobalVariableGet(activeKey);
            int existingID = (int)existing;
            if(existingID > 0)
               return existingID;
         }

         int lastID = 0;
         if(GlobalVariableCheck(lastKey))
            lastID = (int)GlobalVariableGet(lastKey);

         int newID = lastID + 1;
         GlobalVariableSet(lastKey, (double)newID);
         GlobalVariableSet(activeKey, (double)newID);
         return newID;
      }

      void TelemetryClearActiveBasketID()
      {
         string activeKey = TelemetryActiveIDKey();
         // Keep last-id for sequential continuity.
         if(GlobalVariableCheck(activeKey))
            GlobalVariableSet(activeKey, 0.0);
      }

      void TelemetryUpdateBasketStats()
      {
         if(!g_Telemetry_BasketActive) return;

         int orders = 0;
         double lots = 0.0;
         double profit = 0.0;

         for(int i = OrdersTotal() - 1; i >= 0; i--)
         {
            if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
            if(OrderMagicNumber() != Magic) continue;
            if(OrderSymbol() != Symbol()) continue;

            orders++;
            lots += OrderLots();
            profit += OrderProfit() + OrderSwap() + OrderCommission();
         }

         if(orders > g_Telemetry_MaxOrdersConcurrent)
            g_Telemetry_MaxOrdersConcurrent = orders;
         if(lots > g_Telemetry_MaxTotalLots)
            g_Telemetry_MaxTotalLots = lots;

         if(profit > g_Telemetry_MaxFloatingProfit)
            g_Telemetry_MaxFloatingProfit = profit;

         if(profit < 0.0)
         {
            double lossAbs = -profit;
            if(lossAbs > g_Telemetry_MaxFloatingDrawdownAbs)
               g_Telemetry_MaxFloatingDrawdownAbs = lossAbs;
         }

         double equity = AccountEquity();
         double balance = AccountBalance();
         double headroom = GetHeadroomValue(equity, balance);
         if(headroom < g_Telemetry_MinHeadroom)
            g_Telemetry_MinHeadroom = headroom;

         double nearKillThreshold = KillEquityLevel * TelemetryNearKillFraction();
         if(nearKillThreshold < 0.0) nearKillThreshold = 0.0;

         double nearKillResetThreshold = nearKillThreshold + (KillEquityLevel * TelemetryNearKillResetFraction());
         if(nearKillResetThreshold < nearKillThreshold)
            nearKillResetThreshold = nearKillThreshold;

         bool insideNearKill = (headroom <= nearKillThreshold);
         if(insideNearKill && g_Telemetry_HeadroomPrevAboveNearKill)
         {
            g_Telemetry_TimesNearKill++;
            g_Telemetry_HeadroomPrevAboveNearKill = false;
         }
         else if(headroom >= nearKillResetThreshold)
         {
            g_Telemetry_HeadroomPrevAboveNearKill = true;
         }

         // Persist last-known snapshot for cases where the basket closes via broker-side SL.
         g_Telemetry_LastOrders = orders;
         g_Telemetry_LastLots = lots;
         g_Telemetry_LastProfit = profit;
      }

      void TelemetryOnBasketStart(datetime startTime)
      {
         TelemetryEnsureRunContext(true);
         g_Telemetry_BasketActive = true;
         g_Telemetry_WroteRowForActiveBasket = false;
         g_Telemetry_BasketID = TelemetryEnsureActiveBasketID();
         g_Telemetry_StartTime = startTime;
         g_Telemetry_EndTime = 0;
         g_Telemetry_Direction = (g_BasketDirection == OP_BUY ? "BUY" : "SELL");
         g_Telemetry_MaxOrdersConcurrent = 0;
         g_Telemetry_MaxTotalLots = 0.0;
         g_Telemetry_MaxFloatingDrawdownAbs = 0.0;
         g_Telemetry_MaxFloatingProfit = 0.0;
         g_Telemetry_TimesNearKill = 0;
         g_Telemetry_ExposureBlocks = 0;
         g_Telemetry_KillClosePL_Stored = false;

         g_Telemetry_FixedLotsSnap = FixedLots;
         g_Telemetry_PipsStepSnap = PipsStep;
         g_Telemetry_TakeProfitSnap = TakeProfit;
         g_Telemetry_KillEquityLevelSnap = KillEquityLevel;
         g_Telemetry_MaxOrdersInBasketSnap = MaxOrdersInBasket;
         g_Telemetry_MaxTotalLotsInBasketSnap = MaxTotalLotsInBasket;
         g_Telemetry_MagicSnap = Magic;
         g_Telemetry_PointsPerPipSnap = PointsPerPip;
         g_Telemetry_TralSnap = Tral;
         g_Telemetry_TralStartSnap = TralStart;
         g_Telemetry_MaxSpreadSnap = MaxSpread;
         g_Telemetry_TimeStartSnap = TimeStart;
         g_Telemetry_TimeEndSnap = TimeEnd;
         g_Telemetry_OpenTimeSnap = OpenTime;
         g_Telemetry_NewBasketDelaySecondsSnap = NewBasketDelaySeconds;
         g_Telemetry_SpeedEASnap = SpeedEA;
         g_Telemetry_UseBasketTrailingTPSnap = UseBasketTrailingTP;
         g_Telemetry_TrailingStartSnap = TrailingStart;
         g_Telemetry_TrailingStepSnap = TrailingStep;
         g_Telemetry_KillSwitchEnableSnap = KillSwitchEnable;
         g_Telemetry_KillCooldownMinutesSnap = KillCooldownMinutes;
         g_Telemetry_RegimeEnableSnap = RegimeEnable;
         g_Telemetry_RegimeActionSnap = (int)RegimeAction;
         g_Telemetry_RegimeADXPeriodSnap = RegimeADXPeriod;
         g_Telemetry_RegimeADXLevelSnap = RegimeADXLevel;
         g_Telemetry_RegimeADXBarsSnap = RegimeADXBars;
         g_Telemetry_RegimeRangeBarsSnap = RegimeRangeBars;
         g_Telemetry_RegimeRecoveryBarsSnap = RegimeRecoveryBars;
         g_Telemetry_EnableTradingDaysFilterSnap = EnableTradingDaysFilter;
         g_Telemetry_TradeMondaySnap = TradeMonday;
         g_Telemetry_TradeTuesdaySnap = TradeTuesday;
         g_Telemetry_TradeWednesdaySnap = TradeWednesday;
         g_Telemetry_TradeThursdaySnap = TradeThursday;
         g_Telemetry_TradeFridaySnap = TradeFriday;
         g_Telemetry_EnableRecoveryStepUpSnap = EnableRecoveryStepUp;
         g_Telemetry_RecoveryWaitMinutesSnap = RecoveryWaitMinutes;
         g_Telemetry_RecoveryMaxTotalLotsInBasketSnap = RecoveryMaxTotalLotsInBasket;

         g_Telemetry_SpreadAtEntry = (Ask - Bid) / Point;
         g_Telemetry_EquityAtEntry = AccountEquity();
         double balanceAtEntry = AccountBalance();
         g_Telemetry_HeadroomAtEntry = GetHeadroomValue(g_Telemetry_EquityAtEntry, balanceAtEntry);
         g_Telemetry_MinHeadroom = g_Telemetry_HeadroomAtEntry;

         double nearKillThreshold = KillEquityLevel * TelemetryNearKillFraction();
         if(nearKillThreshold < 0.0) nearKillThreshold = 0.0;
         g_Telemetry_HeadroomPrevAboveNearKill = (g_Telemetry_MinHeadroom >= nearKillThreshold);

         // Seed max stats based on current basket state
         TelemetryUpdateBasketStats();
      }

      void TelemetryWriteBasketCSVRow(string closeReason, string outcomeClass, double closePL, int ordersAtClose, double totalLotsAtClose, datetime endTime)
      {
         if(!g_Telemetry_BasketActive) return;
         if(g_Telemetry_WroteRowForActiveBasket) return;

         // A deletion/reset during an active basket belongs to the next run only.
         // Do not recreate or append the closing old basket into that new file.
         TelemetryEnsureRunContext(true);
         if(g_Telemetry_RunResetDeferred || g_Telemetry_SchemaBlocked ||
            !TelemetryRunContextIsValid() || !FileIsExist(TELEMETRY_FILE_NAME))
         {
            Print("Telemetry: basket row skipped because reporting run reset/schema handling is pending.");
            TelemetryClearActiveBasketID();
            TelemetryResetLocal();
            return;
         }

         g_Telemetry_WroteRowForActiveBasket = true;

         int orders = ordersAtClose;
         double lots = totalLotsAtClose;

         double equityAtEntry = g_Telemetry_EquityAtEntry;
         double headroomAtEntry = g_Telemetry_HeadroomAtEntry;
         double minHeadroom = g_Telemetry_MinHeadroom;

         // Calculate outcome if caller provided empty
         if(outcomeClass == "")
         {
            if(closeReason == "KILL") outcomeClass = "KILL";
            else if(closePL > 0.0)
            {
               if(g_Telemetry_MaxFloatingDrawdownAbs > 0.0) outcomeClass = "RECOVERY_PROFIT";
               else outcomeClass = "NORMAL_PROFIT";
            }
            else
               outcomeClass = "OTHER";
         }

         string dirStr = g_Telemetry_Direction;
         if(dirStr == "") dirStr = (g_BasketDirection == OP_BUY ? "BUY" : "SELL");

         string brokerName = AccountCompany();
         string accountNumber = IntegerToString(AccountNumber());
         string timeframe = IntegerToString(Period());
         string startStr = FormatServerTime(g_Telemetry_StartTime);
         string endStr = FormatServerTime(endTime);

         string symbolNormalized = TelemetryNormalizeSymbol(Symbol());
         double equityAtExit = AccountEquity();
         double balanceAfter = AccountBalance();

         int durationSeconds = 0;
         if(endTime > g_Telemetry_StartTime)
            durationSeconds = (int)(endTime - g_Telemetry_StartTime);

         string closeReasonOut = closeReason;
         if(closeReasonOut != "TP" && closeReasonOut != "KILL")
            closeReasonOut = "OTHER";

         // Build one CSV line (comma-separated)
         string line = "";
         line = line + accountNumber + "," + TelemetryCsvEscape(brokerName) + "," + IntegerToString(g_Telemetry_BasketID) + ",";
         line = line + TelemetryCsvEscape(Symbol()) + "," + TelemetryCsvEscape(symbolNormalized) + "," + timeframe + "," + startStr + "," + endStr + ",";
         line = line + IntegerToString(durationSeconds) + "," + TelemetryCsvEscape(dirStr) + ",";
         line = line + IntegerToString(orders) + "," + DoubleToString(lots, 2) + "," + DoubleToString(g_Telemetry_FixedLotsSnap, 2) + ",";
         line = line + IntegerToString(g_Telemetry_MaxOrdersConcurrent) + "," + DoubleToString(g_Telemetry_MaxTotalLots, 2) + ",";
         line = line + DoubleToString(g_Telemetry_MaxFloatingDrawdownAbs, 2) + "," + DoubleToString(g_Telemetry_MaxFloatingProfit, 2) + ",";
         line = line + DoubleToString(closePL, 2) + "," + TelemetryCsvEscape(closeReasonOut) + "," + TelemetryCsvEscape(outcomeClass) + ",";
         line = line + DoubleToString(g_Telemetry_SpreadAtEntry, 0) + ",";
         line = line + DoubleToString(equityAtEntry, 2) + ",";
         line = line + DoubleToString(headroomAtEntry, 2) + ",";
         line = line + DoubleToString(minHeadroom, 2) + ",";
         line = line + IntegerToString(g_Telemetry_TimesNearKill) + ",";
         line = line + IntegerToString(g_Telemetry_ExposureBlocks) + ",";
         line = line + IntegerToString(g_Telemetry_PipsStepSnap) + ",";
         line = line + DoubleToString(g_Telemetry_TakeProfitSnap, 2) + ",";
         line = line + DoubleToString(g_Telemetry_KillEquityLevelSnap, 2) + ",";
         line = line + IntegerToString(g_Telemetry_MaxOrdersInBasketSnap) + ",";
         line = line + DoubleToString(g_Telemetry_MaxTotalLotsInBasketSnap, 2) + ",";
         line = line + DoubleToString(equityAtExit, 2) + ",";
         line = line + DoubleToString(balanceAfter, 2) + ",";
         line = line + FormatTradeDate(g_Telemetry_StartTime) + ",";
         line = line + TelemetryCsvEscape(g_Telemetry_RunID) + ",";
         line = line + FormatServerTime(g_Telemetry_RunStartTime) + ",";
         line = line + DoubleToString(g_Telemetry_RunStartBalance, 2) + ",";
         line = line + TelemetryCsvEscape("AmmarTradingGoldEA") + ",";
         line = line + TelemetryCsvEscape("3.00") + ",";
         line = line + IntegerToString(g_Telemetry_MagicSnap) + ",";
         line = line + IntegerToString(g_Telemetry_PointsPerPipSnap) + ",";
         line = line + IntegerToString(g_Telemetry_TralSnap) + ",";
         line = line + IntegerToString(g_Telemetry_TralStartSnap) + ",";
         line = line + IntegerToString(g_Telemetry_MaxSpreadSnap) + ",";
         line = line + IntegerToString(g_Telemetry_TimeStartSnap) + ",";
         line = line + IntegerToString(g_Telemetry_TimeEndSnap) + ",";
         line = line + IntegerToString(g_Telemetry_OpenTimeSnap) + ",";
         line = line + IntegerToString(g_Telemetry_NewBasketDelaySecondsSnap) + ",";
         line = line + IntegerToString(g_Telemetry_SpeedEASnap) + ",";
         line = line + TelemetryBool(g_Telemetry_UseBasketTrailingTPSnap) + ",";
         line = line + DoubleToString(g_Telemetry_TrailingStartSnap, 2) + ",";
         line = line + DoubleToString(g_Telemetry_TrailingStepSnap, 2) + ",";
         line = line + TelemetryBool(g_Telemetry_KillSwitchEnableSnap) + ",";
         line = line + IntegerToString(g_Telemetry_KillCooldownMinutesSnap) + ",";
         line = line + TelemetryBool(g_Telemetry_RegimeEnableSnap) + ",";
         line = line + IntegerToString(g_Telemetry_RegimeActionSnap) + ",";
         line = line + IntegerToString(g_Telemetry_RegimeADXPeriodSnap) + ",";
         line = line + DoubleToString(g_Telemetry_RegimeADXLevelSnap, 2) + ",";
         line = line + IntegerToString(g_Telemetry_RegimeADXBarsSnap) + ",";
         line = line + IntegerToString(g_Telemetry_RegimeRangeBarsSnap) + ",";
         line = line + IntegerToString(g_Telemetry_RegimeRecoveryBarsSnap) + ",";
         line = line + TelemetryBool(g_Telemetry_EnableTradingDaysFilterSnap) + ",";
         line = line + TelemetryBool(g_Telemetry_TradeMondaySnap) + ",";
         line = line + TelemetryBool(g_Telemetry_TradeTuesdaySnap) + ",";
         line = line + TelemetryBool(g_Telemetry_TradeWednesdaySnap) + ",";
         line = line + TelemetryBool(g_Telemetry_TradeThursdaySnap) + ",";
         line = line + TelemetryBool(g_Telemetry_TradeFridaySnap) + ",";
         line = line + TelemetryBool(g_Telemetry_EnableRecoveryStepUpSnap) + ",";
         line = line + IntegerToString(g_Telemetry_RecoveryWaitMinutesSnap) + ",";
         line = line + DoubleToString(g_Telemetry_RecoveryMaxTotalLotsInBasketSnap, 2) + ",";
         line = line + "3";

         string fileName = TELEMETRY_FILE_NAME;
         bool wrote = false;

         for(int attempt = 0; attempt < 2 && !wrote; attempt++)
         {
            // Use FILE_TXT + manual comma-separated lines to avoid CSV-escaping differences.
            int fh = FileOpen(fileName, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI, 0, CP_UTF8);
            if(fh < 0)
            {
               Print("Telemetry: FileOpen failed attempt=", attempt, " err=", GetLastError());
               Sleep(1000);
               continue;
            }
            else
            {
               // Never write schema-v3 beneath a legacy or externally-corrupted header.
               if(FileSize(fh) == 0)
               {
                  FileClose(fh);
                  Print("Telemetry: write skipped because CSV header is not schema v3.");
                  break;
               }
               FileSeek(fh, 0, SEEK_SET);
               string header = FileReadString(fh);
               if(!TelemetryHeaderIsSchemaV3(header))
               {
                  FileClose(fh);
                  Print("Telemetry: write skipped because CSV header is not schema v3.");
                  break;
               }
               FileSeek(fh, 0, SEEK_END);
            }

            FileWrite(fh, line);
            FileClose(fh);
            wrote = true;
         }

         if(!wrote)
            Print("Telemetry: write skipped (all attempts failed).");

         TelemetryClearActiveBasketID();
         TelemetryResetLocal();
      }

      //+------------------------------------------------------------------+
      //| Calculate basket drawdown percent                                 |
      //+------------------------------------------------------------------+
      double BasketDrawdownPercent()
      {
         return 0.0;
      }

      //+------------------------------------------------------------------+
      //| Calculate equity drawdown percent                                 |
      //+------------------------------------------------------------------+
      double EquityDrawdownPercent()
      {
         if(g_InitialEquity <= 0) return 0.0;
         
         double currentEquity = AccountEquity();
         if(currentEquity >= g_InitialEquity) return 0.0;
         
         double dd = g_InitialEquity - currentEquity;
         return (dd / g_InitialEquity) * 100.0;
      }

      //+------------------------------------------------------------------+
      //| Check if spread is acceptable                                     |
      //+------------------------------------------------------------------+
      bool CurrentSpreadOK()
      {
         double spread = (Ask - Bid) / Point;
         if(spread > g_MaxSpreadPoints)
         {
            Print("Spread too high: ", spread, " points (max: ", g_MaxSpreadPoints, " points = ", MaxSpread, " pips)");
            return false;
         }
         return true;
      }

      //+------------------------------------------------------------------+
      //| Check volatility                                                  |
      //+------------------------------------------------------------------+
      bool VolatilityOK(bool forNewBasket)
      {
         return true;
      }

      //+------------------------------------------------------------------+
      //| Detect sharp/impulsive price move (range vs average range)        |
      //+------------------------------------------------------------------+
      bool ImpulseDetected()
      {
         return false;
      }

      //+------------------------------------------------------------------+
      //| Check remaining exposure (free margin) above threshold             |
      //+------------------------------------------------------------------+
      bool RemainingExposureOK()
      {
         return true;
      }

      //+------------------------------------------------------------------+
      //| Check trading hours                                               |
      //+------------------------------------------------------------------+
      bool WithinTradingHours()
      {
         int currentHour = Hour();
         if(TimeStart <= TimeEnd)
         {
            return (currentHour >= TimeStart && currentHour <= TimeEnd);
         }
         else
         {
            // Overnight session
            return (currentHour >= TimeStart || currentHour <= TimeEnd);
         }
      }

      //+------------------------------------------------------------------+
      //| Check if new basket opening is allowed by weekday filter         |
      //+------------------------------------------------------------------+
      bool TradingDayAllowsNewBasket()
      {
         if(!EnableTradingDaysFilter)
            return true;

         int dow = TimeDayOfWeek(TimeCurrent()); // 0=Sun,1=Mon,...,6=Sat
         if(dow == 1) return TradeMonday;
         if(dow == 2) return TradeTuesday;
         if(dow == 3) return TradeWednesday;
         if(dow == 4) return TradeThursday;
         if(dow == 5) return TradeFriday;
         return false;
      }

      //+------------------------------------------------------------------+
      //| Check margin                                                      |
      //+------------------------------------------------------------------+
      bool MarginOK()
      {
         return true;
      }

      //+------------------------------------------------------------------+
      //| Open first trade automatically using simple momentum (EntryMode Auto) |
      //+------------------------------------------------------------------+
      void OpenAutoEntry()
      {
         if(!CoreOpenGatesPass(true))
         {
            ResetPendingNewBasketEntry();
            return;
         }
         if(!TradingDayAllowsNewBasket())
         {
            ResetPendingNewBasketEntry();
            return;
         }

         if(RegimeEnable && RegimeAction == REGIME_LOCK && g_RegimeBlocked)
         {
            ResetPendingNewBasketEntry();
            return;
         }

         double stepPoints = GetAdjustedStepPoints(true);
         double stepPrice = stepPoints * Point;
         bool sellReady = (g_RefHigh > 0.0 && Bid <= (g_RefHigh - stepPrice));
         bool buyReady = (g_RefLow > 0.0 && Ask >= (g_RefLow + stepPrice));
         if(!sellReady && !buyReady)
         {
            ResetPendingNewBasketEntry();
            return;
         }

         int direction = -1;
         if(sellReady && buyReady)
         {
            double sellDistance = g_RefHigh - Bid;
            double buyDistance = Ask - g_RefLow;
            direction = (sellDistance >= buyDistance) ? OP_SELL : OP_BUY;
         }
         else
         {
            direction = sellReady ? OP_SELL : OP_BUY;
         }

         if(!NewBasketDelayElapsed(direction, TimeCurrent(), NewBasketDelaySeconds))
            return;

         double price = (direction == OP_BUY) ? Ask : Bid;
         int ticket = OrderSend(Symbol(), direction, FixedLots, price, g_MaxBasketSlippagePoints,
                              0, 0, "StageB Entry", Magic, 0,
                              (direction == OP_BUY) ? clrBlue : clrRed);
         if(ticket <= 0)
         {
            Print("Auto entry failed. Error: ", GetLastError());
            return;
         }

         ResetPendingNewBasketEntry();

         g_BasketExists = true;
         g_BasketDirection = direction;
         g_LastGridPrice = price;
         g_BasketHighestProfit = 0.0;
         g_BasketWorstProfit = MathMin(0.0, BasketProfit());
         g_LastAnyOpenTime = TimeCurrent();
         g_LastFirstOpenTime = TimeCurrent();
         g_LastBarTime = (Bars > 0) ? Time[0] : TimeCurrent();

         // Section 6 telemetry: initialize new basket lifecycle
         TelemetryResetLocal();
         TelemetryOnBasketStart(g_LastFirstOpenTime);

         if(direction == OP_SELL)
         {
            g_RefHigh = Bid;
            g_RefLow = 0.0;
         }
         else
         {
            g_RefLow = Ask;
            g_RefHigh = 0.0;
         }
      }

      //+------------------------------------------------------------------+
      //| Handle grid logic                                                 |
      //+------------------------------------------------------------------+
      void HandleGrid()
      {
         if(!g_BasketExists) return;

         double stepPoints = GetAdjustedStepPoints(false);
         double stepPrice = stepPoints * Point;
         double currentPrice = (g_BasketDirection == OP_BUY) ? Ask : Bid;
         bool trigger = false;

         if(g_BasketDirection == OP_SELL)
            trigger = (g_RefHigh > 0.0 && Bid <= (g_RefHigh - stepPrice));
         else
            trigger = (g_RefLow > 0.0 && Ask >= (g_RefLow + stepPrice));

         if(!trigger) return;

         // ExposureBlocks counting: trigger happened, so an add would be attempted
         // unless gates block it (specifically Exposure Cap).
         if(!CoreOpenGatesPass(false))
         {
            if(g_LastOpenBlockedByExposureCap)
            {
               bool recoveryOpened = TryOpenRecoveryAdd(currentPrice);
               if(!recoveryOpened && g_Telemetry_BasketActive)
                  g_Telemetry_ExposureBlocks++;
            }
            return;
         }

         int ticket = OrderSend(Symbol(), g_BasketDirection, FixedLots, currentPrice,
                              g_MaxBasketSlippagePoints, 0, 0, "StageB Add",
                              Magic, 0, (g_BasketDirection == OP_BUY) ? clrBlue : clrRed);
         if(ticket <= 0)
         {
            Print("Grid expansion failed. Error: ", GetLastError());
            return;
         }

         if(g_Telemetry_BasketActive)
            TelemetryUpdateBasketStats();

         g_LastGridPrice = currentPrice;
         g_LastGridAddTime = TimeCurrent();
         g_LastAnyOpenTime = TimeCurrent();
         g_LastBarTime = (Bars > 0) ? Time[0] : TimeCurrent();

         // Best-fit Stage A: reset reference after each add
         if(g_BasketDirection == OP_SELL)
            g_RefHigh = Bid;
         else
            g_RefLow = Ask;
      }

      //+------------------------------------------------------------------+
      //| Handle exit logic                                                 |
      //+------------------------------------------------------------------+
      void HandleExit()
      {
         // (1) Per-order trailing — unchanged: only when GetBasketOrderCount()==1, points-based SL trail.
         HandlePerOrderTrailing();

         double profit = BasketProfit();
         if(profit > g_BasketHighestProfit)
            g_BasketHighestProfit = profit;

         // (2) Fixed basket TP — always evaluated first when UseBasketTrailingTP is true (same as legacy).
         // (3) Basket-level profit trailing — optional; retracement from basket peak profit in account $.
         if(UseBasketTrailingTP)
         {
            if(profit >= TakeProfit)
               CloseBasket("StageB TP");
            else if(g_BasketHighestProfit >= TrailingStart && profit <= g_BasketHighestProfit - TrailingStep)
               CloseBasket("Trailing TP");
         }
         else
         {
            if(profit >= TakeProfit)
               CloseBasket("StageB TP");
         }
      }

      //+------------------------------------------------------------------+
      //| Check emergency close conditions                                  |
      //+------------------------------------------------------------------+
      // EmergencyExit: controlled, configurable; minimizes damage, no blind liquidation
      void CheckEmergencyClose()
      {
         // Removed in Stage B.
      }

      //+------------------------------------------------------------------+
      //| Close entire basket                                               |
      //+------------------------------------------------------------------+
      void CloseBasket(string reason)
      {
         Print("=== CLOSING BASKET ===");
         Print("Reason: ", reason);
         Print("Profit: ", BasketProfit());

         // Section 6 telemetry: capture close snapshot BEFORE orders are actually closed.
         string closeReasonOut = "OTHER";
         if(StringFind(reason, "StageB TP") >= 0 || StringFind(reason, "Trailing TP") >= 0)
            closeReasonOut = "TP";
         else if(StringFind(reason, "KillSwitch") >= 0)
            closeReasonOut = "KILL";

         double closePL = BasketProfit();
         int ordersAtClose = GetBasketOrderCount();
         double lotsAtClose = GetBasketTotalLots();
         
         int attempts = 0;
         int maxAttempts = 3;
         
         bool closeAllManaged = (StringFind(reason, "KillSwitch") >= 0);
         while(GetBasketOrderCount() > 0 && attempts < maxAttempts)
         {
            attempts++;
            
            for(int i = OrdersTotal() - 1; i >= 0; i--)
            {
               if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
               {
                  if(OrderMagicNumber() == Magic && OrderSymbol() == Symbol())
                  {
                     if(closeAllManaged || !g_BasketExists || OrderType() == g_BasketDirection)
                     {
                        double closePrice = (OrderType() == OP_BUY) ? Bid : Ask;
                        bool closed = OrderClose(OrderTicket(), OrderLots(), closePrice, 
                                                g_MaxBasketSlippagePoints, clrWhite);
                        
                        if(!closed)
                        {
                           Print("Failed to close order ", OrderTicket(), ". Error: ", GetLastError());
                           Sleep(1000);
                        }
                        else
                        {
                           Print("Closed order ", OrderTicket());
                        if(g_Telemetry_BasketActive)
                           TelemetryUpdateBasketStats();
                        }
                     }
                  }  
               }
            }
            
            if(GetBasketOrderCount() > 0)
            {
               Sleep(2000);
            }
         }
         
         // If basket is flat, write telemetry row exactly once.
         if(GetBasketOrderCount() == 0)
            TelemetryWriteBasketCSVRow(closeReasonOut, "", closePL, ordersAtClose, lotsAtClose, TimeCurrent());

         // Reset state
         ResetBasketState();
         
         Print("=== BASKET CLOSED ===");
         Print("Remaining orders: ", GetBasketOrderCount());
      }

      //+------------------------------------------------------------------+
      //| Close ALL market positions on the account (KillSwitch)          |
      //+------------------------------------------------------------------+
      bool CloseAllPositionsForKillSwitch()
      {
         // Kill switch must flatten the entire account, regardless of symbol/magic.
         // Only closes market positions (OP_BUY/OP_SELL). Pending orders are not affected.
         for(int i = OrdersTotal() - 1; i >= 0; i--)
         {
            if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
            int type = OrderType();
            if(type != OP_BUY && type != OP_SELL) continue;

            double closePrice = (type == OP_BUY) ? Bid : Ask;
            bool closed = OrderClose(OrderTicket(), OrderLots(), closePrice,
                                    g_MaxBasketSlippagePoints, clrWhite);
            if(!closed)
               Print("KillSwitch: OrderClose failed. ticket=", OrderTicket(), ", err=", GetLastError());
         else if(g_Telemetry_BasketActive)
            TelemetryUpdateBasketStats();
         }

         // If any market positions remain, the kill closure is not complete yet.
         for(int j = OrdersTotal() - 1; j >= 0; j--)
         {
            if(!OrderSelect(j, SELECT_BY_POS, MODE_TRADES)) continue;
            int type2 = OrderType();
            if(type2 == OP_BUY || type2 == OP_SELL)
               return false;
         }

         return true;
      }

      //+------------------------------------------------------------------+
      //| Update on-chart comment                                           |
      //+------------------------------------------------------------------+
      void UpdateComment()
      {
         string lines[];
         ArrayResize(lines, COMMENT_MAX_LINES);
         int n = 0;
         lines[n++] = "=== Ammar Trading Gold EA ===";
         lines[n++] = "";
         lines[n++] = "Magic: " + IntegerToString(Magic);
         lines[n++] = "";
         lines[n++] = "State: " + StateToText(g_SystemState);
         lines[n++] = "";
         lines[n++] = "Basket: " + (g_BasketExists ? (g_BasketDirection == OP_BUY ? "BUY" : "SELL") : "NONE");
         lines[n++] = "";
         lines[n++] = "Orders: " + IntegerToString(GetBasketOrderCount());
         lines[n++] = "";
         lines[n++] = "Profit: " + DoubleToString(BasketProfit(), 2) + " " + AccountCurrency();
         lines[n++] = "";
         lines[n++] = "Basket DD: " + DoubleToString(MathMax(0.0, -BasketProfit()), 2);
         lines[n++] = "";
         lines[n++] = "KillLevel: " + DoubleToString(KillEquityLevel, 2);
         lines[n++] = "";
         lines[n++] = "Spread(points): " + DoubleToString((Ask - Bid) / Point, 0);
         lines[n++] = "";
         lines[n++] = "Free Margin: " + DoubleToString((AccountFreeMargin() / AccountEquity()) * 100.0, 1) + "%";
         lines[n++] = "";
         lines[n++] = "RefHigh: " + DoubleToString(g_RefHigh, Digits);
         lines[n++] = "";
         lines[n++] = "RefLow: " + DoubleToString(g_RefLow, Digits);
         int y0 = 25;
         for(int i = 0; i < n; i++)
         {
            string name = COMMENT_LABEL + "_" + IntegerToString(i);
            if(ObjectFind(0, name) < 0)
            {
               ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
               ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
               ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 10);
               ObjectSetInteger(0, name, OBJPROP_FONTSIZE, COMMENT_FONTSIZE);
               ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
               ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
               ObjectSetInteger(0, name, OBJPROP_BACK, false);
            }
            ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y0 + i * COMMENT_LINE_HEIGHT);
            ObjectSetString(0, name, OBJPROP_TEXT, lines[i]);
         }
         for(int i = n; i < COMMENT_MAX_LINES; i++)
         {
            string name = COMMENT_LABEL + "_" + IntegerToString(i);
            if(ObjectFind(0, name) >= 0)
               ObjectSetString(0, name, OBJPROP_TEXT, "");
         }
         Comment("");
         ChartRedraw(0);
      }

      //+------------------------------------------------------------------+
      string StateToText(ENUM_SYSTEM_STATE state)
      {
         if(state == STATE_NORMAL) return "NORMAL";
         if(state == STATE_EXPOSURE_BLOCK) return "EXPOSURE_BLOCK";
         if(state == STATE_KILL_COOLDOWN) return "KILL_COOLDOWN";
         return "UNKNOWN";
      }

      //+------------------------------------------------------------------+
      //| Reference high/low = current bar high/low; new candle = new bar,  |
      //| updated every tick as the bar develops.                           |
      //+------------------------------------------------------------------+
      void UpdateReferenceExtremes()
      {
         if(Bars < 1) return;

         // Always use current bar's high and low (updates every new candle and every tick)
         g_RefHigh = High[0];
         g_RefLow = Low[0];

         if(g_BasketExists)
         {
            double p = BasketProfit();
            if(p < g_BasketWorstProfit) g_BasketWorstProfit = p;
         }
      }

      bool HandleKillSwitchAndCooldown()
      {
         double balance = AccountBalance();
         double equity = AccountEquity();
         // KillValue semantics: trigger when floating loss >= KillEquityLevel
         bool killTriggered = (equity <= balance - KillEquityLevel);

         if(KillSwitchEnable && (g_KillActive || killTriggered))
         {
            bool enteringKill = (killTriggered && !g_KillActive);
            g_KillActive = true;

            // Capture telemetry close snapshot before any position is closed.
            if(enteringKill && g_Telemetry_BasketActive && !g_Telemetry_WroteRowForActiveBasket)
            {
               TelemetryUpdateBasketStats();
               g_Telemetry_KillClosePL = BasketProfit();
               g_Telemetry_KillClosePL_Stored = true;
               g_Telemetry_KillOrdersAtClose = GetBasketOrderCount();
               g_Telemetry_KillLotsAtClose = GetBasketTotalLots();
            }

            bool closedAll = CloseAllPositionsForKillSwitch();
            if(g_Telemetry_BasketActive)
               TelemetryUpdateBasketStats();
            if(!closedAll)
            {
               g_SystemState = STATE_KILL_COOLDOWN;
               return true;
            }

            // When kill closure is complete, write exactly one telemetry row for the active basket.
            if(g_Telemetry_BasketActive && !g_Telemetry_WroteRowForActiveBasket && g_Telemetry_KillClosePL_Stored)
            {
               TelemetryWriteBasketCSVRow("KILL", "", g_Telemetry_KillClosePL,
                                          g_Telemetry_KillOrdersAtClose, g_Telemetry_KillLotsAtClose,
                                          TimeCurrent());
            }

            g_KillActive = false;
            g_KillCooldownUntil = TimeCurrent() + KillCooldownMinutes * 60;
            g_SystemState = STATE_KILL_COOLDOWN;
            return true;
         }

         if(g_KillCooldownUntil > 0 && TimeCurrent() < g_KillCooldownUntil)
         {
            g_SystemState = STATE_KILL_COOLDOWN;
            return true;
         }

         if(g_KillCooldownUntil > 0 && TimeCurrent() >= g_KillCooldownUntil)
            g_KillCooldownUntil = 0;

         return false;
      }

      bool IsExposureBlockedForOpen()
      {
         bool enabled = (MaxOrdersInBasket > 0 || MaxTotalLotsInBasket > 0.0);
         if(!enabled) return false;
         if(g_ExposureLatched) return true;

         int orders = 0;
         double lots = 0.0;
         for(int i = OrdersTotal() - 1; i >= 0; i--)
         {
            if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES) &&
               OrderMagicNumber() == Magic &&
               OrderSymbol() == Symbol())
            {
               orders++;
               lots += OrderLots();
            }
         }

         bool blocked = false;
         bool ordersBlocked = (MaxOrdersInBasket > 0 && orders >= MaxOrdersInBasket);
         bool baseLotsBlocked = (MaxTotalLotsInBasket > 0.0 && lots >= MaxTotalLotsInBasket);
         blocked = (ordersBlocked || baseLotsBlocked);

         if(blocked && g_BasketExists)
         {
            bool recoveryEnabled = (EnableRecoveryStepUp &&
                                    RecoveryWaitMinutes > 0 &&
                                    MaxTotalLotsInBasket > 0.0 &&
                                    RecoveryMaxTotalLotsInBasket > MaxTotalLotsInBasket);
            bool hardLotsBlocked = recoveryEnabled ? (lots >= RecoveryMaxTotalLotsInBasket) : baseLotsBlocked;
            if(ordersBlocked || hardLotsBlocked)
               g_ExposureLatched = true;
         }
         return blocked;
      }

      void ResetLatchesWhenFlat()
      {
         if(g_BasketExists) return;
         g_ExposureLatched = false;
         g_RecoveryBaseCapReachedAt = 0;
         g_BasketWorstProfit = 0.0;
      }

      void ResetPendingNewBasketEntry()
      {
         g_NewBasketEntryPending = false;
         g_NewBasketEntryPendingSince = 0;
         g_NewBasketEntryPendingDirection = -1;
      }

      bool NewBasketDelayElapsed(int direction, datetime now, int delaySeconds)
      {
         if(delaySeconds <= 0)
         {
            ResetPendingNewBasketEntry();
            return true;
         }

         if(direction != OP_BUY && direction != OP_SELL)
         {
            ResetPendingNewBasketEntry();
            return false;
         }

         if(!g_NewBasketEntryPending ||
            g_NewBasketEntryPendingDirection != direction ||
            now < g_NewBasketEntryPendingSince)
         {
            g_NewBasketEntryPending = true;
            g_NewBasketEntryPendingSince = now;
            g_NewBasketEntryPendingDirection = direction;
            return false;
         }

         return ((now - g_NewBasketEntryPendingSince) >= delaySeconds);
      }

      void RefreshRecoveryBaseCapTimer(double currentLots)
      {
         if(!EnableRecoveryStepUp || RecoveryWaitMinutes <= 0 || MaxTotalLotsInBasket <= 0.0 || RecoveryMaxTotalLotsInBasket <= MaxTotalLotsInBasket)
         {
            g_RecoveryBaseCapReachedAt = 0;
            return;
         }

         if(currentLots >= MaxTotalLotsInBasket && currentLots < RecoveryMaxTotalLotsInBasket)
         {
            if(g_RecoveryBaseCapReachedAt == 0)
               g_RecoveryBaseCapReachedAt = TimeCurrent();
         }
         else
         {
            g_RecoveryBaseCapReachedAt = 0;
         }
      }

      bool TryOpenRecoveryAdd(double currentPrice)
      {
         if(!EnableRecoveryStepUp) return false;
         if(RecoveryWaitMinutes <= 0) return false;
         if(MaxTotalLotsInBasket <= 0.0) return false;
         if(RecoveryMaxTotalLotsInBasket <= MaxTotalLotsInBasket) return false;
         if(MaxOrdersInBasket > 0 && GetBasketOrderCount() >= MaxOrdersInBasket) return false;

         double lotsNow = GetBasketTotalLots();
         RefreshRecoveryBaseCapTimer(lotsNow);
         if(lotsNow < MaxTotalLotsInBasket) return false;
         if(lotsNow >= RecoveryMaxTotalLotsInBasket) return false;
         if(g_RecoveryBaseCapReachedAt <= 0) return false;
         if((TimeCurrent() - g_RecoveryBaseCapReachedAt) < RecoveryWaitMinutes * 60) return false;
         if((lotsNow + FixedLots) > RecoveryMaxTotalLotsInBasket + 1e-8) return false;

         int ticket = OrderSend(Symbol(), g_BasketDirection, FixedLots, currentPrice,
                              g_MaxBasketSlippagePoints, 0, 0, "StageB Recovery Add",
                              Magic, 0, (g_BasketDirection == OP_BUY) ? clrBlue : clrRed);
         if(ticket <= 0)
         {
            Print("Recovery step-up add failed. Error: ", GetLastError());
            return false;
         }

         if(g_Telemetry_BasketActive)
            TelemetryUpdateBasketStats();

         g_LastGridPrice = currentPrice;
         g_LastGridAddTime = TimeCurrent();
         g_LastAnyOpenTime = TimeCurrent();
         g_LastBarTime = (Bars > 0) ? Time[0] : TimeCurrent();
         g_RecoveryBaseCapReachedAt = TimeCurrent();
         g_ExposureLatched = false;

         // V3: keep reference update aligned with existing add path.
         if(g_BasketDirection == OP_SELL)
            g_RefHigh = Bid;
         else
            g_RefLow = Ask;

         return true;
      }

      bool CoreOpenGatesPass(bool forNewBasket)
      {
         g_LastOpenBlockedByExposureCap = false;
         if(!CurrentSpreadOK()) return false;
         if(!WithinTradingHours()) return false;

         if(SpeedEA > 0 && g_LastAnyOpenTime > 0 && (TimeCurrent() - g_LastAnyOpenTime) < SpeedEA)
            return false;
         if(forNewBasket && OpenTime > 0 && g_LastFirstOpenTime > 0 && (TimeCurrent() - g_LastFirstOpenTime) < OpenTime * 60)
            return false;
         if(Bars > 0 && g_LastBarTime == Time[0])
            return false; // one order per bar (entry/add)

         if(IsExposureBlockedForOpen())
         {
            g_LastOpenBlockedByExposureCap = true;
            return false;
         }
         return true;
      }

      double GetAdjustedStepPoints(bool forEntry)
      {
         return (double)g_GridDistancePoints;
      }

      void HandlePerOrderTrailing()
      {
         if(!g_BasketExists) return;
         if(Tral <= 0 || TralStart <= 0) return;
         // Unchanged behavior: per-order SL trail only when exactly one basket order (grid uses basket TP / basket trailing only).
         if(GetBasketOrderCount() != 1) return;

         for(int i = OrdersTotal() - 1; i >= 0; i--)
         {
            if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
            if(OrderMagicNumber() != Magic || OrderSymbol() != Symbol()) continue;
            int otype = OrderType();
            if(!(otype == OP_BUY || otype == OP_SELL)) continue;

            if(otype == OP_BUY)
            {
               double ppBuy = (Bid - OrderOpenPrice()) / Point;
               if(ppBuy < TralStart) continue;
               double slBuy = NormalizeDouble(Bid - Tral * Point, Digits);
               if(OrderStopLoss() == 0.0 || slBuy > OrderStopLoss() + Point)
                  if(!OrderModify(OrderTicket(), OrderOpenPrice(), slBuy, OrderTakeProfit(), 0, clrNONE))
                     Print("OrderModify BUY failed. ticket=", OrderTicket(), ", err=", GetLastError());
            }
            else
            {
               double ppSell = (OrderOpenPrice() - Ask) / Point;
               if(ppSell < TralStart) continue;
               double slSell = NormalizeDouble(Ask + Tral * Point, Digits);
               if(OrderStopLoss() == 0.0 || slSell < OrderStopLoss() - Point)
                  if(!OrderModify(OrderTicket(), OrderOpenPrice(), slSell, OrderTakeProfit(), 0, clrNONE))
                     Print("OrderModify SELL failed. ticket=", OrderTicket(), ", err=", GetLastError());
            }
         }
      }
