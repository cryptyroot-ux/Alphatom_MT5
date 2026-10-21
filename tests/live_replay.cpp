// Offline replay of the live expert loop on exported HFM CENT bars.
//
// The point of this harness is the SLIDING bar window: the live expert
// re-copies the last N closed M1 bars on every new bar, so the window slides
// and every stored index shifts. The harness reproduces exactly that pattern
// (and the POI map refresh cadence) so a real setup can be observed end to
// end: TOUCH -> CONFIRM -> ARM.

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "../MQL5/Include/Alphatom/ExecKernel.mqh"
#include "../MQL5/Include/Alphatom/MSNRLevels.mqh"

namespace {

struct Bar {
  long time = 0;
  double open = 0.0;
  double high = 0.0;
  double low = 0.0;
  double close = 0.0;
};

struct PoiSet {
  std::vector<MSNRLevel> levels;
  long builtAt = -1;      // time of the newest POI bar used for the build
  int minutes = 0;
};

std::vector<std::string> splitCsv(const std::string &line) {
  std::vector<std::string> out;
  std::string cell;
  std::istringstream stream(line);
  while (std::getline(stream, cell, ',')) out.push_back(cell);
  return out;
}

bool loadM1(const std::string &path, std::vector<Bar> &out) {
  std::ifstream file(path);
  if (!file) return false;
  std::string line;
  bool header = true;
  while (std::getline(file, line)) {
    if (line.empty()) continue;
    if (header) { header = false; continue; }
    const std::vector<std::string> cells = splitCsv(line);
    if (cells.size() < 5) continue;
    Bar bar;
    bar.time = std::atol(cells[0].c_str());
    bar.open = std::atof(cells[1].c_str());
    bar.high = std::atof(cells[2].c_str());
    bar.low = std::atof(cells[3].c_str());
    bar.close = std::atof(cells[4].c_str());
    out.push_back(bar);
  }
  return !out.empty();
}

bool loadPoi(const std::string &path, std::vector<Bar> &m15,
             std::vector<Bar> &m30, std::vector<Bar> &h1) {
  std::ifstream file(path);
  if (!file) return false;
  std::string line;
  bool header = true;
  while (std::getline(file, line)) {
    if (line.empty()) continue;
    if (header) { header = false; continue; }
    const std::vector<std::string> cells = splitCsv(line);
    if (cells.size() < 6) continue;
    Bar bar;
    bar.time = std::atol(cells[1].c_str());
    bar.open = std::atof(cells[2].c_str());
    bar.high = std::atof(cells[3].c_str());
    bar.low = std::atof(cells[4].c_str());
    bar.close = std::atof(cells[5].c_str());
    if (cells[0] == "PERIOD_M15") m15.push_back(bar);
    else if (cells[0] == "PERIOD_M30") m30.push_back(bar);
    else if (cells[0] == "PERIOD_H1") h1.push_back(bar);
  }
  return true;
}

MSNRParams makePoiParams() {
  MSNRParams params{};
  MSNR_InitParams(params);
  params.swingLeft = 3;
  params.swingRight = 3;
  params.gapDetection = true;
  params.gapToleranceTicks = 2;
  params.touchTolerancePoints = 0.0;
  params.point = 0.01;
  params.atrPeriod = 14;
  params.mergeToleranceATR = 0.1;
  params.freshReplacesUnfresh = false;
  params.keepUnfresh = true;
  params.showBroken = true;
  params.flipBroken = true;
  params.maxLevelsPerTF = 8;
  params.levelSource = MSNR_SOURCE_OPEN;
  params.tickSize = 0.01;
  return params;
}

ExecConfig makeExecConfig() {
  ExecConfig cfg{};
  cfg.tickSize = 0.01;
  cfg.slBufferTicks = 2;
  cfg.slCapDistance = 5.00;
  cfg.cisdMinRun = 2;
  cfg.cisdMinWidth = 0.20;
  cfg.cisdMaxWidth = 2.00;
  cfg.minZoneWidthTicks = 2;
  cfg.lotsPerLayer = 0.15;
  cfg.moneyPerPipPerLot = 10.0;
  cfg.riskCap = 440.0;
  cfg.tpPips[0] = 30;
  cfg.tpPips[1] = 50;
  cfg.tpPips[2] = 100;
  cfg.slPlusPips = 10;
  return cfg;
}

const char *eventName(const ExecEventType type) {
  switch (type) {
    case EXEC_EVENT_TOUCH: return "TOUCH";
    case EXEC_EVENT_CONFIRM: return "CONFIRM";
    case EXEC_EVENT_ARM: return "ARM";
    case EXEC_EVENT_SKIP: return "SKIP";
    case EXEC_EVENT_CANCEL: return "CANCEL";
    case EXEC_EVENT_FILL: return "FILL";
    case EXEC_EVENT_TP1_LOCK: return "TP1_LOCK";
    case EXEC_EVENT_CLOSE: return "CLOSE";
    case EXEC_EVENT_DONE: return "DONE";
    default: return "NONE";
  }
}

const char *reasonName(const int reason) {
  switch (reason) {
    case EXEC_REASON_NONE: return "NONE";
    case EXEC_REASON_POI_BROKEN: return "POI_BROKEN";
    case EXEC_REASON_ROLE_FLIP: return "ROLE_FLIP";
    case EXEC_REASON_ZONE_INVALID: return "ZONE_INVALID";
    case EXEC_REASON_SL_INVALID: return "SL_INVALID";
    case EXEC_REASON_RISK_CAP: return "RISK_CAP";
    case EXEC_REASON_TP1: return "TP1";
    case EXEC_REASON_CONFIG: return "CONFIG";
    case EXEC_REASON_STALE: return "STALE";
    default: return "UNKNOWN";
  }
}

struct Direction {
  ExecSetup setup{};
  bool active = false;
  long linkCreated = -1;
  int linkTf = -1;
  MSNRState lastState = MSNR_STATE_FRESH;
  MSNRRole lastRole = MSNR_ROLE_SUPPORT;
};

}  // namespace

int main(int argc, char **argv) {
  const std::string m1Path = argc > 1 ? argv[1] : "MQL5/Files/BEX_m1.csv";
  const std::string poiPath = argc > 2 ? argv[2] : "MQL5/Files/BEX_poi.csv";

  std::vector<Bar> m1;
  std::vector<Bar> poiM15;
  std::vector<Bar> poiM30;
  std::vector<Bar> poiH1;
  if (!loadM1(m1Path, m1)) {
    std::fprintf(stderr, "cannot read %s\n", m1Path.c_str());
    return 1;
  }
  if (!loadPoi(poiPath, poiM15, poiM30, poiH1)) {
    std::fprintf(stderr, "cannot read %s\n", poiPath.c_str());
    return 1;
  }
  std::printf("loaded m1=%zu m15=%zu m30=%zu h1=%zu\n", m1.size(), poiM15.size(),
              poiM30.size(), poiH1.size());

  // The live window: CopyRates(0, 400) returns 400 bars of which the last one
  // is still forming, so 399 closed bars are processed.
  const int windowSize = 399;
  if (static_cast<int>(m1.size()) <= windowSize) {
    std::fprintf(stderr, "not enough M1 bars\n");
    return 1;
  }

  const MSNRParams poiParams = makePoiParams();
  const ExecConfig cfg = makeExecConfig();

  std::vector<PoiSet> poiSets(3);
  poiSets[0].minutes = 15;
  poiSets[1].minutes = 30;
  poiSets[2].minutes = 60;
  const std::vector<Bar> *poiSeries[3] = {&poiM15, &poiM30, &poiH1};

  Direction buy;
  Direction sell;
  Exec_ClearSetup(buy.setup);
  Exec_ClearSetup(sell.setup);

  int touches = 0;
  int confirms = 0;
  int arms = 0;
  int cancels = 0;
  int skips = 0;

  for (int step = windowSize; step < static_cast<int>(m1.size()); ++step) {
    const long now = m1[step].time;

    // POI map refresh: rebuilt when the POI timeframe closed a new bar.
    for (int tf = 0; tf < 3; ++tf) {
      const std::vector<Bar> &series = *poiSeries[tf];
      const long period = poiSets[tf].minutes * 60;
      int closedCount = 0;
      for (size_t i = 0; i < series.size(); ++i) {
        if (series[i].time + period <= now) ++closedCount;
        else break;
      }
      if (closedCount <= 0) continue;
      const long newest = series[closedCount - 1].time;
      if (poiSets[tf].builtAt == newest) continue;

      const int first = closedCount > 1500 ? closedCount - 1500 : 0;
      std::vector<MSNRBar> bars;
      bars.reserve(closedCount - first);
      for (int i = first; i < closedCount; ++i) {
        MSNRBar bar{};
        bar.open = series[i].open;
        bar.high = series[i].high;
        bar.low = series[i].low;
        bar.close = series[i].close;
        bar.time = series[i].time;
        bars.push_back(bar);
      }
      PoiSet rebuilt;
      int count = 0;
      if (MSNR_BuildLevels(bars, static_cast<int>(bars.size()), poiParams,
                           rebuilt.levels, count)) {
        rebuilt.builtAt = newest;
        rebuilt.minutes = poiSets[tf].minutes;
        poiSets[tf] = rebuilt;
      }
    }

    // The sliding window of closed M1 bars, exactly as the live expert.
    std::vector<MSNRBar> window;
    window.reserve(windowSize);
    for (int i = step - windowSize + 1; i <= step; ++i) {
      MSNRBar bar{};
      bar.open = m1[i].open;
      bar.high = m1[i].high;
      bar.low = m1[i].low;
      bar.close = m1[i].close;
      bar.time = m1[i].time;
      window.push_back(bar);
    }
    const MSNRBar last = window.back();

    for (int dir = 0; dir < 2; ++dir) {
      const bool isBuy = dir == 0;
      Direction &state = isBuy ? buy : sell;
      ExecSetup &setup = state.setup;
      ExecEvent ev{};

      if (!Exec_IsActive(setup)) {
        // Newest fresh POI touched by the newest closed bar.
        long bestCreated = -1;
        int bestTf = -1;
        MSNRRole bestRole = MSNR_ROLE_SUPPORT;
        MSNRState bestState = MSNR_STATE_FRESH;
        double lower = 0.0;
        double upper = 0.0;
        for (int tf = 0; tf < 3; ++tf) {
          for (size_t i = 0; i < poiSets[tf].levels.size(); ++i) {
            const MSNRLevel &level = poiSets[tf].levels[i];
            if (level.state != MSNR_STATE_FRESH &&
                level.state != MSNR_STATE_FLIPPED_FRESH) continue;
            if (isBuy != (level.role == MSNR_ROLE_SUPPORT)) continue;
            if (!MSNR_TouchesZone(last.low, last.high, level.lower,
                                  level.upper, 0.0)) continue;
            if (level.created <= bestCreated) continue;
            bestCreated = level.created;
            bestTf = tf;
            bestRole = level.role;
            bestState = level.state;
            lower = level.lower;
            upper = level.upper;
          }
        }
        if (bestTf < 0) continue;
        if (!Exec_InitSetup(setup, isBuy, bestRole, lower, upper,
                            poiSets[bestTf].minutes)) continue;
        if (!Exec_Advance(window, static_cast<int>(window.size()), bestState,
                          bestRole, cfg, setup, ev)) {
          Exec_ClearSetup(setup);
          continue;
        }
        state.linkCreated = bestCreated;
        state.linkTf = bestTf;
        state.lastState = bestState;
        ++touches;
        std::printf("%s TOUCH t=%ld poi=[%.2f,%.2f] tf=M%d\n",
                    isBuy ? "BUY" : "SELL", static_cast<long>(ev.time),
                    lower, upper, poiSets[bestTf].minutes);
        continue;
      }

      // Active setup: refresh the POI state, then advance.
      MSNRState poiState = state.lastState;
      MSNRRole poiRole = setup.poiRole;
      for (size_t i = 0; i < poiSets[state.linkTf].levels.size(); ++i) {
        const MSNRLevel &level = poiSets[state.linkTf].levels[i];
        if (level.created != state.linkCreated) continue;
        poiState = level.state;
        poiRole = level.role;
        break;
      }
      state.lastState = poiState;

      if (!Exec_Advance(window, static_cast<int>(window.size()), poiState,
                        poiRole, cfg, setup, ev)) continue;
      if (ev.type == EXEC_EVENT_CONFIRM) ++confirms;
      if (ev.type == EXEC_EVENT_ARM) ++arms;
      if (ev.type == EXEC_EVENT_CANCEL) ++cancels;
      if (ev.type == EXEC_EVENT_SKIP) ++skips;
      if (ev.type == EXEC_EVENT_ARM) {
        std::printf("%s ARM t=%ld E1=%.2f E2=%.2f E3=%.2f SL=%.2f "
                    "TP=%.2f/%.2f/%.2f risk=%.2f kind=%s\n",
                    isBuy ? "BUY" : "SELL", static_cast<long>(ev.time),
                    setup.layers[0], setup.layers[1], setup.layers[2],
                    setup.initialSL, setup.tp[0], setup.tp[1], setup.tp[2],
                    setup.basketRisk,
                    setup.confirmKind == EXEC_CONFIRM_IFVG ? "IFVG" : "CISD");
      } else {
        std::printf("%s %s t=%ld reason=%s\n", isBuy ? "BUY" : "SELL",
                    eventName(ev.type), static_cast<long>(ev.time),
                    reasonName(ev.reason));
      }
    }
  }

  std::printf("replay summary: touch=%d confirm=%d arm=%d cancel=%d skip=%d\n",
              touches, confirms, arms, cancels, skips);
  return 0;
}
