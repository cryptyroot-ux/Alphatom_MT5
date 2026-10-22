# Alphatom EA Spec Audit (guide PDF vs frozen spec vs code)

Audit date: 2026-10-21. Scope: full re-read of `/root/Alphatom_Panduan_Strategi.pdf` (v1.0, 21 Oct 2026) against `docs/ea-execution-spec.md` (rounds 1-3) and the existing implementation (`MQL5/Include/Alphatom/MSNRKernel.mqh`, `MQL5/Indicators/Alphatom_MSNR_MTF.mq5`).

Method: (1) full text extraction of the PDF (`pdftotext -layout`, 582 lines) and clause-by-clause comparison; (2) independent recomputation of every numeric example in the guide; (3) source audit of the kernel/indicator to confirm the spec is implementable against real code; (4) empirical tests on the exported HFM `XAUUSDc` M1 history (750,062 bars, 2024-08-29 → 2026-10-15) to quantify the CISD definition's selectivity.

No order/trading action was taken. The indicator remains non-trading.

## 1. Clause traceability

| Guide clause | Frozen spec | Status |
|---|---|---|
| §1 POI map is a visual reference, not an entry trigger | Chart roles | Consistent (see §5 divergence D-4) |
| §1 POI timeframe M15 or higher | POI sources M15/M30/H1 | Deliberate narrowing (owner decision), documented |
| §1 wick touch on M1/M2/M3 into the POI area | Setup sequence step 1 | Consistent (kernel `MSNR_TouchesZone` = inclusive wick intersection) |
| §1/§2.2 one valid confirmation on any of M1/M2/M3 is enough | Setup sequence step 3 | Consistent; the guide explicitly leaves TF priority open (§13) — see F-6 |
| §1 one shared initial SL from the extreme touch wick | Order intent + round 3 | Consistent (round 3 restated it as the whole touch chain) |
| §1 50-pip cap, setup is not auto-skipped | Round-3 clamp rule | Consistent after the owner's round-3 arbitration |
| §1/§9.1 TP +30/+50/+100 per layer fill | Order intent | Consistent |
| §1/§9.2 SL+10 pips from each layer's own entry | Round-3 SL+ wording | Consistent |
| §5 Tahap A: note whether the area is fresh, decide buy/sell direction | — | **Gap F-1 / F-2** (eligibility + direction derivation were never written down) |
| §5 Tahap C: confirmation must form after the touch | Setup sequence step 2 | Consistent, but the bar-order requirement was implicit — F-3 |
| §5 Tahap D: wait for the pullback/retest of the confirmation zone | Setup sequence step 4 | Consistent — F-3 (retest must be a later bar) |
| §5 "layer plan cannot be placed inside the zone → do not invent spacing" | Round-3 equal thirds + zone-width guard | Consistent (spacing now owner-decided) |
| §6.1 bearish FVG broken up → support IFVG (mirrored) | Round-1 IFVG | Consistent (kernel `MSNR_IsBodyBreak` = close strictly beyond the far boundary) |
| §6.2 bullish change = close above the anchor of a **bearish** delivery | Round-1 CISD | Consistent in intent, ambiguous wording — F-4 |
| §6.2 detailed run/anchor must follow the Bangwik material; do not force a signal | — | **Gap F-5** (our N=0 approximation measured at 689 CISD bars/day) |
| §7.1 sell E1<E2<E3, buy E1>E2>E3, all inside the zone | Order intent | Consistent |
| §7.2 no numeric spacing, no order type, no partial-fill rule yet | Round-2 order type + round-3 spacing + unfilled-layer rule | Closed by owner decisions |
| §8.1 extreme wick of the whole touch chain, not only the last candle | Round-3 SL anchor window | Consistent, but the window's endpoint interacts with F-7 |
| §8.1 buffer beyond the wick not defined | Round-2/3 ± 2 ticks | Closed by owner decision |
| §8.2 clamp at 50 pips, setup proceeds, clamp may sit inside the wick | Round-3 clamp rule | Consistent after arbitration |
| §8.3 examples 4120→4115 / 4120→4125 | Round-3 cap anchor = E1 | Consistent (recomputed, see §2) |
| §9.1 TP1 closes E1 and activates SL+ for E2/E3 | Round-3 SL+ | Consistent |
| §9.2 SL+ formulas per layer | Round-3 SL+ | Consistent (recomputed) |
| §9.3 management order; the earlier "+25 pips" trigger is void | Order intent (+30) | Consistent |
| §10 buy/sell numeric examples | Round-3 math | Consistent (recomputed, see §2) |
| §11.1 pip convention 10 pips = 1.00 | Chart roles | Consistent (10/30/50/100 pips = 1.00/3.00/5.00/10.00 = 100/300/500/1000 points at point=0.01) |
| §11.2 basket risk = tick value × 0.15 × (d1+d2+d3) | — | **Gap F-8** (EA must log it; money cap still undefined per §13) |
| §11.4 stop price is a trigger, not a fill guarantee | — | Consistent with v1 scope (no extra filters) |
| §12 before/after checklist | Round-1..3 rules | Consistent |
| §13 list of still-open rules | §3 below | Tracked, not invented |
| §2.1 the indicator is not read by other scripts | — | **Divergence D-4** |

## 2. Independent recomputation of the guide's numbers

`tests`-style script `/tmp/opencode/audit_angka.py` (pip = 0.10 price units):

```
BUY  E1 4120.0 E2 4119.5 E3 4119.0
  SL structural 4116.5 -> structural 4116.5 | dist to E1 3.50 | below E3? True
  SL structural 4114.0 -> CLAMPED  4115.0  | dist to E1 5.00 | below E3? True
  TP  E1 4123.0  E2 4124.5  E3 4129.0
  SL+ E2 4120.5  E3 4120.0
SELL E1 4120.0 E2 4120.5 E3 4121.0
  SL structural 4123.5 -> structural 4123.5 | dist to E1 3.50 | above E3? True
  SL structural 4126.0 -> CLAMPED  4125.0  | dist to E1 5.00 | above E3? True
  TP  E1 4117.0  E2 4115.5  E3 4111.0
  SL+ E2 4119.5  E3 4120.0
```

Guide §10.1/§10.2 reproduce exactly. "Entry farthest from SL = E1" holds in both directions under fill-order labels (buy: E1 highest, SL below; sell: E1 lowest, SL above).

**Geometric edge case (F-7, high impact).** The clamped SL is anchored at E1, but a shared SL must also sit beyond the *nearest* entry (E3):

```
zone width 0.50 -> E1 4120.0 E3 4119.5 | clamp 4115.0 | valid (SL < E3)? True
zone width 4.00 -> E1 4120.0 E3 4116.0 | clamp 4115.0 | valid (SL < E3)? True
zone width 5.00 -> E1 4120.0 E3 4115.0 | clamp 4115.0 | valid (SL < E3)? False
zone width 6.00 -> E1 4120.0 E3 4114.0 | clamp 4115.0 | valid (SL < E3)? False
```

A zone ≥ 5.00 wide makes the guide's own cap produce a stop on the wrong side of E3 — an order the broker rejects.

## 3. Findings

Severity: **S1** = blocks correct execution, **S2** = changes setup frequency materially, **S3** = hygiene.

- **F-1 (S2) — POI eligibility was never written down.** §4/Tahap A make *fresh* the qualifier ("area fresh hanya membuat POI layak diamati"), but the spec never says which POI states may start a setup. The replica's lifecycle (§ `msnr-replica-spec.md` rule 4) marks a level `UNFRESH` as soon as a source-TF bar wicks into its band, `BROKEN` on a close beyond the far boundary, and `FLIPPED_*` when the role inverts. Proposal: only `FRESH`/`FLIPPED_FRESH` POIs (evaluated on the last **closed** source-TF bar) may start a setup; `BROKEN` disqualifies; `UNFRESH` is ineligible. *Applied to the spec as an owner-visible proposal, pending veto.*
- **F-2 (S1) — plan direction was never derived.** The spec says "confirmation aligned with the plan direction" but never says how the direction is chosen. Derivable from the kernel's role: `MSNR_ROLE_SUPPORT` → buy plan, `MSNR_ROLE_RESISTANCE` → sell plan (gap zones map bullish FVG→support, bearish FVG→resistance). Without this, the EA cannot decide which confirmations qualify. *Applied.*
- **F-3 (S2) — bar ordering was implicit.** The guide requires touch → confirmation → retest in that order; mechanically the confirmation bar index must be strictly greater than the touch bar index, and the retest bar index strictly greater than the confirmation bar index. Without the second inequality, the breaking candle's own wick (which passed through the zone before it closed) could arm the orders. *Applied.*
- **F-4 (S3) — CISD wording is ambiguous.** "anchor = open of the first candle of the latest same-direction delivery run" can be read as "a run in the same direction as the signal", which is the opposite of guide §6.2 (bullish change uses the anchor of a **bearish** delivery). *Applied: explicit direction table.*
- **F-5 (S2, owner decision) — the CISD approximation is close to a tautology.** Measured on 750,062 HFM M1 bars:

  | definition | min run | CISD bars/day | share of M1 bars |
  |---|---|---|---|
  | same-colour run | 1 | 688.6 | 47.8% |
  | same-colour run | 2 | 326.0 | 22.6% |
  | same-colour run | 3 | 234.1 | 16.3% |
  | delivery run (higher-high & higher-low) | 1 | 535.0 | 37.2% |
  | delivery run | 2 | 282.8 | 19.6% |
  | delivery run | 3 | 209.5 | 14.5% |

  With the frozen `N=0` (equivalent to a 1-candle run) a confirmation exists on roughly half of all M1 bars, so CISD filters almost nothing; the effective filter becomes the touch+retest sequence. Guide §6.2 explicitly refuses to force a signal when the anchor is unclear. The `min run` must therefore be an input and the value must be chosen on evidence — the frozen `N=0` is exactly the "false positives appear" trigger named in round 1. *Owner decision D-2.*
- **F-6 (S3) — M1/M2/M3 conflict priority is undefined** (guide §13 lists it as open). Proposal: monitor all three; the earliest valid confirmation after the touch, per direction, defines the confirmation zone; one setup per direction. *Applied as an EA-local rule, flagged for veto.*
- **F-7 (S1, owner decision) — shared-SL geometry can be unexecutable.** The guide anchors the SL at the touch-chain extreme, but in the canonical buy flow (POI touch → break down → IFVG below the POI → retest from above) that extreme sits **above** the entry zone, i.e. between E1/E3 or even above them, so a single shared SL cannot be attached to all three buy limits (broker rejects a buy limit whose SL is above its price). Same mirrored for sells. Also, zone width ≥ 5.00 makes the 50-pip cap itself produce an invalid stop (§2). Resolution must be either (i) extend the SL anchor window to the arming moment over **all** candles in the window (the arming/retest wick then defines the true excursion and is usually beyond the zone), or (ii) keep the literal guide anchor and skip such setups. *Owner decision D-1.*
- **F-8 (S3) — basket risk is computable but not yet logged.** §11.2 gives the formula; the EA must log `tickValue × 0.15 × (d1+d2+d3)` in account currency. The per-pip money value still has to be read from the live HFM contract spec (published Cent spec suggests contract 1.0 and 0.01 USD/tick/lot — unverified on the account). §13 leaves the money cap undefined, so v1 logs the number and refuses to trade until the owner sets a cap.
- **F-9 (S2) — a POI role flip invalidates the premise of an open setup.** The replica flips a broken level's role (RBS/SBR) instead of killing it. A setup planned as a sell at resistance must not survive the resistance becoming support. The spec's cancel trigger only names `BROKEN`. *Owner decision D-3.*
- **F-10 (S3) — price-grid hygiene.** Layer prices must be rounded to the tick (`0.01`) and remain strictly ordered; a zone thinner than 2 ticks cannot hold three distinct limits (round-3 guard) and rounding must not collapse E1/E2/E3. *Applied.*
- **F-11 (S3) — session/break handling.** The EA must consume closed bars only. HFM `XAUUSDc` has a daily break 00:00–01:00 server time with no bars, and the last bar of the day stays forming until the first post-reopen tick, so no events may be derived from it. *Applied as a bar-validity rule.*
- **F-12 (S3) — wording leftovers.** Round 1 still contained "or the aligned signal reverses" (superseded by round 2) and "SL does not change after arming" (must be qualified by the TP1 lock). *Applied.*

### Divergence D-4 (scope, not a rule conflict)

Guide §2.1 states the TradingView indicator is the POI map and that "Alphatom tidak menghitung ulang level POI dari swing sendiri". The EA necessarily derives POIs itself, because MT5 cannot read a TradingView indicator; it uses the validated MT5 MSNR replica as the POI map. Consequence: the EA's POI set may differ from the TV chart, which is one more reason the HFM multi-session validation of the replica is a hard prerequisite before any live use.

## 4. Open items (guide §13) — deliberately not invented

Priority among M1/M2/M3 (F-6 proposes a mechanical default) · money-risk cap per setup/day (F-8 logs only) · handling of partial fills, gaps, extreme spread, news, sessions · TP "touch" vs actual fill · buffer beyond the wick (owner set 2 ticks) · zone width and retest tolerance (owner set) · order type (owner set: GTC limit).

**Status after the long backtest (2026-10-21, `docs/backtest-report.md`):**

| Open item | Status |
|-----------|--------|
| money-risk cap per setup | **decided**: 440 USC (`InpRiskCapMoney`); the per-day cumulative cap is still open |
| priority among M1/M2/M3 | mechanical default in force (earliest valid confirmation wins per direction) |
| order type, buffer, zone width, retest tolerance | decided by the owner and frozen in the spec |
| handling of partial fills, gaps, extreme spread, news, sessions | **still open** — the backtest shows the spread alone moves the expectancy from −1.94 to −3.95 USC |
| TP "touch" vs actual fill | targets are native broker orders; the backtest charges the spread on the round trip |

**The backtest verdict:** the frozen specification has **no edge**. Over 13.5
months of real HFM data the expert would have traded 21 037 positions with a
41.8 % win rate, a profit factor of 0.901 and an expectancy of −1.94 USC per
position (≈ 7.5 standard deviations below zero). Every variant tried is
negative as well. The implementation is faithful; the parameters are the
problem.

## 5. Decisions requested from the strategy owner — RESOLVED 2026-10-21

- **D-1 (F-7, S1):** **RESOLVED — extend the anchor window to the arming moment over all candles.** The structural SL is the extreme wick of every candle from the first POI touch to the arming bar (± 2 ticks); after the 50-pip clamp the SL must still sit beyond the far entry E3, otherwise the setup is skipped with a log line (no invalid stop is ever sent). Recorded as round-4 rule D-1 in `docs/ea-execution-spec.md`.
- **D-2 (F-5, S2):** **RESOLVED — same-colour delivery run with a minimum of 2 candles** (`CISDMinRun` default 2, exposed as an input; 326 CISD bars/day on HFM M1 versus 689 at the frozen N=0). A doji breaks the run. Recorded as round-4 rule D-2.
- **D-3 (F-9, S2):** **RESOLVED — yes, a POI role flip cancels the open setup** (unfilled layers removed, filled layers keep their own SL/TP as on the Broken path). Recorded as round-4 rule D-3.
- **D-4 (owner, 2026-10-21):** **RESOLVED — only one direction may hold the market at a time.** While a side has live orders resting or exposure, the opposite side's setup is cancelled (reason `OPPOSITE`) and its resting orders are deleted; a setup that already carries exposure is never cancelled this way. Motivation: the first live run opened a SELL basket at 17:48 and a BUY basket at 17:51 on the same whipsaw and both were stopped out (−134.10 USC). The long backtest shows the rule is neutral for the expectancy (PF 0.899 with, 0.901 without), so it is kept for the exposure protection, not for the P&L.
- **D-5 (backtest finding, 2026-10-21):** **RESOLVED — a POI level that leaves the map cancels the setup that had no exposure** (reason `POI_GONE`, resting GTC orders deleted). The POI map keeps only the newest levels per timeframe; without this rule a basket that never fills keeps its setup and its orders alive for ever and blocks that direction. A setup with exposure keeps running so the money is still managed. Recorded in the execution spec and covered by two kernel test groups.
- **D-6 (backtest verdict, 2026-10-21):** **the frozen specification has no edge** — 21 037 positions over 13.5 months of real HFM data, 41.8 % win rate, profit factor 0.901, expectancy −1.94 USC per position (≈ 7.5 standard deviations below zero); every variant (spread 0.50/1.00, M2, M3, H1-only, D-4 on) is negative as well. The implementation is faithful, the parameters are the problem. Full analysis and the harness that reproduces it: `docs/backtest-report.md`.
- **D-8 (live finding, 2026-10-22):** **the one-side gate must ask about the opposite side.** `EaSideHoldsMarket(isBuy)` is called with `!isBuy` at both call sites, so the body has to map `isBuy` to the **buy** setup and the fall-through to the **sell** setup. The body was inverted (`isBuy` → the sell setup), so every check asked the arming side about **itself**: a basket that had just been armed was immediately cancelled with reason `OPPOSITE` before a single order went out, and the D-4 whipsaw protection was never actually applied either. Live evidence: every `ARM` in the journal is followed by `CANCEL reason=OPPOSITE(9)` and there is not one `ORDER_PLACED` / `ORDER_MARKET` line in the whole log — the expert has not traded since D-4 was introduced. This also explains the earlier live run (6 positions, −134.10 USC), which happened *before* D-4 existed. Fix: the body now matches the parameter, with two contract tests (*the one-side gate asks about the other side*, *the arm path is not blocked by its own setup*). Commit `d5a1c1e`.
- **D-9 (audit finding, 2026-10-22):** **the state file name carries the symbol and the magic** (`MQL5/Files/Alphatom_state_<symbol>_<magic>.csv`). The frozen spec names the base name `Alphatom_state.csv`; the file name is an implementation detail of the restart recovery, not a strategy rule, and a fixed name lets two instances of the expert (two symbols, or the same symbol twice) overwrite each other's state and restore a setup whose price levels belong to another chart. The spec text is left untouched; the divergence is recorded here. The same audit round also closed: the zero-range bar filter of spec F-11 (a bar without a range may not start, confirm or retest anything — kernel groups *a zero-range bar cannot start a setup* / *cannot invert a gap* / *cannot retest*), the gap-detection tolerance of the IFVG detector (it now uses the same `InpGapToleranceTicks` as the POI map, so the chart and the expert invert the same gaps), the rebuild of the expert config from the live symbol on every bar, and the `DONE_PARTIAL` handling.
- **D-7 (live finding, 2026-10-22):** **the expert must wait for the broker connection instead of refusing the start-up.** The terminal initialises an expert while the connection is still being established, so the symbol specification and the account margin mode are unknown at that moment. `OnInit` used to return `INIT_FAILED` in that case, and MT5 removes an expert whose `OnInit` fails **without ever re-attaching it** — after every terminal restart the whole strategy stopped silently. Observed live: the terminal restarted at 08:07, the journal showed `initializing of Alphatom_EA (XAUUSDc,H1) failed with code 1` followed by `expert Alphatom_EA (XAUUSDc,H1) removed`, and the state file stopped being written from 08:05. The setup that was waiting for its retest was then lost, because its H1 POI level aged out of the map (`POI_GONE`). Resolution: `OnInit` now waits (`INIT_SUCCEEDED` + a 5-second timer), the symbol/account state is re-checked from `OnTick` and `OnTimer`, and the restart recovery only runs once the terminal is in sync (the recovery compares the state file with the broker's positions and resting orders, which are only known after the sync). A permanently wrong account type (a non-hedging account) still refuses the start-up. Evidence: commit `2d7b05a`, contract tests *init does not die when the broker is not connected yet* / *recovery runs only after the broker state is known*, and the live journal of 2026-10-22 09:15 (`ALPHA A ready: the terminal is synchronized with the broker` → `recovery: 1 setup(s) restored` → `init: shadow=false`).
- **D-10 (live finding, 2026-10-22):** **a closing deal does not carry the order comment.** The broker writes its own (`[sl 4112.11]`, `[tp 4115.23]`), so the layer could not be parsed and the close was dropped silently. Observed live: the SELL basket of 09:44 was closed by the broker at its TP1 (4115.23) at 10:00, the expert never recorded it, the state file went stale and the next restart refused the live start. Resolution: the layer is recovered from the deal that **opened** the position (`DEAL_POSITION_ID` → the IN deal keeps the order comment); a deal that still cannot be mapped is reported as `UNMAPPED`. Commit `ea1fce8`.

## 5b. SOP conformance matrix (2026-10-21)

Every frozen rule of `docs/ea-execution-spec.md` against the implementation.
**Conforming** means the code behaves as the rule says and the behaviour is
covered by a test. **Open** means the rule is deliberately not implemented yet
(guide §13) and is listed as such.

| # | Rule (spec) | Status | Evidence |
|---|-------------|--------|----------|
| 1 | Touch = a wick on M1/M2/M3 enters the POI (swing level or gap band) | conforming | `Exec_Advance` IDLE phase, `MSNR_TouchesZone`; kernel group *touch starts setup only on fresh POI* |
| 2 | Confirmation strictly after the touch bar | conforming | detection called with `afterIndex = touchIndex`; group *confirmation before touch is ignored* |
| 3 | Confirmation = IFVG or CISD, aligned with the plan; earliest wins, IFVG priority on a tie | conforming | `Exec_Advance` TOUCHED phase, `confirmKind` logged; groups *IFVG uses first break only*, *confirmation tie prefers IFVG* |
| 4 | Retest strictly after the confirmation bar, wick touch of the zone edge, no depth or close requirement | conforming | `Exec_Advance` CONFIRMED phase; group *retest must be after confirmation bar* |
| 5 | IFVG = close through the far FVG boundary, wick alone never flips it | conforming | `MSNR_IsBodyBreak`; groups *IFVG requires close through far boundary*, *ignores wick only break* |
| 6 | CISD = anchor = open of the first candle of the latest delivery run, min run 2, doji breaks the run (D-2) | conforming | `Exec_DetectCISD`; groups *anchor is first candle of run*, *min run enforced*, *doji breaks run* |
| 7 | Entry zone = full IFVG zone, or the 3-bar M1 band around the anchor bar, width-clamped | conforming | `Exec_BuildIfvgEntryZone`, `Exec_BuildCisdEntryZone`; groups *entry zone for IFVG*, *for CISD uses three bar band* |
| 8 | Layer lifetime: orders placed at the first zone touch, cancelled when the POI breaks | conforming | `Exec_Advance` ARMED branch, `Exec_CancelPending`; group *cancel on broken POI removes unfilled only* |
| 9 | Shared SL = extreme wick of the touch chain ± 2 ticks (D-1 window: first touch bar → arming bar, every candle in it) | conforming | `Exec_Advance` CONFIRMED phase window loop; group *shared SL uses window extreme not last candle* |
| 10 | 50-pip cap = clamp, never a skip | conforming | `Exec_ComputeSharedSL`; group *clamps to fifty pips from E1* |
| 11 | Validity guard: the final SL must sit beyond E3, else skip with a log | conforming | `Exec_ComputeSharedSL`; groups *skips when not beyond far entry*, *arm skips when stop not beyond far entry* |
| 12 | Layers = equal thirds, E1 at the first-touched edge, all inside the zone, tick-rounded, strictly ordered | conforming | `Exec_ComputeLayers`; groups *layers are equal thirds and ordered*, *layer price hygiene* |
| 13 | Zone-width guard ≥ 2 ticks, else skip | conforming | `Exec_ComputeLayers`; group *layers reject too narrow zone* |
| 14 | SL+ after TP1 = +10 pips from each layer's own entry | conforming | `Exec_RecordClose`; groups *TP1 lock cancels unfilled and sets SL+*, *restored setup still locks the stop after TP1* |
| 15 | Unfilled layers cancelled on the TP1 lock and on any cancel event | conforming | `Exec_RecordClose`, `Exec_CancelPending`; groups *TP1 lock cancels unfilled*, *cancel on broken POI* |
| 16 | POI eligibility: only FRESH / FLIPPED_FRESH may start a setup | conforming | `Exec_Advance` IDLE phase, `Exec_TryStartSetup` in the expert; group *touch starts setup only on fresh POI* |
| 17 | Plan direction from the POI role (support → buy, resistance → sell) | conforming | `Exec_InitSetup`; group *one active setup per direction* |
| 18 | F-10 layer price hygiene (tick grid, strict order, inside the zone) | conforming | `Exec_ComputeLayers`; group *layers are equal thirds and ordered* |
| 19 | F-11 closed bars only, no forming/zero-range bar | conforming | the expert copies `copied - 1` closed bars; group *snapshot* / contract test *only closed bars are used* |
| 20 | F-6 all three execution timeframes monitored, earliest valid confirmation per direction | conforming | `InpExecTimeframe` gate + the indicator's POI map; the harness drives the same kernel |
| 21 | D-4 one side at a time (OPPOSITE cancel, exposure never cancelled) | conforming | `Exec_CancelForOpposite`; groups *cancel for opposite stops the setup*, *keeps a filled layer alive*. The expert-side gate must ask about the **opposite** side (D-8): `EaSideHoldsMarket`; contract tests *the one-side gate asks about the other side*, *the arm path is not blocked by its own setup* |
| 22 | POI_GONE: a setup without exposure dies when its POI leaves the map | conforming | `Exec_CancelForMissingPoi`; groups *missing POI cancels a setup without exposure*, *keeps a setup with exposure* |
| 23 | Restart recovery: the setups are persisted and restored, validated against the broker | conforming | `Exec_TakeSnapshot` / `Exec_RestoreSnapshot` + `Alphatom_state_<symbol>_<magic>.csv` (D-9); groups *snapshot round trip*, *stale setup drops*; verified live on the terminal. The recovery runs only after the terminal is in sync (D-7): `EaTryBecomeReady` / `EaInitLive`; contract tests *init does not die when the broker is not connected yet* / *recovery runs only after the broker state is known* |
| 24 | F-8 basket risk logged in the deposit currency from the live contract spec | conforming | `Exec_ComputeBasketRisk` + `EaMoneyPerPipPerLot`; group *basket risk uses all three distances* |
| 25 | Money cap per setup (owner: 440 USC) | conforming | `ExecConfig.riskCap`; group *arm skips when basket risk exceeds cap* |
| 26 | Order type: simple GTC limits, no broker expiry, cancellation is EA logic | conforming | `EaLivePlaceBasket` (`ORDER_TIME_GTC`), `EaLiveCancelPendings` |
| 27 | Marketable layers at arming are executed at market, the rest stay GTC limits | conforming | `EaLivePlaceBasket`, `EaShadowArmFills`; contract test *marketable layers are executed not left invalid* |
| 28 | Scope divergence: the EA uses the MSNR replica, not the TradingView POI map | documented | spec D-4 (scope divergence) |
| 29 | Daily cumulative loss cap (per day) | **open** | guide §13; not implemented |
| 30 | Partial-fill policy, gap/slippage on exits | **open** | guide §13; not implemented |
| 31 | Extreme-spread filter | **open** | guide §13; the backtest shows the spread is the largest single lever (PF 0.901 → 0.815) |
| 32 | News filter, session filter | **open** | guide §13; not implemented |
| 33 | TP "touch" vs actual fill semantics | **open** | the targets are native broker orders, so the broker decides; not modelled beyond that |

**Summary:** 28 of the 33 rules are implemented and covered by tests, and the
whole chain is verified live (TOUCH → CONFIRM → ARM → fill → SL/TP, plus the
restart recovery). The five open rows are the guide §13 items that were never
invented, plus the daily loss cap.

**Conformance is not profitability.** The long backtest
(`docs/backtest-report.md`) shows that the frozen rules are implemented
faithfully and still lose money: profit factor 0.901 over 21 037 positions on
real HFM data.

## 5c. Known open deviations from the frozen spec (audit 2026-10-22)

An independent audit of the expert against the frozen specification found the
following deviations that are **not yet closed**. They are listed here so the
repository never claims more than it delivers.

| # | Spec rule | What the code does | Consequence | Status |
|---|-----------|--------------------|-------------|--------|
| A-1 | **F-6 — all three execution timeframes (M1/M2/M3) are monitored**; the earliest valid confirmation per direction defines the confirmation zone | the expert monitors **one** execution timeframe, chosen by `InpExecTimeframe` (the live instance uses M1) | a setup whose confirmation exists only on M2 or M3 is never detected, so the expert misses valid trades | **open** — needs three bar series and three anchors per direction |
| A-2 | **F-10 — the layer prices are rounded to the tick grid and must stay inside the entry zone**; if the rounding pushes a layer out of the zone the setup is skipped | the zone of a CISD is built from the raw band, so an off-grid zone width (an odd multiple of the tick size) can skip a setup for a purely cosmetic reason | a setup is skipped although its geometry is valid | **open** — the default zone widths (0.20 / 2.00) are on the grid, so the default configuration is unaffected |
| A-3 | **Restart recovery — a missing or unreadable state file refuses the live start** (spec, line 68) | implemented as specified | with real money open, a lost state file parks the expert in shadow and the position is no longer managed | **by design (spec)** — the operator resets the state file with the terminal stopped, see `docs/ea-deployment.md` §5.0 |
| A-4 | **The shared-SL window starts at the first POI touch bar** (D-1) | the window starts at the bar on which the expert started the setup | the expert checks every closed bar, so the setup starts on the first bar whose wick touches the POI — the two readings only differ when a level was touched earlier while it was not eligible | **interpretation recorded** — the reading used is the setup's own touch chain |
| A-5 | **F-8 — the basket risk uses the live contract specification** | `SYMBOL_TRADE_TICK_VALUE_LOSS` and `SYMBOL_TRADE_TICK_VALUE` are **0** on this account, so the money-per-pip falls back to `contract × 10.0` USC/pip/lot | the money cap compares against a published-web constant, not a measured tick value | **open** — the fallback is documented in `docs/ea-deployment.md` §4 |

## 6. Evidence artifacts

- `/tmp/opencode/audit_angka.py` — guide example recomputation, pip/point mapping, zone-width geometry.
- `/tmp/opencode/audit_cisd.py`, `/tmp/opencode/audit_cisd2.py` — CISD frequency measurement on HFM M1 (750,062 bars).
- HFM source of the M1 history: `MQL5/Files/XAUUSD_HFM_M1_20261015_022415_482518984.csv` (exported 2026-10-15 from the live HFM Cent `XAUUSDc`).
