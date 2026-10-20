#ifndef ALPHATOM_MSNR_KERNEL_MQH
#define ALPHATOM_MSNR_KERNEL_MQH

#ifdef __MQL5__
  #define MSNR_ARRAY_PARAMETER(type, name) const type &name[]
  #define MSNR_ARRAY_OUTPUT(type, name) type &name[]
  #define MSNR_ARRAY_SIZE(name) ArraySize(name)
  #define MSNR_ARRAY_ELEMENT(name, index) name[index]
  #define MSNR_DYNAMIC_ARRAY(type, name) type name[]
  #define MSNR_ARRAY_RESIZE(name, size) ArrayResize(name, size)
  #define MSNR_ARRAY_CLEAR(name) ArrayResize(name, 0)
#else
  #include <cmath>
  #include <vector>
  #define MSNR_ARRAY_PARAMETER(type, name) const std::vector<type> &name
  #define MSNR_ARRAY_OUTPUT(type, name) std::vector<type> &name
  #define MSNR_ARRAY_SIZE(name) static_cast<int>((name).size())
  #define MSNR_ARRAY_ELEMENT(name, index) (name)[index]
  #define MSNR_DYNAMIC_ARRAY(type, name) std::vector<type> name
  #define MSNR_ARRAY_RESIZE(name, size) (name).resize(size)
  #define MSNR_ARRAY_CLEAR(name) (name).clear()
  #define MSNR_IS_FINITE_NUMBER(value) std::isfinite(value)
#endif

#ifdef __MQL5__
  #define MSNR_IS_FINITE_NUMBER(value) MathIsValidNumber(value)
#endif

enum MSNRSource
  {
   MSNR_SOURCE_OPEN = 0,
   MSNR_SOURCE_CLOSE = 1
  };

enum MSNRRole
  {
   MSNR_ROLE_SUPPORT = 0,
   MSNR_ROLE_RESISTANCE = 1
  };

enum MSNRState
  {
   MSNR_STATE_FRESH = 0,
   MSNR_STATE_UNFRESH = 1,
   MSNR_STATE_FLIPPED_FRESH = 2,
   MSNR_STATE_FLIPPED_UNFRESH = 3,
   MSNR_STATE_BROKEN = 4
  };

struct MSNRBar
  {
   double open;
   double high;
   double low;
   double close;
   long time;
  };

struct MSNRZone
  {
   bool valid;
   bool bullish;
   double lower;
   double upper;
  };

struct MSNRLevel
  {
   double price;
   double lower;
   double upper;
   MSNRRole role;
   MSNRState state;
   long created;
   bool isGap;
   bool isSwingHigh;
  };

bool MSNR_CandidatePrecedes(const MSNRLevel &first,
                            const MSNRLevel &second)
  {
   if(first.created != second.created)
      return first.created > second.created;
   if(first.isGap != second.isGap)
      return !first.isGap;
   if(first.isSwingHigh != second.isSwingHigh)
      return first.isSwingHigh;
   return false;
  }

bool MSNR_IsValidBar(const MSNRBar &bar)
  {
   if(bar.time <= 0 || !MSNR_IS_FINITE_NUMBER(bar.open) ||
      !MSNR_IS_FINITE_NUMBER(bar.high) ||
      !MSNR_IS_FINITE_NUMBER(bar.low) ||
      !MSNR_IS_FINITE_NUMBER(bar.close))
      return false;
   if(bar.open <= 0.0 || bar.high <= 0.0 || bar.low <= 0.0 ||
      bar.close <= 0.0)
      return false;
   return bar.high >= bar.low && bar.high >= bar.open &&
          bar.high >= bar.close && bar.low <= bar.open &&
          bar.low <= bar.close;
  }

double MSNR_GetLevelPrice(const MSNRBar &bar, const MSNRSource source)
  {
   if(source == MSNR_SOURCE_OPEN)
      return bar.open;
   return bar.close;
  }

bool MSNR_IsPivotHigh(MSNR_ARRAY_PARAMETER(MSNRBar, bars),
                      const int count,
                      const int index,
                      const int left,
                      const int right,
                      const MSNRSource source)
  {
   if(count != MSNR_ARRAY_SIZE(bars) || count <= 0 || left < 0 || right < 0 ||
       index < left || index + right >= count)
      return false;

   const double candidate = MSNR_GetLevelPrice(MSNR_ARRAY_ELEMENT(bars, index), source);
   for(int offset = 1; offset <= left; ++offset)
      if(MSNR_GetLevelPrice(MSNR_ARRAY_ELEMENT(bars, index - offset), source) >= candidate)
         return false;
   for(int offset = 1; offset <= right; ++offset)
      if(MSNR_GetLevelPrice(MSNR_ARRAY_ELEMENT(bars, index + offset), source) >= candidate)
         return false;
   return true;
  }

bool MSNR_IsPivotLow(MSNR_ARRAY_PARAMETER(MSNRBar, bars),
                     const int count,
                     const int index,
                     const int left,
                     const int right,
                     const MSNRSource source)
  {
   if(count != MSNR_ARRAY_SIZE(bars) || count <= 0 || left < 0 || right < 0 ||
       index < left || index + right >= count)
      return false;

   const double candidate = MSNR_GetLevelPrice(MSNR_ARRAY_ELEMENT(bars, index), source);
   for(int offset = 1; offset <= left; ++offset)
      if(MSNR_GetLevelPrice(MSNR_ARRAY_ELEMENT(bars, index - offset), source) <= candidate)
         return false;
   for(int offset = 1; offset <= right; ++offset)
      if(MSNR_GetLevelPrice(MSNR_ARRAY_ELEMENT(bars, index + offset), source) <= candidate)
         return false;
   return true;
  }

MSNRZone MSNR_DetectGap(MSNR_ARRAY_PARAMETER(MSNRBar, bars),
                        const int count,
                        const int oldestIndex,
                        const double tolerance)
  {
   MSNRZone zone;
   zone.valid = false;
   zone.bullish = false;
   zone.lower = 0.0;
   zone.upper = 0.0;

   if(count != MSNR_ARRAY_SIZE(bars) || count < 3 || oldestIndex < 0 ||
      oldestIndex + 2 >= count || tolerance < 0.0)
      return zone;

   const MSNRBar oldest = MSNR_ARRAY_ELEMENT(bars, oldestIndex);
   const MSNRBar newest = MSNR_ARRAY_ELEMENT(bars, oldestIndex + 2);
   if(oldest.high + tolerance < newest.low)
     {
      zone.valid = true;
      zone.bullish = true;
      zone.lower = oldest.high;
      zone.upper = newest.low;
      return zone;
     }
   if(oldest.low - tolerance > newest.high)
     {
      zone.valid = true;
      zone.bullish = false;
      zone.lower = newest.high;
      zone.upper = oldest.low;
     }
   return zone;
  }

bool MSNR_TouchesZone(const double barLow,
                      const double barHigh,
                      const double zoneLow,
                      const double zoneHigh,
                      const double tolerance)
  {
   if(barLow > barHigh || zoneLow > zoneHigh || tolerance < 0.0)
      return false;
   return barHigh + tolerance >= zoneLow && barLow - tolerance <= zoneHigh;
  }

bool MSNR_IsBodyBreak(const double close,
                      const double zoneLow,
                      const double zoneHigh,
                      const MSNRRole role,
                      const double tolerance)
  {
   if(zoneLow > zoneHigh || tolerance < 0.0)
      return false;
   if(role == MSNR_ROLE_RESISTANCE)
      return close > zoneHigh + tolerance;
   if(role == MSNR_ROLE_SUPPORT)
      return close < zoneLow - tolerance;
   return false;
  }

double MSNR_ZoneDistance(const MSNRLevel &first, const MSNRLevel &second)
  {
   if(first.upper < second.lower)
      return second.lower - first.upper;
   if(second.upper < first.lower)
      return first.lower - second.upper;
   return 0.0;
  }

double MSNR_Max(const double first, const double second)
  {
   return first > second ? first : second;
  }

double MSNR_TrueRange(MSNR_ARRAY_PARAMETER(MSNRBar, bars), const int index)
  {
   const MSNRBar current = MSNR_ARRAY_ELEMENT(bars, index);
   const MSNRBar previous = MSNR_ARRAY_ELEMENT(bars, index - 1);
   const double highLow = current.high - current.low;
   const double highPreviousClose = current.high - previous.close;
   const double lowPreviousClose = current.low - previous.close;
   const double highGap = highPreviousClose < 0.0 ? -highPreviousClose :
                                                     highPreviousClose;
   const double lowGap = lowPreviousClose < 0.0 ? -lowPreviousClose :
                                                   lowPreviousClose;
   return MSNR_Max(highLow, MSNR_Max(highGap, lowGap));
  }

double MSNR_CalculateATR(MSNR_ARRAY_PARAMETER(MSNRBar, bars),
                         const int count,
                         const int period)
  {
   if(count != MSNR_ARRAY_SIZE(bars) || period < 1 || count <= period)
      return 0.0;

   double seedTotal = 0.0;
   for(int i = 1; i <= period; ++i)
      seedTotal += MSNR_TrueRange(bars, i);
   double atr = seedTotal / period;

   for(int i = period + 1; i < count; ++i)
      atr = (atr * (period - 1) + MSNR_TrueRange(bars, i)) / period;
   return atr;
  }

void MSNR_ApplyClosedBar(MSNRLevel &level,
                         const MSNRBar &bar,
                         const double touchTolerance,
                         const double breakTolerance,
                         const bool flipBroken)
  {
   if(level.state == MSNR_STATE_BROKEN)
      return;

   const bool wasFlipped = level.state == MSNR_STATE_FLIPPED_FRESH ||
                           level.state == MSNR_STATE_FLIPPED_UNFRESH;
   if(MSNR_IsBodyBreak(bar.close, level.lower, level.upper, level.role,
                       breakTolerance))
     {
      if(flipBroken && !wasFlipped)
        {
         level.role = level.role == MSNR_ROLE_RESISTANCE ? MSNR_ROLE_SUPPORT :
                                                            MSNR_ROLE_RESISTANCE;
         level.state = MSNR_STATE_FLIPPED_FRESH;
        }
      else
         level.state = MSNR_STATE_BROKEN;
      return;
     }

   if(!MSNR_TouchesZone(bar.low, bar.high, level.lower, level.upper,
                        touchTolerance))
      return;
   if(level.state == MSNR_STATE_FRESH)
      level.state = MSNR_STATE_UNFRESH;
   else if(level.state == MSNR_STATE_FLIPPED_FRESH)
      level.state = MSNR_STATE_FLIPPED_UNFRESH;
  }

bool MSNR_ShouldReplaceWithFresh(const MSNRState existingState,
                                 const MSNRState candidateState,
                                 const bool freshReplacesUnfresh)
  {
   if(!freshReplacesUnfresh || candidateState != MSNR_STATE_FRESH)
      return false;
   return existingState == MSNR_STATE_UNFRESH ||
          existingState == MSNR_STATE_FLIPPED_UNFRESH;
  }

bool MSNR_CanRetainCandidate(const int retainedCount, const int maximumLevels)
  {
   return retainedCount >= 0 && maximumLevels > 0 &&
          retainedCount < maximumLevels;
  }

bool MSNR_IsVisibleState(const MSNRState state,
                         const bool keepUnfresh,
                         const bool showBroken)
  {
   if(state == MSNR_STATE_FRESH || state == MSNR_STATE_FLIPPED_FRESH)
      return true;
   if(state == MSNR_STATE_UNFRESH || state == MSNR_STATE_FLIPPED_UNFRESH)
      return keepUnfresh;
   if(state == MSNR_STATE_BROKEN)
      return showBroken;
   return false;
  }

#endif
