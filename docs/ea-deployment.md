# Alphatom EA — deployment & live-enablement runbook

Account: **HFM CENT** (`XAUUSDc`, currency `USC`, hedging). The account login of
the reference installation is deliberately not part of this repository.
Terminal: portable Wine build under `/opt/mt5/work/wp64`, managed by systemd
`mt5-terminal.service` (profile `Guarded`).

## 1. Layout of the Guarded profile

| Chart | Symbol / TF | Attached | Purpose |
|-------|-------------|----------|---------|
| chart01 | XAUUSDc M1 | `Alphatom_EA` | the trading expert (live) |
| chart02 | XAUUSDc M30 | `Alphatom_MSNR_MTF` | POI visualisation (M15/M30/H1) |
| chart03 | XAUUSDc M15 | `Alphatom_MSNR_MTF` + `AlphatomBarsExport` | POI visualisation + bar export |
| chart04 | XAUUSDc H1 | `AlphatomEaRuntimeCheck` | runtime probe (read-only) |

The expert attaches through a `<expert>` block in the chart file
`MQL5/Profiles/Charts/Guarded/chart01.chr` (UTF-16LE).

## 2. What "live" actually requires (all four must hold)

| # | Requirement | Where it lives | How to set it |
|---|-------------|----------------|---------------|
| 1 | The source default `InpShadowMode = false` | `MQL5/Experts/Alphatom_EA.mq5` | source edit + recompile |
| 2 | The chart instance input `InpShadowMode=false` | `chart01.chr` → `<inputs>` | edit the chart file (terminal stopped) |
| 3 | Terminal-wide Algo Trading **on** | `Config/common.ini` → `[Experts] Enabled=1` | edit the ini (UTF-16LE) |
| 4 | Per-EA "Allow Algo Trading" **on** | `chart01.chr` → `expertmode=1` in the `<expert>` block | attach once via the GUI, then keep the flag |

`[Experts] AllowLiveTrading=1` (Tools → Options → Expert Advisors → allow
automated trading) must also stay enabled; it is the third switch, separate
from `[Experts] Enabled`.

Verification: the expert prints its own flags on every start —

```
ALPHA A probe trade flags: terminalAllowed=1 mqlAllowed=1 accountTradeMode=2
```

`terminalAllowed` = requirement 3, `mqlAllowed` = requirement 4,
`accountTradeMode=2` = live/real account. If `mqlAllowed=0` every order is
rejected with **retcode 10027 "AutoTrading disabled by client"**.

`Config/common.ini` and the `.chr` files are UTF-16LE — edit them with a
UTF-16 aware script, never with a plain text editor.

## 3. The chart file must be edited while the terminal is stopped

MT5 rewrites the whole profile when the terminal exits, so any hand edit to a
`.chr` made while the terminal runs is lost. Correct order:

```bash
systemctl stop mt5-terminal.service      # wait until inactive AND no terminal64 process
# edit chart01.chr now
systemctl start mt5-terminal.service
```

## 4. Runtime facts measured on this account

| Property | Value | Consequence |
|----------|-------|-------------|
| `SYMBOL_TRADE_TICK_VALUE_LOSS` / `_PROFIT` / `TICK_VALUE` | **0** | money-per-pip falls back to the contract spec: `contract(1.0 oz) × $0.10/pip = 10.00 USC/pip/lot` |
| `SYMBOL_FILLING_MODE` | **1 (FOK only)** | the expert picks the filling mode from the symbol (`EaFillingMode()`); a hard-coded `ORDER_FILLING_RETURN` is rejected |
| `SYMBOL_TRADE_STOPS_LEVEL` / `FREEZE_LEVEL` | 0 / 8 points | stop distance never blocks a layer |
| `SYMBOL_TRADE_MODE` | `SYMBOL_TRADE_MODE_FULL` | trading is enabled on the account |
| `ACCOUNT_MARGIN_MODE` | `ACCOUNT_MARGIN_MODE_RETAIL_HEDGING` | three independent layers are possible |
| Spread | ~34 points | not filtered (open item, guide §13) |
| M1/M2/M3 history | 750 000 bars each | all three execution timeframes are usable |
| Server time | WIB − 4 h | the daily break is 23:59 → 01:00 server |

## 5. Restart recovery

The expert persists both setups in `MQL5/Files/Alphatom_state_<symbol>_<magic>.csv`
(one CSV row per direction, 39 columns, a shared index table for the writer and
the parser). The name carries the symbol and the magic, so two instances of
the expert cannot overwrite each other's state. The state is written

* right before the basket goes out (so a crash between the write and the
  order still leaves a consistent state),
* on every closed bar,
* on every fill and close.

On start the state is read back and validated against the broker in **both**
directions:

| Situation | Result |
|-----------|--------|
| the state matches the broker | the setup is restored and managed again, live continues |
| an open position or a resting order of this magic is not in the state | live is **refused**, the expert falls back to shadow |
| the state calls a layer filled but the broker has no position for it | live is **refused** (the state is stale) |
| the state calls a layer pending but the order is gone | the layer is cancelled and the setup continues with the remaining layers |

The state file is written by the expert, so **do not edit it while the terminal
runs**; the next write overwrites it. A restart therefore reads the file that
the previous run left behind.

Markers in the log: `recovery: N setup(s) restored`, `live start refused: ...;
running shadow`.

### 5.0 When the live start is refused because the state is ahead of the broker

The frozen spec makes the expert refuse the live start when the state file
disagrees with the broker. The most common case is a position that was closed
by the broker while the expert was down: the state still calls the layer
*filled*, the broker has no position any more, so the expert does not know
whether it hit its target or its stop and stays in shadow.

The state file is a **runtime artifact** written by the expert. Once the
account is flat again (no position and no resting order of this magic) the
stale row can simply be removed — with the terminal stopped:

```bash
systemctl stop mt5-terminal.service
rm -f "<MT5 data folder>/MQL5/Files/Alphatom_state_<symbol>_<magic>.csv"
systemctl start mt5-terminal.service
```

Do **not** do this while a position or a resting order of this magic is open:
the state file is the only link between the expert and the broker's objects.

### 5.1 The expert waits for the broker connection (2026-10-22)

The terminal initialises an expert **while the broker connection is still being
established**. The symbol specification (`SYMBOL_TRADE_TICK_SIZE`,
`SYMBOL_TRADE_CONTRACT_SIZE`) and the account margin mode are unknown at that
moment.

`OnInit` used to refuse the start-up in that case, and **MT5 removes an expert
whose `OnInit` fails and never re-attaches it** — so after every terminal
restart the whole strategy stopped silently. Live evidence (2026-10-22):

```
08:07:30  Experts  expert Alphatom_EA (XAUUSDc,H1) loaded successfully
08:07:35  Experts  initializing of Alphatom_EA (XAUUSDc,H1) failed with code 1
08:07:35  Experts  expert Alphatom_EA (XAUUSDc,H1) removed
```

The expert now **waits** instead of dying: `OnInit` returns `INIT_SUCCEEDED`,
a 5-second timer retries the check, and the restart recovery runs only once the
terminal is in sync (the recovery compares the state file with the broker's
positions and resting orders, which are only known after the sync). The healthy
start-up looks like this:

```
09:15:05  ALPHA A ready: the terminal is synchronized with the broker
09:15:05  ALPHA A recovery: 1 setup(s) restored from Alphatom_state_XAUUSDc_20261021.csv (buy=IDLE sell=CONFIRMED)
09:15:09  ALPHA A init: shadow=false exec=PERIOD_M1 magic=20261021 ...
```

A **permanently** wrong account type (a non-hedging account) still refuses the
start-up, because no amount of waiting can fix it.

**How to tell that the expert is alive:** `MQL5/Files/Alphatom_state_<symbol>_<magic>.csv` is
rewritten on every closed bar. If its timestamp stops moving, the expert is not
running — check the journal for `failed with code 1` / `removed`, and check that
the chart still carries the `<expert>` block (a removed expert is not restored
by a terminal restart on its own; the chart file must be edited while the
terminal is stopped, see §3).

## 6. Live order path (what happens on ARM)

1. The arming bar closes → the basket is placed.
2. A layer whose price is already at/beyond the market cannot rest as a limit:
   it is executed immediately at market (shadow: filled at the retest close).
   The remaining layers stay GTC limits.
3. Every layer carries the shared SL and its own TP (30 / 50 / 100 pips from
   its own fill).
4. After TP1 the pending layers are cancelled and the E2/E3 stops are locked
   at +10 pips from their own entries.
5. Fills and closes are reconciled in `OnTradeTransaction`; the comment
   (`ALPHA B L0` / `ALPHA S L2`) maps a deal back to its layer.

Orders carry magic `20261021`. A live start whose broker state does not match
the state file is refused and downgraded to shadow (§5).

## 7. Diagnostics

* Log: `MQL5/logs/YYYYMMDD.log` in the terminal data folder (UTF-16LE).
  Useful markers: `HEARTBEAT` (liveness + fresh/unfresh/broken POI counts),
  `WAIT` (setup waiting for its confirmation), `ORDER_PLACED` / `ORDER_MARKET`
  (basket sent), `ORDER_FAIL` (rejected, with the retcode), `recovery:` and
  `live start refused:` (restart recovery).
* Runtime probe report: `MQL5/Files/Alphatom_runtime_report.csv`.
* Bar export for the offline replay: `MQL5/Files/BEX_m1.csv`,
  `MQL5/Files/BEX_poi.csv` (regenerate with `AlphatomBarsExport`).
* Offline replay of the expert loop on exported bars: `make test-replay`.
