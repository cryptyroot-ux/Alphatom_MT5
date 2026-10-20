# Alphatom MT5 MSNR Replica — Implementation Spec

## Goal and limits

Build a standalone MT5 custom indicator that presents a documented-behavior replica of the protected TradingView **MTF MSNR Levels (Malaysian SnR)** indicator. It is a POI map only: it must not place, modify, or close trades. Since the TradingView Pine source is closed and not available, this is not a source-code port and exact parity must not be claimed. For the user's execution environment, HFM Cent `XAUUSDc` MT5 OHLC is the source of truth; differences from a TradingView broker feed are not defects by themselves. TradingView is a supplementary structural reference, and exact numeric comparison requires matched feed and history.

## Confirmed user requirements

- POI source periods: **M15, M30, H1**. Each may produce a POI independently; cross-timeframe confluence is not required.
- **H4 is a ceiling only**, not a source period. Do not use D1, W1, MN1, or any POI period above H4.
- The indicator may be attached to an execution chart such as M1; POI calculation periods are independent of the chart period.
- Future EA execution will count an M1/M2/M3 wick entering a POI as a touch, but trade execution is outside this indicator's scope.

## Reference behavior and observed defaults

Observed TradingView inputs: Open source; swing 3/3; require A/V shape on; doji-as-either off; doji max body 0; one-inside off; gap detection on; gap-aware swings off; gap tolerance 2 ticks; touch tolerance 0; show A/V on; ATR 14; merge tolerance 0.1 ATR; fresh replaces unfresh off; unfresh Keep(dimmed); broken Flip(RBS/SBR), visible; maximum 8 levels per timeframe; chart layer plus four Auto HTF layers on.

Public documentation describes levels as confirmed after candle close, A/V candidates from close-line peaks/troughs, Open source as an open-price level, gaps as bands, freshness as absence/presence of wick touch, break as candle-body close through a level, and optional resistance/support role flip. The guide does not disclose enough implementation detail to reproduce all Pine behavior exactly.

## Independent baseline rules (explicit assumptions)

These rules provide deterministic behavior where the protected script's implementation is unknown. They are implementation assumptions, not verified claims about TradingView internals.

1. Process only completed source-timeframe bars. A swing candidate is eligible after the configured right-side bars have closed. A swing high/low is a unique maximum/minimum of the selected source across the configured left/right window; equal extrema do not create duplicate pivots.
2. `Close` source uses the pivot bar close; `Open` source uses the pivot bar open. The meaning of TradingView's “second candle open” is not sufficiently specified; this baseline interpretation must be called out in the UI/docs pending chart comparison.
3. Optional gap zones use the three-candle non-overlap convention: bullish when the oldest bar's high is below the newest bar's low; bearish when the oldest bar's low is above the newest bar's high. Zone bounds are those two non-overlapping prices. Gap-aware swing behavior remains off by default.
4. A wick intersection (inclusive) with a level/zone marks it unfresh. A close strictly beyond the far boundary marks it broken; if flip is enabled, resistance becomes support (RBS) and support becomes resistance (SBR). A close break takes precedence over a touch on the same bar. The level lifecycle is replayed chronologically from closed bars.
5. Merge tolerance is `ATR(period) * multiplier`; the baseline ATR uses Wilder/RMA smoothing initialized with a simple average of the first `period` true ranges. Zero touch tolerance means no extra price padding beyond inclusive wick intersection. Respect the symbol's tick size when applying tick-based gap tolerance.
6. Maximum-level count defaults to eight display-eligible levels per source timeframe, shared by swing levels and gap zones (user decision 2026-10-21: one combined candidate queue ordered newest creation bar first; the same-creation-bar tie-break — swing before gap, then swing-high before swing-low — is a local deterministic choice). Candidates merge by band-separation distance (`MSNR_ZoneDistance` returns zero when price bands overlap) against the ATR merge tolerance; while `fresh replaces unfresh` is off, a merged candidate is discarded. A state hidden by `Keep unfresh`/`Show broken` does not consume a visible slot. Existing-level replacement and dim/visible states follow exposed options, but styling beyond this is implementation-defined and documented.
7. If copied history contains a nonfinite, zero/nonpositive-price, zero-time, or OHLC-inconsistent bar, skip that timeframe for the refresh and clear its owned objects rather than deriving levels from a partial/corrupt series.

## Initial acceptance criteria

- Default enabled POI periods are exactly M15, M30, and H1; no H4+ source is silently added.
- Levels and gap bands are based only on closed bars, have stable per-timeframe object identities, and are removed/updated deterministically on recalculation.
- Defaults match the observed settings above wherever the independent baseline can support them. Unsupported or unverified controls must be labeled honestly rather than presented as exact parity.
- Rendering controls implemented in this version include source, swing left/right, gap detection/tolerance, touch tolerance, ATR/merge tolerance, fresh replacement, retention of unfresh/broken levels, flip behavior, A/V markers, maximum retained levels, and history depth. Doji handling, one-inside patterns, gap-aware swings, dashboard, and alerts are intentionally not exposed because their exact semantics are not recoverable from the available guide.
- Deterministic kernel behavior has unit tests; the `.mq5` indicator compiles with the installed MetaEditor; no order/trade API is called.
- HFM Cent `XAUUSDc` OHLC ingestion and runtime behavior are the primary validation gate. TradingView comparison is supplementary; exact numeric parity requires matched feed/history and must not be inferred from a different broker feed.
- A live broker/account validation and the separate strategy-definition/testing gates remain required before using any indicator output as an autonomous trading signal.

## Deferred / not accepted in this phase

- EA order execution, IFVG/CISD recognition, entry layering, SL/TP management, money-risk sizing, and broker/account actions.
- Exact Pine parity, unobserved settings, alerts/dashboard parity, or a claim of profitability.
- H4, D1, W1, MN1, or arbitrary timeframe POI sources.
