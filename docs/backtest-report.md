# Alphatom — long backtest report

**Date:** 2026-10-21
**Instrument:** HFM CENT `XAUUSDc` (1 oz contract, `USC` deposit currency, hedging)
**Data:** the broker's own history, exported from the live terminal
**Harness:** `tests/backtest.cpp` (`make backtest`), driving the same
`ExecKernel.mqh` / `MSNRLevels.mqh` code the live expert uses

---

## 1. Verdict

**The strategy as specified has no edge. It is statistically significantly
negative.**

Over the full sample the expert would have lost money on every variant that
was tried: profit factors between **0.81 and 0.94**, expectancy between
**−1.26 and −3.99 USC per closed position**, and a peak drawdown of up to
**86 000 USC** — several times the size of the 2 154 USC account it was run on.

The first live run agrees with the backtest: two baskets, both stopped out,
**−134.10 USC** in a single evening.

**Recommendation: do not trade this strategy with real money in its current
form.** Use the backtest harness to test changes before they touch the
account.

---

## 2. Data and its limits

| Series | Bars | Range |
|--------|------|-------|
| M1 (execution) | 399 999 | 2025-09-04 → 2026-10-21 (13.5 months) |
| M15 | 199 999 | 2017-12-13 → now |
| M30 | 106 186 | 2017-12-13 → now |
| H1 | 56 844 | 2017-12-13 → now |

**The M1 history is the binding limit.** The broker only keeps ~13.5 months
of M1 for this cent symbol, so the backtest covers 13.5 months, not the
multi-year M15/H1 history that is available. There is no M1 data before
2025-09-04, which is why the POI timeframes reach further back than the
execution timeframe.

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

## 4. Results

### 4.1 Main run (M1 execution, spread 0.34, all POI timeframes)

| Metric | Value |
|--------|-------|
| POI touches | 11 298 |
| Confirmations | 9 170 |
| Armed baskets | 8 238 |
| Closed positions | **21 020** |
| Wins / losses | 8 747 / 12 273 (win rate **41.6 %**) |
| Gross profit / gross loss | 368 055 / 408 898 USC |
| **Net** | **−40 843 USC** (−27 228 pips) |
| **Profit factor** | **0.900** |
| **Expectancy** | **−1.94 USC per position** |
| Average win / average loss | 42.08 / 33.32 USC |
| Largest win / largest loss | 150.00 / 77.55 USC |
| **Max drawdown** | **45 637 USC** |
| Average holding time | 11 bars |
| TP1 hits | 3 622 |

With 21 020 positions the standard error of the expectancy is ≈ 0.26 USC,
so the result is about **7.4 standard deviations below zero** — the loss is
not a sampling accident.

### 4.2 Variants

| Variant | Positions | Win % | PF | Net (USC) | Max DD (USC) | Expectancy |
|---------|-----------|-------|----|-----------|--------------|------------|
| M1, spread 0.34, D-4 off (base) | 21 020 | 41.6 | 0.900 | −40 843 | 45 637 | −1.94 |
| M1, D-4 **on** (current code) | 18 144 | 41.6 | 0.899 | −35 931 | 42 143 | −1.98 |
| M1, spread 0.50 | 21 025 | 41.4 | 0.879 | −50 658 | 54 865 | −2.41 |
| M1, spread 1.00 | 21 159 | 40.4 | 0.813 | −84 344 | 86 478 | −3.99 |
| M2 execution | 13 209 | 47.7 | 0.905 | −25 800 | 28 351 | −1.95 |
| M3 execution | 9 493 | 51.3 | 0.911 | −17 542 | 18 922 | −1.85 |
| H1 POI only | 8 267 | 44.3 | 0.936 | −10 407 | 14 499 | −1.26 |

**Every variant loses.** The spread is the biggest single lever: at a spread
of 1.00 the strategy loses four times as much. The one-side rule (D-4)
changes almost nothing (PF 0.899 vs 0.900) — it is not the problem.

### 4.3 Where the money is lost (base run)

| Group | Positions | Win % | Net (USC) |
|-------|-----------|-------|-----------|
| BUY | 10 404 | 41.9 | −20 410 |
| SELL | 10 616 | 41.3 | −20 433 |
| POI M15 | 11 092 | 41.0 | −27 135 |
| POI M30 | 5 512 | 42.2 | −4 704 |
| POI H1 | 4 416 | 42.4 | −9 004 |
| IFVG confirmation | 16 261 | 41.8 | −33 431 |
| CISD confirmation | 4 759 | 40.8 | −7 412 |

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

## 6. Why the strategy does not work

The mechanics are internally consistent (the expert implements the frozen
specification faithfully, which the test suite verifies), but the geometry of
the specification does not produce an edge:

* the shared stop is the extreme wick of the touch chain, so the average loss
  (33.3 USC ≈ 22 pips) is *not* the 50-pip cap but a much tighter structural
  stop;
* the targets are 30/50/100 pips, so the average win (42.1 USC ≈ 28 pips) is
  also much smaller than the nominal targets;
* the win rate of 41.6 % then needs an average win of ≈ 1.4× the average
  loss to break even, and it delivers only ≈ 1.26×;
* the TP1 lock (+10 pips) truncates 3 622 winners early, which lowers the
  average win further;
* the costs (spread 0.34 → 0.50) eat the remaining margin quickly.

The result is a strategy that is close to a coin flip with a small negative
tilt, traded very often (≈ 21 000 positions in 13.5 months, i.e. several
positions per day) — which is exactly the profile that produces a large
drawdown for a small expected loss.

## 7. What would be worth trying next

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
   (PF 0.899 vs 0.900) and it removes the double-exposure whipsaw that cost
   134 USC on the first live evening.
5. **Daily loss cap** is still missing; with a negative expectancy it would
   not have saved the account, but it bounds the damage.

## 8. Reproducing

```bash
# the recorded bars (not in git, 37 MB):
#   data/BEX_m1.csv, data/BEX_poi.csv  (exported by MQL5/Experts/AlphatomBarsExport.mq5)
make backtest                                   # the base run
make backtest ARGS="--one-side 0 --spread 0.50"
./build/backtest --m1 data/BEX_m1.csv --poi data/BEX_poi.csv --tf 1
./build/backtest --m1 data/BEX_m1.csv --poi data/BEX_poi.csv --poi-tf 2
```

Options: `--one-side 0|1` (D-4), `--spread <price>`, `--cap <usc>`,
`--tf 0|1|2` (M1/M2/M3 execution), `--poi-tf 0|1|2` (a single POI source),
`--from/--to <epoch>`, `--report <file>` (per-trade CSV).
