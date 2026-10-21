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

// --- Task 1: detection -----------------------------------------------------

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
  // Bearish FVG at [newest high, oldest low] = [95,99] broken upward -> a
  // bullish (support) IFVG.
  std::vector<MSNRBar> bars{bar(100, 101, 99, 100), bar(96, 97, 95, 96),
                             bar(94, 95, 90, 91), bar(92, 105, 92, 104)};
  MSNRZone zone{};
  int index = -1;
  long time = 0;
  CHECK(Exec_DetectIFVG(bars, static_cast<int>(bars.size()), -1,
                        MSNR_ROLE_SUPPORT, 0.0, 0.0, zone, index, time));
  CHECK(index == 3);
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

static void test_cisd_anchor_is_first_candle_of_run() {
  // Two bullish candles (run), then a bearish candle closing below the
  // anchor (open of the first run candle) -> bearish CISD.
  std::vector<MSNRBar> bars{bar(100, 103, 99.5, 102), bar(102, 105, 101, 104),
                             bar(104, 104, 99.0, 99.5)};
  double anchor = 0.0;
  int anchorIndex = -1;
  int index = -1;
  long time = 0;
  CHECK(Exec_DetectCISD(bars, static_cast<int>(bars.size()), -1, 2, false,
                        anchor, anchorIndex, index, time));
  CHECK(index == 2);
  CHECK(anchorIndex == 0);
  CHECK(near(anchor, 100.0));
}

static void test_cisd_min_run_length_is_enforced() {
  // A single bullish candle is not a delivery run when minRun is 2.
  std::vector<MSNRBar> bars{bar(100, 103, 99.5, 102), bar(102, 102.5, 99.0, 99.5)};
  double anchor = 0.0;
  int anchorIndex = -1;
  int index = -1;
  long time = 0;
  CHECK(!Exec_DetectCISD(bars, static_cast<int>(bars.size()), -1, 2, false,
                         anchor, anchorIndex, index, time));
  CHECK(Exec_DetectCISD(bars, static_cast<int>(bars.size()), -1, 1, false,
                        anchor, anchorIndex, index, time));
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
  int anchorIndex = -1;
  int index = -1;
  long time = 0;
  CHECK(Exec_DetectCISD(without, static_cast<int>(without.size()), -1, 2, false,
                        anchor, anchorIndex, index, time));
  CHECK(near(anchor, 100.0));

  std::vector<MSNRBar> withDoji{bar(100, 103, 99.5, 102),
                                 bar(101, 101.5, 100.5, 101),
                                 bar(102, 104, 101, 103),
                                 bar(103, 103, 99.0, 99.5)};
  CHECK(!Exec_DetectCISD(withDoji, static_cast<int>(withDoji.size()), -1, 2,
                         false, anchor, anchorIndex, index, time));
}

static void test_cisd_direction_matches_opposing_run() {
  // Bearish run of two candles, then a close above the anchor -> bullish
  // CISD (the anchor comes from the opposing delivery).
  std::vector<MSNRBar> bars{bar(100, 100.5, 97, 98), bar(98, 98.5, 95, 96),
                             bar(96, 104, 96, 103)};
  double anchor = 0.0;
  int anchorIndex = -1;
  int index = -1;
  long time = 0;
  CHECK(Exec_DetectCISD(bars, static_cast<int>(bars.size()), -1, 2, true,
                        anchor, anchorIndex, index, time));
  CHECK(index == 2);
  CHECK(anchorIndex == 0);
  CHECK(near(anchor, 100.0));
  // The same bars must not produce a bearish CISD.
  CHECK(!Exec_DetectCISD(bars, static_cast<int>(bars.size()), -1, 2, false,
                         anchor, anchorIndex, index, time));
}

static void test_cisd_respects_after_index() {
  std::vector<MSNRBar> bars{bar(100, 103, 99.5, 102), bar(102, 105, 101, 104),
                             bar(104, 104, 99.0, 99.5)};
  double anchor = 0.0;
  int anchorIndex = -1;
  int index = -1;
  long time = 0;
  CHECK(!Exec_DetectCISD(bars, static_cast<int>(bars.size()), 2, 2, false,
                         anchor, anchorIndex, index, time));
  CHECK(Exec_DetectCISD(bars, static_cast<int>(bars.size()), 1, 2, false,
                        anchor, anchorIndex, index, time));
}

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

// --- Task 2: entry zone, layers, SL, TP, risk ------------------------------

static void test_entry_zone_for_ifvg_is_full_zone() {
  MSNRZone gap{};
  gap.valid = true;
  gap.bullish = true;
  gap.lower = 4119.0;
  gap.upper = 4121.5;
  MSNRZone out{};
  CHECK(Exec_BuildIfvgEntryZone(gap, out));
  CHECK(out.valid);
  CHECK(out.bullish);
  CHECK(near(out.lower, 4119.0));
  CHECK(near(out.upper, 4121.5));

  MSNRZone invalid{};
  CHECK(!Exec_BuildIfvgEntryZone(invalid, out));
  CHECK(!out.valid);
}

static void test_entry_zone_for_cisd_uses_three_bar_band() {
  // Anchor bar = index 2 (open 100.00); the band covers bars 1..3 and must
  // contain the level.
  std::vector<MSNRBar> bars{bar(99.0, 99.5, 98.5, 99.0),
                             bar(99.5, 100.4, 99.5, 100.0),
                             bar(100.0, 100.6, 99.8, 100.2),
                             bar(100.2, 100.5, 99.6, 100.1),
                             bar(100.1, 100.3, 99.9, 100.0)};
  MSNRZone band{};
  CHECK(Exec_BuildCisdEntryZone(bars, static_cast<int>(bars.size()), 2, 100.0,
                                0.20, 2.00, band));
  CHECK(near(band.lower, 99.5));
  CHECK(near(band.upper, 100.6));

  // A range narrower than the minimum expands symmetrically around the level.
  std::vector<MSNRBar> narrow{bar(100, 100.02, 99.98, 100.0),
                               bar(100, 100.03, 99.99, 100.0),
                               bar(100, 100.02, 99.98, 100.0)};
  CHECK(Exec_BuildCisdEntryZone(narrow, static_cast<int>(narrow.size()), 1,
                                100.0, 0.20, 2.00, band));
  CHECK(near(band.lower, 99.90));
  CHECK(near(band.upper, 100.10));

  // A range wider than the maximum shrinks symmetrically around the level.
  std::vector<MSNRBar> wide{bar(100, 102.5, 97.5, 100.0),
                             bar(100, 102.0, 98.0, 100.0),
                             bar(100, 101.5, 98.5, 100.0)};
  CHECK(Exec_BuildCisdEntryZone(wide, static_cast<int>(wide.size()), 1, 100.0,
                                0.20, 2.00, band));
  CHECK(near(band.lower, 99.00));
  CHECK(near(band.upper, 101.00));
}

static void test_layers_are_equal_thirds_and_ordered() {
  MSNRZone zone{};
  zone.valid = true;
  zone.lower = 4119.0;
  zone.upper = 4120.0;
  double e1 = 0.0, e2 = 0.0, e3 = 0.0;

  CHECK(Exec_ComputeLayers(zone, true, 0.01, 2, e1, e2, e3));
  CHECK(near(e1, 4120.00));
  CHECK(near(e2, 4119.50));
  CHECK(near(e3, 4119.00));

  CHECK(Exec_ComputeLayers(zone, false, 0.01, 2, e1, e2, e3));
  CHECK(near(e1, 4119.00));
  CHECK(near(e2, 4119.50));
  CHECK(near(e3, 4120.00));
}

static void test_layers_reject_too_narrow_zone() {
  MSNRZone thin{};
  thin.valid = true;
  thin.lower = 4119.99;
  thin.upper = 4120.00;
  double e1 = 0.0, e2 = 0.0, e3 = 0.0;
  CHECK(!Exec_ComputeLayers(thin, true, 0.01, 2, e1, e2, e3));

  MSNRZone minimal{};
  minimal.valid = true;
  minimal.lower = 4119.98;
  minimal.upper = 4120.00;
  CHECK(Exec_ComputeLayers(minimal, true, 0.01, 2, e1, e2, e3));
  CHECK(near(e1, 4120.00));
  CHECK(near(e2, 4119.99));
  CHECK(near(e3, 4119.98));
}

static void test_shared_sl_uses_window_extreme_not_last_candle() {
  double sl = 0.0;
  int reason = 0;
  // The deepest wick of the window is 4115.02 even though the last touch only
  // reached 4118.00; the stop must follow the window extreme.
  CHECK(Exec_ComputeSharedSL(true, 4115.02, 4125.0, 4120.0, 4119.0, 0.01, 2,
                             5.00, sl, reason));
  CHECK(near(sl, 4115.00));
}

static void test_shared_sl_clamps_to_fifty_pips_from_e1() {
  double sl = 0.0;
  int reason = 0;
  CHECK(Exec_ComputeSharedSL(true, 4114.02, 4125.0, 4120.0, 4119.0, 0.01, 2,
                             5.00, sl, reason));
  CHECK(near(sl, 4115.00));
  CHECK(reason == 0);

  CHECK(Exec_ComputeSharedSL(false, 4110.0, 4126.02, 4120.0, 4121.0, 0.01, 2,
                             5.00, sl, reason));
  CHECK(near(sl, 4125.00));
}

static void test_shared_sl_skips_when_not_beyond_far_entry() {
  double sl = 0.0;
  int reason = 0;
  // The retest window never dipped below 4119.50 -> the stop would sit above
  // the far entry (4119.00), which the broker would reject.
  CHECK(!Exec_ComputeSharedSL(true, 4119.52, 4125.0, 4120.0, 4119.0, 0.01, 2,
                              5.00, sl, reason));
  CHECK(reason == 2);

  // A zone wider than the cap makes the clamp itself land on the wrong side.
  CHECK(!Exec_ComputeSharedSL(true, 4100.0, 4125.0, 4120.0, 4114.0, 0.01, 2,
                              5.00, sl, reason));
  CHECK(reason == 2);
}

static void test_tp_and_slplus_use_own_fill_price() {
  CHECK(near(Exec_ComputeTP(true, 4120.0, 30), 4123.0));
  CHECK(near(Exec_ComputeTP(true, 4119.5, 50), 4124.5));
  CHECK(near(Exec_ComputeTP(true, 4119.0, 100), 4129.0));
  CHECK(near(Exec_ComputeSLPlus(true, 4119.5, 10), 4120.5));
  CHECK(near(Exec_ComputeSLPlus(true, 4119.0, 10), 4120.0));

  CHECK(near(Exec_ComputeTP(false, 4120.0, 30), 4117.0));
  CHECK(near(Exec_ComputeTP(false, 4120.5, 50), 4115.5));
  CHECK(near(Exec_ComputeTP(false, 4121.0, 100), 4111.0));
  CHECK(near(Exec_ComputeSLPlus(false, 4120.5, 10), 4119.5));
  CHECK(near(Exec_ComputeSLPlus(false, 4121.0, 10), 4120.0));
}

static void test_guide_numeric_examples() {
  // Buy: zone [4119,4120] -> E1 4120 / E2 4119.5 / E3 4119.
  MSNRZone buyZone{};
  buyZone.valid = true;
  buyZone.lower = 4119.0;
  buyZone.upper = 4120.0;
  double e1 = 0.0, e2 = 0.0, e3 = 0.0, sl = 0.0;
  int reason = 0;
  CHECK(Exec_ComputeLayers(buyZone, true, 0.01, 2, e1, e2, e3));
  CHECK(Exec_ComputeSharedSL(true, 4116.52, 4125.0, e1, e3, 0.01, 2, 5.00, sl,
                             reason));
  CHECK(near(sl, 4116.50));
  CHECK(Exec_ComputeSharedSL(true, 4114.02, 4125.0, e1, e3, 0.01, 2, 5.00, sl,
                             reason));
  CHECK(near(sl, 4115.00));

  // Sell: zone [4120,4121] -> E1 4120 / E2 4120.5 / E3 4121.
  MSNRZone sellZone{};
  sellZone.valid = true;
  sellZone.lower = 4120.0;
  sellZone.upper = 4121.0;
  CHECK(Exec_ComputeLayers(sellZone, false, 0.01, 2, e1, e2, e3));
  CHECK(Exec_ComputeSharedSL(false, 4110.0, 4123.48, e1, e3, 0.01, 2, 5.00, sl,
                             reason));
  CHECK(near(sl, 4123.50));
  CHECK(Exec_ComputeSharedSL(false, 4110.0, 4125.98, e1, e3, 0.01, 2, 5.00, sl,
                             reason));
  CHECK(near(sl, 4125.00));
}

static void test_basket_risk_uses_all_three_distances() {
  // Clamped buy: SL 4115, entries 4120/4119.5/4119 -> 50/45/40 pips.
  // Cent XAUUSDc: 10 USC per pip per lot; 0.15 lot -> 1.5 USC per pip.
  const double risk = Exec_ComputeBasketRisk(50.0, 45.0, 40.0, 0.15, 10.0);
  CHECK(near(risk, 135.0 * 0.15 * 10.0));  // 202.5 USC
  CHECK(near(Exec_ComputeBasketRisk(-1.0, 10.0, 10.0, 0.15, 10.0), 0.0));
}

// --- Task 3: setup state machine ------------------------------------------

// The kernel expects count == size; a closed-bar step therefore sees only the
// bars that existed at that moment.
static std::vector<MSNRBar> head(const std::vector<MSNRBar> &bars, int count) {
  return std::vector<MSNRBar>(bars.begin(), bars.begin() + count);
}

static bool advance(const std::vector<MSNRBar> &bars, int count,
                    MSNRState state, MSNRRole role, const ExecConfig &cfg,
                    ExecSetup &setup, ExecEvent &ev) {
  return Exec_Advance(head(bars, count), count, state, role, cfg, setup, ev);
}

static ExecConfig makeConfig() {
  ExecConfig cfg{};
  cfg.tickSize = 0.01;
  cfg.slBufferTicks = 2;
  cfg.slCapDistance = 5.00;
  cfg.cisdMinRun = 2;
  cfg.cisdMinWidth = 0.20;
  cfg.cisdMaxWidth = 6.00;
  cfg.minZoneWidthTicks = 2;
  cfg.lotsPerLayer = 0.15;
  cfg.moneyPerPipPerLot = 10.0;
  cfg.riskCap = 0.0;
  cfg.tpPips[0] = 30;
  cfg.tpPips[1] = 50;
  cfg.tpPips[2] = 100;
  cfg.slPlusPips = 10;
  return cfg;
}

// Synthetic bullish sequence: bar 0 wicks into the 4119-4120 support POI,
// bars 1-2 are green, bars 3-4 are a red run (anchor 4121.00), bar 5 closes
// above the anchor (bullish CISD -> band [4117.20, 4121.90]) and bar 6 is the
// retest that reaches E1 4121.90.
static std::vector<MSNRBar> buySeries() {
  return {
      bar(4121.50, 4122.00, 4119.50, 4121.00),  // 0 touch
      bar(4121.00, 4121.80, 4120.60, 4121.40),  // 1
      bar(4121.00, 4121.90, 4120.30, 4121.40),  // 2
      bar(4121.00, 4121.10, 4119.70, 4119.90),  // 3 anchor bar
      bar(4119.90, 4120.40, 4117.20, 4119.60),  // 4 run 2
      bar(4119.60, 4122.00, 4119.50, 4121.80),  // 5 CISD confirm
      bar(4121.80, 4122.20, 4120.00, 4120.50)   // 6 retest
  };
}

// Same sequence but bar 4 keeps the tiny bearish gap [4120.20, 4120.30], so
// an IFVG and a CISD both confirm on bar 5: the frozen tie-break picks IFVG.
static std::vector<MSNRBar> tieSeries() {
  std::vector<MSNRBar> bars = buySeries();
  bars[4].high = 4120.20;
  return bars;
}

// Bars 0-5 of buySeries with a much higher bar-2 high, so the CISD band is
// 6.80 wide and the 50-pip clamp lands above the far entry.
static std::vector<MSNRBar> wideSeries() {
  return {
      bar(4121.50, 4122.00, 4119.50, 4121.00),
      bar(4121.00, 4121.80, 4120.60, 4121.40),
      bar(4121.00, 4124.00, 4120.30, 4121.40),
      bar(4121.00, 4121.10, 4119.70, 4119.90),
      bar(4119.90, 4120.40, 4117.20, 4119.60),
      bar(4119.60, 4123.00, 4119.50, 4121.80),
      bar(4122.50, 4123.50, 4123.00, 4123.20)};
}

static void driveBuyToConfirmed(const std::vector<MSNRBar> &bars,
                                const ExecConfig &cfg, ExecSetup &setup,
                                ExecEvent &ev) {
  CHECK(Exec_InitSetup(setup, true, MSNR_ROLE_SUPPORT, 4119.0, 4120.0, 15));
  CHECK(advance(bars, 1, MSNR_STATE_FRESH, MSNR_ROLE_SUPPORT, cfg,
                     setup, ev));
  CHECK(ev.type == EXEC_EVENT_TOUCH);
  CHECK(advance(bars, 6, MSNR_STATE_UNFRESH, MSNR_ROLE_SUPPORT, cfg,
                     setup, ev));
  CHECK(ev.type == EXEC_EVENT_CONFIRM);
}

static void driveBuyToArmed(const std::vector<MSNRBar> &bars,
                            const ExecConfig &cfg, ExecSetup &setup,
                            ExecEvent &ev) {
  driveBuyToConfirmed(bars, cfg, setup, ev);
  CHECK(advance(bars, 7, MSNR_STATE_UNFRESH, MSNR_ROLE_SUPPORT, cfg,
                     setup, ev));
  CHECK(ev.type == EXEC_EVENT_ARM);
}

static void test_touch_starts_setup_only_on_fresh_poi() {
  const ExecConfig cfg = makeConfig();
  const std::vector<MSNRBar> bars = buySeries();
  ExecSetup setup{};
  ExecEvent ev{};

  CHECK(!Exec_InitSetup(setup, false, MSNR_ROLE_SUPPORT, 4119.0, 4120.0, 15));
  CHECK(Exec_InitSetup(setup, true, MSNR_ROLE_SUPPORT, 4119.0, 4120.0, 15));
  CHECK(!advance(bars, 1, MSNR_STATE_UNFRESH, MSNR_ROLE_SUPPORT, cfg,
                      setup, ev));
  CHECK(setup.phase == EXEC_IDLE);
  CHECK(!advance(bars, 1, MSNR_STATE_BROKEN, MSNR_ROLE_SUPPORT, cfg,
                      setup, ev));
  CHECK(setup.phase == EXEC_IDLE);
  CHECK(advance(bars, 1, MSNR_STATE_FRESH, MSNR_ROLE_SUPPORT, cfg, setup,
                     ev));
  CHECK(ev.type == EXEC_EVENT_TOUCH);
  CHECK(setup.phase == EXEC_TOUCHED);
  CHECK(setup.touchIndex == 0);

  // A flipped-fresh level may start a setup too.
  ExecSetup flipped{};
  ExecEvent flippedEvent{};
  CHECK(Exec_InitSetup(flipped, true, MSNR_ROLE_SUPPORT, 4119.0, 4120.0, 15));
  CHECK(advance(bars, 1, MSNR_STATE_FLIPPED_FRESH, MSNR_ROLE_SUPPORT, cfg,
                     flipped, flippedEvent));
  CHECK(flippedEvent.type == EXEC_EVENT_TOUCH);
}

static void test_confirmation_before_touch_is_ignored() {
  const ExecConfig cfg = makeConfig();
  // A bullish CISD fires at index 2; the POI is only touched at index 5.
  const std::vector<MSNRBar> bars{
      bar(4121.00, 4121.10, 4119.70, 4119.90),
      bar(4119.90, 4120.20, 4118.00, 4119.80),
      bar(4119.80, 4121.50, 4119.70, 4121.40),
      bar(4121.40, 4121.90, 4120.30, 4121.00),
      bar(4121.00, 4121.80, 4120.80, 4121.40),
      bar(4121.40, 4122.00, 4119.50, 4121.00)};
  ExecSetup setup{};
  ExecEvent ev{};
  CHECK(Exec_InitSetup(setup, true, MSNR_ROLE_SUPPORT, 4119.0, 4120.0, 15));
  CHECK(advance(bars, 6, MSNR_STATE_FRESH, MSNR_ROLE_SUPPORT, cfg, setup,
                     ev));
  CHECK(ev.type == EXEC_EVENT_TOUCH);
  CHECK(setup.touchIndex == 5);
  CHECK(!advance(bars, 6, MSNR_STATE_UNFRESH, MSNR_ROLE_SUPPORT, cfg,
                      setup, ev));
  CHECK(setup.phase == EXEC_TOUCHED);
}

static void test_retest_must_be_after_confirmation_bar() {
  const ExecConfig cfg = makeConfig();
  const std::vector<MSNRBar> bars = buySeries();
  ExecSetup setup{};
  ExecEvent ev{};
  driveBuyToConfirmed(bars, cfg, setup, ev);

  // Bar 5 also wicks into E1 (low 4119.50 <= 4121.90), but the confirmation
  // bar itself must never arm the basket.
  CHECK(ev.barIndex == 5);
  CHECK(setup.phase == EXEC_CONFIRMED);
  CHECK(near(setup.entryZone.lower, 4117.20));
  CHECK(near(setup.entryZone.upper, 4121.90));
  CHECK(setup.layerState[0] == EXEC_LAYER_NONE);
}

static void test_confirmation_tie_prefers_ifvg() {
  const ExecConfig cfg = makeConfig();
  const std::vector<MSNRBar> bars = tieSeries();
  ExecSetup setup{};
  ExecEvent ev{};
  driveBuyToConfirmed(bars, cfg, setup, ev);
  CHECK(setup.confirmKind == EXEC_CONFIRM_IFVG);
  CHECK(ev.barIndex == 5);
  CHECK(near(setup.entryZone.lower, 4120.20));
  CHECK(near(setup.entryZone.upper, 4120.30));
}

static void test_arm_places_three_layers() {
  const ExecConfig cfg = makeConfig();
  const std::vector<MSNRBar> bars = buySeries();
  ExecSetup setup{};
  ExecEvent ev{};
  driveBuyToArmed(bars, cfg, setup, ev);

  CHECK(setup.phase == EXEC_ARMED);
  CHECK(setup.confirmKind == EXEC_CONFIRM_CISD);
  CHECK(near(setup.layers[0], 4121.90));
  CHECK(near(setup.layers[1], 4119.55));
  CHECK(near(setup.layers[2], 4117.20));
  CHECK(near(setup.initialSL, 4117.18));
  CHECK(near(setup.tp[0], 4124.90));
  CHECK(near(setup.tp[1], 4124.55));
  CHECK(near(setup.tp[2], 4127.20));
  CHECK(near(setup.slPlus[0], 4122.90));
  CHECK(near(setup.slPlus[1], 4120.55));
  CHECK(near(setup.slPlus[2], 4118.20));
  CHECK(near(setup.basketRisk, 106.65));  // 71.1 pips * 0.15 * 10 USC
  for (int i = 0; i < 3; ++i) {
    CHECK(setup.layerState[i] == EXEC_LAYER_PENDING);
    CHECK(near(setup.stops[i], 4117.18));
  }
}

static void test_cancel_on_broken_poi_removes_unfilled_only() {
  const ExecConfig cfg = makeConfig();
  const std::vector<MSNRBar> bars = buySeries();
  ExecSetup setup{};
  ExecEvent ev{};
  driveBuyToArmed(bars, cfg, setup, ev);

  CHECK(Exec_RecordFill(setup, 0, 4121.90, cfg, ev));
  CHECK(ev.type == EXEC_EVENT_FILL);
  CHECK(setup.phase == EXEC_MANAGING);

  CHECK(advance(bars, 7, MSNR_STATE_BROKEN, MSNR_ROLE_SUPPORT, cfg, setup,
                     ev));
  CHECK(ev.type == EXEC_EVENT_CANCEL);
  CHECK(ev.reason == EXEC_REASON_POI_BROKEN);
  CHECK(setup.layerState[0] == EXEC_LAYER_FILLED);
  CHECK(setup.layerState[1] == EXEC_LAYER_CANCELED);
  CHECK(setup.layerState[2] == EXEC_LAYER_CANCELED);
  CHECK(setup.phase == EXEC_MANAGING);  // the filled layer keeps running
  CHECK(Exec_IsActive(setup));

  // A second advance with the same broken POI must not repeat the event.
  CHECK(!advance(bars, 7, MSNR_STATE_BROKEN, MSNR_ROLE_SUPPORT, cfg,
                      setup, ev));
}

static void test_cancel_on_role_flip() {
  const ExecConfig cfg = makeConfig();
  const std::vector<MSNRBar> bars = buySeries();
  ExecSetup setup{};
  ExecEvent ev{};
  driveBuyToArmed(bars, cfg, setup, ev);

  CHECK(advance(bars, 7, MSNR_STATE_FLIPPED_FRESH, MSNR_ROLE_RESISTANCE,
                     cfg, setup, ev));
  CHECK(ev.type == EXEC_EVENT_CANCEL);
  CHECK(ev.reason == EXEC_REASON_ROLE_FLIP);
  CHECK(setup.phase == EXEC_CANCELED);
  CHECK(setup.layerState[0] == EXEC_LAYER_CANCELED);
}

static void test_tp1_lock_cancels_unfilled_and_sets_sl_plus() {
  const ExecConfig cfg = makeConfig();
  const std::vector<MSNRBar> bars = buySeries();

  // Only E1 filled: TP1 cancels the two pending layers and finishes.
  ExecSetup partial{};
  ExecEvent ev{};
  driveBuyToArmed(bars, cfg, partial, ev);
  CHECK(Exec_RecordFill(partial, 0, 4121.90, cfg, ev));
  CHECK(Exec_RecordClose(partial, 0, true, ev));
  CHECK(ev.type == EXEC_EVENT_TP1_LOCK);
  CHECK(partial.slLocked);
  CHECK(partial.layerState[0] == EXEC_LAYER_CLOSED);
  CHECK(partial.layerState[1] == EXEC_LAYER_CANCELED);
  CHECK(partial.layerState[2] == EXEC_LAYER_CANCELED);
  CHECK(partial.phase == EXEC_DONE);
  CHECK(!Exec_IsActive(partial));

  // All three filled: TP1 keeps E2/E3 alive with their own +10 pip stop.
  ExecSetup full{};
  driveBuyToArmed(bars, cfg, full, ev);
  CHECK(Exec_RecordFill(full, 0, 4121.90, cfg, ev));
  CHECK(Exec_RecordFill(full, 1, 4119.55, cfg, ev));
  CHECK(Exec_RecordFill(full, 2, 4117.20, cfg, ev));
  CHECK(Exec_RecordClose(full, 0, true, ev));
  CHECK(ev.type == EXEC_EVENT_TP1_LOCK);
  CHECK(full.slLocked);
  CHECK(full.phase == EXEC_MANAGING);
  CHECK(near(full.stops[1], 4120.55));
  CHECK(near(full.stops[2], 4118.20));

  CHECK(Exec_RecordClose(full, 1, false, ev));
  CHECK(ev.type == EXEC_EVENT_CLOSE);
  CHECK(Exec_RecordClose(full, 2, true, ev));
  CHECK(ev.type == EXEC_EVENT_DONE);
  CHECK(full.phase == EXEC_DONE);
}

static void test_one_active_setup_per_direction() {
  const ExecConfig cfg = makeConfig();
  const std::vector<MSNRBar> bars = buySeries();
  ExecSetup setup{};
  ExecEvent ev{};
  CHECK(Exec_InitSetup(setup, true, MSNR_ROLE_SUPPORT, 4119.0, 4120.0, 15));
  CHECK(!Exec_IsActive(setup));
  CHECK(advance(bars, 1, MSNR_STATE_FRESH, MSNR_ROLE_SUPPORT, cfg, setup,
                     ev));
  CHECK(Exec_IsActive(setup));  // TOUCHED blocks a second buy setup

  // The predicate is the guard the expert uses per direction: a second buy is
  // refused while the first is active, a sell slot stays free.
  CHECK(!Exec_InitSetup(setup, true, MSNR_ROLE_SUPPORT, 4119.0, 4120.0, 15));
  ExecSetup sell{};
  CHECK(Exec_InitSetup(sell, false, MSNR_ROLE_RESISTANCE, 4120.0, 4121.0, 15));
  CHECK(!Exec_IsActive(sell));
}

static void test_arm_skips_when_stop_not_beyond_far_entry() {
  ExecConfig wideCfg = makeConfig();
  wideCfg.cisdMaxWidth = 8.00;  // keep the natural 6.80 band
  const std::vector<MSNRBar> bars = wideSeries();
  ExecSetup setup{};
  ExecEvent ev{};

  CHECK(Exec_InitSetup(setup, true, MSNR_ROLE_SUPPORT, 4119.0, 4120.0, 15));
  CHECK(advance(bars, 1, MSNR_STATE_FRESH, MSNR_ROLE_SUPPORT, wideCfg,
                     setup, ev));
  CHECK(advance(bars, 6, MSNR_STATE_UNFRESH, MSNR_ROLE_SUPPORT, wideCfg,
                     setup, ev));
  CHECK(ev.type == EXEC_EVENT_CONFIRM);
  CHECK(near(setup.entryZone.upper, 4124.00));
  CHECK(advance(bars, 7, MSNR_STATE_UNFRESH, MSNR_ROLE_SUPPORT, wideCfg,
                     setup, ev));
  CHECK(ev.type == EXEC_EVENT_SKIP);
  CHECK(ev.reason == EXEC_REASON_SL_INVALID);
  CHECK(setup.phase == EXEC_CANCELED);
  CHECK(setup.layerState[0] == EXEC_LAYER_NONE);
}

static void test_arm_skips_when_basket_risk_exceeds_cap() {
  ExecConfig cfg = makeConfig();
  cfg.riskCap = 100.0;  // computed basket risk is 106.65 USC
  const std::vector<MSNRBar> bars = buySeries();
  ExecSetup setup{};
  ExecEvent ev{};

  CHECK(Exec_InitSetup(setup, true, MSNR_ROLE_SUPPORT, 4119.0, 4120.0, 15));
  CHECK(advance(bars, 1, MSNR_STATE_FRESH, MSNR_ROLE_SUPPORT, cfg, setup,
                     ev));
  CHECK(advance(bars, 6, MSNR_STATE_UNFRESH, MSNR_ROLE_SUPPORT, cfg, setup,
                     ev));
  CHECK(advance(bars, 7, MSNR_STATE_UNFRESH, MSNR_ROLE_SUPPORT, cfg, setup,
                     ev));
  CHECK(ev.type == EXEC_EVENT_SKIP);
  CHECK(ev.reason == EXEC_REASON_RISK_CAP);
  CHECK(setup.phase == EXEC_CANCELED);
}


// --- Regression: a sliding bar window must not hide the confirmation ------
//
// A live expert re-copies the last N closed bars on every new bar, so the
// window has a FIXED size and slides: every stored index shifts by one. The
// kernel anchors the setup on bar TIMES, so a confirmation after the touch
// must still be found.

static std::vector<MSNRBar> withTimes(const std::vector<MSNRBar> &bars) {
  std::vector<MSNRBar> out = bars;
  for (size_t i = 0; i < out.size(); ++i) {
    out[i].time = static_cast<long>(1700000000 + static_cast<long>(i) * 60);
  }
  return out;
}

// The window [start, start+size-1] of a logical series: the live copy
// pattern - a fixed-size window that slides over the history.
static std::vector<MSNRBar> window(const std::vector<MSNRBar> &bars, int start,
                                    int size) {
  return std::vector<MSNRBar>(bars.begin() + start,
                               bars.begin() + start + size);
}

static std::vector<MSNRBar> slidingSeries() {
  // Ten quiet bars, then the standard buy sequence: touch at index 10, CISD
  // confirmation at index 15, retest at index 16.
  std::vector<MSNRBar> bars;
  for (int i = 0; i < 10; ++i) {
    bars.push_back(bar(4121.50, 4121.60, 4121.40, 4121.50));
  }
  const std::vector<MSNRBar> tail = buySeries();
  bars.insert(bars.end(), tail.begin(), tail.end());
  return bars;
}

static void test_sliding_window_still_finds_the_confirmation() {
  const ExecConfig cfg = makeConfig();
  const std::vector<MSNRBar> timed = withTimes(slidingSeries());
  const int size = 11;

  ExecSetup setup{};
  ExecEvent ev{};

  // Step 1: the touch bar is the newest bar of the window.
  CHECK(Exec_InitSetup(setup, true, MSNR_ROLE_SUPPORT, 4119.0, 4120.0, 15));
  {
    const std::vector<MSNRBar> w = window(timed, 0, size);
    CHECK(Exec_Advance(w, static_cast<int>(w.size()), MSNR_STATE_FRESH,
                       MSNR_ROLE_SUPPORT, cfg, setup, ev));
    CHECK(ev.type == EXEC_EVENT_TOUCH);
    CHECK(setup.touchIndex == 10);
  }

  // Steps 2-5: the window slides; the touch bar moves left but the setup
  // must stay alive and must not confirm early.
  for (int start = 1; start <= 4; ++start) {
    const std::vector<MSNRBar> w = window(timed, start, size);
    CHECK(!Exec_Advance(w, static_cast<int>(w.size()), MSNR_STATE_UNFRESH,
                        MSNR_ROLE_SUPPORT, cfg, setup, ev));
    CHECK(setup.phase == EXEC_TOUCHED);
  }

  // Step 6: the confirmation bar (index 15) enters the window.
  {
    const std::vector<MSNRBar> w = window(timed, 5, size);
    CHECK(Exec_Advance(w, static_cast<int>(w.size()), MSNR_STATE_UNFRESH,
                       MSNR_ROLE_SUPPORT, cfg, setup, ev));
    CHECK(ev.type == EXEC_EVENT_CONFIRM);
    CHECK(setup.confirmIndex == 10);
  }

  // Step 7: the window slides again; the retest bar arms the basket.
  {
    const std::vector<MSNRBar> w = window(timed, 6, size);
    CHECK(Exec_Advance(w, static_cast<int>(w.size()), MSNR_STATE_UNFRESH,
                       MSNR_ROLE_SUPPORT, cfg, setup, ev));
    CHECK(ev.type == EXEC_EVENT_ARM);
    CHECK(setup.phase == EXEC_ARMED);
  }
}

static void test_sliding_window_drops_a_stale_setup() {
  const ExecConfig cfg = makeConfig();
  const std::vector<MSNRBar> timed = withTimes(slidingSeries());
  const int size = 11;

  ExecSetup setup{};
  ExecEvent ev{};
  CHECK(Exec_InitSetup(setup, true, MSNR_ROLE_SUPPORT, 4119.0, 4120.0, 15));
  {
    const std::vector<MSNRBar> w = window(timed, 0, size);
    CHECK(Exec_Advance(w, static_cast<int>(w.size()), MSNR_STATE_FRESH,
                       MSNR_ROLE_SUPPORT, cfg, setup, ev));
    CHECK(ev.type == EXEC_EVENT_TOUCH);
  }
  // The touch bar leaves the window: the setup can no longer be evaluated.
  {
    const std::vector<MSNRBar> w = window(timed, 11, size);
    CHECK(Exec_Advance(w, static_cast<int>(w.size()), MSNR_STATE_UNFRESH,
                       MSNR_ROLE_SUPPORT, cfg, setup, ev));
    CHECK(ev.type == EXEC_EVENT_CANCEL);
    CHECK(ev.reason == EXEC_REASON_STALE);
    CHECK(setup.phase == EXEC_CANCELED);
  }
}


// --- Task 7: restart recovery ---------------------------------------------
//
// A terminal restart must not lose a running setup. The kernel therefore
// exposes a snapshot that survives a save/restore round trip and keeps the
// restored setup fully functional: the TP1 lock and the POI cancel must
// still fire after a restore.

static void test_snapshot_round_trip_preserves_the_setup() {
  const ExecConfig cfg = makeConfig();
  const std::vector<MSNRBar> bars = buySeries();
  ExecSetup setup{};
  ExecEvent ev{};
  driveBuyToArmed(bars, cfg, setup, ev);
  CHECK(Exec_RecordFill(setup, 0, 4121.90, cfg, ev));
  CHECK(setup.layerState[0] == EXEC_LAYER_FILLED);

  ExecSnapshot snap{};
  CHECK(Exec_TakeSnapshot(setup, snap));
  CHECK(snap.valid);
  CHECK(snap.phase == EXEC_MANAGING);   // a fill moves the setup to MANAGING
  CHECK(snap.layerState[0] == EXEC_LAYER_FILLED);
  CHECK(near(snap.fillPrice[0], 4121.90));

  ExecSetup restored{};
  Exec_ClearSetup(restored);
  CHECK(Exec_RestoreSnapshot(snap, restored));
  CHECK(restored.phase == setup.phase);
  CHECK(restored.isBuy == setup.isBuy);
  CHECK(restored.poiRole == setup.poiRole);
  CHECK(near(restored.poiLower, setup.poiLower));
  CHECK(near(restored.poiUpper, setup.poiUpper));
  CHECK(restored.poiSourceMinutes == setup.poiSourceMinutes);
  CHECK(restored.touchTime == setup.touchTime);
  CHECK(restored.confirmTime == setup.confirmTime);
  CHECK(restored.confirmKind == setup.confirmKind);
  CHECK(near(restored.entryZone.lower, setup.entryZone.lower));
  CHECK(near(restored.entryZone.upper, setup.entryZone.upper));
  CHECK(near(restored.initialSL, setup.initialSL));
  CHECK(near(restored.basketRisk, setup.basketRisk));
  for (int i = 0; i < 3; ++i) {
    CHECK(near(restored.layers[i], setup.layers[i]));
    CHECK(near(restored.tp[i], setup.tp[i]));
    CHECK(near(restored.stops[i], setup.stops[i]));
    CHECK(near(restored.slPlus[i], setup.slPlus[i]));
    CHECK(near(restored.fillPrice[i], setup.fillPrice[i]));
    CHECK(restored.layerState[i] == setup.layerState[i]);
  }
}

static void test_restored_setup_still_locks_the_stop_after_tp1() {
  const ExecConfig cfg = makeConfig();
  const std::vector<MSNRBar> bars = buySeries();
  ExecSetup setup{};
  ExecEvent ev{};
  driveBuyToArmed(bars, cfg, setup, ev);
  // All three layers are filled, so the TP1 lock has to move the stops of the
  // two surviving layers.
  CHECK(Exec_RecordFill(setup, 0, setup.layers[0], cfg, ev));
  CHECK(Exec_RecordFill(setup, 1, setup.layers[1], cfg, ev));
  CHECK(Exec_RecordFill(setup, 2, setup.layers[2], cfg, ev));

  ExecSnapshot snap{};
  CHECK(Exec_TakeSnapshot(setup, snap));
  ExecSetup restored{};
  Exec_ClearSetup(restored);
  CHECK(Exec_RestoreSnapshot(snap, restored));

  // The restored setup must still run the TP1 lock: E1 closes at target and
  // the E2/E3 stops move to +10 pips from their own fills.
  CHECK(Exec_RecordClose(restored, 0, true, ev));
  CHECK(ev.type == EXEC_EVENT_TP1_LOCK);
  CHECK(restored.slLocked);
  CHECK(near(restored.stops[1], Exec_ComputeSLPlus(true, restored.fillPrice[1],
                                                  cfg.slPlusPips)));
  CHECK(near(restored.stops[2], Exec_ComputeSLPlus(true, restored.fillPrice[2],
                                                  cfg.slPlusPips)));
}

static void test_restored_setup_cancels_pending_layers_on_tp1() {
  const ExecConfig cfg = makeConfig();
  const std::vector<MSNRBar> bars = buySeries();
  ExecSetup setup{};
  ExecEvent ev{};
  driveBuyToArmed(bars, cfg, setup, ev);
  CHECK(Exec_RecordFill(setup, 0, setup.layers[0], cfg, ev));

  ExecSnapshot snap{};
  CHECK(Exec_TakeSnapshot(setup, snap));
  ExecSetup restored{};
  Exec_ClearSetup(restored);
  CHECK(Exec_RestoreSnapshot(snap, restored));

  // E1 closes at target: the still pending layers must die.
  CHECK(Exec_RecordClose(restored, 0, true, ev));
  CHECK(ev.type == EXEC_EVENT_TP1_LOCK);
  CHECK(restored.layerState[1] == EXEC_LAYER_CANCELED);
  CHECK(restored.layerState[2] == EXEC_LAYER_CANCELED);
}

static void test_restored_setup_still_reacts_to_a_broken_poi() {
  const ExecConfig cfg = makeConfig();
  const std::vector<MSNRBar> bars = buySeries();
  ExecSetup setup{};
  ExecEvent ev{};
  driveBuyToArmed(bars, cfg, setup, ev);

  ExecSnapshot snap{};
  CHECK(Exec_TakeSnapshot(setup, snap));
  ExecSetup restored{};
  Exec_ClearSetup(restored);
  CHECK(Exec_RestoreSnapshot(snap, restored));

  // The POI breaks after the restart: the pending layers must be cancelled.
  const std::vector<MSNRBar> w = head(bars, 7);
  CHECK(Exec_Advance(w, static_cast<int>(w.size()), MSNR_STATE_BROKEN,
                     MSNR_ROLE_SUPPORT, cfg, restored, ev));
  CHECK(ev.type == EXEC_EVENT_CANCEL);
  CHECK(ev.reason == EXEC_REASON_POI_BROKEN);
  CHECK(restored.layerState[0] == EXEC_LAYER_CANCELED);
}

static void test_snapshot_of_an_idle_setup_is_rejected() {
  ExecSetup setup{};
  Exec_ClearSetup(setup);
  ExecSnapshot snap{};
  CHECK(!Exec_TakeSnapshot(setup, snap));
  CHECK(!snap.valid);
  ExecSetup restored{};
  Exec_ClearSetup(restored);
  CHECK(!Exec_RestoreSnapshot(snap, restored));
  CHECK(restored.phase == EXEC_IDLE);
}

static void test_snapshot_keeps_the_layer_states_of_a_closed_layer() {
  const ExecConfig cfg = makeConfig();
  const std::vector<MSNRBar> bars = buySeries();
  ExecSetup setup{};
  ExecEvent ev{};
  driveBuyToArmed(bars, cfg, setup, ev);
  CHECK(Exec_RecordFill(setup, 0, setup.layers[0], cfg, ev));
  CHECK(Exec_RecordClose(setup, 0, false, ev));
  CHECK(setup.layerState[0] == EXEC_LAYER_CLOSED);

  ExecSnapshot snap{};
  CHECK(Exec_TakeSnapshot(setup, snap));
  ExecSetup restored{};
  Exec_ClearSetup(restored);
  CHECK(Exec_RestoreSnapshot(snap, restored));
  CHECK(restored.layerState[0] == EXEC_LAYER_CLOSED);
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
  test_entry_zone_for_ifvg_is_full_zone();
  test_entry_zone_for_cisd_uses_three_bar_band();
  test_layers_are_equal_thirds_and_ordered();
  test_layers_reject_too_narrow_zone();
  test_shared_sl_uses_window_extreme_not_last_candle();
  test_shared_sl_clamps_to_fifty_pips_from_e1();
  test_shared_sl_skips_when_not_beyond_far_entry();
  test_tp_and_slplus_use_own_fill_price();
  test_guide_numeric_examples();
  test_basket_risk_uses_all_three_distances();
  test_touch_starts_setup_only_on_fresh_poi();
  test_confirmation_before_touch_is_ignored();
  test_retest_must_be_after_confirmation_bar();
  test_confirmation_tie_prefers_ifvg();
  test_arm_places_three_layers();
  test_cancel_on_broken_poi_removes_unfilled_only();
  test_cancel_on_role_flip();
  test_tp1_lock_cancels_unfilled_and_sets_sl_plus();
  test_one_active_setup_per_direction();
  test_arm_skips_when_stop_not_beyond_far_entry();
  test_arm_skips_when_basket_risk_exceeds_cap();
  test_sliding_window_still_finds_the_confirmation();
  test_sliding_window_drops_a_stale_setup();
  test_snapshot_round_trip_preserves_the_setup();
  test_restored_setup_still_locks_the_stop_after_tp1();
  test_restored_setup_cancels_pending_layers_on_tp1();
  test_restored_setup_still_reacts_to_a_broken_poi();
  test_snapshot_of_an_idle_setup_is_rejected();
  test_snapshot_keeps_the_layer_states_of_a_closed_layer();

  if (failures > 0) {
    std::fprintf(stderr, "%d Exec kernel check(s) failed\n", failures);
    return 1;
  }
  std::printf("41 Exec kernel test groups passed\n");
  return 0;
}
