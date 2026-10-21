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
input bool            InpShadowMode        = false;   // Live execution enabled
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
input double InpRiskCapMoney      = 440.0;   // Basket risk cap (deposit currency, 0=off)

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
int  g_closedBars = 0;

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

string EaReasonName(const int reason)
  {
   if(reason == EXEC_REASON_NONE)
      return "NONE";
   if(reason == EXEC_REASON_POI_BROKEN)
      return "POI_BROKEN";
   if(reason == EXEC_REASON_ROLE_FLIP)
      return "ROLE_FLIP";
   if(reason == EXEC_REASON_ZONE_INVALID)
      return "ZONE_INVALID";
   if(reason == EXEC_REASON_SL_INVALID)
      return "SL_INVALID";
   if(reason == EXEC_REASON_RISK_CAP)
      return "RISK_CAP";
   if(reason == EXEC_REASON_TP1)
      return "TP1";
   if(reason == EXEC_REASON_CONFIG)
      return "CONFIG";
   if(reason == EXEC_REASON_STALE)
      return "STALE";
   return "UNKNOWN";
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

// The broker advertises which filling policies it accepts (SYMBOL_FILLING_MODE).
// HFM Cent only allows FOK, so a hard-coded RETURN would be rejected.
ENUM_ORDER_TYPE_FILLING EaFillingMode()
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
   const double tickValueAny = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   const double contract = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double tv = 0.0;
   if(tickValue > 0.0)            tv = tickValue;          // preferred: per-tick loss value
   else if(tickValueAny > 0.0)    tv = tickValueAny;       // generic tick value
   if(tickSize > 0.0 && tv > 0.0)
      return tv * (EXEC_PIP_SIZE / tickSize);              // from live spec
   if(contract > 0.0)             return contract * 10.0;  // fallback: 1 oz × $0.10/pip = 10 USC/pip/lot
   return 0.0;
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
   else if(ev.type == EXEC_EVENT_SKIP)
      extra = StringFormat(" risk=%.2f cap=%.2f %s",
                           setup.basketRisk, g_cfg.riskCap,
                           AccountInfoString(ACCOUNT_CURRENCY));
   if(ev.type == EXEC_EVENT_TOUCH)
      extra = StringFormat(" poi=[%.2f,%.2f] tf=M%d",
                           setup.poiLower, setup.poiUpper,
                           setup.poiSourceMinutes);
   PrintFormat("ALPHA %s %s %s %s t=%s reason=%s(%d)%s",
               InpInstanceTag, (isBuy ? "BUY" : "SELL"), EaEventName(ev.type),
               EaPhaseName(setup.phase),
               TimeToString((datetime)ev.time, TIME_DATE | TIME_MINUTES),
               EaReasonName(ev.reason), ev.reason, extra);
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
         request.type_filling = EaFillingMode();
        }
      else
        {
         request.action = TRADE_ACTION_PENDING;
         request.type = isBuy ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT;
         request.price = setup.layers[i];
         request.type_filling = EaFillingMode();
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
      if(ev.type == EXEC_EVENT_ARM)
         EaWriteState();          // the state must exist before the orders go out
      EaHandleLiveEvent(isBuy, setup, ev);
     }
   else if(InpLogEvents && setup.phase == EXEC_TOUCHED && g_execCount > 0)
     {
      // Waiting for a valid IFVG/CISD confirmation after the touch: report the
      // waiting state so a silent setup is never invisible again.
      const long lastTime = g_execBars[g_execCount - 1].time;
      const int barsSince = (int)((lastTime - setup.touchTime) / 60);
      PrintFormat("ALPHA %s %s WAIT %s bars_since_touch=%d poi=[%.2f,%.2f] tf=M%d",
                  InpInstanceTag, (isBuy ? "BUY" : "SELL"),
                  EaPhaseName(setup.phase), barsSince, setup.poiLower,
                  setup.poiUpper, setup.poiSourceMinutes);
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

// Count the POI lifecycle states of one timeframe so the heartbeat can show
// whether a fresh level (the only kind that may start a setup) exists.
string EaPoiStateSummary(const int index)
  {
   int fresh = 0;
   int unfresh = 0;
   int broken = 0;
   for(int i = 0; i < EaPoiCount(index); ++i)
     {
      MSNRLevel level;
      if(!EaPoiLevelAt(index, i, level))
         continue;
      if(level.state == MSNR_STATE_FRESH || level.state == MSNR_STATE_FLIPPED_FRESH)
         ++fresh;
      else if(level.state == MSNR_STATE_BROKEN)
         ++broken;
      else
         ++unfresh;
     }
   return StringFormat("%d/%d/%d", fresh, unfresh, broken);
  }

void EaLogHeartbeat()
  {
   if(!InpLogEvents || g_execCount <= 0)
      return;
   const MSNRBar last = g_execBars[g_execCount - 1];
   PrintFormat("ALPHA %s HEARTBEAT t=%s m15=%s m30=%s h1=%s (fresh/unfresh/broken) buy=%s sell=%s",
               InpInstanceTag,
               TimeToString((datetime)last.time, TIME_DATE | TIME_MINUTES),
               EaPoiStateSummary(0), EaPoiStateSummary(1), EaPoiStateSummary(2),
               EaPhaseName(g_buySetup.phase), EaPhaseName(g_sellSetup.phase));
  }

//+------------------------------------------------------------------+
//| Persistent state (restart recovery)                               |
//|                                                                   |
//| The expert stores the two setups in MQL5/Files so a terminal      |
//| restart can rebuild them instead of leaving positions unmanaged. |
//+------------------------------------------------------------------+
#define EA_STATE_FILE "Alphatom_state.csv"

string EaStateSide(const bool isBuy)
  {
   return isBuy ? "BUY" : "SELL";
  }

string EaStateRow(const bool isBuy, const ExecSetup &setup, const EaLink &link)
  {
   ExecSnapshot snap;
   if(!Exec_TakeSnapshot(setup, snap))
      return "";
   string row = EaStateSide(isBuy);
   row += StringFormat(",%d,%d,%d,%.5f,%.5f,%d,%I64d,%I64d,%d,%.5f,%.5f,%d",
                       (int)snap.phase, (int)snap.isBuy, (int)snap.poiRole,
                       snap.poiLower, snap.poiUpper, snap.poiSourceMinutes,
                       snap.touchTime, snap.confirmTime, snap.confirmKind,
                       snap.entryZone.lower, snap.entryZone.upper,
                       snap.entryZone.valid ? 1 : 0);
   for(int i = 0; i < 3; ++i)
      row += StringFormat(",%.5f", snap.layers[i]);
   row += StringFormat(",%.5f", snap.initialSL);
   for(int i = 0; i < 3; ++i)
      row += StringFormat(",%.5f", snap.stops[i]);
   for(int i = 0; i < 3; ++i)
      row += StringFormat(",%.5f", snap.tp[i]);
   for(int i = 0; i < 3; ++i)
      row += StringFormat(",%.5f", snap.slPlus[i]);
   row += StringFormat(",%d", snap.slLocked ? 1 : 0);
   for(int i = 0; i < 3; ++i)
      row += StringFormat(",%d", (int)snap.layerState[i]);
   for(int i = 0; i < 3; ++i)
      row += StringFormat(",%.5f", snap.fillPrice[i]);
   row += StringFormat(",%.5f,%d,%d,%I64d,%d,%d", snap.basketRisk,
                       snap.skipReason, link.valid ? 1 : 0, link.created,
                       link.tfIndex, (int)link.lastState);
   return row;
  }

void EaWriteState()
  {
   const int handle = FileOpen(EA_STATE_FILE, FILE_WRITE | FILE_TXT |
                                FILE_ANSI);
   if(handle == INVALID_HANDLE)
     {
      PrintFormat("ALPHA %s state: cannot write %s (error %d)", InpInstanceTag,
                  EA_STATE_FILE, GetLastError());
      return;
     }
   FileWriteString(handle, "# alphatom state v1");
   const string buyRow = EaStateRow(true, g_buySetup, g_buyLink);
   if(buyRow != "")
      FileWriteString(handle, buyRow);
   const string sellRow = EaStateRow(false, g_sellSetup, g_sellLink);
   if(sellRow != "")
      FileWriteString(handle, sellRow);
   FileClose(handle);
  }

// Parse one state row into a setup and its POI link.
bool EaParseStateRow(const string &line, bool &outIsBuy, ExecSetup &outSetup,
                     EaLink &outLink)
  {
   string parts[];
   const int count = StringSplit(line, ',', parts);
   if(count < 42)
      return false;
   if(parts[0] == "BUY")
      outIsBuy = true;
   else if(parts[0] == "SELL")
      outIsBuy = false;
   else
      return false;

   ExecSnapshot snap;
   Exec_ClearSnapshot(snap);
   snap.valid = true;
   snap.phase = (ExecPhase)StringToInteger(parts[1]);
   snap.isBuy = StringToInteger(parts[2]) != 0;
   snap.poiRole = (MSNRRole)StringToInteger(parts[3]);
   snap.poiLower = StringToDouble(parts[4]);
   snap.poiUpper = StringToDouble(parts[5]);
   snap.poiSourceMinutes = (int)StringToInteger(parts[6]);
   snap.touchTime = StringToInteger(parts[7]);
   snap.confirmTime = StringToInteger(parts[8]);
   snap.confirmKind = (int)StringToInteger(parts[9]);
   snap.entryZone.lower = StringToDouble(parts[10]);
   snap.entryZone.upper = StringToDouble(parts[11]);
   snap.entryZone.valid = StringToInteger(parts[12]) != 0;
   snap.entryZone.bullish = snap.entryZone.lower < snap.entryZone.upper;
   int index = 13;
   for(int i = 0; i < 3; ++i)
      snap.layers[i] = StringToDouble(parts[index++]);
   snap.initialSL = StringToDouble(parts[index++]);
   for(int i = 0; i < 3; ++i)
      snap.stops[i] = StringToDouble(parts[index++]);
   for(int i = 0; i < 3; ++i)
      snap.tp[i] = StringToDouble(parts[index++]);
   for(int i = 0; i < 3; ++i)
      snap.slPlus[i] = StringToDouble(parts[index++]);
   snap.slLocked = StringToInteger(parts[index++]) != 0;
   for(int i = 0; i < 3; ++i)
      snap.layerState[i] = (ExecLayerState)StringToInteger(parts[index++]);
   for(int i = 0; i < 3; ++i)
      snap.fillPrice[i] = StringToDouble(parts[index++]);
   snap.basketRisk = StringToDouble(parts[index++]);
   snap.skipReason = (int)StringToInteger(parts[index++]);
   outLink.valid = StringToInteger(parts[index++]) != 0;
   outLink.created = StringToInteger(parts[index++]);
   outLink.tfIndex = (int)StringToInteger(parts[index++]);
   outLink.lastState = (MSNRState)StringToInteger(parts[index++]);
   return Exec_RestoreSnapshot(snap, outSetup);
  }

// Read the state file. Returns the number of restored setups.
int EaReadState(bool &outBuyRestored, bool &outSellRestored)
  {
   outBuyRestored = false;
   outSellRestored = false;
   const int handle = FileOpen(EA_STATE_FILE, FILE_READ | FILE_TXT |
                                FILE_ANSI);
   if(handle == INVALID_HANDLE)
      return 0;
   int restored = 0;
   while(!FileIsEnding(handle))
     {
      const string line = FileReadString(handle);
      if(StringLen(line) < 3)
         continue;
      if(StringGetCharacter(line, 0) == '#')
         continue;
      bool isBuy = false;
      ExecSetup setup;
      Exec_ClearSetup(setup);
      EaLink link;
      EaClearLink(link);
      if(!EaParseStateRow(line, isBuy, setup, link))
         continue;
      if(isBuy)
        {
         Exec_ClearSetup(g_buySetup);
         g_buySetup = setup;
         g_buyLink = link;
         outBuyRestored = true;
        }
      else
        {
         Exec_ClearSetup(g_sellSetup);
         g_sellSetup = setup;
         g_sellLink = link;
         outSellRestored = true;
        }
      ++restored;
     }
   FileClose(handle);
   return restored;
  }



// Does the broker hold an open position of this magic for that layer?
bool EaHasOpenPosition(const bool isBuy, const int layer)
  {
   for(int i = 0; i < PositionsTotal(); ++i)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      const string comment = PositionGetString(POSITION_COMMENT);
      if((StringFind(comment, "ALPHA B L") == 0) != isBuy)
         continue;
      if(EaLayerFromComment(comment) != layer)
         continue;
      return true;
     }
   return false;
  }

// Does the broker hold a resting order of this magic for that layer?
bool EaHasRestingOrder(const bool isBuy, const int layer)
  {
   for(int i = 0; i < OrdersTotal(); ++i)
     {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;
      const string comment = OrderGetString(ORDER_COMMENT);
      if((StringFind(comment, "ALPHA B L") == 0) != isBuy)
         continue;
      if(EaLayerFromComment(comment) != layer)
         continue;
      return true;
     }
   return false;
  }

// Verify the restored state against the broker. Any position or resting
// order that the state file does not know about means the state is stale:
// trading must not continue in that case.
string EaValidateSide(const bool isBuy, ExecSetup &setup,
                      const bool restored)
  {
   for(int i = 0; i < PositionsTotal(); ++i)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      const string comment = PositionGetString(POSITION_COMMENT);
      const int layer = EaLayerFromComment(comment);
      const bool posIsBuy = StringFind(comment, "ALPHA B L") == 0;
      if(posIsBuy != isBuy)
         continue;
      if(layer < 0)
         return "an open position carries no layer comment";
      if(!restored)
         return "open positions exist without a matching state file";
      if(setup.layerState[layer] != EXEC_LAYER_FILLED)
         return StringFormat("layer %d is open but the state file does not mark it filled",
                             layer + 1);
     }
   for(int i = 0; i < OrdersTotal(); ++i)
     {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;
      const string comment = OrderGetString(ORDER_COMMENT);
      const int layer = EaLayerFromComment(comment);
      const bool orderIsBuy = StringFind(comment, "ALPHA B L") == 0;
      if(orderIsBuy != isBuy)
         continue;
      if(layer < 0)
         return "a resting order carries no layer comment";
      if(!restored)
         return "resting orders exist without a matching state file";
      if(setup.layerState[layer] != EXEC_LAYER_PENDING)
         return StringFormat("layer %d has a resting order but the state file does not mark it pending",
                             layer + 1);
     }
   // The other way round: a layer the state calls filled must have a position,
   // and a layer it calls pending must have a resting order.
   for(int layer = 0; layer < 3; ++layer)
     {
      if(setup.layerState[layer] == EXEC_LAYER_FILLED &&
         !EaHasOpenPosition(isBuy, layer))
         return StringFormat("the state file marks layer %d filled but the broker has no position for it",
                             layer + 1);
      if(setup.layerState[layer] == EXEC_LAYER_PENDING &&
         !EaHasRestingOrder(isBuy, layer))
         Exec_CancelLayer(setup, layer);
     }
   return "";
  }

string EaValidateRecovery(const bool buyRestored, const bool sellRestored)
  {
   const string buyReason = EaValidateSide(true, g_buySetup, buyRestored);
   if(buyReason != "")
      return buyReason;
   return EaValidateSide(false, g_sellSetup, sellRestored);
  }

void EaOnClosedBar()
  {
   EaRefreshAllPoi();
   if(!EaCopyExecBars())
      return;
   EaProcessDirection(true, g_buySetup, g_buyLink);
   EaProcessDirection(false, g_sellSetup, g_sellLink);
   EaWriteState();
   ++g_closedBars;
   if(g_closedBars % 30 == 0)
      EaLogHeartbeat();
  }

void EaLogRuntimeProbe()
  {
   PrintFormat("ALPHA %s probe account: login=%I64d server=%s currency=%s leverage=1:%I64d marginMode=%s",
               InpInstanceTag, AccountInfoInteger(ACCOUNT_LOGIN),
               AccountInfoString(ACCOUNT_SERVER),
               AccountInfoString(ACCOUNT_CURRENCY),
               AccountInfoInteger(ACCOUNT_LEVERAGE),
               EnumToString((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)));
   PrintFormat("ALPHA %s probe trade flags: terminalAllowed=%d mqlAllowed=%d accountTradeMode=%d",
               InpInstanceTag,
               (int)TerminalInfoInteger(TERMINAL_TRADE_ALLOWED),
               (int)MQLInfoInteger(MQL_TRADE_ALLOWED),
               (int)AccountInfoInteger(ACCOUNT_TRADE_MODE));
   PrintFormat("ALPHA %s probe symbol: %s digits=%d point=%.5f tick=%.5f tickValueLoss=%.4f tickValueProfit=%.4f contract=%.2f stopsLevel=%d freezeLevel=%d spread=%d fillingMask=%d tradeMode=%s moneyPerPipLot=%.4f",
               InpInstanceTag, _Symbol,
               (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS), _Point,
               SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE),
               SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS),
               SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_PROFIT),
               SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE),
               (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
               (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL),
               (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD),
               (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE),
               EnumToString((ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE)),
               EaMoneyPerPipPerLot());
   const ENUM_TIMEFRAMES timeframes[6] =
     {PERIOD_M1, PERIOD_M2, PERIOD_M3, PERIOD_M15, PERIOD_M30, PERIOD_H1};
   for(int i = 0; i < 6; ++i)
     {
      const ENUM_TIMEFRAMES tf = timeframes[i];
      const int bars = Bars(_Symbol, tf);
      const datetime newest = iTime(_Symbol, tf, 0);
      const datetime bar300 = (bars > 300 ? iTime(_Symbol, tf, 299) : 0);
      PrintFormat("ALPHA %s probe series %s bars=%d newest=%s bar300=%s",
                  InpInstanceTag, EnumToString(tf), bars,
                  TimeToString(newest, TIME_DATE | TIME_MINUTES),
                  TimeToString(bar300, TIME_DATE | TIME_MINUTES));
     }
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
   const double contract = SymbolInfoDouble(_Symbol,
                                          SYMBOL_TRADE_CONTRACT_SIZE);
   if(tickSize <= 0.0 || contract <= 0.0)
     {
      Print("ALPHA init refused: symbol tick/contract properties unavailable");
      return false;
     }
   const double tickValue = SymbolInfoDouble(_Symbol,
                                            SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue <= 0.0)
      Print("ALPHA warning: SYMBOL_TRADE_TICK_VALUE_LOSS is 0; using contract-spec fallback for money-per-pip");
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

   // Restart recovery: rebuild the setups from the state file and check them
   // against the broker before any order may be sent.
   bool buyRestored = false;
   bool sellRestored = false;
   const int restored = EaReadState(buyRestored, sellRestored);
   if(restored > 0)
      PrintFormat("ALPHA %s recovery: %d setup(s) restored from %s",
                  InpInstanceTag, restored, EA_STATE_FILE);

   g_liveAllowed = !InpShadowMode;
   if(g_liveAllowed)
     {
      const string reason = EaValidateRecovery(buyRestored, sellRestored);
      if(reason != "")
        {
         PrintFormat("ALPHA live start refused: %s; running shadow", reason);
         g_liveAllowed = false;
        }
      else if(EaCountOwnPositions() > 0)
         PrintFormat("ALPHA %s recovery: %d position(s) of this magic are managed again",
                     InpInstanceTag, EaCountOwnPositions());
     }

   g_lastExecOpen = iTime(_Symbol, InpExecTimeframe, 0);

   EaLogRuntimeProbe();

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
         EaWriteState();
        }
     }
   else
     {
      if(Exec_RecordFill(g_sellSetup, layer, price, g_cfg, ev))
        {
         EaLogEvent(false, g_sellSetup, ev);
         EaLiveModifyStops(false, g_sellSetup);
         EaWriteState();
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
         EaWriteState();
        }
     }
   else
     {
      if(Exec_RecordClose(g_sellSetup, layer, isTp, ev))
        {
         EaLogEvent(false, g_sellSetup, ev);
         if(ev.type == EXEC_EVENT_TP1_LOCK)
            EaLiveModifyStops(false, g_sellSetup);
         EaWriteState();
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
