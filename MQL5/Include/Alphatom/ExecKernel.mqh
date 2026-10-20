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
// outAnchorIndex is the index of the first candle of the anchored run; the
// CISD entry band is built from the three M1 candles around that bar.
bool Exec_DetectCISD(MSNR_ARRAY_PARAMETER(MSNRBar, bars),
                     const int count,
                     const int afterIndex,
                     const int minRun,
                     const bool wantBullish,
                     double &outAnchor,
                     int &outAnchorIndex,
                     int &outIndex,
                     long &outTime)
  {
   outAnchor = 0.0;
   outAnchorIndex = -1;
   outIndex = -1;
   outTime = 0;

   if(count != MSNR_ARRAY_SIZE(bars) || count < 2 || minRun < 1)
      return false;

   int runStart = 0;
   int runLength = 1;
   int runColour = Exec_BarColour(MSNR_ARRAY_ELEMENT(bars, 0));

   double anchorPrice = 0.0;
   int anchorIndex = -1;
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
            anchorIndex = runStart;
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
         outAnchorIndex = anchorIndex;
         outIndex = j;
         outTime = MSNR_ARRAY_ELEMENT(bars, j).time;
         return true;
        }
      if(wantBullish && anchorColour < 0 && close > anchorPrice)
        {
         outAnchor = anchorPrice;
         outAnchorIndex = anchorIndex;
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

// ---------------------------------------------------------------------------
// Task 2: entry zone, layer placement, shared stop, targets and basket risk.
// All distances are in PRICE units; the expert turns them into points.
// ---------------------------------------------------------------------------

// One pip of XAUUSD is 0.10 price units (10 points at digits=2).
#define EXEC_PIP_SIZE 0.10

// Round a price to the instrument tick grid (banker-free half-away-from-zero).
double Exec_RoundToTick(const double price, const double tickSize)
  {
   if(tickSize <= 0.0)
      return price;
#ifdef __MQL5__
   return MathRound(price / tickSize) * tickSize;
#else
   return std::round(price / tickSize) * tickSize;
#endif
  }

// IFVG trigger: the entry zone IS the full inverted gap, untouched.
bool Exec_BuildIfvgEntryZone(const MSNRZone &ifvgZone, MSNRZone &outZone)
  {
   outZone = ifvgZone;
   if(!ifvgZone.valid || ifvgZone.lower <= 0.0 ||
      ifvgZone.upper < ifvgZone.lower)
     {
      outZone.valid = false;
      return false;
     }
   return true;
  }

// CISD trigger: high/low band of the three M1 candles around the anchor bar
// (the bar whose OPEN is the CISD anchor), forced to contain the anchor and
// clamped to [minWidth, maxWidth] symmetrically around it. A band narrower
// than minWidth is widened; a wider one is narrowed. This keeps the retest
// zone anchored on the delivery level instead of the event bar.
bool Exec_BuildCisdEntryZone(MSNR_ARRAY_PARAMETER(MSNRBar, bars),
                             const int count,
                             const int anchorIndex,
                             const double anchorPrice,
                             const double minWidth,
                             const double maxWidth,
                             MSNRZone &outZone)
  {
   outZone.valid = false;
   outZone.bullish = false;
   outZone.lower = 0.0;
   outZone.upper = 0.0;

   if(count != MSNR_ARRAY_SIZE(bars) || count <= 0 || anchorIndex < 0 ||
      anchorIndex >= count || anchorPrice <= 0.0 || minWidth < 0.0 ||
      maxWidth <= 0.0 || minWidth > maxWidth)
      return false;

   const int first = anchorIndex > 0 ? anchorIndex - 1 : anchorIndex;
   const int last = anchorIndex + 1 < count ? anchorIndex + 1 : anchorIndex;
   double low = MSNR_ARRAY_ELEMENT(bars, first).low;
   double high = MSNR_ARRAY_ELEMENT(bars, first).high;
   for(int i = first + 1; i <= last; ++i)
     {
      if(MSNR_ARRAY_ELEMENT(bars, i).low < low)
         low = MSNR_ARRAY_ELEMENT(bars, i).low;
      if(MSNR_ARRAY_ELEMENT(bars, i).high > high)
         high = MSNR_ARRAY_ELEMENT(bars, i).high;
     }
   if(anchorPrice < low)
      low = anchorPrice;
   if(anchorPrice > high)
      high = anchorPrice;

   const double width = high - low;
   if(width < minWidth)
     {
      low = anchorPrice - minWidth * 0.5;
      high = anchorPrice + minWidth * 0.5;
     }
   else if(width > maxWidth)
     {
      low = anchorPrice - maxWidth * 0.5;
      high = anchorPrice + maxWidth * 0.5;
     }

   outZone.valid = true;
   outZone.lower = low;
   outZone.upper = high;
   return true;
  }

// Equal thirds of the zone. E1 is always the edge the retest must touch first
// (upper edge for a buy, lower edge for a sell), E2 the midpoint, E3 the far
// edge - so the frozen stacking (buy E1>E2>E3, sell E1<E2<E3) holds by
// construction. Prices are snapped to the tick grid; if snapping collapses two
// layers or pushes one outside the zone the geometry is rejected.
bool Exec_ComputeLayers(const MSNRZone &zone,
                        const bool isBuy,
                        const double tickSize,
                        const int minWidthTicks,
                        double &e1,
                        double &e2,
                        double &e3)
  {
   e1 = 0.0;
   e2 = 0.0;
   e3 = 0.0;

   if(!zone.valid || zone.lower <= 0.0 || zone.upper < zone.lower ||
      tickSize <= 0.0 || minWidthTicks < 1)
      return false;

   const double width = zone.upper - zone.lower;
   if(width + 1e-9 < minWidthTicks * tickSize)
      return false;

   const double mid = (zone.lower + zone.upper) * 0.5;
   e1 = Exec_RoundToTick(isBuy ? zone.upper : zone.lower, tickSize);
   e2 = Exec_RoundToTick(mid, tickSize);
   e3 = Exec_RoundToTick(isBuy ? zone.lower : zone.upper, tickSize);

   if(isBuy)
     {
      if(!(e1 > e2 && e2 > e3))
         return false;
     }
   else
     {
      if(!(e1 < e2 && e2 < e3))
         return false;
     }
   const double low = zone.lower - 1e-9;
   const double high = zone.upper + 1e-9;
   if(e1 < low || e1 > high || e2 < low || e2 > high || e3 < low ||
      e3 > high)
      return false;
   return true;
  }

// Shared structural stop for the touch chain, then clamped to `capDistance`
// from E1 (the farthest entry). The stop must stay beyond E3, otherwise the
// basket cannot carry a single shared stop and the setup is skipped.
// Skip reasons: 1 = invalid inputs, 2 = stop not beyond the far entry.
bool Exec_ComputeSharedSL(const bool isBuy,
                          const double windowLow,
                          const double windowHigh,
                          const double e1,
                          const double e3,
                          const double tickSize,
                          const int bufferTicks,
                          const double capDistance,
                          double &outSL,
                          int &outSkipReason)
  {
   outSL = 0.0;
   outSkipReason = 0;

   if(tickSize <= 0.0 || bufferTicks < 0 || capDistance <= 0.0 ||
      e1 <= 0.0 || e3 <= 0.0 || windowLow <= 0.0 || windowHigh <= 0.0 ||
      windowLow > windowHigh)
     {
      outSkipReason = 1;
      return false;
     }

   const double buffer = bufferTicks * tickSize;
   double sl = isBuy ? windowLow - buffer : windowHigh + buffer;
   if(sl <= 0.0)
     {
      outSkipReason = 1;
      return false;
     }

   const double distance = isBuy ? e1 - sl : sl - e1;
   if(distance > capDistance)
      sl = isBuy ? e1 - capDistance : e1 + capDistance;

   if(isBuy && !(sl < e3))
     {
      outSkipReason = 2;
      return false;
     }
   if(!isBuy && !(sl > e3))
     {
      outSkipReason = 2;
      return false;
     }

   outSL = sl;
   return true;
  }

// Per-layer take profit, measured from that layer's own fill.
double Exec_ComputeTP(const bool isBuy, const double fillPrice, const int pips)
  {
   const double distance = pips * EXEC_PIP_SIZE;
   return isBuy ? fillPrice + distance : fillPrice - distance;
  }

// Post-TP1 stop lock, measured from each remaining layer's own fill.
double Exec_ComputeSLPlus(const bool isBuy,
                          const double entryPrice,
                          const int pips)
  {
   const double distance = pips * EXEC_PIP_SIZE;
   return isBuy ? entryPrice + distance : entryPrice - distance;
  }

// Basket money risk for the guide formula:
//   money/pip/lot x 0.15 x (|SL-E1| + |SL-E2| + |SL-E3| in pips)
// moneyPerPipPerLot is in the DEPOSIT currency (USC on an HFM cent account)
// and must come from SymbolInfo at runtime, never from a hardcoded constant.
double Exec_ComputeBasketRisk(const double distancePips1,
                              const double distancePips2,
                              const double distancePips3,
                              const double lotsPerLayer,
                              const double moneyPerPipPerLot)
  {
   if(distancePips1 < 0.0 || distancePips2 < 0.0 || distancePips3 < 0.0 ||
      lotsPerLayer <= 0.0 || moneyPerPipPerLot <= 0.0)
      return 0.0;
   return (distancePips1 + distancePips2 + distancePips3) * lotsPerLayer *
          moneyPerPipPerLot;
  }

#endif // ALPHATOM_EXEC_KERNEL_MQH
