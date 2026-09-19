//+------------------------------------------------------------------+
//|                                        Netec1400_XAUUSD_Grid.mq4 |
//|                                   AmarTrading Gold EA v1.0       |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "AmarTrading"
#property version   "1.00"
#property description "AmarTrading Gold EA"
#property strict

//+------------------------------------------------------------------+
//| EA DESCRIPTION                                                    |
//+------------------------------------------------------------------+
/*
   XAUUSD GRID / RECOVERY EA (Phase-1)

   Priority: Survivability > Control > Stability > Profit

   ENTRY LOGIC:
   - Manual (0): Adopt user orders with EA MagicNumber as basket start.
   - Auto (1): Simple momentum - compare price to N bars ago; up->BUY, down->SELL. Fast/continuous.

   GRID LOGIC:
   - Adverse-only: BUY basket adds when price drops; SELL when price rises.
   - Dynamic spacing: BaseStep * (LevelMultiplier ^ level). Trade density: MinSecondsBetweenAdds.
   - Fixed lot sizing. MaxGridLevels enforced.

   EXIT: Basket closes when profit >= BasketTakeProfitMoney. Emergency: basket DD (USD/%), equity DD, margin.
*/

//+------------------------------------------------------------------+
//| ENUMS                                                             |
//+------------------------------------------------------------------+

enum ENUM_ENTRY_MODE
{
   ENTRY_MANUAL = 0,  // Manual (adopt)
   ENTRY_AUTO   = 1   // Auto (momentum)
};

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+

// --- Symbol & Identity ---

input string InpGrp_Symbol = "=== Symbol & Identity ===";  // (group)
input int    MagicNumber = 0;  // Magic Number for order identification


// --- Lots & Grid ---

input string InpGrp_Grid = "=== Lots & Grid ===";  // (group)
input double LotSize = 0.01;                    // Initial lot size
input bool   UseFixedLot = true;                // Use fixed lot for all grid levels
input int    MaxGridLevels = 10;                // Maximum grid levels
input int    GridDistancePips = 50;             // Base grid distance in pips (1 pip = 10 points)
input double LevelMultiplier = 1.0;             // Grid spacing multiplier per level (1.0=fixed)
input int    MinSecondsBetweenAdds = 5;         // Min seconds between grid adds (trade density limit)
input bool   UseDynamicGrid = true;             // Enable dynamic grid expansion
input double DynamicGridMultiplier = 1.5;       // Grid distance multiplier during stress
input double MaxLotMultiplier = 1.0;            // Max lot multiplier (1.0 = no progression)


// --- Entry ---

input string InpGrp_Entry = "=== Entry ===";  // (group)
input ENUM_ENTRY_MODE EntryMode = ENTRY_AUTO;  // Entry mode
input int             EntryLookbackBars = 5;   // Auto mode: bars to look back for momentum


// --- Exit ---

input string InpGrp_Exit = "=== Exit ===";  // (group)
input double BasketTakeProfitMoney = 10.0;      // Basket TP in account currency
input bool   UseTrailingBasketTP = false;       // Enable trailing basket TP
input double TrailingStart = 15.0;              // Trailing starts at this profit
input double TrailingStep = 5.0;                // Trail by this amount


// --- Risk ---

input string InpGrp_Risk = "=== Risk ===";  // (group)
input double MaxBasketDrawdownMoney = 100.0;    // Max basket DD in account currency
input double MaxEquityDrawdownPercent = 20.0;   // Max equity DD in percent
input double PauseNewTradesAtDDPercent = 50.0;  // Pause new trades at this basket DD% (only if UseDDBasedGridPause)
input double IncreaseGridDistanceAtDDPercent = 30.0; // Increase grid distance at this DD% (only if UseDDBasedGridPause)
input double EmergencyCloseAtDDPercent = 80.0;  // Emergency close at this basket DD%
input double MinFreeMarginPercent = 30.0;       // Minimum free margin percent
input bool   UseDDBasedGridPause = false;       // Phase-1 legacy: false = cadence by price/market only


// --- Emergency ---

input string InpGrp_Emergency = "=== Emergency ===";  // (group)
input bool   UseEmergencyExit = true;           // Enable emergency exit
input int    MaxBasketSlippagePips = 5;        // Max slippage for basket close (pips; 1 pip = 10 points)


// --- Filters ---

input string InpGrp_Filters = "=== Filters ===";  // (group)
input int    MaxSpreadPips = 5;                // Max spread in pips (1 pip = 10 points)
input bool   UseVolatilityFilter = false;       // Enable volatility filter (Phase-1 default OFF)
input int    ATR_Period = 14;                   // ATR period
input double ATR_MultiplierThreshold = 2.0;     // ATR multiplier threshold
input bool   BlockNewBasketAboveVolatility = true;  // Block new basket when volatile
input bool   PauseGridAboveVolatility = true;   // Pause grid expansion when volatile
input bool   UseImpulseFilter = false;          // Detect sharp/impulsive moves (Phase-1 default OFF)
input int    ImpulseLookbackBars = 5;           // Bars for average range (impulse)
input double ImpulseRangeMultiplier = 2.0;      // Current range > avg range * this = impulse
input bool   PauseGridOnImpulse = true;         // Pause grid when impulse detected
input bool   BlockNewBasketOnImpulse = true;   // Block new basket when impulse detected
input bool   UseExposureBasedPause = true;      // Pause when free margin below threshold
input double MinRemainingExposureMoney = 100.0; // Min free margin (account currency) to allow new trades


// --- Session ---

input string InpGrp_Session = "=== Session ===";  // (group)
input bool   UseTradingHours = false;           // Enable trading hours filter
input int    StartHour = 0;                     // Trading start hour (broker time)
input int    EndHour = 23;                      // Trading end hour (broker time)


// --- Manual buttons ---

input string InpGrp_Buttons = "=== Manual Buttons (Tester / Chart) ===";  // (group)
input bool   ShowManualButtons = true;          // Show BUY/SELL buttons: true = show, false = hide (use Visual mode in Tester to click)

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+

#define BTN_BUY_NAME    "AmarTradingGoldEA_BtnBUY"
#define BTN_SELL_NAME   "AmarTradingGoldEA_BtnSELL"
#define COMMENT_LABEL  "AmarTradingGoldEA_Comment"
#define COMMENT_FONTSIZE 10   // on-chart comment label font size (larger = bigger text)
#define COMMENT_MAX_LINES 25  // max lines for on-chart comment (OBJ_LABEL does not support \n)
#define COMMENT_LINE_HEIGHT 16  // pixels per line
#define POINTS_PER_PIP 10   // 1 pip = 10 points; pips = points / POINTS_PER_PIP; points = pips * POINTS_PER_PIP

string   g_Symbol = "XAUUSD";
int      g_BasketDirection = -1;     // -1=none, OP_BUY=0, OP_SELL=1
bool     g_BasketExists = false;
int      g_GridDistancePoints = 0;    // from GridDistancePips * POINTS_PER_PIP
int      g_MaxBasketSlippagePoints = 0;
int      g_MaxSpreadPoints = 0;
double   g_LastGridPrice = 0.0;
double   g_BasketHighestProfit = 0.0;
datetime g_LastBarTime = 0;
datetime g_LastGridAddTime = 0;    // Trade density limit
double   g_InitialEquity = 0.0;

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   // Check symbol
   if(!IsXAUUSD())
   {
      Print("ERROR: This EA only works on XAUUSD. Current symbol: ", Symbol());
      return(INIT_FAILED);
   }
   
   // Validate inputs
   if(LotSize <= 0)
   {
      Print("ERROR: LotSize must be > 0");
      return(INIT_PARAMETERS_INCORRECT);
   }
   
   if(GridDistancePips <= 0)
   {
      Print("ERROR: GridDistancePips must be > 0");
      return(INIT_PARAMETERS_INCORRECT);
   }
   g_GridDistancePoints = GridDistancePips * POINTS_PER_PIP;
   g_MaxBasketSlippagePoints = MaxBasketSlippagePips * POINTS_PER_PIP;
   g_MaxSpreadPoints = MaxSpreadPips * POINTS_PER_PIP;
   if(g_GridDistancePoints <= 0) g_GridDistancePoints = 1;
   if(g_MaxBasketSlippagePoints <= 0) g_MaxBasketSlippagePoints = 1;
   if(g_MaxSpreadPoints <= 0) g_MaxSpreadPoints = 1;
   
   if(MaxGridLevels < 1)
   {
      Print("ERROR: MaxGridLevels must be >= 1");
      return(INIT_PARAMETERS_INCORRECT);
   }
   
   if(EntryLookbackBars < 1 || EntryLookbackBars > 100)
   {
      Print("ERROR: EntryLookbackBars must be 1-100");
      return(INIT_PARAMETERS_INCORRECT);
   }
   
   if(LevelMultiplier < 0.5 || LevelMultiplier > 3.0)
   {
      Print("ERROR: LevelMultiplier must be 0.5-3.0");
      return(INIT_PARAMETERS_INCORRECT);
   }
   
   if(MinSecondsBetweenAdds < 0 || MinSecondsBetweenAdds > 300)
   {
      Print("ERROR: MinSecondsBetweenAdds must be 0-300");
      return(INIT_PARAMETERS_INCORRECT);
   }
   
   if(MaxEquityDrawdownPercent <= 0 || MaxEquityDrawdownPercent > 100)
   {
      Print("ERROR: MaxEquityDrawdownPercent must be between 0 and 100");
      return(INIT_PARAMETERS_INCORRECT);
   }
   
   // Store initial equity
   g_InitialEquity = AccountEquity();
   
   // Check for existing basket
   RestoreBasketState();
   
   Print("=== AmarTrading Gold EA Initialized ===");
   Print("Magic Number: ", MagicNumber);
   Print("Lot Size: ", LotSize);
   Print("Grid Distance: ", GridDistancePips, " pips (", g_GridDistancePoints, " points)");
   Print("Max Grid Levels: ", MaxGridLevels);
   Print("Basket TP: ", BasketTakeProfitMoney);
   Print("Entry Mode: ", EnumToString(EntryMode));
   
   if(ShowManualButtons)
   {
      CreateManualButtons();
   }
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   DeleteManualButtons();
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
   // Update display
   UpdateComment();
   
   // Manual BUY/SELL buttons: poll state on tick (works in Strategy Tester where OnChartEvent may not fire)
   if(ShowManualButtons && IsXAUUSD())
   {
      if(ObjectFind(0, BTN_BUY_NAME) >= 0 && ObjectGetInteger(0, BTN_BUY_NAME, OBJPROP_STATE))
      {
         ObjectSetInteger(0, BTN_BUY_NAME, OBJPROP_STATE, false);
         OpenManualOrder(OP_BUY);
      }
      else if(ObjectFind(0, BTN_SELL_NAME) >= 0 && ObjectGetInteger(0, BTN_SELL_NAME, OBJPROP_STATE))
      {
         ObjectSetInteger(0, BTN_SELL_NAME, OBJPROP_STATE, false);
         OpenManualOrder(OP_SELL);
      }
   }
   
   // Check for basket state recovery
   CheckBasketStateConsistency();
   
   // Check emergency conditions first
   if(UseEmergencyExit)
   {
      CheckEmergencyClose();
   }
   
   // Main logic
   if(!g_BasketExists)
   {
      if(EntryMode == ENTRY_MANUAL)
         TryAdoptUserBasket();
      else if(EntryMode == ENTRY_AUTO)
         OpenAutoEntry();
   }
   else
   {
      // Basket exists - manage it
      HandleExit();
      HandleGrid();
   }
}

//+------------------------------------------------------------------+
//| Chart event - handle BUY/SELL button clicks                      |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long& lparam, const double& dparam, const string& sparam)
{
   if(id != CHARTEVENT_OBJECT_CLICK) return;
   if(!ShowManualButtons) return;
   if(!IsXAUUSD()) return;
   
   // if(sparam == BTN_BUY_NAME)
   // {
   //    ObjectSetInteger(0, BTN_BUY_NAME, OBJPROP_STATE, false);  // reset so OnTick does not open again
   //    OpenManualOrder(OP_BUY);
   //    return;
   // }
   // if(sparam == BTN_SELL_NAME)
   // {
   //    ObjectSetInteger(0, BTN_SELL_NAME, OBJPROP_STATE, false);  // reset so OnTick does not open again
   //    OpenManualOrder(OP_SELL);
   //    return;
   // }
}

//+------------------------------------------------------------------+
//| Create BUY and SELL buttons on chart                             |
//+------------------------------------------------------------------+
void CreateManualButtons()
{
   int w = 80;
   int h = 28;
   int x = 220;   // distance from right edge (40px left of default)
   int y = 30;
   
   if(ObjectFind(0, BTN_BUY_NAME) < 0)
   {
      ObjectCreate(BTN_BUY_NAME, OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(0, BTN_BUY_NAME, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
      ObjectSetInteger(0, BTN_BUY_NAME, OBJPROP_XDISTANCE, x + w + 5);
      ObjectSetInteger(0, BTN_BUY_NAME, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, BTN_BUY_NAME, OBJPROP_XSIZE, w);
      ObjectSetInteger(0, BTN_BUY_NAME, OBJPROP_YSIZE, h);
      ObjectSetString(0, BTN_BUY_NAME, OBJPROP_TEXT, "BUY");
      ObjectSetInteger(0, BTN_BUY_NAME, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, BTN_BUY_NAME, OBJPROP_BACK, false);
      ObjectSetInteger(0, BTN_BUY_NAME, OBJPROP_COLOR, clrWhite);
      ObjectSetInteger(0, BTN_BUY_NAME, OBJPROP_BGCOLOR, clrDodgerBlue);
      ObjectSetInteger(0, BTN_BUY_NAME, OBJPROP_BORDER_COLOR, clrNavy);
      ObjectSetInteger(0, BTN_BUY_NAME, OBJPROP_STATE, false);
      ObjectSetInteger(0, BTN_BUY_NAME, OBJPROP_FONTSIZE, 10);
   }
   
   if(ObjectFind(0, BTN_SELL_NAME) < 0)
   {
      ObjectCreate(BTN_SELL_NAME, OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(0, BTN_SELL_NAME, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
      ObjectSetInteger(0, BTN_SELL_NAME, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, BTN_SELL_NAME, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, BTN_SELL_NAME, OBJPROP_XSIZE, w);
      ObjectSetInteger(0, BTN_SELL_NAME, OBJPROP_YSIZE, h);
      ObjectSetString(0, BTN_SELL_NAME, OBJPROP_TEXT, "SELL");
      ObjectSetInteger(0, BTN_SELL_NAME, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, BTN_SELL_NAME, OBJPROP_BACK, false);
      ObjectSetInteger(0, BTN_SELL_NAME, OBJPROP_COLOR, clrWhite);
      ObjectSetInteger(0, BTN_SELL_NAME, OBJPROP_BGCOLOR, clrCrimson);
      ObjectSetInteger(0, BTN_SELL_NAME, OBJPROP_BORDER_COLOR, clrDarkRed);
      ObjectSetInteger(0, BTN_SELL_NAME, OBJPROP_STATE, false);
      ObjectSetInteger(0, BTN_SELL_NAME, OBJPROP_FONTSIZE, 10);
   }
   
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Delete BUY/SELL buttons                                           |
//+------------------------------------------------------------------+
void DeleteManualButtons()
{
   ObjectDelete(0, BTN_BUY_NAME);
   ObjectDelete(0, BTN_SELL_NAME);
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Open one manual order (BUY or SELL) with EA MagicNumber          |
//+------------------------------------------------------------------+
void OpenManualOrder(int orderType)
{
   Print("=== MANUAL BUTTON CLICKED ===");
   Print("Direction: ", (orderType == OP_BUY ? "BUY" : "SELL"));
   Print("Symbol: ", Symbol(), " LotSize: ", LotSize);
   Print("Free Margin: ", AccountFreeMargin(), " ", AccountCurrency());
   
   if(!IsXAUUSD())
   {
      Print("Manual button: XAUUSD only. Current symbol: ", Symbol());
      return;
   }
   if(!RemainingExposureOK())
   {
      Print("Manual button: exposure pause - free margin below threshold");
      return;
   }
   
   double price = (orderType == OP_BUY) ? Ask : Bid;
   Print("Sending order: ", (orderType == OP_BUY ? "BUY" : "SELL"), " at ", price);
   
   int ticket = OrderSend(Symbol(), orderType, LotSize, price, g_MaxBasketSlippagePoints,
                         0, 0, "Manual", MagicNumber, 0,
                         (orderType == OP_BUY) ? clrBlue : clrRed);
   
   if(ticket > 0)
   {
      g_BasketExists = true;
      g_BasketDirection = orderType;
      g_LastGridPrice = price;
      g_BasketHighestProfit = 0.0;
      Print("=== MANUAL ORDER OPENED (Basket started) ===");
      Print("Direction: ", (orderType == OP_BUY ? "BUY" : "SELL"));
      Print("Price: ", price, " Lot: ", LotSize, " Ticket: ", ticket);
   }
   else
   {
      int err = GetLastError();
      Print("Manual order failed. Error: ", err);
      Print("Error details: ", ErrorDescription(err));
   }
}

//+------------------------------------------------------------------+
//| Get error description                                             |
//+------------------------------------------------------------------+
string ErrorDescription(int error_code)
{
   switch(error_code)
   {
      case 0:   return "No error";
      case 1:   return "No error, but result is unknown";
      case 2:   return "Common error";
      case 3:   return "Invalid trade parameters";
      case 4:   return "Trade server is busy";
      case 5:   return "Old version of the client terminal";
      case 6:   return "No connection with trade server";
      case 7:   return "Not enough rights";
      case 8:   return "Too frequent requests";
      case 9:   return "Malfunctional trade operation";
      case 64:  return "Account disabled";
      case 65:  return "Invalid account";
      case 128: return "Trade timeout";
      case 129: return "Invalid price";
      case 130: return "Invalid stops";
      case 131: return "Invalid trade volume";
      case 132: return "Market is closed";
      case 133: return "Trade is disabled";
      case 134: return "Not enough money";
      case 135: return "Price changed";
      case 136: return "Off quotes";
      case 137: return "Broker is busy";
      case 138: return "Requote";
      case 139: return "Order is locked";
      case 140: return "Long positions only allowed";
      case 141: return "Too many requests";
      case 145: return "Modification denied because order too close to market";
      case 146: return "Trade context is busy";
      case 147: return "Expirations are denied by broker";
      case 148: return "Amount of open and pending orders has reached the limit";
      case 149: return "Hedging is prohibited";
      case 150: return "Prohibited by FIFO rules";
      default:  return "Unknown error";
   }
}

//+------------------------------------------------------------------+
//| Check if current symbol is XAUUSD                                |
//+------------------------------------------------------------------+
bool IsXAUUSD()
{
   string sym = Symbol();
   return (StringFind(sym, "XAUUSD") >= 0 || StringFind(sym, "GOLD") >= 0);
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
   
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderMagicNumber() == MagicNumber && OrderSymbol() == Symbol())
         {
            count++;
            if(direction == -1)
            {
               direction = OrderType();
            }
            double op = OrderOpenPrice();
            if(minPrice == 0.0 || op < minPrice) minPrice = op;
            if(maxPrice == 0.0 || op > maxPrice) maxPrice = op;
         }
      }
   }
   
   if(count > 0)
   {
      g_BasketExists = true;
      g_BasketDirection = direction;
      // BUY basket: next grid below = use min open price; SELL: next grid above = use max
      g_LastGridPrice = (direction == OP_BUY) ? minPrice : maxPrice;
      Print("Basket restored: ", count, " orders, Direction: ", 
            (direction == OP_BUY ? "BUY" : "SELL"));
   }
   else
   {
      g_BasketExists = false;
      g_BasketDirection = -1;
      g_LastGridPrice = 0.0;
   }
}

//+------------------------------------------------------------------+
//| Try to adopt user-placed order(s) as basket (Phase-1 Manual mode) |
//+------------------------------------------------------------------+
void TryAdoptUserBasket()
{
   int count = 0;
   int direction = -1;
   int hasBuy = 0;
   int hasSell = 0;
   double minPrice = 0.0;
   double maxPrice = 0.0;
   
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderMagicNumber() == MagicNumber && OrderSymbol() == Symbol())
         {
            count++;
            int otype = OrderType();
            if(otype == OP_BUY) hasBuy++;
            if(otype == OP_SELL) hasSell++;
            if(direction == -1) direction = otype;
            double op = OrderOpenPrice();
            if(minPrice == 0.0 || op < minPrice) minPrice = op;
            if(maxPrice == 0.0 || op > maxPrice) maxPrice = op;
         }
      }
   }
   
   if(count == 0) return;
   
   // Single-direction only: reject mixed BUY and SELL
   if(hasBuy > 0 && hasSell > 0)
   {
      Print("Mixed direction; cannot adopt. Please close orders or use single direction.");
      return;
   }
   
   g_BasketExists = true;
   g_BasketDirection = direction;
   // BUY basket: next grid below = min open price; SELL: next grid above = max open price
   g_LastGridPrice = (direction == OP_BUY) ? minPrice : maxPrice;
   Print("=== BASKET ADOPTED (Manual) ===");
   Print("Orders: ", count, ", Direction: ", (direction == OP_BUY ? "BUY" : "SELL"));
   Print("Last grid price: ", g_LastGridPrice);
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
         if(OrderMagicNumber() == MagicNumber && OrderSymbol() == Symbol())
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
//| Calculate basket profit                                           |
//+------------------------------------------------------------------+
double BasketProfit()
{
   double profit = 0.0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderMagicNumber() == MagicNumber && OrderSymbol() == Symbol())
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
//| Calculate basket drawdown percent                                 |
//+------------------------------------------------------------------+
double BasketDrawdownPercent()
{
   if(MaxBasketDrawdownMoney <= 0) return 0.0;
   
   double profit = BasketProfit();
   if(profit >= 0) return 0.0;
   
   double dd = MathAbs(profit);
   return (dd / MaxBasketDrawdownMoney) * 100.0;
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
      Print("Spread too high: ", (int)(spread / POINTS_PER_PIP), " pips (max: ", MaxSpreadPips, ")");
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Check volatility                                                  |
//+------------------------------------------------------------------+
bool VolatilityOK(bool forNewBasket)
{
   if(!UseVolatilityFilter) return true;
   
   double atr = iATR(Symbol(), 0, ATR_Period, 0);
   double atrAvg = 0.0;
   
   // Calculate average ATR
   for(int i = 1; i <= 20; i++)
   {
      atrAvg += iATR(Symbol(), 0, ATR_Period, i);
   }
   atrAvg /= 20.0;
   
   bool isVolatile = (atr > atrAvg * ATR_MultiplierThreshold);
   
   if(isVolatile)
   {
      if(forNewBasket && BlockNewBasketAboveVolatility)
      {
         Print("Volatility too high for new basket. ATR: ", atr, " Avg: ", atrAvg);
         return false;
      }
      if(!forNewBasket && PauseGridAboveVolatility)
      {
         Print("Volatility too high for grid expansion. ATR: ", atr, " Avg: ", atrAvg);
         return false;
      }
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Detect sharp/impulsive price move (range vs average range)        |
//+------------------------------------------------------------------+
bool ImpulseDetected()
{
   if(!UseImpulseFilter) return false;
   if(ImpulseLookbackBars < 1 || ImpulseRangeMultiplier <= 0) return false;
   
   int limit = MathMin(ImpulseLookbackBars, 100);
   if(Bars < limit + 2) return false;
   
   double avgRange = 0.0;
   for(int i = 1; i <= limit; i++)
   {
      avgRange += (High[i] - Low[i]);
   }
   avgRange /= (double)limit;
   
   if(avgRange <= 0) return false;
   
   double range0 = High[0] - Low[0];
   double range1 = (Bars >= 2) ? (High[1] - Low[1]) : range0;
   double currentRange = MathMax(range0, range1);
   
   if(currentRange > avgRange * ImpulseRangeMultiplier)
   {
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Check remaining exposure (free margin) above threshold             |
//+------------------------------------------------------------------+
bool RemainingExposureOK()
{
   if(!UseExposureBasedPause) return true;
   if(AccountFreeMargin() < MinRemainingExposureMoney)
   {
      Print("Exposure pause: Free margin ", AccountFreeMargin(), " < ", MinRemainingExposureMoney, " ", AccountCurrency());
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Check trading hours                                               |
//+------------------------------------------------------------------+
bool WithinTradingHours()
{
   if(!UseTradingHours) return true;
   
   int currentHour = Hour();
   
   if(StartHour <= EndHour)
   {
      return (currentHour >= StartHour && currentHour <= EndHour);
   }
   else
   {
      // Overnight session
      return (currentHour >= StartHour || currentHour <= EndHour);
   }
}

//+------------------------------------------------------------------+
//| Check margin                                                      |
//+------------------------------------------------------------------+
bool MarginOK()
{
   double freeMargin = AccountFreeMargin();
   double equity = AccountEquity();
   
   if(equity <= 0) return false;
   
   double freeMarginPercent = (freeMargin / equity) * 100.0;
   
   if(freeMarginPercent < MinFreeMarginPercent)
   {
      Print("Free margin too low: ", freeMarginPercent, "% (min: ", MinFreeMarginPercent, "%)");
      return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Open first trade automatically using simple momentum (EntryMode Auto) |
//+------------------------------------------------------------------+
void OpenAutoEntry()
{
   // Simple momentum: compare current price to price N bars ago
   if(Bars < EntryLookbackBars + 1)
      return;
   
   double currentPrice = (Close[0] + Open[0]) / 2.0;   // Use mid of current bar
   double referencePrice = Close[EntryLookbackBars];
   
   int direction = -1;
   if(currentPrice > referencePrice)
      direction = OP_BUY;
   else if(currentPrice < referencePrice)
      direction = OP_SELL;
   else
      return;  // No signal when equal
   
   // Basic filters (spread, margin, exposure) - no volatility/impulse for fast/continuous
   if(!CurrentSpreadOK()) return;
   if(!RemainingExposureOK()) return;
   if(!MarginOK()) return;
   if(!WithinTradingHours()) return;
   
   double equityDD = EquityDrawdownPercent();
   if(equityDD > MaxEquityDrawdownPercent)
      return;
   
   double price = (direction == OP_BUY) ? Ask : Bid;
   int ticket = OrderSend(Symbol(), direction, LotSize, price, g_MaxBasketSlippagePoints,
                         0, 0, "Auto Entry", MagicNumber, 0,
                         (direction == OP_BUY) ? clrBlue : clrRed);
   
   if(ticket > 0)
   {
      g_BasketExists = true;
      g_BasketDirection = direction;
      g_LastGridPrice = price;
      g_BasketHighestProfit = 0.0;
      
      Print("=== NEW BASKET OPENED (Auto momentum) ===");
      Print("Direction: ", (direction == OP_BUY ? "BUY" : "SELL"));
      Print("Current: ", currentPrice, " Ref(", EntryLookbackBars, "): ", referencePrice);
      Print("Price: ", price, " Lot: ", LotSize, " Ticket: ", ticket);
   }
   else
   {
      Print("Auto entry failed. Error: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Handle grid logic                                                 |
//+------------------------------------------------------------------+
void HandleGrid()
{
   double basketDD = BasketDrawdownPercent();
   
   // DD-based pause/dynamic grid: only when enabled (Phase-1 default off = legacy cadence by price/market only)
   if(UseDDBasedGridPause)
   {
      if(basketDD >= PauseNewTradesAtDDPercent)
      {
         Print("Grid paused - basket DD: ", basketDD, "%");
         return;
      }
   }
   
   // Exposure-based pause: stop adding when free margin below threshold
   if(!RemainingExposureOK()) return;
   
   // Check filters
   if(!CurrentSpreadOK()) return;
   if(!VolatilityOK(false)) return;
   if(UseImpulseFilter && PauseGridOnImpulse && ImpulseDetected())
   {
      Print("Grid paused - impulse detected");
      return;
   }
   if(!MarginOK()) return;
   
   // Check max levels
   int orderCount = GetBasketOrderCount();
   if(orderCount >= MaxGridLevels)
   {
      return;
   }
   
   // Trade density limit: min seconds between adds
   if(g_LastGridAddTime > 0 && (TimeCurrent() - g_LastGridAddTime) < MinSecondsBetweenAdds)
      return;
   
   // Dynamic grid spacing: BaseStep * (LevelMultiplier ^ (level-1))
   double effectivePips = GridDistancePips * MathPow(LevelMultiplier, orderCount - 1);
   if(effectivePips < 0.1) effectivePips = 0.1;
   double gridDistance = (int)(effectivePips * POINTS_PER_PIP) * Point;
   if(gridDistance <= 0) gridDistance = Point;
   
   if(UseDDBasedGridPause && UseDynamicGrid && basketDD >= IncreaseGridDistanceAtDDPercent)
   {
      gridDistance *= DynamicGridMultiplier;
      Print("Dynamic grid active - distance: ", (int)((gridDistance / Point) / POINTS_PER_PIP), " pips");
   }
   
   // Check if price has moved enough for new grid level (adverse-only)
   double currentPrice = (g_BasketDirection == OP_BUY) ? Ask : Bid;
   double priceMove = 0.0;
   
   if(g_BasketDirection == OP_BUY)
   {
      // For BUY basket, add level when price drops
      priceMove = g_LastGridPrice - currentPrice;
   }
   else
   {
      // For SELL basket, add level when price rises
      priceMove = currentPrice - g_LastGridPrice;
   }
   
   if(priceMove >= gridDistance)
   {
      // Phase-1: fixed lot only
      double lotSize = LotSize;
      
      // Open grid level
      int ticket = OrderSend(Symbol(), g_BasketDirection, lotSize, currentPrice, 
                            g_MaxBasketSlippagePoints, 0, 0, "Grid Level", 
                            MagicNumber, 0, 
                            (g_BasketDirection == OP_BUY) ? clrBlue : clrRed);
      
      if(ticket > 0)
      {
         g_LastGridPrice = currentPrice;
         g_LastGridAddTime = TimeCurrent();
         Print("=== GRID LEVEL ADDED ===");
         Print("Level: ", orderCount + 1);
         Print("Price: ", currentPrice);
         Print("Lot: ", lotSize);
         Print("Basket DD: ", basketDD, "%");
      }
      else
      {
         int err = GetLastError();
         Print("Grid expansion failed (basket unchanged, grid paused). Error: ", err, " - ", ErrorDescription(err));
      }
   }
}

//+------------------------------------------------------------------+
//| Handle exit logic                                                 |
//+------------------------------------------------------------------+
void HandleExit()
{
   double profit = BasketProfit();
   
   // Update highest profit for trailing
   if(profit > g_BasketHighestProfit)
   {
      g_BasketHighestProfit = profit;
   }
   
   // Check normal TP
   if(profit >= BasketTakeProfitMoney)
   {
      Print("=== BASKET TP REACHED ===");
      Print("Profit: ", profit);
      CloseBasket("TP Reached");
      return;
   }
   
   // Check trailing TP
   if(UseTrailingBasketTP && g_BasketHighestProfit >= TrailingStart)
   {
      double trailThreshold = g_BasketHighestProfit - TrailingStep;
      if(profit <= trailThreshold)
      {
         Print("=== TRAILING TP TRIGGERED ===");
         Print("Highest Profit: ", g_BasketHighestProfit);
         Print("Current Profit: ", profit);
         CloseBasket("Trailing TP");
         return;
      }
   }
}

//+------------------------------------------------------------------+
//| Check emergency close conditions                                  |
//+------------------------------------------------------------------+
// EmergencyExit: controlled, configurable; minimizes damage, no blind liquidation
void CheckEmergencyClose()
{
   if(!g_BasketExists) return;
   
   bool emergencyTriggered = false;
   string reason = "";
   
   // Check basket DD (USD): close when loss exceeds MaxBasketDrawdownMoney
   double profit = BasketProfit();
   if(MaxBasketDrawdownMoney > 0 && profit <= -MaxBasketDrawdownMoney)
   {
      emergencyTriggered = true;
      reason = "Basket DD USD: " + DoubleToString(profit, 2) + " " + AccountCurrency();
   }
   
   // Check basket DD (percent)
   double basketDD = BasketDrawdownPercent();
   if(!emergencyTriggered && basketDD >= EmergencyCloseAtDDPercent)
   {
      emergencyTriggered = true;
      reason = "Basket DD: " + DoubleToString(basketDD, 2) + "%";
   }
   
   // Check equity DD
   double equityDD = EquityDrawdownPercent();
   if(equityDD >= MaxEquityDrawdownPercent)
   {
      emergencyTriggered = true;
      reason = "Equity DD: " + DoubleToString(equityDD, 2) + "%";
   }
   
   // Margin: do NOT trigger emergency close here. Low margin already pauses grid
   // expansion (MarginOK/RemainingExposureOK). Closing basket on margin would
   // incorrectly treat "cannot add next grid level" as a fatal state.
   
   if(emergencyTriggered)
   {
      Print("!!! EMERGENCY CLOSE TRIGGERED !!!");
      Print("Reason: ", reason);
      CloseBasket("EMERGENCY: " + reason);
   }
}

//+------------------------------------------------------------------+
//| Close entire basket                                               |
//+------------------------------------------------------------------+
void CloseBasket(string reason)
{
   Print("=== CLOSING BASKET ===");
   Print("Reason: ", reason);
   Print("Profit: ", BasketProfit());
   
   int attempts = 0;
   int maxAttempts = 3;
   
   while(GetBasketOrderCount() > 0 && attempts < maxAttempts)
   {
      attempts++;
      
      for(int i = OrdersTotal() - 1; i >= 0; i--)
      {
         if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         {
            if(OrderMagicNumber() == MagicNumber && OrderSymbol() == Symbol())
            {
               if(!g_BasketExists || OrderType() == g_BasketDirection)
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
   
   // Reset state
   ResetBasketState();
   
   Print("=== BASKET CLOSED ===");
   Print("Remaining orders: ", GetBasketOrderCount());
}

//+------------------------------------------------------------------+
//| Update on-chart comment                                           |
//+------------------------------------------------------------------+
void UpdateComment()
{
   string lines[];
   ArrayResize(lines, COMMENT_MAX_LINES);
   int n = 0;
   lines[n++] = "=== AmarTrading Gold EA (Phase-1) ===";
   lines[n++] = "";
   lines[n++] = "Magic: " + IntegerToString(MagicNumber);
   lines[n++] = "";
   lines[n++] = "Entry: " + (EntryMode == ENTRY_MANUAL ? "Manual" : "Auto");
   lines[n++] = "";
   lines[n++] = "Basket: " + (g_BasketExists ? (g_BasketDirection == OP_BUY ? "BUY" : "SELL") : "NONE");
   lines[n++] = "";
   lines[n++] = "Orders: " + IntegerToString(GetBasketOrderCount()) + " / " + IntegerToString(MaxGridLevels);
   lines[n++] = "";
   lines[n++] = "Profit: " + DoubleToString(BasketProfit(), 2) + " " + AccountCurrency();
   lines[n++] = "";
   lines[n++] = "Basket DD: " + DoubleToString(BasketDrawdownPercent(), 1) + "%";
   lines[n++] = "";
   lines[n++] = "Equity DD: " + DoubleToString(EquityDrawdownPercent(), 1) + "%";
   lines[n++] = "";
   lines[n++] = "Spread: " + DoubleToString(((Ask - Bid) / Point) / POINTS_PER_PIP, 0) + " pips";
   lines[n++] = "";
   lines[n++] = "Free Margin: " + DoubleToString((AccountFreeMargin() / AccountEquity()) * 100.0, 1) + "%";
   if(!g_BasketExists && EntryMode == ENTRY_AUTO)
   {
      lines[n++] = "";
      lines[n++] = "Auto mode: momentum (" + IntegerToString(EntryLookbackBars) + " bars)";
   }
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
