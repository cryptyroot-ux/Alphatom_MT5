# Alphatom MT5 MSNR Indicator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use the executing-plans skill to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a non-trading MT5 indicator that independently renders MSNR-style POI levels for M15, M30, and H1.

**Architecture:** Put deterministic price-pattern and lifecycle rules in a small shared `.mqh` kernel, exercise that same header with a native C++ test harness, and have the MT5 indicator copy completed bars from the three required source periods and render chart objects. Treat the output as an independent behavioral replica because the TradingView Pine source is protected; keep all assumptions explicit and never add order execution.

**Tech Stack:** MQL5 / MetaEditor under Wine; C++17 test harness compiled with the system compiler; standard-library-only test runner.

**Spec:** `docs/msnr-replica-spec.md`.

## Global Constraints

- POI periods are M15, M30, and H1; each may independently supply a POI.
- H4 is only the upper boundary, not an enabled POI period; do not use a period above H4.
- Do not add trade execution or claim exact TradingView source parity.
- Process closed bars only and keep the chart period independent from POI periods.
- Default settings must use the observed TradingView values where they are implemented; disclose unsupported or approximate semantics.

## Review Focus

- Right-side pivot confirmation and closed-bar-only updates — test candidate availability at the exact right-window boundary and reject unconfirmed/latest bars.
- Equality/tie handling in pivot extrema — test equal highs/lows do not create duplicate pivots.
- Wick touch versus body-close break and same-bar precedence — test touch-only, close-through, and close-through on a candle that also intersects the level.
- Multi-timeframe selection and identity — verify exactly M15/M30/H1 are requested and object names include source timeframe.
- Missing/unsynchronized history and repeated recalculation — ensure no stale POI objects remain and no zero/uninitialized bars create levels.

---

### Task 1: Deterministic MSNR rule kernel

**Files:**
- Create: `MQL5/Include/Alphatom/MSNRKernel.mqh`
- Test: `tests/msnr_kernel_tests.cpp`
- Create: `Makefile`

**Interfaces:**
- Produces `MSNRBar {open, high, low, close, time}`, `MSNRZone {valid, bullish, lower, upper}`, and `MSNRLevel {price, lower, upper, role, state, created}`. Exact pure-function signatures: `bool MSNR_IsPivotHigh(const MSNRBar bars[], int count, int index, int left, int right, MSNRSource source)`; same parameters for `MSNR_IsPivotLow`; `double MSNR_GetLevelPrice(const MSNRBar &bar, MSNRSource source)`; `MSNRZone MSNR_DetectGap(const MSNRBar bars[], int count, int oldestIndex, double tolerance)`; `bool MSNR_TouchesZone(double barLow, double barHigh, double zoneLow, double zoneHigh, double tolerance)`; and `bool MSNR_IsBodyBreak(double close, double zoneLow, double zoneHigh, MSNRRole role, double tolerance)`.
- The indicator in Task 2 consumes these functions; test runner compiles the same `.mqh` header with C++17, not a reimplementation.

- [x] Create `tests/msnr_kernel_tests.cpp` with tests named `test_pivot_needs_closed_right_window`, `test_equal_extrema_are_rejected`, `test_level_source_uses_open_or_close`, `test_gap_detection_returns_band_bounds`, `test_wick_intersection_counts_as_touch`, and `test_break_requires_close_beyond_boundary`, plus a `Makefile` whose `test` target compiles the same `.mqh` kernel under C++17 with `-Wall -Wextra -Werror -pedantic` and runs it.
- [x] Run `make test` before adding the kernel; expected: compilation fails because `MSNRKernel.mqh`/declared functions do not exist.
- [x] Implement only the shared types/functions in `MQL5/Include/Alphatom/MSNRKernel.mqh`, using the exact baseline rules in the spec.
- [x] Run `make test`; expected: all named assertions pass with warnings treated as errors.

### Task 2: MTF data and lifecycle model

**Files:**
- Modify: `MQL5/Include/Alphatom/MSNRKernel.mqh`
- Test: `tests/msnr_kernel_tests.cpp`
- Create: `tests/indicator_contract_tests.py`
- Create: `MQL5/Indicators/Alphatom_MSNR_MTF.mq5`

**Interfaces:**
- Consumes Task 1 kernel.
- Produces an indicator with explicit M15/M30/H1 periods, inputs for the observed swing/source/gap/touch/ATR/merge/retention settings, stable IDs, and deterministic Fresh → Unfresh → Broken/Flipped state transitions.

- [x] Add `tests/indicator_contract_tests.py` with checks for the M15/M30/H1 source list, no H4+ source, observed implemented defaults, closed-bar exclusion, valid OHLC bars, all three processed periods, hidden-state filtering, and absence of trade API calls; add lifecycle, band-distance, Wilder ATR, exact-window-boundary, and equal-extrema tests to `tests/msnr_kernel_tests.cpp`.
- [x] Run `make test` and `python3 -m unittest discover -s tests -p 'test_*.py' -v`; expected: C++ compilation fails because lifecycle functions are absent, and Python contract checks fail because the indicator source is absent.
- [x] Implement the kernel lifecycle/replacement functions and the indicator's closed-bar `CopyRates` processing; do not request POI data from H4 or higher and do not call trade APIs.
- [x] Run `make test`; expected: all C++ kernel and Python contract tests pass.

### Task 3: Chart rendering and build verification

**Files:**
- Modify: `MQL5/Indicators/Alphatom_MSNR_MTF.mq5`
- Modify: `docs/msnr-replica-spec.md`
- Create: `docs/validation-checklist.md`

**Interfaces:**
- Consumes the MTF level/lifecycle model from Task 2.
- Produces chart lines/bands and labels keyed by timeframe/type/time/price; clears only objects owned by this indicator; reports history/synchronization limitations without fabricating levels.

- [x] Add failing contract checks for stable timeframe-qualified object IDs, prefix-scoped cleanup, and handling of unavailable source history; run `make test` and observe those checks fail.
- [x] Implement rendering for support/resistance lines and gap bands, visibly distinguish Fresh/Unfresh/Flipped status, and scope cleanup to the indicator's unique object prefix.
- [x] Add a validation checklist for TradingView golden-chart comparison and MT5 attachment; explicitly mark parity/live-broker checks as not yet performed.
- [x] Run `make test` and compile `MQL5/Indicators/Alphatom_MSNR_MTF.mq5` in the active VPS MetaEditor; expected: full host suite passes and MetaEditor reports zero errors (warnings recorded, not hidden).

Implementation status: host tests pass. The indicator and kernel were installed in the active portable MT5 prefix at `/opt/mt5/work/wp64/drive_c/Program Files/MetaTrader 5/MQL5`; MetaEditor GUI reported **0 errors, 0 warnings** and generated `Alphatom_MSNR_MTF.ex5`. The saved comparison template is applied to XAUUSDc H1/M30/M15/M1 charts. TV has been configured to M1 with M15/M30/H1 source layers, but its available XAUUSD feed is FOREXCOM while MT5 uses HFM XAUUSDc, so exact parity remains incomplete; see `docs/validation-checklist.md` for matched-time OHLC samples and level mismatches.
