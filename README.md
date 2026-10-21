# Alphatom — POI execution expert for MetaTrader 5

A rule-based trading expert for **XAUUSDc (Gold Spot Cent)** that implements a
frozen, fully specified strategy: it waits for a **POI** (point of interest)
on M15/M30/H1, trades its **touch** on M1/M2/M3, requires a **confirmation**
(IFVG or CISD), waits for the **retest** and then places a **three layer
basket** with one shared stop and three targets.

The interesting part of this repository is not the expert itself but the
**specification and the test suite** around it: every number, every state
transition and every cancel trigger is written down in
[`docs/ea-execution-spec.md`](docs/ea-execution-spec.md) and covered by an
executable test suite.

> **Risk warning.** This software places real orders on a live account when
> live mode is enabled. Trading gold on leverage carries the risk of losing
> money. Start in shadow mode, test on a demo/cent account, and only enable
> live trading when you fully understand the rules below. The authors accept no
> liability for trading losses.

---

## The strategy in one screen

```
POI (M15 / M30 / H1, fresh or flipped-fresh)
   │  price wicks into the POI on M1 / M2 / M3          → TOUCH
   ▼
confirmation on a LATER bar: IFVG (close through the far FVG boundary)
                            or CISD (close beyond a delivery anchor) → CONFIRM
   ▼
retest: a wick touches the near edge of the entry zone  → ARM
   ▼
three layers are placed inside the entry zone (GTC limits):
   E1  E2  E3   equal thirds, strictly ordered
   one shared stop, clamped to 50 pips from E1
   targets: E1 +30 pips, E2 +50 pips, E3 +100 pips
   after TP1 the remaining layers are cancelled and their stops are locked
   at +10 pips from their own entries
```

Key rules (the full list lives in the spec):

| Rule | Value | Where |
|------|-------|-------|
| POI timeframes | M15, M30, H1 (independent, H4 is only the upper bound) | spec §1 |
| Execution timeframes | M1, M2, M3 | spec §1 |
| Confirmation | strictly after the touch bar, IFVG wins a same-bar tie | spec §4 |
| Entry zone | full IFVG gap, or the 3-bar M1 band around the CISD anchor | spec §5 |
| Layers | 3 equal thirds, 0.15 lot each (configurable) | spec §6 |
| Shared stop | extreme wick of the touch chain ± 2 ticks, clamped to 50 pips from E1 | spec §7 |
| Targets | +30 / +50 / +100 pips from each layer's own fill | spec §8 |
| Post-TP1 lock | stop at +10 pips from the own entry, pending layers cancelled | spec §9 |
| Cancel triggers | POI broken, role flip, stale window, risk cap | spec §10 |
| One side at a time | only one direction may hold orders or exposure | spec D-4 |

---

## Repository layout

```
MQL5/
  Experts/
    Alphatom_EA.mq5              the expert (shadow by default)
    AlphatomEaRuntimeCheck.mq5   read-only runtime probe, writes a CSV report
    AlphatomBarsExport.mq5       read-only bar exporter for the offline replay
  Include/Alphatom/
    ExecKernel.mqh               detection, entry geometry, state machine
    MSNRKernel.mqh               POI structures and lifecycle helpers
    MSNRLevels.mqh               shared POI pipeline (indicator + expert)
  Indicators/
    Alphatom_MSNR_MTF.mq5        the POI indicator (M15/M30/H1)
tests/
  msnr_kernel_tests.cpp          POI pipeline tests
  exec_kernel_tests.cpp          execution kernel tests (44 groups)
  level_replay_tests.cpp         golden replay of the POI pipeline
  live_replay.cpp                offline replay of the expert loop on real bars
  test_ea_contract.py            contract tests for the expert source
  test_indicator_contract.py     contract tests for the indicator source
  golden/, data/                 recorded HFM bars for the replays
docs/
  ea-execution-spec.md           the frozen execution specification
  ea-spec-audit.md               guide vs spec vs code audit, F-1…F-12, D-1…D-4
  msnr-replica-spec.md           the POI indicator specification
  ea-deployment.md               how to enable live trading, runbook
  validation-checklist.md        the validation log
```

The indicator and the expert share **one** POI pipeline
(`MSNRLevels.mqh`), so what the chart draws and what the expert trades can
never drift apart.

---

## Installation

1. Copy the compiled expert `Alphatom_EA.ex5` into
   `<MT5 data folder>/MQL5/Experts/`, or copy the `MQL5/` tree of this
   repository into the data folder and compile it with MetaEditor.
2. Restart MetaTrader 5 (or right-click the Navigator → *Refresh*).
3. Drag **Alphatom_EA** from *Navigator → Expert Advisors* onto a
   **XAUUSDc** chart.
4. Keep **Allow Algo Trading for this EA** ticked when you want it to trade.

The expert refuses to start on a netting account (it needs hedging for three
independent layers) and warns when the broker does not expose a tick value.

---

## Inputs

| Input | Default | Meaning |
|-------|---------|---------|
| `InpShadowMode` | `true` | shadow mode: detect, simulate and log, never send an order |
| `InpExecTimeframe` | `PERIOD_M1` | execution timeframe (M1, M2 or M3) |
| `InpMagic` | `20261021` | magic number of the expert's orders |
| `InpLotsPerLayer` | `0.15` | lot size of each of the three layers |
| `InpSlippagePoints` | `30` | deviation for market orders |
| `InpRiskCapMoney` | `440.0` | **money cap**: a setup whose basket risk exceeds this (in the deposit currency) is skipped. `0` disables the cap |
| `InpCISDMinRun` | `2` | minimum run of same-colour candles for a CISD |
| `InpCisdZoneMinWidth` / `MaxWidth` | `0.20` / `2.00` | bounds of the CISD entry band |
| `InpMinZoneWidthTicks` | `2` | narrowest entry zone that may be traded |
| `InpSlBufferTicks` | `2` | buffer between the extreme wick and the shared stop |
| `InpSlCapPips` | `50` | the shared stop is clamped to this distance from E1 |
| `InpTp1Pips` / `Tp2Pips` / `Tp3Pips` | `30` / `50` / `100` | targets per layer |
| `InpSlPlusPips` | `10` | post-TP1 stop lock |
| POI inputs | indicator defaults | swing/gap/ATR parameters; they must match the chart indicator |
| `InpExecHistoryBars` | `400` | closed execution bars kept in memory |
| `InpPoiHistoryBars` | `1500` | closed POI bars used to rebuild the POI map |

`InpRiskCapMoney` is expressed in the **deposit currency** of the account.
On a cent account in `USC` with 1 oz contracts, one pip per lot is worth
`10.00 USC`, so a basket that risks `1.50` USC per pip (3 × 0.15 lot) with a
total stop distance of 80 pips risks `120 USC`.

---

## Enabling live trading

Live mode needs four independent switches — see
[`docs/ea-deployment.md`](docs/ea-deployment.md) for the details:

1. `InpShadowMode = false` in the expert inputs (and in the chart profile),
2. the terminal wide **Algo Trading** switch on,
3. the per-expert **Allow Algo Trading** permission,
4. a money cap you have decided on.

The expert logs its own permission state on every start:

```
ALPHA A probe trade flags: terminalAllowed=1 mqlAllowed=1 accountTradeMode=2
```

`terminalAllowed=0` or `mqlAllowed=0` means every order will be rejected with
retcode 10027 (*AutoTrading disabled by client*).

**Restart recovery.** The expert persists both setups in
`MQL5/Files/Alphatom_state.csv`, so a terminal restart does not leave open
positions unmanaged. The restored state is checked against the broker in both
directions: a position or resting order that the state does not know about, or
a layer the state calls filled without a matching position, refuses the live
start and the expert falls back to shadow mode.

---

## Tests

```bash
make test          # POI kernel + execution kernel + golden replay + contract tests
make test-replay   # replay the expert loop over recorded live bars
```

The suite has no external dependency beyond a C++17 compiler and Python 3.

| Suite | Groups | What it covers |
|-------|--------|----------------|
| `test-kernel` | 15 | POI detection, gaps, swings, lifecycle, merging |
| `test-exec` | 44 | IFVG/CISD detection, entry geometry, shared stop, targets, the state machine, the sliding window, restart recovery, one-side-at-a-time |
| `test-levels` | 1 | golden replay of the POI pipeline against recorded HFM objects |
| `test-python` | 34 | contract tests that read the MQL5 sources |
| `test-replay` | – | the expert loop replayed over 4 000 recorded M1 bars |

The replay is the strongest evidence that the expert behaves as specified:

```
without the time-anchored fix: touch=5 confirm=0 arm=0
with    the time-anchored fix: touch=5 confirm=4 arm=4
```

---

## Documentation

* [`docs/ea-execution-spec.md`](docs/ea-execution-spec.md) — the frozen
  execution specification, round by round, with the decisions taken.
* [`docs/ea-spec-audit.md`](docs/ea-spec-audit.md) — the audit of the original
  guide against the specification and the code (findings F-1…F-12, decisions
  D-1…D-4).
* [`docs/msnr-replica-spec.md`](docs/msnr-replica-spec.md) — the POI indicator
  specification.
* [`docs/ea-deployment.md`](docs/ea-deployment.md) — deployment runbook.
* [`docs/validation-checklist.md`](docs/validation-checklist.md) — what was
  validated on a live account, and how.

---

## License

MIT — see [LICENSE](LICENSE). The recorded market data under `tests/golden/`
and `tests/data/` is provided for reproducible testing.
