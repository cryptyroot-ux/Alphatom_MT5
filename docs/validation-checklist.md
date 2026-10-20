# Alphatom MSNR MT5 Indicator Validation Checklist

Status: **partial**. Host tests pass and MetaEditor compilation/runtime attachment are verified on the VPS. The TradingView comparison below is preliminary only; exact parity is not established.

## TradingView golden-chart comparison

1. For operational correctness, treat HFM Cent `XAUUSDc` MT5 history as authoritative. TradingView may be used as a structural reference; do not treat cross-broker price differences as an indicator defect. Require the same feed/history only when claiming exact numeric parity, and record broker/timezone differences.
2. Keep the TradingView MSNR indicator's reference settings documented in `msnr-replica-spec.md`. On both platforms load M15, M30, and H1 levels; verify they are independent and do not require confluence.
3. For each visible level, record source timeframe, originating candle time, price (or gap lower/upper bounds), role, freshness, and flip state. Compare exact matches and classify discrepancies; do not tune settings to one screenshot only.
4. Check that a candidate appears only after the configured right-side swing bars close. Replay one bar at a time to verify there is no intrabar pivot repaint.
5. Compare wick-touch/unfresh transitions, body-close breaks, and both RBS/SBR flips, including a bar whose wick touches while its close breaks the level.
6. Verify gap bands separately. The current three-candle non-overlap detector is an explicit approximation and may not match the protected script's definition.
7. Repeat comparisons on multiple volatile and quiet periods and save chart screenshots plus a row-by-row mismatch log. Change a baseline assumption only when evidence supports it, then rerun the full sample.

### Preliminary VPS comparison — 2026-10-21

- TradingView showed `FOREXCOM:XAUUSD` on M15; the active VPS terminal showed broker symbol `XAUUSDc` on M5. Current displayed prices were approximately 4120.61 and 4120.42 respectively. The terminal clock was about three hours ahead of the TradingView UTC clock. Feed, chart timeframe, and time alignment therefore differ; these values are not parity evidence.
- The visible common settings include Open source, swing 3/3, gap detection with tolerance 2, touch tolerance 0, ATR 14, merge tolerance 0.1, Keep dimmed, Flip (RBS/SBR), and max 8. This confirms only the displayed common controls, not hidden Pine semantics.
- The MT5 chart rendered M15/M30/H1 lines and status labels. Some right-edge labels overlap when several levels cluster. TradingView's visible 15m dashboard showed resistance near 4121.42 and support near 4120.09; no candle-by-candle/source-time/role/state match was established against MT5.
- At the end of this initial pass, comparison was blocked by mismatched feed, date window, chart timeframe/source layers, and the absence of a row-by-row level log. The later aligned M1/source-layer pass below addresses timeframe, approximate window, and source periods only; the feed mismatch and missing source-time/lifecycle mapping remain. The protected TradingView source is unavailable, so exact-code parity cannot be claimed.

### Aligned M1/source-layer comparison — 2026-10-21

- MT5 now has four tiled `XAUUSDc` charts: H1, M30, M15, and M1. All use green bullish/up bars and bodies, red bearish/down bars and bodies, white background, and no grid. The `Alphatom_Compare` template applies the same MSNR indicator to all four charts. Market Watch, Navigator, and Toolbox panes were hidden to give the charts room.
- TradingView was changed to M1 and its MTF MSNR layers were set to chart layer **off**, HTF layers **15 / 30 / 60 minutes**, final HTF layer **off**. This matches the replica's M15/M30/H1 source periods. The M1 chart window overlapped approximately 2026-10-20 16:45–20:16 UTC on both platforms after applying the observed +3-hour MT5 server-time offset.
- TradingView searches for `HFM` (only unrelated fund results), `HFMarkets:XAUUSD`, and `XAUUSDc` returned no matching HFM symbol. TradingView remains `FOREXCOM:XAUUSD`; MT5 remains HFM `XAUUSDc`. Thus the requested same-feed comparison is **not available from the current TradingView symbol list**.

| TradingView UTC candle | TV O / H / L / C | MT5 server candle | MT5 O / H / L / C |
|---|---|---|---|
| 2026-10-20 18:56 | 4123.08 / 4123.12 / 4122.81 / 4122.81 | 21:56 | 4122.93 / 4122.96 / 4122.56 / 4122.56 |
| 2026-10-20 19:29 | 4122.56 / 4122.63 / 4122.19 / 4122.50 | 22:29 | 4122.59 / 4122.59 / 4121.85 / 4122.33 |
| 2026-10-20 19:59 | 4120.48 / 4120.60 / 4120.06 / 4120.37 | 22:59 | 4120.24 / 4120.43 / 4119.73 / 4120.26 |

- Price differences confirm the feeds are not interchangeable; in these three samples, MT5 lows are 0.25–0.34 below TV lows and closes differ by 0.11–0.25. Treat the approximate +3h server offset as observed for this sample, not a permanent timezone guarantee.
- TV's visible dashboard showed M30 resistance/support near 4124.86 / 4117.65 and H1 resistance/support near 4143.19 / 4112.67. MT5 showed an M30 support near 4117.73 (about +0.08) and an H1 resistance near 4142.99 (about -0.20); however, the MT5 line nearest TV's M30 resistance around 4124.86 was labeled M15, not M30. Exact source-time/lifecycle matching is therefore still incomplete. TV's `Require A/V candle shape` is enabled; the replica does not expose that exact protected-script rule.
- The comparison is now aligned by chart timeframe, approximate date window, and POI source layers, but not by feed. It remains a preliminary parity sample; additional sessions, exact pivot/source timestamps, gap bounds, freshness/break/flip transitions, and a same-feed data source are still required.

### HFM Cent MT5 OHLC/runtime audit — 2026-10-21

- A read-only audit script was compiled in the active portable MetaEditor with **0 errors, 0 warnings** and run on the active `XAUUSDc` M1 chart. It made no trading/API calls. HFM returned company `HF Markets (SV) Ltd.`, server `HFMarketsGlobal-Live19`, account currency `USC`, and hedging mode. `XAUUSDc` reports 2 digits, point/tick size `0.01`, and contract size `1.0`.

| Source TF | Synchronized | Bars copied | Closed / forming | Direct `iTime`+OHLC comparisons | Invalid OHLC / time order | Current / latest closed (server time) |
|---|---:|---:|---:|---:|---:|---|
| M15 | yes | 1500 | 1499 / 1 | 300; 0 mismatches | 0 / 0 | 23:45 / 23:30 |
| M30 | yes | 1500 | 1499 / 1 | 300; 0 mismatches | 0 / 0 | 23:30 / 23:00 |
| H1 | yes | 1500 | 1499 / 1 | 300; 0 mismatches | 0 / 0 | 23:00 / 22:00 |

- The audit exported actual broker rates via `CopyRates(_Symbol, tf, 0, 1500, rates)` and compared the newest 300 timestamps and OHLC tuples to MT5 `iTime/iOpen/iHigh/iLow/iClose`. All three series were synchronized; all 1500 bars per timeframe had valid OHLC and strictly ascending timestamps in the kernel's chronological order. The forming bar was identified separately and is excluded by the indicator (`closed_count = copied - 1`).
- With the live default settings (Open source, swing 3/3, maximum 8), each timeframe rendered eight swing levels. Independent replay over the HFM closed bars matched all 24 object source timestamps, pivot-open prices, roles, and Fresh/Unfresh/Flipped/Broken labels. Both resistance-to-support and support-to-resistance role flips were present in the output. This confirms the current swing/lifecycle calculations against this HFM history sample, not the protected Pine semantics.
- For all 24 displayed pivots, replay confirms they are unavailable before the three right-side bars close and their pivot condition remains stable after confirmation. Repeated full re-renders (audit reruns at server 00:03 and 00:20/00:30, all inside the daily break with no new bars) produced byte-identical object sets — render idempotence. The closed-bar-only transition rule itself is covered by the C++ kernel tests; a genuine live across-close snapshot pair for the reopened session (first post-reopen M15 close at 01:15 server) is scheduled on 2026-10-21.
- **Gap starvation — resolved (2026-10-21).** The user selected a combined cap of eight candidates per timeframe, ordered newest creation bar first (same-bar ties: swing before gap, then swing-high before swing-low; both local deterministic choices). Implemented test-first: failing C++/Python selection tests, then kernel `MSNR_CandidatePrecedes` plus an indicator-side swing/gap candidate queue; MetaEditor rebuild **0 errors / 0 warnings**. HFM re-audit renders M15 5 swing + 3 gap, M30 5 swing + 3 gap, H1 4 swing + 4 gap. An independent replay using the kernel's band-separation merge rule (`MSNR_ZoneDistance`: zero when bands overlap) matches every selection, price/bounds, label, and replayed lifecycle state on all three timeframes. An apparent H1 mismatch in the first re-check was a verifier bug (midpoint distance instead of band-separation distance), not an indicator defect. Gray gap bands are visibly rendered on the tiled charts. Gap output is validated for this sample; long-duration multi-session validation remains open.
- Audit CSVs are in the active terminal's `MQL5/Files` directory (`Alphatom_HFM_OHLC_audit.csv`, `Alphatom_HFM_objects_audit.csv`, and `Alphatom_HFM_summary_audit.csv`). No orders or positions were changed.

## MT5 attachment and runtime

1. Verified on VPS: `Alphatom_MSNR_MTF.mq5` and `MSNRKernel.mqh` installed in the active portable terminal's `MQL5/Indicators` and `MQL5/Include/Alphatom`; MetaEditor GUI reported **0 errors, 0 warnings** and generated `Alphatom_MSNR_MTF.ex5`. The saved template is now applied to XAUUSDc H1, M30, M15, and M1 charts (the first attachment was on M5 before that chart was changed to M30).
2. HFM runtime audit confirmed M15/M30/H1 closed-bar OHLC ingestion and swing/lifecycle outputs for the sample above; after the combined newest-eight selection fix, gap rectangles render and the composite-key replay matches all selected swing/gap candidates on every timeframe.
3. Remove/re-attach the indicator and change symbols/timeframes; confirm only objects with its `ATMSNR_<tag>_` prefix are removed and no stale levels remain.
4. Verify missing or still-loading source history produces no fabricated level and clears that timeframe's stale objects; check Experts/Journal for errors.
5. Run a sustained chart test while monitoring CPU, object count, and redraw flicker. This initial version recalculates the fixed history window on chart updates; performance must be assessed on the target terminal.

## Gates before autonomous use

- Complete chart-by-chart golden comparison and review all material mismatches.
- Verify actual broker symbol tick size, price digits, account mode, and history feed.
- Only after separate strategy definitions and tests are approved may this map feed an EA. This indicator itself contains no order execution.
