# Alphatom EA Execution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use the executing-plans skill to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a test-first MT5 expert advisor that executes the frozen Alphatom sequence — POI wick touch (M1/M2/M3) → IFVG or CISD confirmation → retest → three 0,15-lot GTC limit layers → one shared SL (capped at 50 pips) → TP +30/+50/+100 with the +10-pip SL+ lock — while never sending an order until the owner explicitly enables it.

**Architecture:** Put every rule that can be expressed as pure data transformation in a dual-language kernel (`ExecKernel.mqh`) compiled by the same C++ harness that already tests `MSNRKernel.mqh`; keep the MQL5 expert thin — it copies bars, feeds the kernel, and translates kernel intents into MT5 order calls. The POI map is produced by the *same* level computation the indicator uses, extracted into a shared include so the EA and the indicator cannot drift. Trading is gated behind a shadow-mode flag that is ON by default, so the first live runs only log decisions.

**Tech Stack:** MQL5 / MetaEditor under Wine (`/opt/mt5/work/wp64`, user `mt5`, `DISPLAY=:99`); C++17 harness via the repo `Makefile`; Python `unittest` contract tests over the MQL5 sources.

**Spec:** `docs/ea-execution-spec.md` (frozen rounds 1–4) and `docs/ea-spec-audit.md` (findings F-1…F-12, decisions D-1…D-3).

## Global Constraints

- POI sources are M15/M30/H1 (independent; H4 is a boundary only). Execution timeframes M1/M2/M3.
- Lots 0.15 per layer; sell `E1<E2<E3`, buy `E1>E2>E3`; all three inside the entry zone.
- One shared SL = extreme wick of the window [first POI touch → arming] ± 2 ticks, clamped to exactly 5.00 from E1; the final SL must sit beyond E3 or the setup is skipped.
- TP +30/+50/+100 from each layer's own fill; after TP1 the E2/E3 SL locks +10 pips from each own entry.
- `InpShadowMode` defaults to **true**: no order API is reachable while it is on (enforced by contract test, not by comment).
- Closed bars only; the HFM session break (23:59 → 01:00 server) and the frozen forming bar yield no events.
- The indicator stays non-trading. No parity, profitability, or "ready for live" claim until the HFM demo validation in Task 6 passes.
- Pip = 0.10 price units; tick = 0.01; all prices rounded to the tick grid.

## Review Focus

- Order of events: touch bar < confirmation bar < retest bar < arming bar — every transition must assert this.
- Shared-SL geometry: the stop must be beyond E3 after the clamp; a zone ≥ 5.00 wide or a touch-chain extreme on the wrong side must produce a *skip with a log*, never a malformed order.
- Cancellation symmetry: Broken, role flip, and TP1-lock must cancel exactly the unfilled layers and leave filled layers with their own SL/TP.
- Fill-side correctness: a buy limit fills at ask, a sell limit at bid; TP/SL must be computed from the *filled* price, not the request price.
- Data hazards: forming bars, zero-range bars, unsynchronized history, and the daily break must never produce a touch, confirmation, retest, or break.
- No invented parameters: every number must trace to the spec, the guide, or an explicit input with a documented default.

---

### Task 1: Execution kernel — detection core (IFVG + CISD)

**Files:**
- Create: `MQL5/Include/Alphatom/ExecKernel.mqh`
- Create: `tests/exec_kernel_tests.cpp`
- Modify: `Makefile`

**Interfaces:**
- `ExecKernel.mqh` includes `MSNRKernel.mqh` and reuses `MSNRBar`, `MSNRZone`, `MSNRRole`, `MSNR_IsBodyBreak`, `MSNR_TouchesZone`, `MSNR_DetectGap`. It adds:
  - `bool Exec_DetectIFVG(const MSNRBar bars[], int count, int afterIndex, const MSNRRole wanted, MSNRZone &outZone, int &outIndex, long &outTime)` — returns the earliest inverted FVG whose break bar index is `> afterIndex`; the break is a **close** strictly beyond the far boundary of a gap that formed earlier (bullish gap closed below → bearish/resistance IFVG, and the mirror).
  - `bool Exec_DetectCISD(const MSNRBar bars[], int count, int afterIndex, const int minRun, const bool wantBullish, double &outAnchor, int &outIndex, long &outTime)` — a delivery run is a same-colour sequence (`close>open` / `close<open`) of at least `minRun` candles (doji breaks a run); the anchor is the **open of the first candle of the latest completed qualifying run**; a bullish CISD needs a later close **above** a bearish run's anchor, a bearish CISD a close **below** a bullish run's anchor.
  - `bool Exec_FindTouchChain(const MSNRBar bars[], int count, const double zoneLow, const double zoneHigh, int &outFirstIndex, int &outLastIndex)` — the POI touch chain: first and last bar whose wick intersects the POI band.
- The C++ harness compiles the same header; no reimplementation.

- [x] Add `tests/exec_kernel_tests.cpp` with groups `test_ifvg_requires_close_through_far_boundary`, `test_ifvg_ignores_wick_only_break`, `test_ifvg_ignores_formation_before_touch`, `test_cisd_anchor_is_first_candle_of_run`, `test_cisd_min_run_length_is_enforced`, `test_cisd_doji_breaks_run`, `test_cisd_direction_matches_opposing_run`, `test_touch_chain_spans_repeated_wicks`; extend the `Makefile` with an `exec` test target included in `test`.
- [x] Run `make test`; expected: **RED** — compilation fails because `ExecKernel.mqh` does not exist. *(Observed: `No rule to make target 'MQL5/Include/Alphatom/ExecKernel.mqh'` — the build stops before compiling, as expected.)*
- [x] Implement `ExecKernel.mqh` with exactly the interfaces above (pure functions, no MT5 API, C++17-clean under `-Wall -Wextra -Werror -pedantic`).
- [x] Run `make test`; expected: **GREEN** — all groups pass and the pre-existing MSNR/Python suites stay green. *(Observed: 15 MSNR groups + 12 Exec groups + 14 Python tests pass. One initial failure was a wrong test expectation — the bearish gap band is `[newest high, oldest low]`, not `[close, low]` — and the test was corrected, not the implementation.)*

### Task 2: Execution kernel — entry zone, layers, SL/TP math

**Files:**
- Modify: `MQL5/Include/Alphatom/ExecKernel.mqh`
- Modify: `tests/exec_kernel_tests.cpp`

**Interfaces (as built):**
- `bool Exec_BuildIfvgEntryZone(const MSNRZone &ifvgZone, MSNRZone &outZone)` — the full inverted gap, copied unchanged.
- `bool Exec_BuildCisdEntryZone(const MSNRBar bars[], const int count, const int anchorIndex, const double anchorPrice, const double minWidth, const double maxWidth, MSNRZone &outZone)` — high/low band of the three M1 candles around the anchor bar (bar whose open is the CISD anchor), forced to contain the anchor, widened to `minWidth` or narrowed to `maxWidth` symmetrically around it.
- `bool Exec_ComputeLayers(const MSNRZone &zone, const bool isBuy, const double tickSize, const int minWidthTicks, double &e1, double &e2, double &e3)` — equal thirds; E1 is the near edge by direction (upper for buy, lower for sell), E2 the midpoint, E3 the far edge; all rounded to the tick grid and strictly ordered; `false` when the zone is too narrow or rounding collapses a price. *(The `firstTouchPrice` parameter was dropped: direction + stacking fully determine the edge order, and the state machine validates which edge the arming wick touched.)*
- `bool Exec_ComputeSharedSL(const bool isBuy, const double windowLow, const double windowHigh, const double e1, const double e3, const double tickSize, const int bufferTicks, const double capDistance, double &outSL, int &outSkipReason)` — extreme wick of the arming window ± buffer ticks → clamp to exactly `capDistance` from E1 → require the final SL beyond E3; otherwise return `false` with a skip reason.
- `double Exec_ComputeTP(const bool isBuy, const double fillPrice, const int pips)`, `double Exec_ComputeSLPlus(const bool isBuy, const double entryPrice, const int pips)`.
- `double Exec_ComputeBasketRisk(const double distancePips1, const double distancePips2, const double distancePips3, const double lotsPerLayer, const double moneyPerPipPerLot)` — guide §11.2 basket risk in deposit currency (USC on the cent account); `moneyPerPipPerLot` must be derived from SymbolInfo at runtime.
- `Exec_DetectCISD` gained `int &outAnchorIndex` (index of the anchored run's first candle) so the CISD band can be built without re-deriving the anchor bar.

- [x] Add groups `test_entry_zone_for_cisd_uses_three_bar_band`, `test_entry_zone_for_ifvg_is_full_zone`, `test_layers_are_equal_thirds_and_ordered`, `test_layers_reject_too_narrow_zone`, `test_shared_sl_uses_window_extreme_not_last_candle`, `test_shared_sl_clamps_to_fifty_pips_from_e1`, `test_shared_sl_skips_when_not_beyond_far_entry`, `test_tp_and_slplus_use_own_fill_price`, plus `test_guide_numeric_examples` and `test_basket_risk_uses_all_three_distances`.
- [x] Run `make test`; expected: **RED** (functions absent). *(Observed: compile errors for every new symbol, as expected.)*
- [x] Implement the functions; expected: **GREEN**. *(Observed: 22 Exec groups pass, 15 MSNR groups and 14 Python tests stay green. One failure during the first run was a wrong test value — sell structural wick `4123.52 + 2 ticks` is `4123.54`, not `4123.50`; the test was corrected to `4123.48`.)*
- [x] Re-verify the guide's numeric examples as a test: buy E1 4120.0 / E2 4119.5 / E3 4119.0 with structural SL 4116.5 kept, structural SL 4114.0 clamped to 4115.0, SL+ E2 4120.5 / E3 4120.0; sell mirror (SL 4123.5 kept, 4126.0 → 4125.0, SL+ 4119.5 / 4120.0). *(Covered by `test_guide_numeric_examples`.)*

### Task 3: Execution kernel — setup state machine

**Files:**
- Modify: `MQL5/Include/Alphatom/ExecKernel.mqh`
- Modify: `tests/exec_kernel_tests.cpp`

**Interfaces (as built):**
- `enum ExecPhase { EXEC_IDLE, EXEC_TOUCHED, EXEC_CONFIRMED, EXEC_ARMED, EXEC_MANAGING, EXEC_DONE, EXEC_CANCELED }`, `enum ExecEventType { NONE, TOUCH, CONFIRM, ARM, SKIP, CANCEL, FILL, TP1_LOCK, CLOSE, DONE }`, `enum ExecReason { NONE, POI_BROKEN, ROLE_FLIP, ZONE_INVALID, SL_INVALID, RISK_CAP, TP1, CONFIG }`, `enum ExecLayerState { NONE, PENDING, FILLED, CANCELED, CLOSED }`.
- `struct ExecConfig` mirrors the expert inputs (tick, SL buffer/cap, CISD run and band width, min zone ticks, lots, money-per-pip, risk cap, TP pips 30/50/100, SL+ pips 10).
- `struct ExecSetup` holds phase, POI role/bounds/source minutes, touch/confirm indices+times, confirm kind, entry zone, layers, initial/current stops, TPs, SL+ levels, fill prices, layer states, basket risk and skip reason.
- `struct ExecEvent` reports type, resulting phase, bar index, time, layer, price and reason.
- `bool Exec_InitSetup(...)` clears and arms a direction; it refuses to re-initialise an active setup, so the expert keeps at most one setup per direction. `bool Exec_IsActive(...)`.
- `bool Exec_Advance(execBars, execCount, poiState, poiRole, config, setup, event)` — one closed-bar step; TOUCH on a fresh/flipped-fresh POI, CONFIRM after the touch (earliest valid IFVG/CISD; same-bar tie → IFVG), ARM on the first retest strictly after the confirmation (layers, D-1 window stop, clamp, skip guards, basket risk), and POI break/role flip cancels pending layers only.
- `bool Exec_RecordFill(setup, layer, price, config, event)` re-derives that layer's TP and SL+ from the actual fill. `bool Exec_RecordClose(setup, layer, isTp, event)` implements the TP1 lock (E2/E3 → own +10 pips, pending killed) and DONE detection.

- [x] Add groups `test_touch_starts_setup_only_on_fresh_poi`, `test_confirmation_before_touch_is_ignored`, `test_retest_must_be_after_confirmation_bar`, `test_arm_places_three_layers`, `test_cancel_on_broken_poi_removes_unfilled_only`, `test_cancel_on_role_flip`, `test_tp1_lock_cancels_unfilled_and_sets_sl_plus`, `test_one_active_setup_per_direction`, plus `test_confirmation_tie_prefers_ifvg`, `test_arm_skips_when_stop_not_beyond_far_entry`, `test_arm_skips_when_basket_risk_exceeds_cap`.
- [x] Run `make test`; expected: **RED**. *(Observed: `ExecConfig`/`ExecSetup`/`ExecEvent` unknown, all machine calls unresolved.)*
- [x] Implement the machine; expected: **GREEN**. *(Observed: 33 Exec groups + 15 MSNR + 14 Python. First run exposed a harness mistake — tests passed a short `count` with the full vector, while the kernel contract is `count == size`; fixed with a `head()` helper that simulates bar-by-bar steps. The synthetic series also formed a tiny IFVG on the same bar as the CISD, which made the tie-break visible; the series was cleaned for the CISD tests and a dedicated tie test keeps the rule pinned.)*
- [x] MetaEditor compile of the kernel (**0 errors / 0 warnings**); it caught a local reference variable (`const MSNRBar &current = ...`) that MQL5 rejects and C++ accepts — replaced with a struct copy.

### Task 4: Shared POI level computation (no behavior change)

**Files:**
- Create: `MQL5/Include/Alphatom/MSNRLevels.mqh`
- Modify: `MQL5/Indicators/Alphatom_MSNR_MTF.mq5` (call the shared function instead of its private copy)
- Modify: `tests/msnr_kernel_tests.cpp`, `tests/test_indicator_contract.py`

**Interfaces:**
- `void MSNR_BuildLevels(const MSNRBar bars[], const int count, const MSNRParams &params, MSNRLevel &outLevels[], int &outCount)` — candidate selection (combined newest-eight cap, swing-before-gap ties), band merge, lifecycle replay, exactly as the indicator does today.

- [x] Capture the **golden object snapshot** from the live terminal before touching the indicator (the 60-object dump produced in the audit run) into `tests/golden/hfm_objects_20261021.csv`, together with the exact bars the indicator used (`tests/golden/hfm_bars_20261021.csv`, 1499 closed bars x M15/M30/H1).
- [x] Add a host test that replays the exported HFM M15/M30/H1 bars through `MSNR_BuildLevels` and matches the golden snapshot's names, prices, roles and lifecycle labels (`tests/level_replay_tests.cpp`, `make test-levels`).
- [x] Run `make test`; expected: **RED** (no `MSNRLevels.mqh`). *(Observed: the new target failed to build until the include and macros existed.)*
- [x] Extract the computation, switch the indicator to it, re-run the host tests and the MetaEditor build (0 errors / 0 warnings). *(Observed: golden replay PASS — 8 levels per TF, all prices, gap bounds, roles, states and labels identical; MetaEditor 0 errors / 0 warnings for both the kernel harness and the refactored indicator; 15 MSNR + 33 Exec + 1 level replay + 14 Python green.)*
- [x] Live object-diff note: the golden replay on the **same bar window** is the parity gate. A fresh live audit cannot be byte-identical because the market has advanced (new bars legitimately add/evict levels); the live self-consistency check (export bars + objects in the same session, replay host-side) is folded into Task 6's shadow run.
- [x] If the diff is not empty, revert the indicator to its private path and record the discrepancy instead of shipping it. *(Not needed: the diff is empty.)*

### Task 5: Expert advisor shell (shadow mode first)

**Files:**
- Create: `MQL5/Experts/Alphatom_EA.mq5`
- Create: `tests/test_ea_contract.py`

**Interfaces:**
- Inputs: `InpShadowMode` (default **true**), `InpMagic` (20261021), `InpLots` (0.15), `InpExecTimeframes` (M1/M2/M3), `InpPOITimeframes` (M15/M30/H1), `InpCISDMinRun` (2), `InpMinZoneWidthTicks` (2), `InpSLBufferTicks` (2), `InpCapPips` (50), `InpTP1Pips` (30), `InpTP2Pips` (50), `InpTP3Pips` (100), `InpSLPlusPips` (10), `InpMaxRiskMoney` (0 = log only).
- The EA copies closed bars per timeframe, calls `MSNR_BuildLevels` for the POI timeframes, runs `Exec_Advance` per execution timeframe, and in shadow mode writes one CSV/JSON log line per event; in live mode it places the three GTC limits, sets TP/SL, and manages the TP1 lock.

**As built:** the EA keeps the frozen numbers as inputs (`InpSlCapPips` 50, TP 30/50/100, `InpSlPlusPips` 10, `InpLotsPerLayer` 0.15), mirrors the validated indicator's POI inputs, forces the POI map to expose unfresh/broken states (display-only filters never hide a lifecycle transition), and reads money-per-pip-per-lot from `SYMBOL_TRADE_TICK_VALUE_LOSS * (0.10 / tickSize)` at runtime. It refuses to start on a non-hedging account. Shadow mode additionally *simulates* limit fills and stops/targets on closed bars (stop checked before target inside one bar) so the whole state machine, including the TP1 lock, is exercised without orders. Layers already at/beyond the market when the retest bar closes cannot rest as valid limits, so they are executed immediately (shadow: at the retest close; live: market order) and the rest stay GTC limits; TP/SL+ always use the actual fill. Live mode is only reachable through `EaLiveEnabled()` (`!InpShadowMode && g_liveAllowed`); a live start with existing magic positions is refused and downgraded to shadow because restart recovery is not implemented yet.

- [x] Add `tests/test_ea_contract.py` asserting: the file exists; `InpShadowMode` defaults to true; every order call site is inside a shadow guard; the magic number is configurable and used; the kernel include is present; the EA never calls order APIs from `OnInit`; closed-bar-only copies; no `WebRequest`/`DllCall`; execution timeframe restricted to M1/M2/M3.
- [x] Run `python3 -m unittest discover -s tests -p 'test_*.py' -v`; expected: **RED** (no EA file). *(Observed: `FileNotFoundError`.)*
- [x] Implement `Alphatom_EA.mq5`; expected: **GREEN**; then compile in MetaEditor — expected **0 errors / 0 warnings**. *(Observed: 9 contract tests pass; MetaEditor first reported `ACCOUNT_MARGIN_MODE_HEDGING` (the real constant is `ACCOUNT_MARGIN_MODE_RETAIL_HEDGING`), then 0 errors / 0 warnings. Full suite: 15 MSNR + 33 Exec + level replay + 23 Python.)*
- [ ] Attach the EA to the live XAUUSDc M1 chart in **shadow mode** and confirm the log produces sensible events without any order in the Terminal's Trade tab. *(Moved to Task 6: the first shadow run must happen together with the runtime probe on the same terminal session.)*

### Task 6: HFM runtime checks and shadow validation

**Files:**
- Create: `MQL5/Scripts/AlphatomEaRuntimeCheck.mq5`
- Modify: `docs/validation-checklist.md`

- [ ] Runtime check script (read-only) records: symbol digits/point/tick/contract/tick value, margin mode, filling modes, stop-level distance, **whether M2 and M3 history exist on HFM** (open question for the EA's execution timeframes), and the live contract value used for the basket-risk log.
- [ ] Run it on the live terminal; record the result in the validation checklist.
- [ ] Let the shadow EA run across at least one full session; compare its logged events against a host-side replay of the same exported bars (the kernel must produce the same event sequence offline).
- [ ] Only after: fill in the guide §13 open items the owner has decided (money cap, session filters) and re-open the trading gate.

## Out of scope for v1

News/spread/session filters, partial-fill policy, TP "touch" semantics vs actual fill, money cap enforcement, multi-POI parallelism beyond one setup per direction, and any TradingView numeric parity claim.
