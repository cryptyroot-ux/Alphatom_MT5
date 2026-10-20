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

## 5. Decisions requested from the strategy owner

- **D-1 (F-7, S1):** how to keep the shared SL executable — extend the anchor window to the arming moment over all candles, or keep the literal touch-chain anchor and skip setups whose SL is not beyond the far entry.
- **D-2 (F-5, S2):** the CISD minimum delivery-run length for v1 (`0` as frozen, or `2` recommended on the measured evidence; exposed as an input either way).
- **D-3 (F-9, S2):** whether a POI role flip cancels an open setup (recommended: yes).

## 6. Evidence artifacts

- `/tmp/opencode/audit_angka.py` — guide example recomputation, pip/point mapping, zone-width geometry.
- `/tmp/opencode/audit_cisd.py`, `/tmp/opencode/audit_cisd2.py` — CISD frequency measurement on HFM M1 (750,062 bars).
- HFM source of the M1 history: `MQL5/Files/XAUUSD_HFM_M1_20261015_022415_482518984.csv` (exported 2026-10-15 from the live HFM Cent `XAUUSDc`).
