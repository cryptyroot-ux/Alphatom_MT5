#include <cmath>
#include <cstdio>
#include <limits>
#include <vector>

#include "../MQL5/Include/Alphatom/MSNRKernel.mqh"

static int failures = 0;

#define CHECK(condition)                                                        \
  do {                                                                          \
    if (!(condition)) {                                                         \
      std::fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, \
                   #condition);                                                \
      ++failures;                                                               \
    }                                                                           \
  } while (false)

static bool near(double actual, double expected) {
  return std::fabs(actual - expected) < 1e-9;
}

static MSNRBar bar(double open, double high, double low, double close,
                   long time = 0) {
  MSNRBar result{};
  result.open = open;
  result.high = high;
  result.low = low;
  result.close = close;
  result.time = time;
  return result;
}

static void test_pivot_needs_closed_right_window() {
  std::vector<MSNRBar> bars{bar(5, 7, 4, 6), bar(6, 9, 5, 8),
                            bar(8, 7, 6, 6)};
  CHECK(!MSNR_IsPivotHigh(bars, static_cast<int>(bars.size()), 1, 1, 2,
                          MSNR_SOURCE_CLOSE));
  bars.push_back(bar(6, 8, 5, 7));
  CHECK(MSNR_IsPivotHigh(bars, static_cast<int>(bars.size()), 1, 1, 2,
                         MSNR_SOURCE_CLOSE));
}

static void test_equal_extrema_are_rejected() {
  std::vector<MSNRBar> highs{bar(1, 8, 0, 8), bar(1, 9, 0, 9),
                             bar(1, 9, 0, 9), bar(1, 8, 0, 8)};
  std::vector<MSNRBar> lows{bar(1, 4, 2, 2), bar(1, 3, 1, 1),
                            bar(1, 3, 1, 1), bar(1, 4, 2, 2)};
  CHECK(!MSNR_IsPivotHigh(highs, static_cast<int>(highs.size()), 1, 1, 1,
                          MSNR_SOURCE_CLOSE));
  CHECK(!MSNR_IsPivotHigh(highs, static_cast<int>(highs.size()), 2, 1, 1,
                          MSNR_SOURCE_CLOSE));
  CHECK(!MSNR_IsPivotLow(lows, static_cast<int>(lows.size()), 1, 1, 1,
                         MSNR_SOURCE_CLOSE));
  CHECK(!MSNR_IsPivotLow(lows, static_cast<int>(lows.size()), 2, 1, 1,
                         MSNR_SOURCE_CLOSE));
}

static void test_level_source_uses_open_or_close() {
  const MSNRBar pivot = bar(1875.25, 1880.0, 1870.0, 1877.75);
  CHECK(near(MSNR_GetLevelPrice(pivot, MSNR_SOURCE_OPEN), 1875.25));
  CHECK(near(MSNR_GetLevelPrice(pivot, MSNR_SOURCE_CLOSE), 1877.75));
}

static void test_gap_detection_returns_band_bounds() {
  std::vector<MSNRBar> bullish{bar(100, 101, 99, 100),
                               bar(102, 104, 101, 103),
                               bar(106, 108, 105, 107)};
  MSNRZone gap = MSNR_DetectGap(bullish, static_cast<int>(bullish.size()), 0,
                                2.0);
  CHECK(gap.valid);
  CHECK(gap.bullish);
  CHECK(near(gap.lower, 101.0));
  CHECK(near(gap.upper, 105.0));

  std::vector<MSNRBar> bearish{bar(106, 108, 105, 107),
                               bar(102, 104, 101, 103),
                               bar(98, 100, 95, 97)};
  gap = MSNR_DetectGap(bearish, static_cast<int>(bearish.size()), 0, 2.0);
  CHECK(gap.valid);
  CHECK(!gap.bullish);
  CHECK(near(gap.lower, 100.0));
  CHECK(near(gap.upper, 105.0));
}

static void test_wick_intersection_counts_as_touch() {
  CHECK(MSNR_TouchesZone(100.0, 101.0, 100.0, 100.0, 0.0));
  CHECK(MSNR_TouchesZone(99.0, 101.0, 100.0, 102.0, 0.0));
  CHECK(!MSNR_TouchesZone(98.0, 99.0, 100.0, 102.0, 0.0));
  CHECK(MSNR_TouchesZone(99.0, 99.5, 100.0, 102.0, 0.5));
}

static void test_break_requires_close_beyond_boundary() {
  CHECK(!MSNR_IsBodyBreak(100.0, 100.0, 100.0, MSNR_ROLE_RESISTANCE, 0.0));
  CHECK(MSNR_IsBodyBreak(100.01, 100.0, 100.0, MSNR_ROLE_RESISTANCE, 0.0));
  CHECK(!MSNR_IsBodyBreak(100.0, 100.0, 100.0, MSNR_ROLE_SUPPORT, 0.0));
  CHECK(MSNR_IsBodyBreak(99.99, 100.0, 100.0, MSNR_ROLE_SUPPORT, 0.0));
  CHECK(!MSNR_IsBodyBreak(100.2, 100.0, 101.0, MSNR_ROLE_RESISTANCE, 0.1));
}

static void test_lifecycle_marks_wick_touch_unfresh() {
  MSNRLevel level{};
  level.price = 100.0;
  level.lower = 100.0;
  level.upper = 100.0;
  level.role = MSNR_ROLE_RESISTANCE;
  level.state = MSNR_STATE_FRESH;
  level.created = 1;
  MSNR_ApplyClosedBar(level, bar(100.5, 101.0, 99.5, 99.75, 2), 0.0, 0.0,
                      true);
  CHECK(level.state == MSNR_STATE_UNFRESH);
}

static void test_body_break_precedes_touch_and_flips_both_roles() {
  MSNRLevel resistance{};
  resistance.price = 100.0;
  resistance.lower = 100.0;
  resistance.upper = 100.0;
  resistance.role = MSNR_ROLE_RESISTANCE;
  resistance.state = MSNR_STATE_FRESH;
  MSNR_ApplyClosedBar(resistance, bar(99.0, 102.0, 98.0, 101.0, 3), 0.0, 0.0,
                      true);
  CHECK(resistance.role == MSNR_ROLE_SUPPORT);
  CHECK(resistance.state == MSNR_STATE_FLIPPED_FRESH);

  MSNRLevel support{};
  support.price = 100.0;
  support.lower = 100.0;
  support.upper = 100.0;
  support.role = MSNR_ROLE_SUPPORT;
  support.state = MSNR_STATE_FRESH;
  MSNR_ApplyClosedBar(support, bar(101.0, 102.0, 98.0, 99.0, 4), 0.0, 0.0,
                      true);
  CHECK(support.role == MSNR_ROLE_RESISTANCE);
  CHECK(support.state == MSNR_STATE_FLIPPED_FRESH);
}

static void test_flipped_level_can_be_retested_and_invalidated() {
  MSNRLevel level{};
  level.price = 100.0;
  level.lower = 100.0;
  level.upper = 100.0;
  level.role = MSNR_ROLE_SUPPORT;
  level.state = MSNR_STATE_FLIPPED_FRESH;
  MSNR_ApplyClosedBar(level, bar(100.5, 101.0, 99.5, 100.25, 5), 0.0, 0.0,
                      true);
  CHECK(level.state == MSNR_STATE_FLIPPED_UNFRESH);
  MSNR_ApplyClosedBar(level, bar(99.0, 99.5, 98.0, 99.0, 6), 0.0, 0.0, true);
  CHECK(level.state == MSNR_STATE_BROKEN);
}

static void test_replacement_and_retention_policies() {
  CHECK(!MSNR_ShouldReplaceWithFresh(MSNR_STATE_UNFRESH, MSNR_STATE_FRESH,
                                     false));
  CHECK(MSNR_ShouldReplaceWithFresh(MSNR_STATE_UNFRESH, MSNR_STATE_FRESH,
                                    true));
  CHECK(!MSNR_ShouldReplaceWithFresh(MSNR_STATE_FRESH, MSNR_STATE_UNFRESH,
                                     true));
  CHECK(MSNR_CanRetainCandidate(7, 8));
  CHECK(!MSNR_CanRetainCandidate(8, 8));
  CHECK(!MSNR_CanRetainCandidate(0, 0));
}

static void test_recent_candidates_precede_older_with_deterministic_ties() {
  MSNRLevel newerGap{};
  newerGap.created = 200;
  newerGap.isGap = true;
  MSNRLevel olderSwing{};
  olderSwing.created = 199;
  olderSwing.isGap = false;
  olderSwing.isSwingHigh = true;
  CHECK(MSNR_CandidatePrecedes(newerGap, olderSwing));
  CHECK(!MSNR_CandidatePrecedes(olderSwing, newerGap));

  MSNRLevel sameTimeSwingHigh{};
  sameTimeSwingHigh.created = 200;
  sameTimeSwingHigh.isSwingHigh = true;
  MSNRLevel sameTimeSwingLow{};
  sameTimeSwingLow.created = 200;
  CHECK(MSNR_CandidatePrecedes(sameTimeSwingHigh, newerGap));
  CHECK(MSNR_CandidatePrecedes(sameTimeSwingHigh, sameTimeSwingLow));
  CHECK(!MSNR_CandidatePrecedes(newerGap, sameTimeSwingHigh));
}

static void test_zone_distance_respects_band_overlap() {
  MSNRLevel first{};
  first.lower = 99.0;
  first.upper = 101.0;
  MSNRLevel overlap{};
  overlap.lower = 100.0;
  overlap.upper = 102.0;
  MSNRLevel separated{};
  separated.lower = 104.0;
  separated.upper = 105.0;
  CHECK(near(MSNR_ZoneDistance(first, overlap), 0.0));
  CHECK(near(MSNR_ZoneDistance(first, separated), 3.0));
}

static void test_atr_uses_wilder_rma_after_seed() {
  std::vector<MSNRBar> bars{bar(10, 11, 9, 10), bar(10, 13, 10, 12),
                            bar(12, 14, 11, 13), bar(13, 16, 12, 15)};
  CHECK(near(MSNR_CalculateATR(bars, static_cast<int>(bars.size()), 2), 3.5));
  CHECK(near(MSNR_CalculateATR(bars, 2, 2), 0.0));
}

static void test_hidden_states_do_not_consume_visible_limit() {
  CHECK(MSNR_IsVisibleState(MSNR_STATE_FRESH, false, false));
  CHECK(MSNR_IsVisibleState(MSNR_STATE_FLIPPED_FRESH, false, false));
  CHECK(!MSNR_IsVisibleState(MSNR_STATE_UNFRESH, false, true));
  CHECK(MSNR_IsVisibleState(MSNR_STATE_UNFRESH, true, true));
  CHECK(!MSNR_IsVisibleState(MSNR_STATE_FLIPPED_UNFRESH, false, true));
  CHECK(MSNR_IsVisibleState(MSNR_STATE_BROKEN, true, true));
  CHECK(!MSNR_IsVisibleState(MSNR_STATE_BROKEN, true, false));
}

static void test_invalid_ohlc_bars_are_rejected() {
  MSNRBar valid = bar(100.0, 103.0, 98.0, 101.0, 123);
  MSNRBar zero = bar(0.0, 0.0, 0.0, 0.0, 123);
  MSNRBar inverted = bar(100.0, 99.0, 98.0, 101.0, 123);
  MSNRBar notANumber = bar(std::numeric_limits<double>::quiet_NaN(), 103.0,
                           98.0, 101.0, 123);
  CHECK(MSNR_IsValidBar(valid));
  CHECK(!MSNR_IsValidBar(zero));
  CHECK(!MSNR_IsValidBar(inverted));
  CHECK(!MSNR_IsValidBar(notANumber));
}

int main() {
  test_pivot_needs_closed_right_window();
  test_equal_extrema_are_rejected();
  test_level_source_uses_open_or_close();
  test_gap_detection_returns_band_bounds();
  test_wick_intersection_counts_as_touch();
  test_break_requires_close_beyond_boundary();
  test_lifecycle_marks_wick_touch_unfresh();
  test_body_break_precedes_touch_and_flips_both_roles();
  test_flipped_level_can_be_retested_and_invalidated();
  test_replacement_and_retention_policies();
  test_recent_candidates_precede_older_with_deterministic_ties();
  test_zone_distance_respects_band_overlap();
  test_atr_uses_wilder_rma_after_seed();
  test_hidden_states_do_not_consume_visible_limit();
  test_invalid_ohlc_bars_are_rejected();
  if (failures != 0) {
    std::fprintf(stderr, "%d MSNR kernel assertion(s) failed\n", failures);
    return 1;
  }
  std::puts("15 MSNR kernel test groups passed");
  return 0;
}
