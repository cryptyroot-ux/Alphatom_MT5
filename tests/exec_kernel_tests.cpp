#include <cmath>
#include <cstdio>
#include <vector>

#include "../MQL5/Include/Alphatom/ExecKernel.mqh"

static int failures = 0;

#define CHECK(condition)                                                        \
  do {                                                                          \
    if (!(condition)) {                                                         \
      std::fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, \
                   #condition);                                                 \
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

// --- IFVG -----------------------------------------------------------------

static void test_ifvg_requires_close_through_far_boundary() {
  // Bullish FVG at [101,105] (bars 0..2) then a close below 101 -> the gap
  // inverts and becomes a bearish (resistance) IFVG.
  std::vector<MSNRBar> bars{bar(100, 101, 99, 100), bar(102, 104, 101, 103),
                             bar(106, 108, 105, 107), bar(106, 106, 99, 100)};
  MSNRZone zone{};
  int index = -1;
  long time = 0;
  CHECK(Exec_DetectIFVG(bars, static_cast<int>(bars.size()), -1,
                        MSNR_ROLE_RESISTANCE, 0.0, 0.0, zone, index, time));
  CHECK(index == 3);
  CHECK(time == bars[3].time);
  CHECK(near(zone.lower, 101.0));
  CHECK(near(zone.upper, 105.0));
}

static void test_ifvg_ignores_wick_only_break() {
  // Same bullish FVG, but the break bar only wicks below 101 and closes at 102.
  std::vector<MSNRBar> bars{bar(100, 101, 99, 100), bar(102, 104, 101, 103),
                             bar(106, 108, 105, 107), bar(106, 106, 99, 102)};
  MSNRZone zone{};
  int index = -1;
  long time = 0;
  CHECK(!Exec_DetectIFVG(bars, static_cast<int>(bars.size()), -1,
                         MSNR_ROLE_RESISTANCE, 0.0, 0.0, zone, index, time));
}

static void test_ifvg_mirrors_to_support_zone() {
  // Bearish FVG at [91,99] broken upward by a close above 99 -> bullish
  // (support) IFVG.
  std::vector<MSNRBar> bars{bar(100, 101, 99, 100), bar(96, 97, 95, 96),
                             bar(94, 95, 90, 91), bar(92, 105, 92, 104)};
  MSNRZone zone{};
  int index = -1;
  long time = 0;
  CHECK(Exec_DetectIFVG(bars, static_cast<int>(bars.size()), -1,
                        MSNR_ROLE_SUPPORT, 0.0, 0.0, zone, index, time));
  CHECK(index == 3);
  // Bearish gap bounds follow MSNR_DetectGap: lower = newest high (95),
  // upper = oldest low (99).
  CHECK(near(zone.lower, 95.0));
  CHECK(near(zone.upper, 99.0));
}

static void test_ifvg_ignores_formation_before_touch() {
  // Break happens at index 3, the POI touch happens later at index 4; a
  // confirmation that formed before the touch must not qualify.
  std::vector<MSNRBar> bars{bar(100, 101, 99, 100), bar(102, 104, 101, 103),
                             bar(106, 108, 105, 107), bar(106, 106, 99, 100),
                             bar(99, 100, 98, 99)};
  MSNRZone zone{};
  int index = -1;
  long time = 0;
  CHECK(!Exec_DetectIFVG(bars, static_cast<int>(bars.size()), 4,
                         MSNR_ROLE_RESISTANCE, 0.0, 0.0, zone, index, time));
  CHECK(Exec_DetectIFVG(bars, static_cast<int>(bars.size()), 2,
                        MSNR_ROLE_RESISTANCE, 0.0, 0.0, zone, index, time));
  CHECK(index == 3);
}

static void test_ifvg_uses_first_break_only() {
  // The gap is broken at index 3 (downward, -> resistance). A later close
  // above 105 must not resurrect the same gap as a support IFVG.
  std::vector<MSNRBar> bars{bar(100, 101, 99, 100), bar(102, 104, 101, 103),
                             bar(106, 108, 105, 107), bar(106, 106, 99, 100),
                             bar(100, 110, 100, 108)};
  MSNRZone zone{};
  int index = -1;
  long time = 0;
  CHECK(!Exec_DetectIFVG(bars, static_cast<int>(bars.size()), 3,
                         MSNR_ROLE_SUPPORT, 0.0, 0.0, zone, index, time));
}

// --- CISD -----------------------------------------------------------------

static void test_cisd_anchor_is_first_candle_of_run() {
  // Two bullish candles (run), then a bearish candle closing below the
  // anchor (open of the first run candle) -> bearish CISD.
  std::vector<MSNRBar> bars{bar(100, 103, 99.5, 102), bar(102, 105, 101, 104),
                             bar(104, 104, 99.0, 99.5)};
  double anchor = 0.0;
  int index = -1;
  long time = 0;
  CHECK(Exec_DetectCISD(bars, static_cast<int>(bars.size()), -1, 2, false,
                        anchor, index, time));
  CHECK(index == 2);
  CHECK(near(anchor, 100.0));
}

static void test_cisd_min_run_length_is_enforced() {
  // A single bullish candle is not a delivery run when minRun is 2.
  std::vector<MSNRBar> bars{bar(100, 103, 99.5, 102), bar(102, 102.5, 99.0, 99.5)};
  double anchor = 0.0;
  int index = -1;
  long time = 0;
  CHECK(!Exec_DetectCISD(bars, static_cast<int>(bars.size()), -1, 2, false,
                         anchor, index, time));
  CHECK(Exec_DetectCISD(bars, static_cast<int>(bars.size()), -1, 1, false,
                        anchor, index, time));
  CHECK(near(anchor, 100.0));
}

static void test_cisd_doji_breaks_run() {
  // Without the doji the two bullish candles form one run of 2, so the later
  // close below 100 is a bearish CISD. The doji separates them: no run ever
  // reaches the minimum length, so no CISD may fire.
  std::vector<MSNRBar> without{bar(100, 103, 99.5, 102),
                                bar(102, 104, 101, 103),
                                bar(103, 103, 99.0, 99.5)};
  double anchor = 0.0;
  int index = -1;
  long time = 0;
  CHECK(Exec_DetectCISD(without, static_cast<int>(without.size()), -1, 2, false,
                        anchor, index, time));
  CHECK(near(anchor, 100.0));

  std::vector<MSNRBar> withDoji{bar(100, 103, 99.5, 102),
                                 bar(101, 101.5, 100.5, 101),
                                 bar(102, 104, 101, 103),
                                 bar(103, 103, 99.0, 99.5)};
  CHECK(!Exec_DetectCISD(withDoji, static_cast<int>(withDoji.size()), -1, 2,
                         false, anchor, index, time));
}

static void test_cisd_direction_matches_opposing_run() {
  // Bearish run of two candles, then a close above the anchor -> bullish
  // CISD (the anchor comes from the opposing delivery).
  std::vector<MSNRBar> bars{bar(100, 100.5, 97, 98), bar(98, 98.5, 95, 96),
                             bar(96, 104, 96, 103)};
  double anchor = 0.0;
  int index = -1;
  long time = 0;
  CHECK(Exec_DetectCISD(bars, static_cast<int>(bars.size()), -1, 2, true,
                        anchor, index, time));
  CHECK(index == 2);
  CHECK(near(anchor, 100.0));
  // The same bars must not produce a bearish CISD.
  CHECK(!Exec_DetectCISD(bars, static_cast<int>(bars.size()), -1, 2, false,
                         anchor, index, time));
}

static void test_cisd_respects_after_index() {
  std::vector<MSNRBar> bars{bar(100, 103, 99.5, 102), bar(102, 105, 101, 104),
                             bar(104, 104, 99.0, 99.5)};
  double anchor = 0.0;
  int index = -1;
  long time = 0;
  CHECK(!Exec_DetectCISD(bars, static_cast<int>(bars.size()), 2, 2, false,
                         anchor, index, time));
  CHECK(Exec_DetectCISD(bars, static_cast<int>(bars.size()), 1, 2, false,
                        anchor, index, time));
}

// --- touch chain ----------------------------------------------------------

static void test_touch_chain_spans_repeated_wicks() {
  std::vector<MSNRBar> bars{bar(100, 100.5, 99.5, 100), bar(100, 100.6, 99.4, 100),
                             bar(100, 100.5, 99.5, 100), bar(100, 100.6, 99.4, 100)};
  int first = -1;
  int last = -1;
  CHECK(Exec_FindTouchChain(bars, static_cast<int>(bars.size()), 99.9, 100.1,
                            0.0, first, last));
  CHECK(first == 0);
  CHECK(last == 3);
}

static void test_touch_chain_reports_no_touch() {
  std::vector<MSNRBar> bars{bar(100, 100.5, 99.5, 100), bar(100, 100.5, 99.5, 100)};
  int first = -1;
  int last = -1;
  CHECK(!Exec_FindTouchChain(bars, static_cast<int>(bars.size()), 101.0, 102.0,
                             0.0, first, last));
}

int main() {
  test_ifvg_requires_close_through_far_boundary();
  test_ifvg_ignores_wick_only_break();
  test_ifvg_mirrors_to_support_zone();
  test_ifvg_ignores_formation_before_touch();
  test_ifvg_uses_first_break_only();
  test_cisd_anchor_is_first_candle_of_run();
  test_cisd_min_run_length_is_enforced();
  test_cisd_doji_breaks_run();
  test_cisd_direction_matches_opposing_run();
  test_cisd_respects_after_index();
  test_touch_chain_spans_repeated_wicks();
  test_touch_chain_reports_no_touch();

  if (failures > 0) {
    std::fprintf(stderr, "%d Exec kernel check(s) failed\n", failures);
    return 1;
  }
  std::printf("12 Exec kernel test groups passed\n");
  return 0;
}
