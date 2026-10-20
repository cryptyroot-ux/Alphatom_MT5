#ifndef ALPHATOM_MSNR_LEVELS_MQH
#define ALPHATOM_MSNR_LEVELS_MQH

#include "MSNRKernel.mqh"

// ---------------------------------------------------------------------------
// Shared POI level computation.
//
// This is the exact pipeline the validated HFM indicator uses: swing and gap
// candidates are collected newest-first, merged into a single newest-eight
// queue (swing wins ties), overlapping bands are merged, and every level's
// lifecycle is replayed over the closed bars after its creation. The expert
// calls the same function so its POI map cannot drift from the chart.
// ---------------------------------------------------------------------------

struct MSNRParams
  {
   int      swingLeft;
   int      swingRight;
   bool     gapDetection;
   int      gapToleranceTicks;
   double   tickSize;
   double   touchTolerancePoints;
   double   point;
   int      atrPeriod;
   double   mergeToleranceATR;
   bool     freshReplacesUnfresh;
   bool     keepUnfresh;
   bool     flipBroken;
   bool     showBroken;
   int      maxLevelsPerTF;
   MSNRSource levelSource;
  };

// Defaults equal the validated indicator inputs (M15/M30/H1 profile).
void MSNR_InitParams(MSNRParams &params)
  {
   params.swingLeft = 3;
   params.swingRight = 3;
   params.gapDetection = true;
   params.gapToleranceTicks = 2;
   params.tickSize = 0.0;
   params.touchTolerancePoints = 0.0;
   params.point = 0.01;
   params.atrPeriod = 14;
   params.mergeToleranceATR = 0.1;
   params.freshReplacesUnfresh = false;
   params.keepUnfresh = true;
   params.flipBroken = true;
   params.showBroken = true;
   params.maxLevelsPerTF = 8;
   params.levelSource = MSNR_SOURCE_OPEN;
  }

void MSNR_StoreCandidate(MSNR_ARRAY_OUTPUT(MSNRLevel, candidates),
                         int &candidateCount,
                         const MSNRLevel &candidate)
  {
   if(candidateCount >= MSNR_ARRAY_SIZE(candidates))
      return;
   candidates[candidateCount] = candidate;
   ++candidateCount;
  }

void MSNR_InitializeCandidate(MSNRLevel &candidate,
                              const double lower,
                              const double upper,
                              const MSNRRole role,
                              const long created,
                              const bool isGap,
                              const bool isSwingHigh,
                              MSNR_ARRAY_PARAMETER(MSNRBar, bars),
                              const int count,
                              const int firstLifecycleBar,
                              const MSNRParams &params)
  {
   candidate.lower = lower;
   candidate.upper = upper;
   candidate.price = (lower + upper) * 0.5;
   candidate.role = role;
   candidate.state = MSNR_STATE_FRESH;
   candidate.created = created;
   candidate.isGap = isGap;
   candidate.isSwingHigh = isSwingHigh;

   const double touchTolerance = params.touchTolerancePoints * params.point;
   for(int i = firstLifecycleBar; i < count; ++i)
      MSNR_ApplyClosedBar(candidate, MSNR_ARRAY_ELEMENT(bars, i),
                          touchTolerance, 0.0, params.flipBroken);
  }

void MSNR_AddCandidate(MSNR_ARRAY_OUTPUT(MSNRLevel, levels),
                       int &levelCount,
                       const MSNRLevel &candidate,
                       const MSNRParams &params,
                       const double mergeTolerance)
  {
   if(!MSNR_IsVisibleState(candidate.state, params.keepUnfresh,
                           params.showBroken))
      return;
   for(int i = 0; i < levelCount; ++i)
     {
      if(MSNR_ZoneDistance(levels[i], candidate) > mergeTolerance)
         continue;
      if(MSNR_ShouldReplaceWithFresh(levels[i].state, candidate.state,
                                     params.freshReplacesUnfresh))
         levels[i] = candidate;
      return;
     }

   if(!MSNR_CanRetainCandidate(levelCount, params.maxLevelsPerTF))
      return;
   MSNR_ARRAY_RESIZE(levels, levelCount + 1);
   if(levelCount >= MSNR_ARRAY_SIZE(levels))
      return;
   levels[levelCount] = candidate;
   ++levelCount;
  }

// Returns false when the inputs are unusable (caller should clear its render).
bool MSNR_BuildLevels(MSNR_ARRAY_PARAMETER(MSNRBar, bars),
                      const int count,
                      const MSNRParams &params,
                      MSNR_ARRAY_OUTPUT(MSNRLevel, outLevels),
                      int &outCount)
  {
   outCount = 0;
   MSNR_ARRAY_CLEAR(outLevels);

   if(count != MSNR_ARRAY_SIZE(bars) || count < 3 ||
      params.swingLeft < 0 || params.swingRight < 0 ||
      count <= params.swingLeft + params.swingRight ||
      params.maxLevelsPerTF < 1 || params.atrPeriod < 1 ||
      params.point <= 0.0 || params.mergeToleranceATR < 0.0)
      return false;
   for(int i = 0; i < count; ++i)
      if(!MSNR_IsValidBar(MSNR_ARRAY_ELEMENT(bars, i)))
         return false;

   const double atr = MSNR_CalculateATR(bars, count, params.atrPeriod);
   const double mergeTolerance = atr * params.mergeToleranceATR;
   double tickSize = params.tickSize;
   if(tickSize <= 0.0)
      tickSize = params.point;
   const double gapTolerance = params.gapToleranceTicks * tickSize;

   MSNR_DYNAMIC_ARRAY(MSNRLevel, swingCandidates);
   MSNR_DYNAMIC_ARRAY(MSNRLevel, gapCandidates);
   MSNR_ARRAY_RESIZE(swingCandidates, count * 2);
   MSNR_ARRAY_RESIZE(gapCandidates, count - 2);
   if(MSNR_ARRAY_SIZE(swingCandidates) != count * 2 ||
      MSNR_ARRAY_SIZE(gapCandidates) != count - 2)
      return false;
   int swingCount = 0;
   int gapCount = 0;

   const int newestSwing = count - params.swingRight - 1;
   for(int index = newestSwing; index >= params.swingLeft; --index)
     {
      if(MSNR_IsPivotHigh(bars, count, index, params.swingLeft,
                          params.swingRight, params.levelSource))
        {
         const double price = MSNR_GetLevelPrice(
            MSNR_ARRAY_ELEMENT(bars, index), params.levelSource);
         MSNRLevel candidate;
         MSNR_InitializeCandidate(candidate, price, price,
                                  MSNR_ROLE_RESISTANCE,
                                  MSNR_ARRAY_ELEMENT(bars, index).time,
                                  false, true, bars, count, index + 1,
                                  params);
         MSNR_StoreCandidate(swingCandidates, swingCount, candidate);
        }
      if(MSNR_IsPivotLow(bars, count, index, params.swingLeft,
                         params.swingRight, params.levelSource))
        {
         const double price = MSNR_GetLevelPrice(
            MSNR_ARRAY_ELEMENT(bars, index), params.levelSource);
         MSNRLevel candidate;
         MSNR_InitializeCandidate(candidate, price, price,
                                  MSNR_ROLE_SUPPORT,
                                  MSNR_ARRAY_ELEMENT(bars, index).time,
                                  false, false, bars, count, index + 1,
                                  params);
         MSNR_StoreCandidate(swingCandidates, swingCount, candidate);
        }
     }

   if(params.gapDetection)
     {
      for(int oldestIndex = count - 3; oldestIndex >= 0; --oldestIndex)
        {
         const MSNRZone zone = MSNR_DetectGap(bars, count, oldestIndex,
                                              gapTolerance);
         if(!zone.valid)
            continue;
         MSNRLevel candidate;
         const MSNRRole role = zone.bullish ? MSNR_ROLE_SUPPORT :
                                              MSNR_ROLE_RESISTANCE;
         MSNR_InitializeCandidate(candidate, zone.lower, zone.upper, role,
                                  MSNR_ARRAY_ELEMENT(bars,
                                                     oldestIndex + 2).time,
                                  true, false, bars, count,
                                  oldestIndex + 3, params);
         MSNR_StoreCandidate(gapCandidates, gapCount, candidate);
        }
     }

   int swingIndex = 0;
   int gapIndex = 0;
   while((swingIndex < swingCount || gapIndex < gapCount) &&
         MSNR_CanRetainCandidate(outCount, params.maxLevelsPerTF))
     {
      bool takeSwing = gapIndex >= gapCount;
      if(swingIndex < swingCount && gapIndex < gapCount)
         takeSwing = MSNR_CandidatePrecedes(swingCandidates[swingIndex],
                                            gapCandidates[gapIndex]);
      if(takeSwing)
        {
         MSNR_AddCandidate(outLevels, outCount, swingCandidates[swingIndex],
                           params, mergeTolerance);
         ++swingIndex;
        }
      else
        {
         MSNR_AddCandidate(outLevels, outCount, gapCandidates[gapIndex],
                           params, mergeTolerance);
         ++gapIndex;
        }
     }

   return outCount > 0;
  }

#endif // ALPHATOM_MSNR_LEVELS_MQH
