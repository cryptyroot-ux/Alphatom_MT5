import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
EA_PATH = ROOT / "MQL5" / "Experts" / "Alphatom_EA.mq5"


class ExpertContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = EA_PATH.read_text(encoding="utf-8")

    def test_ea_file_exists_and_is_mql5(self):
        self.assertTrue(EA_PATH.is_file())
        self.assertIn("#property", self.source)
        self.assertIn("OnTick()", self.source)

    def test_live_mode_requires_an_explicit_enable(self):
        # The owner enabled live execution, so the source default may be false.
        # What must never change: the live gate needs BOTH the input flag and
        # the runtime pre-flight flag, and the flag stays a plain input.
        self.assertRegex(self.source, r"input\s+bool\s+InpShadowMode\s*=\s*(true|false)\s*;")
        self.assertRegex(self.source, r"return\s*!InpShadowMode\s*&&\s*g_liveAllowed\s*;")
        self.assertIn("g_liveAllowed = !InpShadowMode;", self.source)

    def test_live_start_is_refused_when_state_cannot_be_recovered(self):
        # A live start with positions of this magic is refused and downgraded
        # to shadow, because restart recovery is not implemented.
        self.assertRegex(
            self.source,
            r"g_liveAllowed\s*&&\s*EaCountOwnPositions\(\)\s*>\s*0",
        )
        self.assertRegex(self.source, r"g_liveAllowed\s*=\s*false;")

    def test_filling_mode_follows_the_broker(self):
        # HFM Cent only accepts FOK; a hard-coded RETURN would be rejected.
        self.assertIn("SYMBOL_FILLING_MODE", self.source)
        self.assertIn("EaFillingMode", self.source)
        self.assertIn("ORDER_FILLING_FOK", self.source)
        self.assertNotIn("request.type_filling = ORDER_FILLING_RETURN;", self.source)

    def test_waiting_setup_state_is_logged(self):
        # A setup that waits for a confirmation must never be silent.
        self.assertIn("WAIT", self.source)
        self.assertIn("bars_since_touch", self.source)

    def test_cancel_reasons_are_logged_by_name(self):
        self.assertIn("EaReasonName", self.source)
        self.assertIn("EXEC_REASON_STALE", self.source)

    def test_kernels_are_included(self):
        self.assertIn('<Alphatom/ExecKernel.mqh>', self.source)
        self.assertIn('<Alphatom/MSNRLevels.mqh>', self.source)

    def test_order_calls_are_guarded_by_the_live_gate(self):
        # Every function that can send/modify/delete an order must first pass
        # the live gate; shadow mode can never reach a trade call.
        order_calls = re.findall(
            r"\b(OrderSend|OrderSendAsync|OrderModify|OrderDelete)\s*\(", self.source
        )
        self.assertGreater(len(order_calls), 0, "expected a live execution path")
        for match in re.finditer(r"^(?:[A-Za-z_][\w:<>\s\*&]*)\s+(\w+)\s*\([^;]*?\)\s*$",
                                 self.source, re.MULTILINE):
            pass
        # Split into top-level functions by a conservative pattern.
        functions = re.split(r"\n(?=[A-Za-z_][\w:<>\s\*&]*\s+\w+\s*\([^;]*\)\s*\n\s*\{)", self.source)
        guarded = [f for f in functions if "EaLiveEnabled()" in f]
        for function in functions:
            if re.search(r"\b(OrderSend|OrderSendAsync|OrderModify|OrderDelete)\s*\(", function):
                self.assertIn("EaLiveEnabled()", function,
                              "order call outside the live gate")

    def test_magic_is_configurable_and_used(self):
        self.assertRegex(self.source, r"input\s+long\s+InpMagic\s*=")
        self.assertIn("InpMagic", self.source)
        self.assertRegex(self.source, r"magic\s*=\s*\(ulong\)InpMagic")

    def test_init_never_trades(self):
        init = self.source[self.source.index("int OnInit()"):]
        init = init[: init.index("\n  }")]
        self.assertNotRegex(init, r"\bOrder(Send|SendAsync|Modify|Delete)\b")

    def test_only_closed_bars_are_used(self):
        self.assertIn("ArraySetAsSeries(rates, false)", self.source)
        self.assertRegex(self.source, r"copied\s*-\s*1")

    def test_execution_timeframes_are_m1_m2_m3(self):
        self.assertRegex(self.source, r"PERIOD_M1")
        self.assertRegex(self.source, r"PERIOD_M2")
        self.assertRegex(self.source, r"PERIOD_M3")
        self.assertRegex(
            self.source,
            r"InpExecTimeframe\s*!=\s*PERIOD_M1\s*&&\s*InpExecTimeframe\s*!=\s*PERIOD_M2\s*&&\s*InpExecTimeframe\s*!=\s*PERIOD_M3",
        )

    def test_marketable_layers_are_executed_not_left_invalid(self):
        # At arming the retest bar has closed; layers already past the market
        # must become immediate fills instead of invalid pending limits.
        self.assertIn("EaShadowArmFills", self.source)
        self.assertIn("marketable", self.source)
        self.assertRegex(self.source, r"request.action = TRADE_ACTION_DEAL;")
        self.assertRegex(self.source, r"request.action = TRADE_ACTION_PENDING;")

    def test_money_cap_input_is_configurable_and_logged(self):
        # Guide §13 leaves the money cap undefined: the EA exposes it as an
        # input (0 = off), reads it into ExecConfig.riskCap, and logs basket
        # risk on both ARM and SKIP events so capped setups remain visible.
        self.assertRegex(self.source, r"input\s+double\s+InpRiskCapMoney\s*=")
        self.assertIn("g_cfg.riskCap = InpRiskCapMoney;", self.source)
        self.assertRegex(self.source, r"risk=%.2f")
        self.assertIn("setup.basketRisk", self.source)

    def test_no_network_or_dll_calls(self):
        self.assertNotRegex(self.source, r"\b(WebRequest|DllCall|MessageBox)\b")


if __name__ == "__main__":
    unittest.main()


class RuntimeCheckContractTests(unittest.TestCase):
    """The diagnostic probe must never trade on the live CENT account."""

    def setUp(self):
        self.path = ROOT / "MQL5" / "Experts" / "AlphatomEaRuntimeCheck.mq5"
        self.source = self.path.read_text(encoding="utf-8")

    def test_exists(self):
        self.assertTrue(self.path.is_file())

    def test_never_trades(self):
        for call in ("OrderSend", "OrderModify", "OrderDelete", "OrderClose",
                     "PositionClose", "CTrade"):
            self.assertNotIn(call, self.source)

    def test_exports_report(self):
        self.assertIn("Alphatom_runtime_report.csv", self.source)
        self.assertIn("FileOpen", self.source)
        self.assertIn("money_per_pip_per_lot", self.source)
