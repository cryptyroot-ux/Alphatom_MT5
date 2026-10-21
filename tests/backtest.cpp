// Long backtest of the Alphatom execution rules over recorded HFM bars.
//
// The harness drives the very same kernel as the live expert and mirrors
// its live behaviour:
//
//   * the execution window slides (the live expert re-copies the last N
//     closed bars on every bar),
//   * the POI map is rebuilt when a POI timeframe closes a bar,
//   * only one direction may hold the market at a time (owner decision D-4),
//   * the money cap skips a setup whose basket risk is too large,
//   * the order lifecycle is simulated: GTC limits, immediate market fills
//     for layers that are already beyond the market, one shared stop and
//     per-layer targets, and the TP1 stop lock.
//
// Assumptions that the bar data cannot resolve are resolved conservatively:
// the stop is assumed to be hit before a target inside the same bar, and a
// limit fill is skipped when the same bar also reaches the stop (the stop
// would have been hit first).

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#include "../MQL5/Include/Alphatom/ExecKernel.mqh"
#include "../MQL5/Include/Alphatom/MSNRLevels.mqh"

namespace {

const bool kDebug = true;

struct Bar {
  long time = 0;
  double open = 0.0;
  double high = 0.0;
  double low = 0.0;
  double close = 0.0;
};

struct Options {
  std::string m1Path = "data/BEX_m1.csv";
  std::string poiPath = "data/BEX_poi.csv";
  std::string reportPath;
  long from = 0;
  long to = 0;
  double riskCap = 440.0;
  double spread = 0.34;      // price units, applied to market fills
  bool oneSide = true;       // owner decision D-4
  bool consumeCancelled = true;  // a POI cancelled by D-4 is not traded again
  int windowSize = 399;      // closed execution bars, as in the expert
  int execTf = 0;            // 0 = M1, 1 = M2, 2 = M3
  int poiTfOnly = -1;        // -1 = all, 0 = M15, 1 = M30, 2 = H1
};

struct Bucket {
  int touches = 0;
  int confirms = 0;
  int arms = 0;
  int fills = 0;
  int closed = 0;
  int wins = 0;
  int losses = 0;
  int scratches = 0;
  int tp1 = 0;
  int cancelledOpp = 0;
  int skippedCap = 0;
  int poiGone = 0;
  double grossProfit = 0.0;
  double grossLoss = 0.0;
  double net = 0.0;
  double maxWin = 0.0;
  double maxLoss = 0.0;
  double pips = 0.0;
  long holdBarsSum = 0;
  int holdCount = 0;
};

struct Trade {
  long time = 0;
  bool isBuy = false;
  int layer = 0;
  int poiTf = 0;
  int confirmKind = 0;
  double entry = 0.0;
  double exit = 0.0;
  double profit = 0.0;
  double pips = 0.0;
  bool isTp = false;
  long holdBars = 0;
};

struct Side {
  ExecSetup setup{};
  long linkCreated = -1;
  int linkTf = -1;
  MSNRState lastState = MSNR_STATE_FRESH;
  long fillTime[3] = {0, 0, 0};
};

struct Context {
  Bucket total;
  std::map<int, Bucket> byDirection;
  std::map<int, Bucket> byPoiTf;
  std::map<int, Bucket> byConfirm;
  std::vector<Trade> trades;
  std::ofstream report;
  double cumulative = 0.0;
  double peak = 0.0;
  double trough = 0.0;
  double maxDrawdown = 0.0;
  int poiMinutes[3] = {15, 30, 60};
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
    const std::vector<std::string> c = splitCsv(line);
    if (c.size() < 5) continue;
    Bar bar;
    bar.time = std::atol(c[0].c_str());
    bar.open = std::atof(c[1].c_str());
    bar.high = std::atof(c[2].c_str());
    bar.low = std::atof(c[3].c_str());
    bar.close = std::atof(c[4].c_str());
    out.push_back(bar);
  }
  return !out.empty();
}

bool loadPoi(const std::string &path, std::vector<Bar> &m15, std::vector<Bar> &m30,
             std::vector<Bar> &h1) {
  std::ifstream file(path);
  if (!file) return false;
  std::string line;
  bool header = true;
  while (std::getline(file, line)) {
    if (line.empty()) continue;
    if (header) { header = false; continue; }
    const std::vector<std::string> c = splitCsv(line);
    if (c.size() < 6) continue;
    Bar bar;
    bar.time = std::atol(c[1].c_str());
    bar.open = std::atof(c[2].c_str());
    bar.high = std::atof(c[3].c_str());
    bar.low = std::atof(c[4].c_str());
    bar.close = std::atof(c[5].c_str());
    if (c[0] == "PERIOD_M15") m15.push_back(bar);
    else if (c[0] == "PERIOD_M30") m30.push_back(bar);
    else if (c[0] == "PERIOD_H1") h1.push_back(bar);
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

ExecConfig makeExecConfig(const Options &opt) {
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
  cfg.riskCap = opt.riskCap;
  cfg.tpPips[0] = 30;
  cfg.tpPips[1] = 50;
  cfg.tpPips[2] = 100;
  cfg.slPlusPips = 10;
  return cfg;
}

void recordClose(Context &ctx, const bool isBuy, const int dir, const int tf,
                 const int confirmKind, const double entry, const double exitPrice,
                 const bool isTp, const long holdBars, const long now,
                 const ExecConfig &cfg) {
  const double priceDiff = isBuy ? (exitPrice - entry) : (entry - exitPrice);
  const double pips = priceDiff / EXEC_PIP_SIZE;
  const double profit = pips * cfg.lotsPerLayer * cfg.moneyPerPipPerLot;
  Bucket &t = ctx.total;
  Bucket &d = ctx.byDirection[dir];
  Bucket &p = ctx.byPoiTf[tf];
  Bucket &c = ctx.byConfirm[confirmKind];
  t.closed++; d.closed++; p.closed++; c.closed++;
  if (isTp && dir == 0) { /* the TP1 flag is counted by the caller */ }
  if (profit > 0.0) {
    t.wins++; d.wins++; p.wins++; c.wins++;
    t.grossProfit += profit; d.grossProfit += profit; p.grossProfit += profit; c.grossProfit += profit;
    if (profit > t.maxWin) t.maxWin = profit;
  } else if (profit < 0.0) {
    t.losses++; d.losses++; p.losses++; c.losses++;
    t.grossLoss += -profit; d.grossLoss += -profit; p.grossLoss += -profit; c.grossLoss += -profit;
    if (-profit > t.maxLoss) t.maxLoss = -profit;
  } else {
    t.scratches++; d.scratches++; p.scratches++; c.scratches++;
  }
  t.net += profit; d.net += profit; p.net += profit; c.net += profit;
  t.pips += pips; d.pips += pips; p.pips += pips; c.pips += pips;
  t.holdBarsSum += holdBars; t.holdCount++;
  d.holdBarsSum += holdBars; d.holdCount++;
  ctx.cumulative += profit;
  if (ctx.cumulative > ctx.peak) ctx.peak = ctx.cumulative;
  if (ctx.cumulative < ctx.trough) ctx.trough = ctx.cumulative;
  if (ctx.peak - ctx.cumulative > ctx.maxDrawdown) ctx.maxDrawdown = ctx.peak - ctx.cumulative;
  Trade trade;
  trade.time = now; trade.isBuy = isBuy; trade.layer = 0;
  trade.poiTf = tf; trade.confirmKind = confirmKind;
  trade.entry = entry; trade.exit = exitPrice; trade.profit = profit;
  trade.pips = pips; trade.isTp = isTp; trade.holdBars = holdBars;
  ctx.trades.push_back(trade);
  if (ctx.report.is_open())
    ctx.report << now << "," << (isBuy ? "BUY" : "SELL") << ","
               << ctx.poiMinutes[tf] << ","
               << (confirmKind == EXEC_CONFIRM_IFVG ? "IFVG" : "CISD")
               << "," << entry << "," << exitPrice << "," << pips << "," << profit << ","
               << (isTp ? "TP" : "SL") << "," << holdBars << "\n";
}

// The waiting basket: the pending limits the bar reached are filled, and the
// filled layers the bar pushed through their stop or their target are closed.
const char *EaPhaseNameDbg(const ExecPhase phase) {
  switch (phase) {
    case EXEC_IDLE: return "IDLE";
    case EXEC_TOUCHED: return "TOUCHED";
    case EXEC_CONFIRMED: return "CONFIRMED";
    case EXEC_ARMED: return "ARMED";
    case EXEC_MANAGING: return "MANAGING";
    case EXEC_DONE: return "DONE";
    case EXEC_CANCELED: return "CANCELED";
  }
  return "?";
}

void simulateBar(const bool isBuy, const int dir, ExecSetup &setup, Side &side,
                 const MSNRBar &last, const ExecConfig &cfg,
                 const int tf, const int confirmKind, Context &ctx, const long now) {
  ExecEvent ev{};
  for (int i = 0; i < 3; ++i) {
    if (setup.layerState[i] != EXEC_LAYER_PENDING) continue;
    const bool hit = isBuy ? (last.low <= setup.layers[i]) : (last.high >= setup.layers[i]);
    if (!hit) continue;
    // Conservative: when the same bar also reaches the stop, the stop would
    // have been hit before the limit was filled.
    const bool stopFirst = isBuy ? (last.low <= setup.stops[i]) : (last.high >= setup.stops[i]);
    if (stopFirst) continue;
    if (Exec_RecordFill(setup, i, setup.layers[i], cfg, ev)) {
      ctx.total.fills++; ctx.byDirection[dir].fills++; ctx.byPoiTf[tf].fills++;
      side.fillTime[i] = last.time;
    }
  }
  for (int i = 0; i < 3; ++i) {
    if (setup.layerState[i] != EXEC_LAYER_FILLED) continue;
    const bool stopHit = isBuy ? (last.low <= setup.stops[i]) : (last.high >= setup.stops[i]);
    const bool tpHit = isBuy ? (last.high >= setup.tp[i]) : (last.low <= setup.tp[i]);
    if (!stopHit && !tpHit) continue;
    const bool isTp = tpHit && !stopHit;
    const double exitPrice = isTp ? setup.tp[i] : setup.stops[i];
    const double entry = setup.fillPrice[i];
    const long held = (last.time - side.fillTime[i]) / 60;
    const bool tp1 = (i == 0 && isTp);
    if (!Exec_RecordClose(setup, i, isTp, ev)) continue;
    if (tp1) { ctx.total.tp1++; ctx.byDirection[dir].tp1++; }
    recordClose(ctx, isBuy, dir, tf, confirmKind, entry, exitPrice, isTp, held, now, cfg);
  }
}

}  // namespace

int main(int argc, char **argv) {
  Options opt;
  for (int i = 1; i < argc; ++i) {
    const std::string a = argv[i];
    const bool hasNext = (i + 1 < argc);
    if (a == "--m1" && hasNext) opt.m1Path = argv[++i];
    else if (a == "--poi" && hasNext) opt.poiPath = argv[++i];
    else if (a == "--report" && hasNext) opt.reportPath = argv[++i];
    else if (a == "--from" && hasNext) opt.from = std::atol(argv[++i]);
    else if (a == "--to" && hasNext) opt.to = std::atol(argv[++i]);
    else if (a == "--cap" && hasNext) opt.riskCap = std::atof(argv[++i]);
    else if (a == "--spread" && hasNext) opt.spread = std::atof(argv[++i]);
    else if (a == "--one-side" && hasNext) opt.oneSide = std::atoi(argv[++i]) != 0;
    else if (a == "--consume" && hasNext) opt.consumeCancelled = std::atoi(argv[++i]) != 0;
    else if (a == "--window" && hasNext) opt.windowSize = std::atoi(argv[++i]);
    else if (a == "--tf" && hasNext) opt.execTf = std::atoi(argv[++i]);
    else if (a == "--poi-tf" && hasNext) opt.poiTfOnly = std::atoi(argv[++i]);
  }

  std::vector<Bar> m1;
  std::vector<Bar> poiM15, poiM30, poiH1;
  if (!loadM1(opt.m1Path, m1)) { std::fprintf(stderr, "cannot read %s\n", opt.m1Path.c_str()); return 1; }
  if (!loadPoi(opt.poiPath, poiM15, poiM30, poiH1)) { std::fprintf(stderr, "cannot read %s\n", opt.poiPath.c_str()); return 1; }
  std::printf("loaded m1=%zu m15=%zu m30=%zu h1=%zu\n", m1.size(), poiM15.size(), poiM30.size(), poiH1.size());

  // The execution timeframe: M1, M2 or M3 are all allowed by the strategy.
  std::vector<Bar> exec;
  if (opt.execTf == 0) {
    exec = m1;
  } else {
    const int fold = (opt.execTf == 1) ? 2 : 3;
    for (size_t i = 0; i + 1 < m1.size(); i += static_cast<size_t>(fold)) {
      Bar bar;
      bar.time = m1[i].time;
      bar.open = m1[i].open;
      bar.close = m1[i + fold - 1].close;
      bar.high = m1[i].high;
      bar.low = m1[i].low;
      for (int k = 0; k < fold && i + static_cast<size_t>(k) < m1.size(); ++k) {
        if (m1[i + k].high > bar.high) bar.high = m1[i + k].high;
        if (m1[i + k].low < bar.low) bar.low = m1[i + k].low;
      }
      exec.push_back(bar);
    }
  }

  const MSNRParams poiParams = makePoiParams();
  const ExecConfig cfg = makeExecConfig(opt);

  Context ctx;
  if (!opt.reportPath.empty()) {
    ctx.report.open(opt.reportPath.c_str());
    ctx.report << "time,side,poi_tf,confirm,entry,exit,pips,profit_usc,exit_kind,hold_bars\n";
  }

  std::vector<std::vector<MSNRLevel> > poiSets(3);
  std::vector<long> poiBuiltAt(3, -1);
  int closedCursor[3] = {0, 0, 0};
  const std::vector<Bar> *poiSeries[3] = {&poiM15, &poiM30, &poiH1};

  Side sides[2];
  std::map<long, bool> consumed[3];
  long gateBlocks = 0, gateCancels = 0, starts = 0;

  for (int step = opt.windowSize; step < static_cast<int>(exec.size()); ++step) {
    const long now = exec[step].time;
    if (opt.from > 0 && now < opt.from) continue;
    if (opt.to > 0 && now > opt.to) continue;

    // POI map refresh: rebuilt when the POI timeframe closed a new bar.
    for (int tf = 0; tf < 3; ++tf) {
      const std::vector<Bar> &series = *poiSeries[tf];
      const long period = ctx.poiMinutes[tf] * 60;
      int &closedCount = closedCursor[tf];
      while (closedCount < static_cast<int>(series.size()) &&
             series[closedCount].time + period <= now) ++closedCount;
      if (closedCount <= 0) continue;
      const long newest = series[closedCount - 1].time;
      if (poiBuiltAt[tf] == newest) continue;
      const int first = closedCount > 1500 ? closedCount - 1500 : 0;
      std::vector<MSNRBar> bars;
      bars.reserve(closedCount - first);
      for (int i = first; i < closedCount; ++i) {
        MSNRBar bar{};
        bar.open = series[i].open; bar.high = series[i].high;
        bar.low = series[i].low; bar.close = series[i].close;
        bar.time = series[i].time;
        bars.push_back(bar);
      }
      std::vector<MSNRLevel> levels;
      int count = 0;
      if (MSNR_BuildLevels(bars, static_cast<int>(bars.size()), poiParams, levels, count)) {
        poiSets[tf] = levels;
        poiBuiltAt[tf] = newest;
        if (!consumed[tf].empty()) {
          std::map<long, bool> keep;
          for (std::map<long, bool>::iterator c = consumed[tf].begin(); c != consumed[tf].end(); ++c) {
            bool present = false;
            for (size_t k = 0; k < levels.size(); ++k)
              if (levels[k].created == c->first) { present = true; break; }
            if (present) keep[c->first] = true;
          }
          consumed[tf] = keep;
        }
      }
    }

    if (kDebug && (step % 10000) == 0) {
      std::printf("[dbg] step=%d t=%ld buy=%s link_tf=%d link_created=%ld | sell=%s link_tf=%d link_created=%ld\n",
                  step, static_cast<long>(now),
                  EaPhaseNameDbg(sides[0].setup.phase), sides[0].linkTf,
                  static_cast<long>(sides[0].linkCreated),
                  EaPhaseNameDbg(sides[1].setup.phase), sides[1].linkTf,
                  static_cast<long>(sides[1].linkCreated));
    }

    // The sliding window of closed execution bars.
    std::vector<MSNRBar> window;
    window.reserve(opt.windowSize);
    for (int i = step - opt.windowSize + 1; i <= step; ++i) {
      MSNRBar bar{};
      bar.open = exec[i].open; bar.high = exec[i].high;
      bar.low = exec[i].low; bar.close = exec[i].close;
      bar.time = exec[i].time;
      window.push_back(bar);
    }
    const MSNRBar last = window.back();

    for (int dir = 0; dir < 2; ++dir) {
      const bool isBuy = (dir == 0);
      Side &side = sides[dir];
      ExecSetup &setup = side.setup;
      ExecEvent ev{};

      // D-4: only one side may hold the market.
      if (opt.oneSide) {
        const Side &other = sides[1 - dir];
        bool otherHolds = false;
        if (other.setup.phase == EXEC_ARMED || other.setup.phase == EXEC_MANAGING) {
          for (int i = 0; i < 3; ++i) {
            if (other.setup.layerState[i] == EXEC_LAYER_FILLED ||
                other.setup.layerState[i] == EXEC_LAYER_PENDING) { otherHolds = true; break; }
          }
        }
        if (otherHolds) {
          ++gateBlocks;
          if (Exec_IsActive(setup) && Exec_CancelForOpposite(setup, ev)) {
            ++gateCancels;
            ctx.total.cancelledOpp++;
            ctx.byDirection[dir].cancelledOpp++;
            if (opt.consumeCancelled && side.linkTf >= 0)
              consumed[side.linkTf][side.linkCreated] = true;
          }
          continue;
        }
      }

      if (!Exec_IsActive(setup)) {
        // Newest fresh POI touched by the newest closed bar.
        long bestCreated = -1;
        int bestTf = -1;
        MSNRRole bestRole = MSNR_ROLE_SUPPORT;
        MSNRState bestState = MSNR_STATE_FRESH;
        double lower = 0.0, upper = 0.0;
        for (int tf = 0; tf < 3; ++tf) {
          if (opt.poiTfOnly >= 0 && tf != opt.poiTfOnly) continue;
          for (size_t i = 0; i < poiSets[tf].size(); ++i) {
            const MSNRLevel &level = poiSets[tf][i];
            if (level.state != MSNR_STATE_FRESH && level.state != MSNR_STATE_FLIPPED_FRESH) continue;
            if (isBuy != (level.role == MSNR_ROLE_SUPPORT)) continue;
            if (!MSNR_TouchesZone(last.low, last.high, level.lower, level.upper, 0.0)) continue;
            if (level.created <= bestCreated) continue;
            if (opt.consumeCancelled && consumed[tf].count(level.created) > 0) continue;
            bestCreated = level.created; bestTf = tf; bestRole = level.role;
            bestState = level.state; lower = level.lower; upper = level.upper;
          }
        }
        if (bestTf < 0) continue;
        ++starts;
        if (!Exec_InitSetup(setup, isBuy, bestRole, lower, upper, ctx.poiMinutes[bestTf])) continue;
        if (!Exec_Advance(window, static_cast<int>(window.size()), bestState, bestRole, cfg, setup, ev)) {
          Exec_ClearSetup(setup);
          continue;
        }
        side.linkCreated = bestCreated; side.linkTf = bestTf; side.lastState = bestState;
        if (ev.type == EXEC_EVENT_TOUCH) {
          ctx.total.touches++; ctx.byDirection[dir].touches++; ctx.byPoiTf[bestTf].touches++;
        }
        continue;
      }

      // Active setup: refresh the POI state, then advance.
      MSNRState poiState = side.lastState;
      MSNRRole poiRole = setup.poiRole;
      bool found = false;
      for (size_t i = 0; i < poiSets[side.linkTf].size(); ++i) {
        const MSNRLevel &level = poiSets[side.linkTf][i];
        if (level.created != side.linkCreated) continue;
        poiState = level.state; poiRole = level.role; found = true; break;
      }
      side.lastState = poiState;
      if (!found) {
        // The POI level left the map: a setup without exposure dies here.
        if (Exec_CancelForMissingPoi(setup, ev)) {
          ctx.total.poiGone++;
          ctx.byDirection[dir].poiGone++;
          continue;
        }
      }

      const int tf = side.linkTf;
      const bool wasArmed = (setup.phase == EXEC_ARMED || setup.phase == EXEC_MANAGING);
      const int confirmKind = setup.confirmKind;

      const bool produced = Exec_Advance(window, static_cast<int>(window.size()),
                                         poiState, poiRole, cfg, setup, ev);
      if (!produced) {
        // No state change: an armed basket waits for its fills and exits.
        if (!wasArmed) continue;
        simulateBar(isBuy, dir, setup, side, last, cfg, tf, confirmKind, ctx, now);
        continue;
      }

      if (ev.type == EXEC_EVENT_CONFIRM) {
        ctx.total.confirms++; ctx.byDirection[dir].confirms++;
        ctx.byPoiTf[tf].confirms++; ctx.byConfirm[setup.confirmKind].confirms++;
        continue;
      }
      if (ev.type == EXEC_EVENT_ARM) {
        if (opt.oneSide) {
          const Side &other = sides[1 - dir];
          bool otherHolds = false;
          if (other.setup.phase == EXEC_ARMED || other.setup.phase == EXEC_MANAGING) {
            for (int k = 0; k < 3; ++k) {
              if (other.setup.layerState[k] == EXEC_LAYER_FILLED ||
                  other.setup.layerState[k] == EXEC_LAYER_PENDING) { otherHolds = true; break; }
            }
          }
          if (otherHolds) {
            // The opposite side took the market in the meantime: stand down.
            if (Exec_CancelForOpposite(setup, ev)) {
              ctx.total.cancelledOpp++;
              ctx.byDirection[dir].cancelledOpp++;
            }
            continue;
          }
        }
        ctx.total.arms++; ctx.byDirection[dir].arms++;
        ctx.byPoiTf[tf].arms++; ctx.byConfirm[setup.confirmKind].arms++;
        // Layers that are already at or beyond the market are executed at
        // market right away, exactly like the expert does.
        for (int i = 0; i < 3; ++i) {
          if (setup.layerState[i] != EXEC_LAYER_PENDING) continue;
          const bool marketable = isBuy ? (last.close <= setup.layers[i]) : (last.close >= setup.layers[i]);
          if (!marketable) continue;
          const double price = isBuy ? (last.close + opt.spread * 0.5) : (last.close - opt.spread * 0.5);
          const bool stopValid = isBuy ? (price > setup.initialSL) : (price < setup.initialSL);
          if (!stopValid) continue;
          if (Exec_RecordFill(setup, i, price, cfg, ev)) {
            ctx.total.fills++; ctx.byDirection[dir].fills++; ctx.byPoiTf[tf].fills++;
            side.fillTime[i] = last.time;
          }
        }
        continue;
      }
      if (ev.type == EXEC_EVENT_CANCEL) continue;
      if (ev.type == EXEC_EVENT_SKIP) {
        if (ev.reason == EXEC_REASON_RISK_CAP) {
          ctx.total.skippedCap++; ctx.byDirection[dir].skippedCap++;
        }
        continue;
      }
    }
  }

  const Bucket &t = ctx.total;
  std::printf("\n================ ALPHATOM BACKTEST ================\n");
  std::printf("exec bars=%zu  window=%d  one_side=%s  risk_cap=%.0f  spread=%.2f\n",
              exec.size(), opt.windowSize, opt.oneSide ? "on" : "off", opt.riskCap, opt.spread);
  std::printf("touches=%d confirms=%d arms=%d fills=%d closed=%d (wins=%d losses=%d scratches=%d)\n",
              t.touches, t.confirms, t.arms, t.fills, t.closed, t.wins, t.losses, t.scratches);
  std::printf("cancelled_opposite=%d skipped_risk_cap=%d poi_gone=%d tp1_hits=%d\n",
              t.cancelledOpp, t.skippedCap, t.poiGone, t.tp1);
  std::printf("debug: gate_blocks=%ld gate_cancels=%ld starts=%ld\n", gateBlocks, gateCancels, starts);
  std::printf("gross=%.2f loss=%.2f net=%.2f USC  (%.1f pips)\n",
              t.grossProfit, t.grossLoss, t.net, t.pips);
  if (t.grossLoss > 0.0)
    std::printf("profit_factor=%.3f  expectancy=%.2f USC/position\n",
                t.grossProfit / t.grossLoss, t.closed ? t.net / t.closed : 0.0);
  else
    std::printf("profit_factor=inf (no losing position)\n");
  std::printf("avg_win=%.2f avg_loss=%.2f max_win=%.2f max_loss=%.2f max_dd=%.2f\n",
              t.wins ? t.grossProfit / t.wins : 0.0, t.losses ? t.grossLoss / t.losses : 0.0,
              t.maxWin, t.maxLoss, ctx.maxDrawdown);
  if (t.holdCount > 0)
    std::printf("avg_hold=%.0f bars\n", static_cast<double>(t.holdBarsSum) / t.holdCount);
  std::printf("\n-- by direction --\n");
  for (std::map<int, Bucket>::iterator it = ctx.byDirection.begin(); it != ctx.byDirection.end(); ++it) {
    const Bucket &b = it->second;
    std::printf("  %s: arms=%d fills=%d closed=%d wins=%d losses=%d net=%.2f USC\n",
                it->first == 0 ? "BUY " : "SELL", b.arms, b.fills, b.closed, b.wins, b.losses, b.net);
  }
  std::printf("-- by POI timeframe --\n");
  for (std::map<int, Bucket>::iterator it = ctx.byPoiTf.begin(); it != ctx.byPoiTf.end(); ++it) {
    const Bucket &b = it->second;
    std::printf("  M%-2d: arms=%d closed=%d wins=%d losses=%d net=%.2f USC\n",
                ctx.poiMinutes[it->first], b.arms, b.closed, b.wins, b.losses, b.net);
  }
  std::printf("-- by confirmation --\n");
  for (std::map<int, Bucket>::iterator it = ctx.byConfirm.begin(); it != ctx.byConfirm.end(); ++it) {
    const Bucket &b = it->second;
    std::printf("  %-4s: arms=%d closed=%d wins=%d losses=%d net=%.2f USC\n",
                it->first == EXEC_CONFIRM_IFVG ? "IFVG" : (it->first == EXEC_CONFIRM_CISD ? "CISD" : "none"),
                b.arms, b.closed, b.wins, b.losses, b.net);
  }
  std::printf("===================================================\n");
  return 0;
}
