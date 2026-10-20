#property copyright "Alphatom"
#property version   "1.00"
#property description "Independent MTF MSNR-style POI map for M15, M30 and H1"
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

#include "..\Include\Alphatom\MSNRKernel.mqh"

input string     InpInstanceTag             = "A";
input MSNRSource InpLevelSource             = MSNR_SOURCE_OPEN;
input int        InpSwingLeft               = 3;
input int        InpSwingRight              = 3;
input bool       InpGapDetection            = true;
input int        InpGapToleranceTicks        = 2;
input double     InpTouchTolerancePoints     = 0.0;
input int        InpATRPeriod                = 14;
input double     InpMergeToleranceATR        = 0.1;
input bool       InpFreshReplacesUnfresh     = false;
input bool       InpKeepUnfresh              = true;
input bool       InpFlipBroken               = true;
input bool       InpShowAV                   = true;
input bool       InpShowBroken               = true;
input int        InpMaxLevelsPerTF           = 8;
input int        InpHistoryBars              = 1500;

ENUM_TIMEFRAMES MSNR_SOURCE_PERIODS[3] =
  {PERIOD_M15, PERIOD_M30, PERIOD_H1};

MSNRLevel g_m15_levels[];
MSNRLevel g_m30_levels[];
MSNRLevel g_h1_levels[];
int g_m15_level_count = 0;
int g_m30_level_count = 0;
int g_h1_level_count = 0;

string TimeframeTag(const ENUM_TIMEFRAMES timeframe)
  {
   if(timeframe == PERIOD_M15)
      return "M15";
   if(timeframe == PERIOD_M30)
      return "M30";
   if(timeframe == PERIOD_H1)
      return "H1";
   return "TF";
  }

string TimeframePrefix(const ENUM_TIMEFRAMES timeframe)
  {
   string tag = InpInstanceTag;
   if(StringLen(tag) == 0)
      tag = "A";
   if(StringLen(tag) > 8)
      tag = StringSubstr(tag, 0, 8);
   return "ATMSNR_" + tag + "_" + TimeframeTag(timeframe) + "_";
  }

void ClearTimeframeObjects(const string prefix)
  {
   ObjectsDeleteAll(0, prefix);
  }

string LevelObjectName(const string prefix,
                       const long created,
                       const string kind)
  {
   return prefix + kind + "_" + IntegerToString((int)created);
  }

string StateTag(const MSNRState state)
  {
   if(state == MSNR_STATE_FRESH)
      return "Fresh";
   if(state == MSNR_STATE_UNFRESH)
      return "Unfresh";
   if(state == MSNR_STATE_FLIPPED_FRESH)
      return "Flipped fresh";
   if(state == MSNR_STATE_FLIPPED_UNFRESH)
      return "Flipped unfresh";
   return "Broken";
  }

color LevelColor(const MSNRLevel &level)
  {
   if(level.state == MSNR_STATE_UNFRESH ||
      level.state == MSNR_STATE_FLIPPED_UNFRESH)
      return clrDarkGray;
   if(level.state == MSNR_STATE_FLIPPED_FRESH)
      return clrLimeGreen;
   if(level.state == MSNR_STATE_BROKEN)
      return clrSilver;
   return level.role == MSNR_ROLE_SUPPORT ? clrDodgerBlue : clrTomato;
  }

ENUM_LINE_STYLE LevelStyle(const MSNRLevel &level)
  {
   if(level.state == MSNR_STATE_UNFRESH ||
      level.state == MSNR_STATE_FLIPPED_UNFRESH)
      return STYLE_DASH;
   if(level.state == MSNR_STATE_FLIPPED_FRESH)
      return STYLE_DOT;
   if(level.state == MSNR_STATE_BROKEN)
      return STYLE_DASHDOT;
   return STYLE_SOLID;
  }

void DrawLevel(const ENUM_TIMEFRAMES timeframe,
               const string prefix,
               const MSNRLevel &level)
  {
   if(level.state == MSNR_STATE_BROKEN && !InpShowBroken)
      return;
   if((level.state == MSNR_STATE_UNFRESH ||
       level.state == MSNR_STATE_FLIPPED_UNFRESH) && !InpKeepUnfresh)
      return;

   string kind = "SL";
   if(level.isGap)
      kind = "GAP";
   else if(level.isSwingHigh)
      kind = "SH";
   const string name = LevelObjectName(prefix, level.created, kind);
   const color lineColor = LevelColor(level);
   bool created = false;
   if(level.isGap)
      created = ObjectCreate(0, name, OBJ_RECTANGLE, 0,
                             (datetime)level.created, level.upper,
                             TimeCurrent(), level.lower);
   else
      created = ObjectCreate(0, name, OBJ_HLINE, 0, 0, level.price);
   if(!created)
      return;

   ObjectSetInteger(0, name, OBJPROP_COLOR, lineColor);
   ObjectSetInteger(0, name, OBJPROP_STYLE, LevelStyle(level));
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_BACK, level.isGap);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   if(level.isGap)
      ObjectSetInteger(0, name, OBJPROP_FILL, true);

   const string roleTag = level.role == MSNR_ROLE_SUPPORT ? "S" : "R";
   const string labelName = LevelObjectName(prefix, level.created,
                                             "TXT_" + kind);
   const double labelPrice = level.isGap ? (level.lower + level.upper) * 0.5 :
                                           level.price;
   if(ObjectCreate(0, labelName, OBJ_TEXT, 0, TimeCurrent(), labelPrice))
     {
      ObjectSetString(0, labelName, OBJPROP_TEXT,
                      TimeframeTag(timeframe) + " " + roleTag + " " +
                      StateTag(level.state));
      ObjectSetInteger(0, labelName, OBJPROP_COLOR, lineColor);
      ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, 8);
      ObjectSetInteger(0, labelName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, labelName, OBJPROP_HIDDEN, true);
     }

   if(!level.isGap && InpShowAV)
     {
      const string markerName = LevelObjectName(prefix, level.created,
                                                 "AV_" + kind);
      if(ObjectCreate(0, markerName, OBJ_ARROW, 0,
                      (datetime)level.created, level.price))
        {
         ObjectSetInteger(0, markerName, OBJPROP_ARROWCODE, 159);
         ObjectSetInteger(0, markerName, OBJPROP_COLOR, lineColor);
         ObjectSetInteger(0, markerName, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, markerName, OBJPROP_HIDDEN, true);
        }
     }
  }

void RenderTimeframe(const ENUM_TIMEFRAMES timeframe,
                     const MSNRLevel &levels[],
                     const int levelCount)
  {
   const string prefix = TimeframePrefix(timeframe);
   for(int i = 0; i < levelCount; ++i)
      DrawLevel(timeframe, prefix, levels[i]);
  }

bool ValidInputs()
  {
   if(InpSwingLeft < 1 || InpSwingRight < 1 || InpGapToleranceTicks < 0 ||
      InpTouchTolerancePoints < 0.0 || InpATRPeriod < 1 ||
      InpMergeToleranceATR < 0.0 || InpMaxLevelsPerTF < 1 ||
      InpHistoryBars <= InpSwingLeft + InpSwingRight + 3)
      return false;
   return true;
  }

void AddCandidate(MSNRLevel &levels[],
                  int &levelCount,
                  const MSNRLevel &candidate,
                  const double mergeTolerance)
  {
   if(!MSNR_IsVisibleState(candidate.state, InpKeepUnfresh, InpShowBroken))
      return;
   for(int i = 0; i < levelCount; ++i)
     {
      if(MSNR_ZoneDistance(levels[i], candidate) > mergeTolerance)
         continue;
      if(MSNR_ShouldReplaceWithFresh(levels[i].state, candidate.state,
                                     InpFreshReplacesUnfresh))
         levels[i] = candidate;
      return;
     }

   if(!MSNR_CanRetainCandidate(levelCount, InpMaxLevelsPerTF))
      return;
   if(ArrayResize(levels, levelCount + 1) != levelCount + 1)
      return;
   levels[levelCount] = candidate;
   ++levelCount;
  }

void StoreCandidate(MSNRLevel &candidates[],
                    int &candidateCount,
                    const MSNRLevel &candidate)
  {
   if(candidateCount >= ArraySize(candidates))
      return;
   candidates[candidateCount] = candidate;
   ++candidateCount;
  }

void InitializeCandidate(MSNRLevel &candidate,
                         const double lower,
                         const double upper,
                         const MSNRRole role,
                         const long created,
                         const bool isGap,
                         const bool isSwingHigh,
                         const MSNRBar &bars[],
                         const int count,
                         const int firstLifecycleBar)
  {
   candidate.lower = lower;
   candidate.upper = upper;
   candidate.price = (lower + upper) * 0.5;
   candidate.role = role;
   candidate.state = MSNR_STATE_FRESH;
   candidate.created = created;
   candidate.isGap = isGap;
   candidate.isSwingHigh = isSwingHigh;

   const double touchTolerance = InpTouchTolerancePoints * _Point;
   for(int i = firstLifecycleBar; i < count; ++i)
      MSNR_ApplyClosedBar(candidate, bars[i], touchTolerance, 0.0,
                          InpFlipBroken);
  }

void ProcessTimeframe(const ENUM_TIMEFRAMES timeframe,
                      MSNRLevel &outLevels[],
                      int &outCount)
  {
   const string prefix = TimeframePrefix(timeframe);
   ClearTimeframeObjects(prefix);
   outCount = 0;
   ArrayResize(outLevels, 0);

   long synchronized = 0;
   if(!SeriesInfoInteger(_Symbol, timeframe, SERIES_SYNCHRONIZED,
                         synchronized) || synchronized == 0)
      return;

   MqlRates rates[];
   ArraySetAsSeries(rates, false);
   const int copied = CopyRates(_Symbol, timeframe, 0, InpHistoryBars, rates);
   if(copied <= 0)
     {
      ClearTimeframeObjects(prefix);
      return;
     }

   const int closed_count = copied - 1;
   if(closed_count <= InpSwingLeft + InpSwingRight)
      return;

   MSNRBar bars[];
   if(ArrayResize(bars, closed_count) != closed_count)
      return;
   for(int i = 0; i < closed_count; ++i)
     {
      bars[i].open = rates[i].open;
      bars[i].high = rates[i].high;
      bars[i].low = rates[i].low;
      bars[i].close = rates[i].close;
      bars[i].time = (long)rates[i].time;
      if(!MSNR_IsValidBar(bars[i]))
        {
         ArrayResize(outLevels, 0);
         outCount = 0;
         ClearTimeframeObjects(prefix);
         return;
        }
     }

   const double atr = MSNR_CalculateATR(bars, closed_count, InpATRPeriod);
   const double mergeTolerance = atr * InpMergeToleranceATR;
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0)
      tickSize = _Point;
   const double gapTolerance = InpGapToleranceTicks * tickSize;

   MSNRLevel swingCandidates[];
   MSNRLevel gapCandidates[];
   if(ArrayResize(swingCandidates, closed_count * 2) != closed_count * 2 ||
      ArrayResize(gapCandidates, closed_count - 2) != closed_count - 2)
      return;
   int swingCount = 0;
   int gapCount = 0;

   const int newestSwing = closed_count - InpSwingRight - 1;
   for(int index = newestSwing;
       index >= InpSwingLeft;
       --index)
     {
      if(MSNR_IsPivotHigh(bars, closed_count, index, InpSwingLeft,
                          InpSwingRight, InpLevelSource))
        {
         const double price = MSNR_GetLevelPrice(bars[index], InpLevelSource);
         MSNRLevel candidate;
         InitializeCandidate(candidate, price, price, MSNR_ROLE_RESISTANCE,
                             bars[index].time, false, true, bars, closed_count,
                             index + 1);
         StoreCandidate(swingCandidates, swingCount, candidate);
        }
      if(MSNR_IsPivotLow(bars, closed_count, index, InpSwingLeft,
                         InpSwingRight, InpLevelSource))
        {
         const double price = MSNR_GetLevelPrice(bars[index], InpLevelSource);
         MSNRLevel candidate;
         InitializeCandidate(candidate, price, price, MSNR_ROLE_SUPPORT,
                             bars[index].time, false, false, bars, closed_count,
                             index + 1);
         StoreCandidate(swingCandidates, swingCount, candidate);
        }
     }

   if(InpGapDetection)
     {
      for(int oldestIndex = closed_count - 3;
          oldestIndex >= 0;
          --oldestIndex)
        {
         const MSNRZone zone = MSNR_DetectGap(bars, closed_count, oldestIndex,
                                              gapTolerance);
         if(!zone.valid)
            continue;
         MSNRLevel candidate;
         const MSNRRole role = zone.bullish ? MSNR_ROLE_SUPPORT :
                                              MSNR_ROLE_RESISTANCE;
         InitializeCandidate(candidate, zone.lower, zone.upper, role,
                             bars[oldestIndex + 2].time, true, false, bars,
                             closed_count, oldestIndex + 3);
         StoreCandidate(gapCandidates, gapCount, candidate);
        }
     }

   int swingIndex = 0;
   int gapIndex = 0;
   while((swingIndex < swingCount || gapIndex < gapCount) &&
         MSNR_CanRetainCandidate(outCount, InpMaxLevelsPerTF))
     {
      bool takeSwing = gapIndex >= gapCount;
      if(swingIndex < swingCount && gapIndex < gapCount)
         takeSwing = MSNR_CandidatePrecedes(swingCandidates[swingIndex],
                                            gapCandidates[gapIndex]);
      if(takeSwing)
        {
         AddCandidate(outLevels, outCount, swingCandidates[swingIndex],
                      mergeTolerance);
         ++swingIndex;
        }
      else
        {
         AddCandidate(outLevels, outCount, gapCandidates[gapIndex],
                      mergeTolerance);
         ++gapIndex;
        }
     }
   RenderTimeframe(timeframe, outLevels, outCount);
  }

int OnInit()
  {
   if(!ValidInputs())
      return INIT_PARAMETERS_INCORRECT;
   IndicatorSetString(INDICATOR_SHORTNAME,
                      "Alphatom MSNR MTF (M15/M30/H1)");
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   for(int i = 0; i < ArraySize(MSNR_SOURCE_PERIODS); ++i)
      ClearTimeframeObjects(TimeframePrefix(MSNR_SOURCE_PERIODS[i]));
  }

int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   if(rates_total <= 0)
      return 0;
   ProcessTimeframe(MSNR_SOURCE_PERIODS[0], g_m15_levels, g_m15_level_count);
   ProcessTimeframe(MSNR_SOURCE_PERIODS[1], g_m30_levels, g_m30_level_count);
   ProcessTimeframe(MSNR_SOURCE_PERIODS[2], g_h1_levels, g_h1_level_count);
   return rates_total;
  }
