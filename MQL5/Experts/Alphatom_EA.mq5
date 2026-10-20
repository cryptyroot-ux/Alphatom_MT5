//+------------------------------------------------------------------+
//| Alphatom_EA.mq5                                                  |
//| POI execution expert for the frozen Alphatom strategy.           |
//|                                                                  |
//| SHADOW MODE IS THE DEFAULT. While InpShadowMode is true no trade  |
//| function is ever called: the expert only detects, simulates and   |
//| logs. Live execution stays behind EaLiveEnabled(), which requires |
//| InpShadowMode=false and a clean live pre-flight.                  |
//+------------------------------------------------------------------+
#property copyright "Alphatom"
#property version   "1.00"
#property description "Alphatom POI execution EA (shadow by default, no trading)"

#include <Alphatom/ExecKernel.mqh>
#include <Alphatom/MSNRLevels.mqh>

//--- execution
input bool            InpShadowMode        = true;   // Shadow mode (no orders)
input ENUM_TIMEFRAMES InpExecTimeframe     = PERIOD_M1; // Execution timeframe (M1/M2/M3)
input long            InpMagic             = 20261021;
input double          InpLotsPerLayer      = 0.15;
input int             InpSlippagePoints    = 30;

//--- frozen strategy numbers
input int    InpCISDMinRun        = 2;      // CISD minimum run (same-colour candles)
input double InpCisdZoneMinWidth  = 0.20;   // CISD band minimum width (price)
input double InpCisdZoneMaxWidth  = 2.00;   // CISD band maximum width (price)
input int    InpMinZoneWidthTicks = 2;      // Minimum entry-zone width in ticks
input int    InpSlBufferTicks     = 2;      // SL buffer beyond the extreme wick
input double InpSlCapPips         = 50.0;   // Shared SL cap from E1 (pips)
input int    InpTp1Pips           = 30;     // Layer 1 target (pips)
input int    InpTp2Pips           = 50;     // Layer 2 target (pips)
input int    InpTp3Pips           = 100;    // Layer 3 target (pips)
input int    InpSlPlusPips        = 10;     // Post-TP1 stop lock (pips)
input double InpRiskCapMoney      = 0.0;    // Basket risk cap (deposit currency, 0=off)

//--- POI map inputs: must match the chart indicator
input int    InpSwingLeft          = 3;
input int    InpSwingRight         = 3;
input bool   InpGapDetection       = true;
input int    InpGapToleranceTicks  = 2;
input double InpTouchTolerancePts  = 0.0;
input int    InpATRPeriod          = 14;
input double InpMergeToleranceATR  = 0.1;
input bool   InpFreshReplacesUnfresh = false;
input int    InpMaxLevelsPerTF     = 8;

//--- data window
input int  InpExecHistoryBars = 400;
input int  InpPoiHistoryBars  = 1500;
input bool InpLogEvents       = true;
input string InpInstanceTag   = "A";

//+------------------------------------------------------------------+
//| Internal types                                                   |
//+------------------------------------------------------------------+
struct EaLink
  {
   bool      valid;
   long      created;
   int       tfIndex;
   MSNRState lastState;
  };

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
MSNRLevel g_levelsM15[];
MSNRLevel g_levelsM30[];
MSNRLevel g_levelsH1[];
int       g_countM15 = 0;
int       g_countM30 = 0;
int       g_countH1 = 0;
datetime  g_poiBarOpen[3] = {0, 0, 0};
bool      g_poiReady[3] = {false, false, false};

MSNRBar  g_execBars[];
int      g_execCount = 0;
datetime g_lastExecOpen = 0;

ExecSetup g_buySetup;
ExecSetup g_sellSetup;
EaLink    g_buyLink;
EaLink    g_sellLink;
ExecConfig g_cfg;

bool g_liveAllowed = false;

//+------------------------------------------------------------------+
//| Small helpers                                                    |
//+------------------------------------------------------------------+
int EaTfIndex(const ENUM_TIMEFRAMES tf)
  {
   if(tf == PERIOD_M15)
      return 0;
   if(tf == PERIOD_M30)
      return 1;
   return 2;
  }

ENUM_TIMEFRAMES EaTfAt(const int index)
  {
   if(index == 0)
      return PERIOD_M15;
   if(index == 1)
      return PERIOD_M30;
   return PERIOD_H1;
  }

int EaTfMinutes(const int index)
  {
   if(index == 0)
      return 15;
   if(index == 1)
      return 30;
   return 60;
  }

int EaPoiCount(const int index)
  {
   if(index == 0)
      return g_countM15;
   if(index == 1)
      return g_countM30;
   return g_countH1;
  }

bool EaPoiLevelAt(const int index, const int slot, MSNRLevel &level)
  {
   if(index == 0)
     {
      if(slot < 0 || slot >= g_countM15)
         return false;
      level = g_levelsM15[slot];
      return true;
     }
   if(index == 1)
     {
      if(slot < 0 || slot >= g_countM30)
         return false;
      level = g_levelsM30[slot];
      return true;
     }
   if(slot < 0 || slot >= g_countH1)
      return false;
   level = g_levelsH1[slot];
   return true;
  }

bool EaFindLevel(const int index, const long created, MSNRLevel &level)
  {
   for(int i = 0; i < EaPoiCount(index); ++i)
     {
      MSNRLevel candidate;
      if(!EaPoiLevelAt(index, i, candidate))
         continue;
      if(candidate.created != created)
         continue;
      level = candidate;
      return true;
     }
   return false;
  }

void EaClearLink(EaLink &link)
  {
   link.valid = false;
   link.created = 0;
   link.tfIndex = -1;
   link.lastState = MSNR_STATE_FRESH;
  }

string EaEventName(const ExecEventType type)
  {
   if(type == EXEC_EVENT_TOUCH)
      return "TOUCH";
   if(type == EXEC_EVENT_CONFIRM)
      return "CONFIRM";
   if(type == EXEC_EVENT_ARM)
      return "ARM";
   if(type == EXEC_EVENT_SKIP)
      return "SKIP";
   if(type == EXEC_EVENT_CANCEL)
      return "CANCEL";
   if(type == EXEC_EVENT_FILL)
      return "FILL";
   if(type == EXEC_EVENT_TP1_LOCK)
      return "TP1_LOCK";
   if(type == EXEC_EVENT_CLOSE)
      return "CLOSE";
   if(type == EXEC_EVENT_DONE)
      return "DONE";
   return "NONE";
  }

string EaPhaseName(const ExecPhase phase)
  {
   if(phase == EXEC_TOUCHED)
      return "TOUCHED";
   if(phase == EXEC_CONFIRMED)
      return "CONFIRMED";
   if(phase == EXEC_ARMED)
      return "ARMED";
   if(phase == EXEC_MANAGING)
      return "MANAGING";
   if(phase == EXEC_DONE)
      return "DONE";
   if(phase == EXEC_CANCELED)
      return "CANCELED";
   return "IDLE";
  }

//+------------------------------------------------------------------+
//| Live gate: every order call must pass through this               |
//+------------------------------------------------------------------+
bool EaLiveEnabled()
  {
   return !InpShadowMode && g_liveAllowed;
  }

ENUM_ORDER_TYPE_FILLING EaMarketFilling()
  {
   const long modes = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((modes & SYMBOL_FILLING_FOK) != 0)
      return ORDER_FILLING_FOK;
   if((modes & SYMBOL_FILLING_IOC) != 0)
      return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
  }

double EaMoneyPerPipPerLot()
  {
   const double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   const double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickSize <= 0.0 || tickValue <= 0.0)
      return 0.0;
   return tickValue * (EXEC_PIP_SIZE / tickSize);
  }

void EaBuildConfig()
  {
   ZeroMemory(g_cfg);
   g_cfg.tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(g_cfg.tickSize <= 0.0)
      g_cfg.tickSize = _Point;
   g_cfg.slBufferTicks = InpSlBufferTicks;
   g_cfg.slCapDistance = InpSlCapPips * EXEC_PIP_SIZE;
   g_cfg.cisdMinRun = InpCISDMinRun;
   g_cfg.cisdMinWidth = InpCisdZoneMinWidth;
   g_cfg.cisdMaxWidth = InpCisdZoneMaxWidth;
   g_cfg.minZoneWidthTicks = InpMinZoneWidthTicks;
   g_cfg.lotsPerLayer = InpLotsPerLayer;
   g_cfg.moneyPerPipPerLot = EaMoneyPerPipPerLot();
   g_cfg.riskCap = InpRiskCapMoney;
   g_cfg.tpPips[0] = InpTp1Pips;
   g_cfg.tpPips[1] = InpTp2Pips;
   g_cfg.tpPips[2] = InpTp3Pips;
   g_cfg.slPlusPips = InpSlPlusPips;
  }

void EaBuildPoiParams(MSNRParams &params)
  {
   MSNR_InitParams(params);
   params.swingLeft = InpSwingLeft;
   params.swingRight = InpSwingRight;
   params.gapDetection = InpGapDetection;
   params.gapToleranceTicks = InpGapToleranceTicks;
   params.touchTolerancePoints = InpTouchTolerancePts;
   params.point = _Point;
   params.atrPeriod = InpATRPeriod;
   params.mergeToleranceATR = InpMergeToleranceATR;
   params.freshReplacesUnfresh = InpFreshReplacesUnfresh;
   params.maxLevelsPerTF = InpMaxLevelsPerTF;
   params.levelSource = MSNR_SOURCE_OPEN;
   params.tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   // The expert always needs to observe every lifecycle state, even when the
   // chart is configured to hide some of them.
   params.keepUnfresh = true;
   params.showBroken = true;
   params.flipBroken = true;
  }

//+------------------------------------------------------------------+
//| POI map refresh (closed POI bars only)                            |
//+------------------------------------------------------------------+
bool EaRefreshPoi(const int index)
  {
   const ENUM_TIMEFRAMES tf = EaTfAt(index);
   const datetime open = iTime(_Symbol, tf, 0);
   if(open == 0)
      return false;
   if(g_poiReady[index] && open == g_poiBarOpen[index])
      return true;

   long synchronized = 0;
   if(!SeriesInfoInteger(_Symbol, tf, SERIES_SYNCHRONIZED, synchronized) ||
      synchronized == 0)
      return false;

   MqlRates rates[];
   ArraySetAsSeries(rates, false);
   const int copied = CopyRates(_Symbol, tf, 0, InpPoiHistoryBars, rates);
   if(copied <= 1)
      return false;
   const int closed = copied - 1;
   if(closed <= InpSwingLeft + InpSwingRight)
      return false;

   MSNRBar bars[];
   if(ArrayResize(bars, closed) != closed)
      return false;
   for(int i = 0; i < closed; ++i)
     {
      bars[i].open = rates[i].open;
      bars[i].high = rates[i].high;
      bars[i].low = rates[i].low;
      bars[i].close = rates[i].close;
      bars[i].time = (long)rates[i].time;
     }

   MSNRParams params;
   EaBuildPoiParams(params);
   MSNRLevel levels[];
   int count = 0;
   if(!MSNR_BuildLevels(bars, closed, params, levels, count))
      return false;

   if(index == 0)
     {
      ArrayResize(g_levelsM15, count);
      for(int i = 0; i < count; ++i)
         g_levelsM15[i] = levels[i];
      g_countM15 = count;
     }
   else if(index == 1)
     {
      ArrayResize(g_levelsM30, count);
      for(int i = 0; i < count; ++i)
         g_levelsM30[i] = levels[i];
      g_countM30 = count;
     }
   else
     {
      ArrayResize(g_levelsH1, count);
      for(int i = 0; i < count; ++i)
         g_levelsH1[i] = levels[i];
      g_countH1 = count;
     }

   g_poiBarOpen[index] = open;
   g_poiReady[index] = true;
   return true;
  }

void EaRefreshAllPoi()
  {
   for(int i = 0; i < 3; ++i)
      EaRefreshPoi(i);
  }

//+------------------------------------------------------------------+
//| Execution bars (closed only)                                     |
//+------------------------------------------------------------------+
bool EaCopyExecBars()
  {
   MqlRates rates[];
   ArraySetAsSeries(rates, false);
   const int copied = CopyRates(_Symbol, InpExecTimeframe, 0,
                                InpExecHistoryBars, rates);
   if(copied <= 1)
      return false;
   const int closed = copied - 1;
   if(ArrayResize(g_execBars, closed) != closed)
      return false;
   for(int i = 0; i < closed; ++i)
     {
      g_execBars[i].open = rates[i].open;
      g_execBars[i].high = rates[i].high;
      g_execBars[i].low = rates[i].low;
      g_execBars[i].close = rates[i].close;
      g_execBars[i].time = (long)rates[i].time;
     }
   g_execCount = closed;
   return true;
  }

//+------------------------------------------------------------------+
//| Logging                                                          |
//+------------------------------------------------------------------+
void EaLogEvent(const bool isBuy, const ExecSetup &setup, const ExecEvent &ev)
  {
   if(!InpLogEvents)
      return;
   string extra = "";
   if(ev.type == EXEC_EVENT_ARM)
      extra = StringFormat(" E1=%.2f E2=%.2f E3=%.2f SL=%.2f TP=%.2f/%.2f/%.2f risk=%.2f %s",
                           setup.layers[0], setup.layers[1], setup.layers[2],
                           setup.initialSL, setup.tp[0], setup.tp[1],
                           setup.tp[2], setup.basketRisk,
                           AccountInfoString(ACCOUNT_CURRENCY));
   if(ev.type == EXEC_EVENT_TOUCH)
      extra = StringFormat(" poi=[%.2f,%.2f] tf=M%d",
                           setup.poiLower, setup.poiUpper,
                           setup.poiSourceMinutes);
   PrintFormat("ALPHA %s %s %s %s t=%s reason=%d%s",
               InpInstanceTag, (isBuy ? "BUY" : "SELL"), EaEventName(ev.type),
               EaPhaseName(setup.phase),
               TimeToString((datetime)ev.time, TIME_DATE | TIME_MINUTES),
               ev.reason, extra);
  }

void EaLogShadowFill(const bool isBuy, const ExecSetup &setup, const int layer)
  {
   if(!InpLogEvents)
      return;
   PrintFormat("ALPHA %s %s SHADOW_FILL L%d price=%.2f sl=%.2f tp=%.2f",
               InpInstanceTag, (isBuy ? "BUY" : "SELL"), layer + 1,
               setup.fillPrice[layer], setup.stops[layer], setup.tp[layer]);
  }

void EaLogShadowClose(const bool isBuy, const int layer, const bool isTp,
                      const ExecSetup &setup, const ExecEvent &ev)
  {
   if(!InpLogEvents)
      return;
   PrintFormat("ALPHA %s %s SHADOW_%s L%d price=%.2f phase=%s",
               InpInstanceTag, (isBuy ? "BUY" : "SELL"),
               (isTp ? "TP" : "SL"), layer + 1,
               (isTp ? setup.tp[layer] : setup.stops[layer]),
               EaPhaseName(setup.phase));
   if(ev.type == EXEC_EVENT_TP1_LOCK)
      PrintFormat("ALPHA %s %s TP1_LOCK cancel pending, E2 stop=%.2f E3 stop=%.2f",
                  InpInstanceTag, (isBuy ? "BUY" : "SELL"),
                  setup.stops[1], setup.stops[2]);
  }

//+------------------------------------------------------------------+
//| Setup start: newest fresh POI touched by the newest closed bar   |
//+------------------------------------------------------------------+
bool EaTryStartSetup(const bool isBuy, ExecSetup &setup, EaLink &link)
  {
   if(g_execCount <= 0)
      return false;
   const MSNRBar bar = g_execBars[g_execCount - 1];

   long      bestCreated = -1;
   int       bestTf = -1;
   MSNRRole  bestRole = MSNR_ROLE_SUPPORT;
   MSNRState bestState = MSNR_STATE_FRESH;
   double    lower = 0.0;
   double    upper = 0.0;

   for(int tf = 0; tf < 3; ++tf)
     {
      for(int i = 0; i < EaPoiCount(tf); ++i)
        {
         MSNRLevel level;
         if(!EaPoiLevelAt(tf, i, level))
            continue;
         if(level.state != MSNR_STATE_FRESH &&
            level.state != MSNR_STATE_FLIPPED_FRESH)
            continue;
         if(isBuy != (level.role == MSNR_ROLE_SUPPORT))
            continue;
         if(!MSNR_TouchesZone(bar.low, bar.high, level.lower, level.upper,
                              0.0))
            continue;
         if(level.created <= bestCreated)
            continue;
         bestCreated = level.created;
         bestTf = tf;
         bestRole = level.role;
         bestState = level.state;
         lower = level.lower;
         upper = level.upper;
        }
     }

   if(bestTf < 0)
      return false;

   if(!Exec_InitSetup(setup, isBuy, bestRole, lower, upper,
                      EaTfMinutes(bestTf)))
      return false;

   ExecEvent ev;
   if(!Exec_Advance(g_execBars, g_execCount, bestState, bestRole, g_cfg,
                    setup, ev))
     {
      Exec_ClearSetup(setup);
      return false;
     }

   link.valid = true;
   link.created = bestCreated;
   link.tfIndex = bestTf;
   link.lastState = bestState;
   EaLogEvent(isBuy, setup, ev);
   return true;
  }

//+------------------------------------------------------------------+
//| Shadow arm: layers already past the market fill immediately      |
//+------------------------------------------------------------------+
void EaShadowArmFills(const bool isBuy, ExecSetup &setup)
  {
   if(g_execCount <= 0)
      return;
   const double close = g_execBars[g_execCount - 1].close;
   ExecEvent ev;
   for(int i = 0; i < 3; ++i)
     {
      if(setup.layerState[i] != EXEC_LAYER_PENDING)
         continue;
      const bool marketable = isBuy ? (close <= setup.layers[i])
                                    : (close >= setup.layers[i]);
      if(!marketable)
         continue;
      const bool stopValid = isBuy ? (close > setup.initialSL)
                                   : (close < setup.initialSL);
      if(!stopValid)
        {
         PrintFormat("ALPHA %s %s SHADOW_ARM_SKIP L%d close=%.2f sl=%.2f",
                     InpInstanceTag, (isBuy ? "BUY" : "SELL"), i + 1, close,
                     setup.initialSL);
         continue;
        }
      if(Exec_RecordFill(setup, i, close, g_cfg, ev))
         EaLogShadowFill(isBuy, setup, i);
     }
  }

//+------------------------------------------------------------------+
//| Shadow simulation: limits fill on wick touch, stop checked first |
//+------------------------------------------------------------------+
void EaSimulateBars(const bool isBuy, ExecSetup &setup)
  {
   if(setup.phase != EXEC_ARMED && setup.phase != EXEC_MANAGING)
      return;
   if(g_execCount <= 0)
      return;
   const MSNRBar bar = g_execBars[g_execCount - 1];
   ExecEvent ev;

   for(int i = 0; i < 3; ++i)
     {
      if(setup.layerState[i] != EXEC_LAYER_PENDING)
         continue;
      const bool hit = setup.isBuy ? (bar.low <= setup.layers[i])
                                   : (bar.high >= setup.layers[i]);
      if(hit && Exec_RecordFill(setup, i, setup.layers[i], g_cfg, ev))
         EaLogShadowFill(isBuy, setup, i);
     }

   for(int i = 0; i < 3; ++i)
     {
      if(setup.layerState[i] != EXEC_LAYER_FILLED)
         continue;
      const bool stopHit = setup.isBuy ? (bar.low <= setup.stops[i])
                                       : (bar.high >= setup.stops[i]);
      const bool tpHit = setup.isBuy ? (bar.high >= setup.tp[i])
                                     : (bar.low <= setup.tp[i]);
      if(stopHit)
        {
         if(Exec_RecordClose(setup, i, false, ev))
            EaLogShadowClose(isBuy, i, false, setup, ev);
        }
      else if(tpHit)
        {
         if(Exec_RecordClose(setup, i, true, ev))
            EaLogShadowClose(isBuy, i, true, setup, ev);
        }
     }
  }

//+------------------------------------------------------------------+
//| Live execution (never reachable in shadow mode)                  |
//+------------------------------------------------------------------+
string EaLayerComment(const bool isBuy, const int layer)
  {
   return StringFormat("ALPHA %s L%d", (isBuy ? "B" : "S"), layer);
  }

int EaLayerFromComment(const string comment)
  {
   const int pos = StringFind(comment, " L");
   if(pos < 0 || pos + 2 >= StringLen(comment))
      return -1;
   const long layer = StringToInteger(StringSubstr(comment, pos + 2, 1));
   if(layer < 0 || layer > 2)
      return -1;
   return (int)layer;
  }

bool EaLiveStopsDistanceOk(const ExecSetup &setup)
  {
   const double point = (double)SymbolInfoInteger(_Symbol,
                                                  SYMBOL_TRADE_STOPS_LEVEL);
   const double minimum = point * _Point;
   for(int i = 0; i < 3; ++i)
     {
      if(MathAbs(setup.layers[i] - setup.initialSL) < minimum)
         return false;
      if(MathAbs(setup.tp[i] - setup.layers[i]) < minimum)
         return false;
     }
   return true;
  }

void EaLivePlaceBasket(const bool isBuy, const ExecSetup &setup)
  {
   if(!EaLiveEnabled())
      return;
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
     {
      PrintFormat("ALPHA %s %s ARM rejected: no market price",
                  InpInstanceTag, (isBuy ? "BUY" : "SELL"));
      return;
     }
   if(!EaLiveStopsDistanceOk(setup))
     {
      PrintFormat("ALPHA %s %s ARM rejected: broker stop level too wide",
                  InpInstanceTag, (isBuy ? "BUY" : "SELL"));
      return;
     }

   for(int i = 0; i < 3; ++i)
     {
      // A layer already at or beyond the market cannot rest as a limit: it is
      // executed immediately at market, exactly as a trader would at the close
      // of the retest bar.
      const bool marketable = isBuy ? (ask <= setup.layers[i])
                                    : (bid >= setup.layers[i]);
      MqlTradeRequest request;
      MqlTradeResult result;
      ZeroMemory(request);
      ZeroMemory(result);
      request.symbol = _Symbol;
      request.volume = InpLotsPerLayer;
      request.sl = setup.initialSL;
      request.tp = setup.tp[i];
      request.deviation = (ulong)InpSlippagePoints;
      request.magic = (ulong)InpMagic;
      request.comment = EaLayerComment(isBuy, i);
      if(marketable)
        {
         request.action = TRADE_ACTION_DEAL;
         request.type = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
         request.price = isBuy ? ask : bid;
         request.type_filling = EaMarketFilling();
        }
      else
        {
         request.action = TRADE_ACTION_PENDING;
         request.type = isBuy ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT;
         request.price = setup.layers[i];
         request.type_filling = ORDER_FILLING_RETURN;
         request.type_time = ORDER_TIME_GTC;
        }
      const bool sent = OrderSend(request, result);
      if(!sent || (result.retcode != TRADE_RETCODE_DONE &&
                   result.retcode != TRADE_RETCODE_PLACED))
         PrintFormat("ALPHA %s %s ORDER_FAIL L%d ret=%d comment=%s",
                     InpInstanceTag, (isBuy ? "BUY" : "SELL"), i + 1,
                     (int)result.retcode, result.comment);
      else
         PrintFormat("ALPHA %s %s ORDER_%s L%d ticket=%I64u price=%.2f",
                     InpInstanceTag, (isBuy ? "BUY" : "SELL"),
                     (marketable ? "MARKET" : "PLACED"), i + 1,
                     result.order, request.price);
     }
  }

void EaLiveCancelPendings(const bool isBuy, const ExecSetup &setup)
  {
   if(!EaLiveEnabled())
      return;
   const string prefix = StringFormat("ALPHA %s L", (isBuy ? "B" : "S"));
   for(int i = OrdersTotal() - 1; i >= 0; --i)
     {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;
      if(StringFind(OrderGetString(ORDER_COMMENT), prefix) != 0)
         continue;
      MqlTradeRequest request;
      MqlTradeResult result;
      ZeroMemory(request);
      ZeroMemory(result);
      request.action = TRADE_ACTION_REMOVE;
      request.order = ticket;
      if(!OrderSend(request, result))
         PrintFormat("ALPHA %s %s ORDER_DELETE_FAIL ticket=%I64u ret=%d",
                     InpInstanceTag, (isBuy ? "BUY" : "SELL"), ticket,
                     (int)result.retcode);
     }
  }

void EaLiveModifyStops(const bool isBuy, const ExecSetup &setup)
  {
   if(!EaLiveEnabled())
      return;
   const string prefix = StringFormat("ALPHA %s L", (isBuy ? "B" : "S"));
   for(int i = PositionsTotal() - 1; i >= 0; --i)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      if(StringFind(PositionGetString(POSITION_COMMENT), prefix) != 0)
         continue;
      const int layer = EaLayerFromComment(PositionGetString(POSITION_COMMENT));
      if(layer < 0 || setup.layerState[layer] != EXEC_LAYER_FILLED)
         continue;
      MqlTradeRequest request;
      MqlTradeResult result;
      ZeroMemory(request);
      ZeroMemory(result);
      request.action = TRADE_ACTION_SLTP;
      request.position = ticket;
      request.sl = setup.stops[layer];
      request.tp = setup.tp[layer];
      if(!OrderSend(request, result) || result.retcode != TRADE_RETCODE_DONE)
         PrintFormat("ALPHA %s %s SLTP_FAIL ticket=%I64u ret=%d",
                     InpInstanceTag, (isBuy ? "BUY" : "SELL"), ticket,
                     (int)result.retcode);
     }
  }

void EaHandleLiveEvent(const bool isBuy, const ExecSetup &setup,
                       const ExecEvent &ev)
  {
   if(ev.type == EXEC_EVENT_ARM)
      EaLivePlaceBasket(isBuy, setup);
   else if(ev.type == EXEC_EVENT_CANCEL || ev.type == EXEC_EVENT_SKIP ||
           ev.type == EXEC_EVENT_DONE)
      EaLiveCancelPendings(isBuy, setup);
  }

//+------------------------------------------------------------------+
//| Direction step                                                   |
//+------------------------------------------------------------------+
void EaProcessDirection(const bool isBuy, ExecSetup &setup, EaLink &link)
  {
   if(!Exec_IsActive(setup))
     {
      EaTryStartSetup(isBuy, setup, link);
      return;
     }

   MSNRState state = link.lastState;
   MSNRRole role = setup.poiRole;
   MSNRLevel level;
   if(link.valid && EaFindLevel(link.tfIndex, link.created, level))
     {
      state = level.state;
      role = level.role;
      link.lastState = state;
     }

   ExecEvent ev;
   const bool produced = Exec_Advance(g_execBars, g_execCount, state, role,
                                      g_cfg, setup, ev);
   if(produced)
     {
      EaLogEvent(isBuy, setup, ev);
      EaHandleLiveEvent(isBuy, setup, ev);
     }

   if(ev.type == EXEC_EVENT_ARM)
     {
      if(InpShadowMode || !g_liveAllowed)
         EaShadowArmFills(isBuy, setup);
      return;
     }

   if(InpShadowMode || !g_liveAllowed)
      EaSimulateBars(isBuy, setup);

   if(!Exec_IsActive(setup))
      EaClearLink(link);
  }

void EaOnClosedBar()
  {
   EaRefreshAllPoi();
   if(!EaCopyExecBars())
      return;
   EaProcessDirection(true, g_buySetup, g_buyLink);
   EaProcessDirection(false, g_sellSetup, g_sellLink);
  }

//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
bool EaSymbolReady()
  {
   if(!SymbolSelect(_Symbol, true))
      return false;
   const ENUM_ACCOUNT_MARGIN_MODE mode =
      (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(mode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      Print("ALPHA init refused: hedging account required for three independent layers");
      return false;
     }
   const double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   const double tickValue = SymbolInfoDouble(_Symbol,
                                            SYMBOL_TRADE_TICK_VALUE_LOSS);
   const double contract = SymbolInfoDouble(_Symbol,
                                          SYMBOL_TRADE_CONTRACT_SIZE);
   if(tickSize <= 0.0 || tickValue <= 0.0 || contract <= 0.0)
     {
      Print("ALPHA init refused: symbol tick/contract properties unavailable");
      return false;
     }
   return true;
  }

int EaCountOwnPositions()
  {
   int count = 0;
   for(int i = 0; i < PositionsTotal(); ++i)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) == InpMagic)
         ++count;
     }
   return count;
  }

int OnInit()
  {
   if(InpExecTimeframe != PERIOD_M1 && InpExecTimeframe != PERIOD_M2 && InpExecTimeframe != PERIOD_M3)
     {
      Print("ALPHA init refused: execution timeframe must be M1, M2 or M3");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpLotsPerLayer <= 0.0 || InpTp1Pips <= 0 || InpTp2Pips <= 0 ||
      InpTp3Pips <= 0 || InpSlPlusPips <= 0 || InpSlCapPips <= 0.0 ||
      InpMinZoneWidthTicks < 1 || InpCisdZoneMinWidth < 0.0 ||
      InpCisdZoneMaxWidth <= 0.0 || InpCISDMinRun < 1 ||
      InpSlBufferTicks < 0)
     {
      Print("ALPHA init refused: invalid strategy inputs");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(!EaSymbolReady())
      return INIT_FAILED;

   Exec_ClearSetup(g_buySetup);
   Exec_ClearSetup(g_sellSetup);
   EaClearLink(g_buyLink);
   EaClearLink(g_sellLink);
   EaBuildConfig();

   g_liveAllowed = !InpShadowMode;
   if(g_liveAllowed && EaCountOwnPositions() > 0)
     {
      Print("ALPHA live start refused: existing positions with this magic; ",
            "state recovery is not implemented, running shadow");
      g_liveAllowed = false;
     }

   g_lastExecOpen = iTime(_Symbol, InpExecTimeframe, 0);

   PrintFormat("ALPHA %s init: shadow=%s exec=%s magic=%I64d tick=%.2f contract=%.2f money/pip/lot=%.2f %s",
               InpInstanceTag, (EaLiveEnabled() ? "false" : "true"),
               EnumToString(InpExecTimeframe), InpMagic,
               SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE),
               SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE),
               EaMoneyPerPipPerLot(),
               AccountInfoString(ACCOUNT_CURRENCY));
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   PrintFormat("ALPHA %s stop: reason=%d buy=%s sell=%s",
               InpInstanceTag, reason, EaPhaseName(g_buySetup.phase),
               EaPhaseName(g_sellSetup.phase));
  }

//+------------------------------------------------------------------+
//| Tick: process the first closed bar after the previous bar open   |
//+------------------------------------------------------------------+
void OnTick()
  {
   const datetime open = iTime(_Symbol, InpExecTimeframe, 0);
   if(open == 0)
      return;
   if(g_lastExecOpen == 0)
     {
      g_lastExecOpen = open;
      return;
     }
   if(open == g_lastExecOpen)
      return;
   g_lastExecOpen = open;
   EaOnClosedBar();
  }

//+------------------------------------------------------------------+
//| Broker events: fills and closes (live only)                     |
//+------------------------------------------------------------------+
void EaHandleDealFill(const bool isBuy, const int layer, const double price)
  {
   ExecEvent ev;
   if(isBuy)
     {
      if(Exec_RecordFill(g_buySetup, layer, price, g_cfg, ev))
        {
         EaLogEvent(true, g_buySetup, ev);
         EaLiveModifyStops(true, g_buySetup);
        }
     }
   else
     {
      if(Exec_RecordFill(g_sellSetup, layer, price, g_cfg, ev))
        {
         EaLogEvent(false, g_sellSetup, ev);
         EaLiveModifyStops(false, g_sellSetup);
        }
     }
  }

void EaHandleDealClose(const bool isBuy, const int layer, const bool isTp)
  {
   ExecEvent ev;
   if(isBuy)
     {
      if(Exec_RecordClose(g_buySetup, layer, isTp, ev))
        {
         EaLogEvent(true, g_buySetup, ev);
         if(ev.type == EXEC_EVENT_TP1_LOCK)
            EaLiveModifyStops(true, g_buySetup);
        }
     }
   else
     {
      if(Exec_RecordClose(g_sellSetup, layer, isTp, ev))
        {
         EaLogEvent(false, g_sellSetup, ev);
         if(ev.type == EXEC_EVENT_TP1_LOCK)
            EaLiveModifyStops(false, g_sellSetup);
        }
     }
  }

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(!EaLiveEnabled())
      return;
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   if(!HistoryDealSelect(trans.deal))
      return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol)
      return;
   if((long)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic)
      return;

   const string comment = HistoryDealGetString(trans.deal, DEAL_COMMENT);
   const int layer = EaLayerFromComment(comment);
   if(layer < 0)
      return;
   const bool isBuy = StringFind(comment, "ALPHA B L") == 0;
   const long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   const double price = HistoryDealGetDouble(trans.deal, DEAL_PRICE);

   if(entry == DEAL_ENTRY_IN)
      EaHandleDealFill(isBuy, layer, price);
   else if(entry == DEAL_ENTRY_OUT)
     {
      const long reason = HistoryDealGetInteger(trans.deal, DEAL_REASON);
      EaHandleDealClose(isBuy, layer, reason == DEAL_REASON_TP);
     }
  }
//+------------------------------------------------------------------+
