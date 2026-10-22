# Alphatom — long backtest report

**Date:** 2026-10-22 (data refreshed; the recorded bars now end 2026-10-22)
**Instrument:** HFM CENT `XAUUSDc` (1 oz contract, `USC` deposit currency, hedging)
**Data:** the broker's own history, exported from the live terminal
**Harness:** `tests/backtest.cpp` (`make backtest`), driving the same
`ExecKernel.mqh` / `MSNRLevels.mqh` code the live expert uses

---

## 1. Verdict

**The strategy as specified has no edge. It is statistically significantly
negative.**

Over the full sample the expert would have lost money on every variant that
was tried: profit factors between **0.813 and 0.933**, expectancy between
**−1.37 and −3.99 USC per closed position**, and a peak drawdown of up to
**86 683 USC** — forty times the size of the 2 154 USC account it was run on.

The first live run agrees with the backtest: two baskets, both stopped out,
**−134.10 USC** in a single evening.

**Recommendation: do not trade this strategy with real money in its current
form.** Use the backtest harness to test changes before they touch the
account.

---

## 2. Data and its limits

| Series | Bars | Range |
|--------|------|-------|
| M1 (execution) | 399 999 | 2025-09-04 → 2026-10-22 (413 calendar days) |
| M15 | 199 999 | 2017-12-13 → now |
| M30 | 106 206 | 2017-12-13 → now |
| H1 | 56 854 | 2017-12-13 → now |

**The M1 history is the binding limit.** The broker only keeps ~13.5 months
of M1 for this cent symbol, so the backtest covers 13.5 months, not the
multi-year M15/H1 history that is available. There is no M1 data before
2025-09-04, which is why the POI timeframes reach further back than the
execution timeframe.

The M1 series is also **sparse**: 399 999 bars over 413 calendar days is
about 968 bars per day, not the 1 440 a continuously quoted market would
print. All frequencies below are therefore given per bar as well as per
calendar day.

The POI map is always built from the newest 1 500 closed POI bars, exactly as
the live expert does, so the map is never short of history.

## 3. Method

The harness reproduces the live expert's mechanics:

* the execution window **slides** (the last 399 closed M1 bars are re-copied
  on every bar, so stored bar indices shift — the kernel anchors on bar times),
* the POI map is **rebuilt when a POI timeframe closes a bar**,
* one setup per direction, POI role decides the direction (support → buy),
* a fresh or flipped-fresh POI must be touched by the newest closed bar,
* the confirmation must be an IFVG or CISD on a later bar, the retest must
  touch the entry zone edge, the shared stop is the extreme wick of the touch
  chain ± 2 ticks clamped to 50 pips from E1, targets are +30/+50/+100 pips
  from each layer's own fill, TP1 cancels the pending layers and locks the
  remaining stops at +10 pips,
* the money cap (440 USC) skips a setup whose basket risk is too large,
* the one-side-at-a-time rule (owner decision D-4) is applied,
* order lifecycle: GTC limits, immediate market fills for layers that are
  already beyond the market, per-layer targets, the TP1 lock.

**Conservative assumptions** (bar data cannot resolve the intrabar path):

* the stop is assumed to be hit **before** a target inside the same bar,
* a limit fill is **skipped** when the same bar also reaches the stop,
* market fills pay half the spread.

**Optimistic assumptions** (these flatter the result):

* limit orders fill exactly at their price, with no slippage and no requote,
* the stop and the target fill exactly at their price, with no gap risk,
* commission is zero (the account's deals show 0.00 commission).

**Known harness gap.** When a basket closes on the same bar on which a new
POI is touched, the harness loses that touch: the new-setup search for that
direction runs at the start of the bar, while the closing of the old basket
happens at the end of it. The live expert does not have this gap — the broker
delivers the close through `OnTradeTransaction`, which is independent of the
bar loop, so the touch is caught on the next bar. The harness is therefore
slightly conservative: it trades marginally fewer setups than the live expert
would. This was observed on 2026-10-22 at epoch 1792630800, where the live
expert registered an H1 touch that the harness attributed to the still-open
opposite basket.

## 4. Results

### 4.1 Main run (M1 execution, spread 0.34, all POI timeframes)

| Metric | Value |
|--------|-------|
| POI touches | 11 293 |
| Confirmations | 9 166 |
| Armed baskets | 8 236 |
| Closed positions | **21 015** |
| Wins / losses | 8 749 / 12 266 (win rate **41.6 %**) |
| Gross profit / gross loss | 368 025 / 408 964 USC |
| **Net** | **−40 939 USC** (−27 292 pips) |
| **Profit factor** | **0.900** |
| **Expectancy** | **−1.95 USC per position** |
| Average win / average loss | 42.06 / 33.34 USC |
| Largest win / largest loss | 150.00 / 77.55 USC |
| **Max drawdown** | **45 711 USC** |
| Average holding time | 11 bars |
| TP1 hits | 3 622 |
| Setups cancelled, POI gone | 636 |

With 21 015 positions the standard error of the expectancy is ≈ 0.26 USC,
so the result is about **7.6 standard deviations below zero** — the loss is
not a sampling accident.

### 4.2 Variants

| Variant | Positions | Win % | PF | Net (USC) | Max DD (USC) | Expectancy |
|---------|-----------|-------|----|-----------|--------------|------------|
| M1, spread 0.34, D-4 off (base) | 21 015 | 41.6 | 0.900 | −40 939 | 45 711 | −1.95 |
| M1, D-4 **on** (current code) | 18 151 | 41.6 | 0.898 | −36 315 | 42 547 | −2.00 |
| M1, spread 0.50 | 21 020 | 41.4 | 0.879 | −50 753 | 54 984 | −2.41 |
| M1, spread 1.00 | 21 154 | 40.4 | 0.813 | −84 375 | 86 683 | −3.99 |
| M2 execution | 11 448 | 47.2 | 0.878 | −29 208 | 29 931 | −2.55 |
| M3 execution | 8 230 | 51.8 | 0.933 | −11 253 | 17 111 | −1.37 |
| H1 POI only | 7 820 | 44.1 | 0.932 | −10 435 | 15 841 | −1.33 |

**Every variant loses.** The spread is the biggest single lever: at a spread
of 1.00 the strategy loses four times as much. The one-side rule (D-4)
changes almost nothing (PF 0.898 vs 0.900) — it is not the problem.

### 4.3 Where the money is lost (base run)

| Group | Positions | Win % | Net (USC) |
|-------|-----------|-------|-----------|
| BUY | 10 400 | 41.9 | −20 262 |
| SELL | 10 615 | 41.4 | −20 677 |
| POI M15 | 11 103 | 41.0 | −27 516 |
| POI M30 | 5 509 | 42.3 | −4 610 |
| POI H1 | 4 403 | 42.5 | −8 813 |
| IFVG confirmation | 16 262 | 41.9 | −33 372 |
| CISD confirmation | 4 753 | 40.8 | −7 566 |

No subgroup is profitable. The M15 POIs and the IFVG confirmation are the
worst, but the whole curve sits below 1.0.

## 5. A live bug the backtest exposed

The first backtest runs produced an implausible result (only 4 months of
trading out of 13.5). The diagnostic trace showed both setups frozen in the
`ARMED` phase for the whole sample:

```
[dbg] step=10000  buy=ARMED link_created=1757586600 | sell=ARMED link_created=1757908800
[dbg] step=220000 buy=ARMED link_created=1757586600 | sell=ARMED link_created=1757908800
```

**Cause.** The POI map keeps only the newest 8 levels per timeframe. When the
level of a running setup is evicted, the lookup by its creation time fails,
the POI state freezes on its last known value, and the "POI broken" cancel can
never fire. The setup therefore stays `ARMED` for ever: its resting GTC
orders survive indefinitely and that direction is blocked for the rest of the
data.

**Fix.** A setup without exposure is now cancelled when its POI level leaves
the map (`EXEC_REASON_POI_GONE`), and its resting orders are deleted. A setup
that already carries exposure keeps running, because that money still has to
be managed to its target or its stop.

This bug was live in the deployed expert as well: a basket that never fills
would have kept its GTC orders resting forever and blocked that direction
until the next terminal restart. The fix is deployed (`5864a53`, kernel
`EXEC_REASON_POI_GONE`, 2 new test groups).

**Note on the earlier numbers.** Any backtest result obtained before this fix
is invalid: the dead period silently removed trades from the sample.

## 6. Why the strategy does not work (measured, not guessed)

The mechanics are internally consistent — the expert implements the frozen
specification faithfully, which the test suite verifies — but the geometry of
the specification leaves no edge. Every number below is measured by the
harness on the base run (M1, spread 0.34, D-4 off, 21 015 positions).

### 6.1 The shared stop is *not* mostly the 50-pip cap

| Measurement | Value | Spec reference |
|---|---|---|
| Average distance E1 → shared SL | **33.7 pips** | spec §7 / D-1: structural SL (extreme wick of the touch chain ± 2 ticks) |
| Setups where the 50-pip cap actually bound | **2 098 of 8 236 (25 %)** | spec §7: the cap is a clamp, not a skip |
| Average loss per closed position | **33.34 USC ≈ 22.2 pips** | 1.50 USC per pip per layer |

The 22-pip average loss is *not* the stop distance. Three effects shorten it:

1. the stop is shared, so E2 and E3 sit closer to it than E1 does (the
   average is taken over all three layers);
2. a layer that is already beyond the market when the basket is armed is
   filled at the market (spec, marketable-layer clarification), which is a
   better price than the nominal layer price;
3. the validity guard (spec D-1: the SL must sit beyond E3) skips setups
   whose stop would land on the wrong side.

So the stop is a *real* structural stop in three quarters of the setups, and
the 50-pip cap is a genuine but minority clamp.

### 6.2 The wins are a mix of targets and the TP1 lock

| Exit | Count | Average | Note |
|------|-------|---------|------|
| Target reached (TP1/TP2/TP3) | **5 175** | **60.76 USC ≈ 40.5 pips** | spec §6: +30 / +50 / +100 pips from each own fill |
| Closed by the +10-pip SL+ lock (a win) | **3 574** | **15.00 USC = 10.0 pips** | spec §9 / line 47: after TP1 the E2/E3 stop is locked at +10 pips |
| Closed by a real stop (a loss) | 12 266 | 33.34 USC ≈ 22.2 pips | |
| **Total** | **21 015** | **42.06 USC ≈ 28.1 pips per winner** | |

The TP1 lock does not truncate the target wins — it converts a *running*
winner into a +10-pip win: 3 574 of the 8 749 winners (41 %) are E2/E3
positions that were stopped at the locked stop after E1 had already hit its
target. That is exactly what the specification asks for, and it is what
pulls the average winner down from 40.5 pips (the target winners) to 28.1
pips (all winners).

### 6.3 The break-even arithmetic

| Quantity | Value |
|----------|-------|
| Win rate | 41.6 % |
| Required average win / average loss for break-even | `(1 − 0.416) / 0.416` = **1.404×** |
| Delivered average win / average loss | `42.06 / 33.34` = **1.262×** |
| Gap | **−10 % relative** → expectancy **−1.95 USC per position** |

The strategy needs a 1.40× payoff and delivers 1.26×. At 21 015 positions the
standard error of the expectancy is ≈ 0.26 USC, so the shortfall is ≈ 7.6
standard deviations — the loss is structural, not noise.

### 6.4 Costs remove the remainder

| Spread | Positions | PF | Net (USC) | Expectancy |
|--------|-----------|----|-----------|------------|
| 0.34 (measured) | 21 015 | 0.900 | −40 939 | −1.95 |
| 0.50 (stress) | 21 020 | 0.879 | −50 753 | −2.41 |
| 1.00 (stress) | 21 154 | 0.813 | −84 375 | −3.99 |

The spread is charged twice — on the market fills of the marketable layers
and on the round trip of every position — so it is the single largest lever.
At a spread of 1.00 the strategy loses more than twice as much.

### 6.5 Frequency and drawdown

21 015 positions over 399 999 M1 bars (413 calendar days) is **one position
every 19 bars** and 8 236 armed baskets is **one basket every 49 bars** —
about 51 positions and 20 baskets per calendar day. A near-coin-flip payoff
traded several times a day is the profile that produces a large drawdown for
a small expected loss: the peak-to-trough drawdown is **45 711 USC**, more
than twenty times the 2 154 USC balance of the account it was run on.

### 6.6 The retest step: measured

The retest (spec §4: the price must touch the entry-zone edge on a bar
**strictly after** the confirmation bar) is the step that decides whether a
setup ever becomes a basket. The harness now measures it directly: the
number of execution bars between the confirmation bar and the retest bar, and
the distance the market still had to travel to reach E1.

| Measurement | Base run (D-4 off) | D-4 on (current code) |
|---|---|---|
| Average latency, confirmation → retest | **10.3 bars** | **5.2 bars** |
| Median latency | 1 bar | 1 bar |
| Longest latency | 3 286 bars (≈ 2.3 days) | 3 119 bars |
| Retested within 1 bar | 5 429 (66 %) | 4 936 (70 %) |
| Retested within 15 bars | 7 576 (92 %) | 6 802 (96 %) |
| Longer than 15 bars | 660 (8 %) | 305 (4 %) |
| Average distance still to travel to E1 | **8.1 pips** | **7.6 pips** |

**Reading.** The retest is not a filter that rarely fires: two thirds of the
confirmations are armed on the very next bar, and the market typically has to
travel only ~8 pips to reach the zone edge. The long tail is real though —
8 % of the setups wait more than 15 bars, and the worst case is more than two
days, during which the POI level can age out of the map and the setup is
cancelled with `POI_GONE` (636 setups on the base run).

This is also what a live setup looks like while it waits. The live instance
of 2026-10-22 confirmed a SELL at 08:02 and was still waiting for its retest
at 08:32 — 30 bars, i.e. inside the measured distribution but above its
median.

### 6.7 Summary

The specification is coherent and the implementation matches it; the
*parameters* do not produce an edge. Three concrete numbers explain the
result:

* the shared structural stop is **33.7 pips** from E1 on average, so a
  winner has to clear a ~22-pip average loss, and the 41.6 % win rate only
  pays 1.26× where 1.40× is needed;
* the TP1 lock turns 41 % of the winners into +10-pip wins, which is what
  keeps the average winner at 28 pips instead of the 40 pips the target
  winners actually deliver;
* the frequency (one position every 19 bars) turns a −1.95 USC expectancy
  into a −40 939 USC total and a 45 711 USC drawdown.

## 7. A second live bug: the expert died on every terminal restart

The live question "why has the expert not opened a position?" was answered
from the terminal journal, not from the harness. The terminal restarted at
08:07 on 2026-10-22 and the journal showed:

```
08:07:30  Experts  expert Alphatom_EA (XAUUSDc,H1) loaded successfully
08:07:35  Experts  initializing of Alphatom_EA (XAUUSDc,H1) failed with code 1
08:07:35  Experts  expert Alphatom_EA (XAUUSDc,H1) removed
08:07:35  Experts  ALPHA init refused: hedging account required for three independent layers
```

**Cause.** The terminal initialises an expert *while the broker connection is
still being established* (the connection was authorized 46 seconds later).
The symbol specification and the account margin mode are unknown at that
moment, so the expert's pre-flight check refused the start-up and `OnInit`
returned `INIT_FAILED`. **MT5 removes an expert whose `OnInit` fails and
never re-attaches it**, so the whole strategy stopped silently: the state file
stopped being written, the setup that was waiting for its retest was lost,
and nothing in the account showed why.

**Consequence for the trade count.** A dead expert is a dead setup. When the
expert came back at 09:15 it restored the SELL setup from the state file, but
its H1 POI level had aged out of the map in the meantime, so the setup was
cancelled with `POI_GONE` and a fresh one started. A restart therefore costs
one setup, not the account.

**Fix.** The expert now waits for the connection instead of dying: `OnInit`
returns `INIT_SUCCEEDED`, a 5-second timer retries the check, and the
restart recovery only runs once the terminal is in sync. A permanently wrong
account type still refuses the start-up. Commit `2d7b05a`; the details and
the runbook are in `docs/ea-deployment.md` §5.1 and `docs/ea-spec-audit.md`
decision D-7.

**Lesson for the harness.** The backtest cannot see this class of failure:
it always starts with a connected terminal. The liveness check that does see
it is the state-file timestamp — it must move on every closed bar.

## 8. What would be worth trying next

These are *hypotheses to test with the harness*, not recommendations to trade:

1. **Trade less.** The per-setup expectancy is negative, but the frequency is
   enormous. Adding a filter (session, trend, volatility, distance from the
   POI, confirmation strength) may cut the losing tail. Test it as a variant
   in the harness before it ever reaches the account.
2. **Re-check the target geometry.** With a 22-pip average loss, a 30/50/100
   pip target set may be mismatched; the win/loss ratio needed is
   ≈ 1.4×, so targets and the stop anchor have to be considered together.
3. **Re-check the stop anchor.** The structural stop is much tighter than the
   50-pip cap, which suggests the cap almost never binds. A deliberate,
   fixed stop distance would make the geometry predictable.
4. **One side at a time (D-4) stays** — it is neutral in the backtest
   (PF 0.898 vs 0.900) and it removes the double-exposure whipsaw that cost
   134 USC on the first live evening.
5. **Daily loss cap** is still missing; with a negative expectancy it would
   not have saved the account, but it bounds the damage.

## 9. Reproducing

```bash
# the recorded bars (not in git, 37 MB):
#   data/BEX_m1.csv, data/BEX_poi.csv  (exported by MQL5/Experts/AlphatomBarsExport.mq5)
make backtest                                   # the base run
make backtest ARGS="--one-side 0 --spread 0.50"
./build/backtest --m1 data/BEX_m1.csv --poi data/BEX_poi.csv --tf 1
./build/backtest --m1 data/BEX_m1.csv --poi data/BEX_poi.csv --poi-tf 2
./build/backtest --trace                        # touch -> confirm -> retest -> arm timeline
./build/backtest --from 1792590000 --to 1792636200 --trace   # a single live window
```

Options: `--one-side 0|1` (D-4), `--spread <price>`, `--cap <usc>`,
`--tf 0|1|2` (M1/M2/M3 execution), `--poi-tf 0|1|2` (a single POI source),
`--from/--to <epoch>`, `--report <file>` (per-trade CSV), `--trace` (the
touch → confirm → retest → arm → fill → close timeline on stdout).

Every run prints the retest measurement of §6.6:

```
retest: latency avg=10.3 bars max=3286 | hist 1bar=5429 2bars=750 3-5=771 6-15=626 >15=660 | gap to E1 avg=8.1 pips
```
