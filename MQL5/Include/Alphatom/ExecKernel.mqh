#ifndef ALPHATOM_EXEC_KERNEL_MQH
#define ALPHATOM_EXEC_KERNEL_MQH

#include "MSNRKernel.mqh"

// ---------------------------------------------------------------------------
// Alphatom execution kernel (pure logic, shared by the MQL5 expert and the
// host C++ harness). Every rule implemented here is frozen in
// docs/ea-execution-spec.md; nothing here may place, modify or close an
// order - the expert translates the returned intents into MT5 calls.
// ---------------------------------------------------------------------------

// Colour of a closed candle: +1 bullish, -1 bearish, 0 doji.
inline int Exec_BarColour(const MSNRBar &bar)
  {
   if(bar.close > bar.open)
      return 1;
   if(bar.close < bar.open)
      return -1;
   return 0;
  }

// Earliest inverted FVG whose break bar is later than `afterIndex`.
// A gap inverts when a candle CLOSES strictly beyond its far boundary
// (body close, never a wick). A bullish gap closed below turns into a
// bearish (resistance) IFVG, a bearish gap closed above into a bullish
// (support) IFVG. The first break of a gap decides its fate forever.
// outZone.bullish reports the INVERTED role (true = support zone).
bool Exec_DetectIFVG(MSNR_ARRAY_PARAMETER(MSNRBar, bars),
                     const int count,
                     const int afterIndex,
                     const MSNRRole wanted,
                     const double gapTolerance,
                     const double breakTolerance,
                     MSNRZone &outZone,
                     int &outIndex,
                     long &outTime)
  {
   outZone.valid = false;
   outZone.bullish = false;
   outZone.lower = 0.0;
   outZone.upper = 0.0;
   outIndex = -1;
   outTime = 0;

   if(count != MSNR_ARRAY_SIZE(bars) || count < 3 || gapTolerance < 0.0 ||
      breakTolerance < 0.0)
      return false;

   for(int j = afterIndex + 1; j < count; ++j)
     {
      if(j < 2)
         continue;
      for(int i = j - 2; i >= 0; --i)
        {
         const MSNRZone gap = MSNR_DetectGap(bars, count, i, gapTolerance);
         if(!gap.valid)
            continue;

         const MSNRRole gapRole = gap.bullish ? MSNR_ROLE_SUPPORT :
                                                  MSNR_ROLE_RESISTANCE;
         bool brokenBefore = false;
         for(int k = i + 2; k < j; ++k)
           {
            const double close = MSNR_ARRAY_ELEMENT(bars, k).close;
            if(MSNR_IsBodyBreak(close, gap.lower, gap.upper, gapRole,
                                breakTolerance))
              {
               brokenBefore = true;
               break;
              }
           }
         if(brokenBefore)
            continue;

         const double close = MSNR_ARRAY_ELEMENT(bars, j).close;
         if(!MSNR_IsBodyBreak(close, gap.lower, gap.upper, gapRole,
                              breakTolerance))
            continue;

         const MSNRRole inverted = gap.bullish ? MSNR_ROLE_RESISTANCE :
                                                  MSNR_ROLE_SUPPORT;
         if(inverted != wanted)
            continue;

         outZone.valid = true;
         outZone.bullish = inverted == MSNR_ROLE_SUPPORT;
         outZone.lower = gap.lower;
         outZone.upper = gap.upper;
         outIndex = j;
         outTime = MSNR_ARRAY_ELEMENT(bars, j).time;
         return true;
        }
     }
   return false;
  }

// Change in State of Delivery.
// A delivery run is a sequence of same-colour candles of at least `minRun`
// candles; a doji breaks the run. The anchor is the OPEN of the first candle
// of the latest completed qualifying run. A bullish CISD needs a later close
// ABOVE the anchor of a bearish run, a bearish CISD a close BELOW the anchor
// of a bullish run. The event bar must be later than `afterIndex`.
bool Exec_DetectCISD(MSNR_ARRAY_PARAMETER(MSNRBar, bars),
                     const int count,
                     const int afterIndex,
                     const int minRun,
                     const bool wantBullish,
                     double &outAnchor,
                     int &outIndex,
                     long &outTime)
  {
   outAnchor = 0.0;
   outIndex = -1;
   outTime = 0;

   if(count != MSNR_ARRAY_SIZE(bars) || count < 2 || minRun < 1)
      return false;

   int runStart = 0;
   int runLength = 1;
   int runColour = Exec_BarColour(MSNR_ARRAY_ELEMENT(bars, 0));

   double anchorPrice = 0.0;
   int anchorColour = 0;
   bool anchorValid = false;

   for(int j = 1; j < count; ++j)
     {
      const int colour = Exec_BarColour(MSNR_ARRAY_ELEMENT(bars, j));
      if(colour != 0 && colour == runColour)
        {
         ++runLength;
        }
      else
        {
         if(runColour != 0 && runLength >= minRun)
           {
            anchorPrice = MSNR_ARRAY_ELEMENT(bars, runStart).open;
            anchorColour = runColour;
            anchorValid = true;
           }
         runStart = j;
         runLength = (colour == 0) ? 0 : 1;
         runColour = colour;
        }

      if(!anchorValid || j <= afterIndex)
         continue;

      const double close = MSNR_ARRAY_ELEMENT(bars, j).close;
      if(!wantBullish && anchorColour > 0 && close < anchorPrice)
        {
         outAnchor = anchorPrice;
         outIndex = j;
         outTime = MSNR_ARRAY_ELEMENT(bars, j).time;
         return true;
        }
      if(wantBullish && anchorColour < 0 && close > anchorPrice)
        {
         outAnchor = anchorPrice;
         outIndex = j;
         outTime = MSNR_ARRAY_ELEMENT(bars, j).time;
         return true;
        }
     }
   return false;
  }

// First and last closed bar whose wick intersects the POI band - the touch
// chain that produces the shared structural stop.
bool Exec_FindTouchChain(MSNR_ARRAY_PARAMETER(MSNRBar, bars),
                         const int count,
                         const double zoneLow,
                         const double zoneHigh,
                         const double tolerance,
                         int &outFirst,
                         int &outLast)
  {
   outFirst = -1;
   outLast = -1;

   if(count != MSNR_ARRAY_SIZE(bars) || count <= 0)
      return false;

   bool found = false;
   for(int i = 0; i < count; ++i)
     {
      const MSNRBar &current = MSNR_ARRAY_ELEMENT(bars, i);
      if(!MSNR_TouchesZone(current.low, current.high, zoneLow, zoneHigh,
                           tolerance))
         continue;
      if(!found)
        {
         outFirst = i;
         found = true;
        }
      outLast = i;
     }
   return found;
  }

#endif // ALPHATOM_EXEC_KERNEL_MQH
