# Alphatom EA Execution Spec — Frozen Definitions

Status: **frozen (rounds 1-2 recorded 2026-10-21)**. These decisions bind the future EA; the MSNR indicator remains non-trading and no parity or profitability claim is valid until broker-matched validation passes. Implementation begins only after this document.

All prices/timings use HFM Cent `XAUUSDc` MT5 semantics: 2 digits, point/tick size `0.01`, hedging account (`HFMarketsGlobal-Live19`). `50 pips = 5.00` price change.

## Chart roles

- Execution timeframes: **M1/M2/M3** — wick touches, IFVG/CISD detection, retest, order placement.
- POI sources: **M15/M30/H1**, each independent (no confluence requirement). H4 is a maximum boundary only; never a POI source. No POI timeframe above H4.

## Setup sequence (frozen)

1. A wick on M1/M2/M3 enters a POI (swing level or gap band) → that is the **touch**.
2. Only after the touch may a confirmation form; a confirmation that existed before the touch does not qualify.
3. Confirmation = **IFVG or CISD** aligned with the plan direction; just one is required.
4. Entry waits for the **retest**: trigger IFVG → retest must return to the IFVG zone used as confirmation; trigger CISD → retest must return to the CISD level/band used as confirmation.

## Round-1 frozen detections (user decisions 2026-10-21)

- **IFVG:** confirmed on candle **close through** the opposite FVG zone boundary on M1/M2/M3 (body-close breach; wick alone never flips it intrabar). The inverted zone flips role (bearish FVG broken upward becomes support/bullish IFVG; mirrored otherwise) and becomes the confirmation/retest zone.
- **CISD:** anchor = **open of the first candle** of the latest same-direction delivery run on M1/M2/M3. CISD when a candle closes beyond that open (bullish run, then close below the first up-candle's open = bearish CISD; mirrored). No minimum run length in this round (N=0); revisit only as a documented change if false positives appear.
- **Entry zone:** trigger IFVG → the three layers are spread inside the **full IFVG zone**. Trigger CISD (a level) → zone = **3-bar M1 high/low band** around the CISD level, with configurable minimum/maximum width inputs.
- **Layer lifetime:** the three pending orders are placed when the entry zone is first touched; they remain active while their POI stays valid, and are canceled when the POI becomes Broken or the aligned signal reverses (round 2 defines the exact cancel trigger).

## Order intent (carried from the agreed strategy; round 2 confirms order type)

- Three entries, **0.15 lots each**; all inside the entry zone. Sell stacking `E2 > E1` and `E3 > E2` (E1 lowest); buy mirrored `E2 < E1` and `E3 < E2` (E1 highest).
- Shared SL anchored at the **extreme wick of the touch candle**; at most **50 pips (5.00)** from the farthest entry.
- TP per fill: E1 **+30**, E2 **+50**, E3 **+100** pips. After TP1 fill closes E1, the E2/E3 SL is locked to **+10 pips**.

## Round-2 frozen rules (user decisions 2026-10-21)

- **Retest gating:** the three pending orders are placed as soon as an M1/M2/M3 wick touches the edge of the entry zone (same wick-touch convention as the indicator). No minimum depth, no close requirement.
- **Shared SL:** extreme wick **± 2 ticks (`0.02`)** beyond the wick. If the distance from SL to the farthest entry exceeds `5.00` (50 pips), the entire setup is **skipped** — never clamped to the cap.
- **Order type:** simple **GTC limit** orders at the three layer prices; no broker expiry — cancellation is EA logic.
- **Unfilled layers:** on the TP1 lock event (E1 closed, E2/E3 SL locked to +10 pips) or on any cancellation event, layers still unfilled are **canceled**; the setup continues with whichever layers filled.
- **Cancel trigger (refines round 1):** unfilled layers are canceled **only when the POI that sourced the setup becomes Broken** on its origin timeframe (M15/M30/H1). Broken POIs elsewhere or opposing confirmations do not cancel in v1; the round-1 "or the aligned signal reverses" clause is superseded by this narrowing.

## Remaining before any autonomous trading

- Implement the EA per this spec with test-first development; the indicator stays non-trading.
- Broker/account runtime checks and multi-session demo validation on HFM before live use; never claim profitability before that validation.

