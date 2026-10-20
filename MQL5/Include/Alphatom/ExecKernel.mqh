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
      const MSNRBar current = MSNR_ARRAY_ELEMENT(bars, i);
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

// ---------------------------------------------------------------------------
// Task 3: setup state machine.
// Bar-driven transitions happen in Exec_Advance (one event per closed bar);
// broker-driven transitions (fill, close) are reported through the Record*
// functions. The expert persists the struct and mirrors it to orders.
// ---------------------------------------------------------------------------

enum ExecPhase
  {
   EXEC_IDLE = 0,
   EXEC_TOUCHED = 1,
   EXEC_CONFIRMED = 2,
   EXEC_ARMED = 3,
   EXEC_MANAGING = 4,
   EXEC_DONE = 5,
   EXEC_CANCELED = 6
  };

enum ExecEventType
  {
   EXEC_EVENT_NONE = 0,
   EXEC_EVENT_TOUCH = 1,
   EXEC_EVENT_CONFIRM = 2,
   EXEC_EVENT_ARM = 3,
   EXEC_EVENT_SKIP = 4,
   EXEC_EVENT_CANCEL = 5,
   EXEC_EVENT_FILL = 6,
   EXEC_EVENT_TP1_LOCK = 7,
   EXEC_EVENT_CLOSE = 8,
   EXEC_EVENT_DONE = 9
  };

enum ExecReason
  {
   EXEC_REASON_NONE = 0,
   EXEC_REASON_POI_BROKEN = 1,
   EXEC_REASON_ROLE_FLIP = 2,
   EXEC_REASON_ZONE_INVALID = 3,
   EXEC_REASON_SL_INVALID = 4,
   EXEC_REASON_RISK_CAP = 5,
   EXEC_REASON_TP1 = 6,
   EXEC_REASON_CONFIG = 7
  };

enum ExecConfirmKind
  {
   EXEC_CONFIRM_NONE = 0,
   EXEC_CONFIRM_IFVG = 1,
   EXEC_CONFIRM_CISD = 2
  };

enum ExecLayerState
  {
   EXEC_LAYER_NONE = 0,
   EXEC_LAYER_PENDING = 1,
   EXEC_LAYER_FILLED = 2,
   EXEC_LAYER_CANCELED = 3,
   EXEC_LAYER_CLOSED = 4
  };

// Mirrors the expert inputs. tpPips holds the per-layer distances 30/50/100.
struct ExecConfig
  {
   double tickSize;
   int    slBufferTicks;
   double slCapDistance;
   int    cisdMinRun;
   double cisdMinWidth;
   double cisdMaxWidth;
   int    minZoneWidthTicks;
   double lotsPerLayer;
   double moneyPerPipPerLot;
   double riskCap;            // 0 = cap disabled
   int    tpPips[3];
   int    slPlusPips;
  };

struct ExecSetup
  {
   ExecPhase phase;
   bool      isBuy;
   MSNRRole  poiRole;
   double    poiLower;
   double    poiUpper;
   int       poiSourceMinutes;
   int       touchIndex;
   long      touchTime;
   int       confirmIndex;
   long      confirmTime;
   int       confirmKind;
   MSNRZone  entryZone;
   double    layers[3];
   double    initialSL;
   double    stops[3];        // current stop per layer
   double    tp[3];           // per-layer target from its own fill
   double    slPlus[3];       // post-TP1 stop from its own fill
   bool      slLocked;
   ExecLayerState layerState[3];
   double    fillPrice[3];
   double    basketRisk;
   int       skipReason;
  };

struct ExecEvent
  {
   ExecEventType type;
   ExecPhase     phase;
   int           barIndex;
   long          time;
   int           layer;
   double        price;
   int           reason;
  };

void Exec_ClearEvent(ExecEvent &outEvent)
  {
   outEvent.type = EXEC_EVENT_NONE;
   outEvent.phase = EXEC_IDLE;
   outEvent.barIndex = -1;
   outEvent.time = 0;
   outEvent.layer = -1;
   outEvent.price = 0.0;
   outEvent.reason = EXEC_REASON_NONE;
  }

void Exec_ClearSetup(ExecSetup &setup)
  {
   setup.phase = EXEC_IDLE;
   setup.isBuy = false;
   setup.poiRole = MSNR_ROLE_SUPPORT;
   setup.poiLower = 0.0;
   setup.poiUpper = 0.0;
   setup.poiSourceMinutes = 0;
   setup.touchIndex = -1;
   setup.touchTime = 0;
   setup.confirmIndex = -1;
   setup.confirmTime = 0;
   setup.confirmKind = EXEC_CONFIRM_NONE;
   setup.entryZone.valid = false;
   setup.entryZone.bullish = false;
   setup.entryZone.lower = 0.0;
   setup.entryZone.upper = 0.0;
   setup.initialSL = 0.0;
   setup.slLocked = false;
   setup.basketRisk = 0.0;
   setup.skipReason = EXEC_REASON_NONE;
   for(int i = 0; i < 3; ++i)
     {
      setup.layers[i] = 0.0;
      setup.stops[i] = 0.0;
      setup.tp[i] = 0.0;
      setup.slPlus[i] = 0.0;
      setup.layerState[i] = EXEC_LAYER_NONE;
      setup.fillPrice[i] = 0.0;
     }
  }

bool Exec_IsActive(const ExecSetup &setup)
  {
   return setup.phase == EXEC_TOUCHED || setup.phase == EXEC_CONFIRMED ||
          setup.phase == EXEC_ARMED || setup.phase == EXEC_MANAGING;
  }

// A setup direction is fixed by the POI role: support -> buy, resistance ->
// sell. An active setup is never re-initialised, so the expert naturally
// keeps at most one setup per direction.
bool Exec_InitSetup(ExecSetup &setup,
                    const bool isBuy,
                    const MSNRRole poiRole,
                    const double poiLower,
                    const double poiUpper,
                    const int poiSourceMinutes)
  {
   if(Exec_IsActive(setup))
      return false;
   Exec_ClearSetup(setup);
   if(poiLower <= 0.0 || poiUpper < poiLower)
      return false;
   if(isBuy != (poiRole == MSNR_ROLE_SUPPORT))
      return false;
   setup.isBuy = isBuy;
   setup.poiRole = poiRole;
   setup.poiLower = poiLower;
   setup.poiUpper = poiUpper;
   setup.poiSourceMinutes = poiSourceMinutes;
   return true;
  }

int Exec_CountPending(const ExecSetup &setup)
  {
   int count = 0;
   for(int i = 0; i < 3; ++i)
      if(setup.layerState[i] == EXEC_LAYER_PENDING)
         ++count;
   return count;
  }

int Exec_CountFilled(const ExecSetup &setup)
  {
   int count = 0;
   for(int i = 0; i < 3; ++i)
      if(setup.layerState[i] == EXEC_LAYER_FILLED)
         ++count;
   return count;
  }

int Exec_CancelPending(ExecSetup &setup)
  {
   int count = 0;
   for(int i = 0; i < 3; ++i)
      if(setup.layerState[i] == EXEC_LAYER_PENDING)
        {
         setup.layerState[i] = EXEC_LAYER_CANCELED;
         ++count;
        }
   return count;
  }

int Exec_PoiCancelReason(const ExecSetup &setup,
                         const MSNRState poiState,
                         const MSNRRole poiRole)
  {
   if(poiRole != setup.poiRole)
      return EXEC_REASON_ROLE_FLIP;
   if(poiState == MSNR_STATE_BROKEN)
      return EXEC_REASON_POI_BROKEN;
   return EXEC_REASON_NONE;
  }

// One closed-bar step. Returns true when an event was produced.
bool Exec_Advance(MSNR_ARRAY_PARAMETER(MSNRBar, execBars),
                  const int execCount,
                  const MSNRState poiState,
                  const MSNRRole poiRole,
                  const ExecConfig &config,
                  ExecSetup &setup,
                  ExecEvent &outEvent)
  {
   Exec_ClearEvent(outEvent);

   if(execCount <= 0 || execCount != MSNR_ARRAY_SIZE(execBars) ||
      config.tickSize <= 0.0 || config.minZoneWidthTicks < 1)
      return false;

   const int lastIndex = execCount - 1;
   const MSNRBar last = MSNR_ARRAY_ELEMENT(execBars, lastIndex);

   if(setup.phase == EXEC_IDLE)
     {
      if(poiState != MSNR_STATE_FRESH &&
         poiState != MSNR_STATE_FLIPPED_FRESH)
         return false;
      if(poiRole != setup.poiRole)
         return false;
      if(!MSNR_TouchesZone(last.low, last.high, setup.poiLower,
                           setup.poiUpper, 0.0))
         return false;

      setup.touchIndex = lastIndex;
      setup.touchTime = last.time;
      setup.phase = EXEC_TOUCHED;
      outEvent.type = EXEC_EVENT_TOUCH;
      outEvent.phase = setup.phase;
      outEvent.barIndex = lastIndex;
      outEvent.time = last.time;
      return true;
     }

   if(setup.phase == EXEC_TOUCHED)
     {
      const int cancelReason = Exec_PoiCancelReason(setup, poiState, poiRole);
      if(cancelReason != EXEC_REASON_NONE)
        {
         setup.phase = EXEC_CANCELED;
         setup.skipReason = cancelReason;
         outEvent.type = EXEC_EVENT_CANCEL;
         outEvent.phase = setup.phase;
         outEvent.barIndex = lastIndex;
         outEvent.time = last.time;
         outEvent.reason = cancelReason;
         return true;
        }

      MSNRZone ifvgZone;
      ifvgZone.valid = false;
      int ifvgIndex = -1;
      long ifvgTime = 0;
      const MSNRRole wantedRole = setup.isBuy ? MSNR_ROLE_SUPPORT :
                                               MSNR_ROLE_RESISTANCE;
      const bool hasIfvg = Exec_DetectIFVG(execBars, execCount,
                                           setup.touchIndex, wantedRole,
                                           0.0, 0.0, ifvgZone, ifvgIndex,
                                           ifvgTime);

      double anchor = 0.0;
      int anchorIndex = -1;
      int cisdIndex = -1;
      long cisdTime = 0;
      const bool hasCisd = Exec_DetectCISD(execBars, execCount,
                                           setup.touchIndex,
                                           config.cisdMinRun, setup.isBuy,
                                           anchor, anchorIndex, cisdIndex,
                                           cisdTime);

      if(!hasIfvg && !hasCisd)
         return false;

      MSNRZone zone;
      zone.valid = false;
      zone.bullish = false;
      zone.lower = 0.0;
      zone.upper = 0.0;
      int confirmIndex = -1;
      long confirmTime = 0;
      int kind = EXEC_CONFIRM_NONE;
      bool built = false;
      // Earliest valid confirmation wins; on the same bar IFVG has priority.
      if(hasIfvg && (!hasCisd || ifvgIndex <= cisdIndex))
        {
         kind = EXEC_CONFIRM_IFVG;
         confirmIndex = ifvgIndex;
         confirmTime = ifvgTime;
         built = Exec_BuildIfvgEntryZone(ifvgZone, zone);
        }
      else if(hasCisd)
        {
         kind = EXEC_CONFIRM_CISD;
         confirmIndex = cisdIndex;
         confirmTime = cisdTime;
         built = Exec_BuildCisdEntryZone(execBars, execCount, anchorIndex,
                                         anchor, config.cisdMinWidth,
                                         config.cisdMaxWidth, zone);
        }

      if(!built)
        {
         setup.phase = EXEC_CANCELED;
         setup.skipReason = EXEC_REASON_ZONE_INVALID;
         outEvent.type = EXEC_EVENT_SKIP;
         outEvent.phase = setup.phase;
         outEvent.barIndex = lastIndex;
         outEvent.time = last.time;
         outEvent.reason = EXEC_REASON_ZONE_INVALID;
         return true;
        }

      setup.confirmKind = kind;
      setup.confirmIndex = confirmIndex;
      setup.confirmTime = confirmTime;
      setup.entryZone = zone;
      setup.phase = EXEC_CONFIRMED;
      outEvent.type = EXEC_EVENT_CONFIRM;
      outEvent.phase = setup.phase;
      outEvent.barIndex = confirmIndex;
      outEvent.time = confirmTime;
      return true;
     }

   if(setup.phase == EXEC_CONFIRMED)
     {
      const int cancelReason = Exec_PoiCancelReason(setup, poiState, poiRole);
      if(cancelReason != EXEC_REASON_NONE)
        {
         setup.phase = EXEC_CANCELED;
         setup.skipReason = cancelReason;
         outEvent.type = EXEC_EVENT_CANCEL;
         outEvent.phase = setup.phase;
         outEvent.barIndex = lastIndex;
         outEvent.time = last.time;
         outEvent.reason = cancelReason;
         return true;
        }

      // The retest bar must be strictly later than the confirmation bar.
      if(lastIndex <= setup.confirmIndex)
         return false;

      double e1 = 0.0;
      double e2 = 0.0;
      double e3 = 0.0;
      if(!Exec_ComputeLayers(setup.entryZone, setup.isBuy, config.tickSize,
                             config.minZoneWidthTicks, e1, e2, e3))
        {
         setup.phase = EXEC_CANCELED;
         setup.skipReason = EXEC_REASON_ZONE_INVALID;
         outEvent.type = EXEC_EVENT_SKIP;
         outEvent.phase = setup.phase;
         outEvent.barIndex = lastIndex;
         outEvent.time = last.time;
         outEvent.reason = EXEC_REASON_ZONE_INVALID;
         return true;
        }

      const bool retest = setup.isBuy ? (last.low <= e1) : (last.high >= e1);
      if(!retest)
         return false;

      // D-1: the stop anchor spans every candle from the first POI touch to
      // the arming bar, not just the retest candle.
      double windowLow = MSNR_ARRAY_ELEMENT(execBars, setup.touchIndex).low;
      double windowHigh = MSNR_ARRAY_ELEMENT(execBars, setup.touchIndex).high;
      for(int i = setup.touchIndex + 1; i <= lastIndex; ++i)
        {
         if(MSNR_ARRAY_ELEMENT(execBars, i).low < windowLow)
            windowLow = MSNR_ARRAY_ELEMENT(execBars, i).low;
         if(MSNR_ARRAY_ELEMENT(execBars, i).high > windowHigh)
            windowHigh = MSNR_ARRAY_ELEMENT(execBars, i).high;
        }

      double sl = 0.0;
      int slReason = 0;
      if(!Exec_ComputeSharedSL(setup.isBuy, windowLow, windowHigh, e1, e3,
                               config.tickSize, config.slBufferTicks,
                               config.slCapDistance, sl, slReason))
        {
         setup.phase = EXEC_CANCELED;
         setup.skipReason = EXEC_REASON_SL_INVALID;
         outEvent.type = EXEC_EVENT_SKIP;
         outEvent.phase = setup.phase;
         outEvent.barIndex = lastIndex;
         outEvent.time = last.time;
         outEvent.reason = EXEC_REASON_SL_INVALID;
         return true;
        }

      const double distance1 = setup.isBuy ? (e1 - sl) : (sl - e1);
      const double distance2 = setup.isBuy ? (e2 - sl) : (sl - e2);
      const double distance3 = setup.isBuy ? (e3 - sl) : (sl - e3);
      const double pips1 = distance1 / EXEC_PIP_SIZE;
      const double pips2 = distance2 / EXEC_PIP_SIZE;
      const double pips3 = distance3 / EXEC_PIP_SIZE;
      const double risk = Exec_ComputeBasketRisk(pips1, pips2, pips3,
                                                 config.lotsPerLayer,
                                                 config.moneyPerPipPerLot);
      if(config.riskCap > 0.0 && risk > config.riskCap)
        {
         setup.phase = EXEC_CANCELED;
         setup.skipReason = EXEC_REASON_RISK_CAP;
         setup.basketRisk = risk;
         outEvent.type = EXEC_EVENT_SKIP;
         outEvent.phase = setup.phase;
         outEvent.barIndex = lastIndex;
         outEvent.time = last.time;
         outEvent.reason = EXEC_REASON_RISK_CAP;
         return true;
        }

      setup.layers[0] = e1;
      setup.layers[1] = e2;
      setup.layers[2] = e3;
      setup.initialSL = sl;
      setup.basketRisk = risk;
      for(int i = 0; i < 3; ++i)
        {
         setup.stops[i] = sl;
         setup.tp[i] = Exec_ComputeTP(setup.isBuy, setup.layers[i],
                                      config.tpPips[i]);
         setup.slPlus[i] = Exec_ComputeSLPlus(setup.isBuy,
                                              setup.layers[i],
                                              config.slPlusPips);
         setup.layerState[i] = EXEC_LAYER_PENDING;
         setup.fillPrice[i] = 0.0;
        }
      setup.phase = EXEC_ARMED;
      outEvent.type = EXEC_EVENT_ARM;
      outEvent.phase = setup.phase;
      outEvent.barIndex = lastIndex;
      outEvent.time = last.time;
      return true;
     }

   if(setup.phase == EXEC_ARMED || setup.phase == EXEC_MANAGING)
     {
      const int cancelReason = Exec_PoiCancelReason(setup, poiState, poiRole);
      if(cancelReason == EXEC_REASON_NONE)
         return false;
      const int canceled = Exec_CancelPending(setup);
      if(canceled <= 0)
         return false;
      // D-3: filled layers keep their own SL/TP; only pending layers die.
      if(Exec_CountFilled(setup) == 0)
         setup.phase = EXEC_CANCELED;
      setup.skipReason = cancelReason;
      outEvent.type = EXEC_EVENT_CANCEL;
      outEvent.phase = setup.phase;
      outEvent.barIndex = lastIndex;
      outEvent.time = last.time;
      outEvent.reason = cancelReason;
      return true;
     }

   return false;
  }

bool Exec_RecordFill(ExecSetup &setup,
                     const int layer,
                     const double price,
                     const ExecConfig &config,
                     ExecEvent &outEvent)
  {
   Exec_ClearEvent(outEvent);
   if(layer < 0 || layer > 2 || price <= 0.0)
      return false;
   if(setup.phase != EXEC_ARMED && setup.phase != EXEC_MANAGING)
      return false;
   if(setup.layerState[layer] != EXEC_LAYER_PENDING || setup.slLocked)
      return false;

   setup.layerState[layer] = EXEC_LAYER_FILLED;
   setup.fillPrice[layer] = price;
   setup.tp[layer] = Exec_ComputeTP(setup.isBuy, price, config.tpPips[layer]);
   setup.slPlus[layer] = Exec_ComputeSLPlus(setup.isBuy, price,
                                            config.slPlusPips);
   setup.stops[layer] = setup.initialSL;
   setup.phase = EXEC_MANAGING;

   outEvent.type = EXEC_EVENT_FILL;
   outEvent.phase = setup.phase;
   outEvent.layer = layer;
   outEvent.price = price;
   return true;
  }

// isTp = true when the layer closed on its target, false on its stop.
bool Exec_RecordClose(ExecSetup &setup,
                      const int layer,
                      const bool isTp,
                      ExecEvent &outEvent)
  {
   Exec_ClearEvent(outEvent);
   if(layer < 0 || layer > 2)
      return false;
   if(setup.layerState[layer] != EXEC_LAYER_FILLED)
      return false;

   setup.layerState[layer] = EXEC_LAYER_CLOSED;

   // TP1 on layer 0 locks the remaining filled layers at +slPlusPips from
   // their own fills and kills the pending ones.
   if(isTp && layer == 0 && !setup.slLocked)
     {
      setup.slLocked = true;
      for(int i = 1; i < 3; ++i)
        {
         if(setup.layerState[i] == EXEC_LAYER_PENDING)
            setup.layerState[i] = EXEC_LAYER_CANCELED;
         else if(setup.layerState[i] == EXEC_LAYER_FILLED)
            setup.stops[i] = setup.slPlus[i];
        }
      if(Exec_CountFilled(setup) == 0 && Exec_CountPending(setup) == 0)
         setup.phase = EXEC_DONE;

      outEvent.type = EXEC_EVENT_TP1_LOCK;
      outEvent.phase = setup.phase;
      outEvent.layer = layer;
      outEvent.price = setup.tp[layer];
      outEvent.reason = EXEC_REASON_TP1;
      return true;
     }

   if(Exec_CountFilled(setup) == 0 && Exec_CountPending(setup) == 0)
     {
      setup.phase = EXEC_DONE;
      outEvent.type = EXEC_EVENT_DONE;
      outEvent.phase = setup.phase;
      outEvent.layer = layer;
      return true;
     }

   setup.phase = (Exec_CountFilled(setup) > 0) ? EXEC_MANAGING : EXEC_ARMED;
   outEvent.type = EXEC_EVENT_CLOSE;
   outEvent.phase = setup.phase;
   outEvent.layer = layer;
   return true;
  }

#endif // ALPHATOM_EXEC_KERNEL_MQH
