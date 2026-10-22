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

    def test_live_start_is_refused_when_the_state_does_not_match_the_broker(self):
        # Positions or resting orders of this magic that the state file does
        # not know about mean the state is stale: live must be refused and the
        # expert falls back to shadow.
        self.assertIn("EaValidateRecovery", self.source)
        self.assertIn("running shadow", self.source)
        self.assertIn("open positions exist without a matching state file", self.source)
        self.assertIn("resting orders exist without a matching state file", self.source)
        self.assertRegex(self.source, r"g_liveAllowed\s*=\s*false;")

    def test_state_file_is_written_and_restored(self):
        # The setups are persisted so a terminal restart can rebuild them.
        self.assertIn("Alphatom_state.csv", self.source)
        self.assertIn("EaWriteState", self.source)
        self.assertIn("EaReadState", self.source)
        self.assertIn("Exec_TakeSnapshot", self.source)
        self.assertIn("Exec_RestoreSnapshot", self.source)
        # The state must exist before the orders are sent.
        self.assertRegex(self.source, r"EXEC_EVENT_ARM\)\s*\n\s*EaWriteState\(\);")

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

    def test_only_one_side_may_hold_the_market(self):
        # Owner decision 2026-10-21: while the opposite side has live orders
        # or exposure, this side may not keep a setup.
        self.assertIn("EaSideHoldsMarket", self.source)
        self.assertIn("Exec_CancelForOpposite", self.source)
        self.assertIn("EXEC_REASON_OPPOSITE", self.source)
        self.assertRegex(self.source, r"OPPOSITE")

    def test_the_one_side_gate_asks_about_the_other_side(self):
        # EaSideHoldsMarket(isBuy) must answer "does the BUY side hold the
        # market?". Both call sites ask for the opposite side with !isBuy.
        # An inverted body makes an armed setup check ITSELF: the arming
        # basket is then cancelled with reason OPPOSITE before a single
        # order is sent, and the expert never trades.
        body = self.source[self.source.index("bool EaSideHoldsMarket("):]
        body = body[: body.index("\n  }")]
        start = body.index("if(isBuy)")
        end = body.index("\n     }\n", start)
        then_branch = body[start:end]
        rest = body[end:]
        self.assertIn("g_buySetup", then_branch)
        self.assertNotIn("g_sellSetup", then_branch)
        self.assertIn("g_sellSetup", rest)
        self.assertNotIn("g_buySetup", rest)

    def test_the_arm_path_is_not_blocked_by_its_own_setup(self):
        # The arm-time guard asks whether the OPPOSITE side took the market
        # between the check and the arming bar. Asking about the arming side
        # itself would cancel every basket the moment it is armed.
        arm = self.source[self.source.index("void EaHandleLiveEvent("):]
        arm = arm[: arm.index("\n  }")]
        self.assertIn("EaSideHoldsMarket(!isBuy)", arm)
        self.assertIn("EaLivePlaceBasket", arm)

    def test_the_stop_modify_only_sends_a_request_that_changes_something(self):
        # A layer that fills exactly at its limit price already carries the
        # stop and the target of the order it was placed with. Sending the
        # same values again is a no-op that the broker answers with 10025
        # ("no changes"), which the expert logged as SLTP_FAIL - a false
        # alarm on a completely normal event that hides real failures.
        fn = self.source[self.source.index("void EaLiveModifyStops("):]
        fn = fn[: fn.index("\n  }")]
        # The position's current stop and target have to be read first.
        self.assertIn("POSITION_SL", fn)
        self.assertIn("POSITION_TP", fn)
        # And the request may only go out when a value really differs.
        self.assertRegex(fn, r"if\s*\(\s*!\w*changed\w*\s*\)\s*\n\s*continue;")
        # A broker "no changes" answer must not be reported as a failure.
        self.assertIn("TRADE_RETCODE_NO_CHANGES", fn)

    def test_a_position_without_a_stop_always_gets_one(self):
        # The skip must never leave a position unprotected: a position whose
        # broker stop is 0 still needs the modify, so the comparison has to
        # treat "no stop at all" as different.
        fn = self.source[self.source.index("void EaLiveModifyStops("):]
        fn = fn[: fn.index("\n  }")]
        self.assertRegex(fn, r"currentSl\s*<=\s*0\.0|currentSl\s*==\s*0\.0")
        self.assertRegex(fn, r"currentTp\s*<=\s*0\.0|currentTp\s*==\s*0\.0")

    def test_a_rejected_order_cancels_its_layer(self):
        # A layer whose order the broker rejected must not stay PENDING: a
        # PENDING layer counts as "holding the market" in the one-side gate,
        # so the direction would stay blocked until the POI level ages out
        # of the map, and the state file would claim an order that does not
        # exist at the broker.
        fn = self.source[self.source.index("void EaLivePlaceBasket("):]
        fn = fn[: fn.index("\n  }")]
        self.assertIn("ORDER_FAIL", fn)
        self.assertIn("Exec_CancelLayer", fn)

    def test_the_recovery_adopts_a_position_the_broker_already_filled(self):
        # The state is written BEFORE the order goes out, so a terminal that
        # dies between the fill and the next state write leaves a PENDING
        # layer while the broker already holds the position. The recovery
        # must adopt that position instead of refusing the live start,
        # otherwise the open position is never managed.
        fn = self.source[self.source.index("string EaValidateSide("):]
        fn = fn[: fn.index("\n  }")]
        self.assertNotIn("does not mark it filled", fn)
        self.assertIn("adopt", fn.lower())

    def test_a_state_that_is_ahead_of_the_broker_still_refuses_live(self):
        # The opposite direction must keep refusing: the state says the
        # layer is filled but the broker has no position, so the expert
        # cannot know whether the position hit its target or its stop.
        fn = self.source[self.source.index("string EaValidateSide("):]
        fn = fn[: fn.index("\n  }")]
        self.assertIn("the broker has no position for it", fn)

    def test_the_tp1_lock_deletes_the_pending_orders_at_the_broker(self):
        # After TP1 the kernel marks the pending layers as cancelled, but the
        # resting GTC orders must also be deleted at the broker. Otherwise
        # they keep resting, can fill later, and open a position the expert
        # does not expect (the layer is cancelled, so the fill is refused and
        # the position stays unmanaged).
        fn = self.source[self.source.index("void EaHandleDealClose("):]
        fn = fn[: fn.index("\n  }")]
        self.assertIn("EXEC_EVENT_TP1_LOCK", fn)
        self.assertIn("EaLiveCancelPendings", fn)

    def test_a_fill_that_cannot_be_mapped_to_a_layer_is_logged(self):
        # The layer is recovered from the order comment. If a broker rewrites
        # the comment, the fill cannot be mapped to its layer and the
        # position would stay unmanaged - silently. The unmapped deal must
        # be reported.
        fn = self.source[self.source.index("void OnTradeTransaction("):]
        fn = fn[: fn.index("\n  }")]
        self.assertIn("EaLayerFromComment", fn)
        self.assertRegex(fn, r"PrintFormat\([^;]*UNMAPPED")

    def test_a_deal_is_mapped_to_its_layer_through_the_position(self):
        # A closing deal does not carry the order comment: the broker writes
        # its own ("[sl 4112.11]" / "[tp 4115.23]"). The layer must then be
        # recovered from the deal that OPENED the position, otherwise the
        # close is dropped, the basket never finishes in the expert's view,
        # the state file goes stale and the next restart refuses the live
        # start. Observed live on 2026-10-22.
        self.assertIn("EaLayerFromPositionId", self.source)
        fn = self.source[self.source.index("void OnTradeTransaction("):]
        fn = fn[: fn.index("\n  }")]
        self.assertIn("EaLayerFromPositionId", fn)
        self.assertIn("DEAL_POSITION_ID", fn)
        self.assertIn("DEAL_ENTRY_IN", fn)

    def test_the_order_delete_checks_the_broker_retcode(self):
        # OrderSend returns true for most server rejections; the failure is
        # in the retcode. A delete that the broker refused must be reported
        # and retried, or the order keeps resting while the expert believes
        # it is gone.
        fn = self.source[self.source.index("void EaLiveCancelPendings("):]
        fn = fn[: fn.index("\n  }")]
        self.assertIn("TRADE_RETCODE_DONE", fn)
        self.assertIn("ORDER_DELETE_FAIL", fn)
        self.assertIn("g_deleteRetry", self.source)

    def test_an_adopted_position_is_given_its_stop_and_target(self):
        # The recovery adopts a position the broker filled while the expert
        # was down. The stop and the target have to be recomputed from the
        # real fill (the SL+ is measured from the own fill), and the stop
        # has to be pushed to the broker.
        fn = self.source[self.source.index("string EaValidateSide("):]
        fn = fn[: fn.index("\n  }")]
        self.assertIn("Exec_ComputeSLPlus", fn)
        self.assertIn("Exec_ComputeTP", fn)
        self.assertIn("g_adoptedSide", self.source)
        self.assertIn("EaLiveModifyStops", self.source)

    def test_the_simulation_never_touches_a_setup_the_broker_still_holds(self):
        # A refused live start means the state file and the broker disagree
        # and the account may still hold real money. Simulating fills on that
        # setup would overwrite the live state with a simulation.
        self.assertIn("EaBrokerHoldsObjects", self.source)
        fn = self.source[self.source.index("void EaProcessDirection("):]
        fn = fn[: fn.index("\n  }")]
        self.assertIn("EaBrokerHoldsObjects", fn)

    def test_a_rejected_basket_leaves_no_phantom_layers(self):
        # When the pre-flight refuses the basket, no order goes out. The
        # layers must not stay PENDING, or the state file claims orders
        # that do not exist and the direction stays blocked.
        fn = self.source[self.source.index("void EaLivePlaceBasket("):]
        fn = fn[: fn.index("\n  }")]
        self.assertIn("EaAbandonBasket", fn)
        self.assertIn("ARM rejected", fn)

    def test_a_setup_waiting_for_the_retest_is_logged(self):
        # A confirmed setup that waits for its retest must be visible, not
        # only a setup that waits for its confirmation.
        fn = self.source[self.source.index("void EaProcessDirection("):]
        fn = fn[: fn.index("\n  }")]
        self.assertIn("EXEC_CONFIRMED", fn)
        self.assertIn("bars_since_confirm", self.source)

    def test_the_state_file_is_named_after_the_symbol_and_the_magic(self):
        # Two instances of the expert (two symbols, or the same symbol twice)
        # must not overwrite each other's state and restore a setup whose
        # price levels belong to another chart.
        self.assertIn("EaStateFileName", self.source)
        fn = self.source[self.source.index("string EaStateFileName()"):]
        fn = fn[: fn.index("\n  }")]
        self.assertIn("_Symbol", fn)
        self.assertIn("InpMagic", fn)

    def test_the_config_is_rebuilt_from_the_live_symbol(self):
        # The contract specification can change during the session, so the
        # tick size and the money-per-pip may not stay stale for the whole
        # session.
        fn = self.source[self.source.index("bool EaOnClosedBar()"):]
        fn = fn[: fn.index("\n  }")]
        self.assertIn("EaBuildConfig()", fn)

    def test_no_network_or_dll_calls(self):
        self.assertNotRegex(self.source, r"\b(WebRequest|DllCall|MessageBox)\b")

    def test_init_does_not_die_when_the_broker_is_not_connected_yet(self):
        # The terminal initialises the expert while the broker connection is
        # still being established, so SYMBOL_TRADE_TICK_SIZE / CONTRACT_SIZE
        # and the account margin mode can still be unknown. Returning
        # INIT_FAILED there makes MT5 remove the expert from the chart for the
        # rest of the session - it is never re-attached - which silently
        # stops the whole strategy after every terminal restart.
        # The expert must wait for the connection instead of dying.
        init = self.source[self.source.index("int OnInit()"):]
        init = init[: init.index("\n  }")]
        self.assertNotRegex(
            init,
            r"if\s*\(\s*!EaSymbolReady\(\)\s*\)\s*\n\s*return INIT_FAILED;",
        )
        self.assertIn("waiting for the broker connection", init)
        self.assertIn("EventSetTimer", init)

    def test_recovery_runs_only_after_the_broker_state_is_known(self):
        # The recovery validation compares the state file with the broker's
        # positions and resting orders. Before the terminal is in sync those
        # queries return nothing, so the validation would wrongly cancel
        # layers or refuse live. It must be deferred until the connection
        # is established, and the live gate must stay closed until then.
        self.assertIn("EaInitLive", self.source)
        self.assertIn("g_symbolReady", self.source)
        self.assertIn("EaTryBecomeReady", self.source)
        # The live gate is still the input flag plus the runtime flag.
        self.assertRegex(self.source, r"return\s*!InpShadowMode\s*&&\s*g_liveAllowed\s*;")
        # g_liveAllowed only becomes true inside EaInitLive.
        body = self.source[self.source.index("void EaInitLive()"):]
        body = body[: body.index("\n  }")]
        self.assertIn("g_liveAllowed = !InpShadowMode;", body)

    def test_init_may_still_refuse_a_permanent_configuration_error(self):
        # A genuinely wrong account type is a permanent error and must still
        # stop the expert instead of retrying for ever.
        self.assertIn("hedging account required", self.source)
        self.assertRegex(self.source, r"INIT_FAILED;")


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


class DiagnosticToolContractTests(unittest.TestCase):
    """The published diagnostic tools must stay read-only.

    They are handed to users who want to inspect their own broker before
    running the expert, so none of them may be able to touch the account.
    """

    TOOLS = (
        "AlphatomHistoryDepth.mq5",
        "Alphatom_ExecKernelCheck.mq5",
    )

    def setUp(self):
        self.sources = {}
        for name in self.TOOLS:
            path = ROOT / "MQL5" / "Experts" / name
            self.assertTrue(path.is_file(), f"{name} is missing")
            self.sources[name] = path.read_text(encoding="utf-8")

    def test_no_tool_can_send_an_order(self):
        for name, source in self.sources.items():
            for call in ("OrderSend", "OrderModify", "OrderDelete",
                         "OrderClose", "PositionClose", "CTrade", "COrder"):
                self.assertNotIn(call, source, f"{name} must not call {call}")

    def test_no_tool_hardcodes_an_account_or_a_path(self):
        for name, source in self.sources.items():
            for secret in ("InpLogin", "InpPassword", "InpAccount",
                           "/root/", "C:\\", "api_key", "token"):
                self.assertNotIn(secret, source, f"{name} must stay portable")

    def test_the_history_probe_only_reads_bars(self):
        source = self.sources["AlphatomHistoryDepth.mq5"]
        self.assertIn("CopyRates", source)
        self.assertIn("InpDays", source)
        for tf in ("PERIOD_M1", "PERIOD_M15", "PERIOD_H1"):
            self.assertIn(tf, source)

    def test_the_kernel_check_only_type_checks_the_kernel(self):
        source = self.sources["Alphatom_ExecKernelCheck.mq5"]
        self.assertIn("#include <Alphatom/ExecKernel.mqh>", source)
        self.assertIn("Exec_Advance", source)
        self.assertIn("Exec_RecordFill", source)
        self.assertIn("Exec_RecordClose", source)
        # It must not read the market: it exists to type-check the kernel.
        self.assertNotIn("CopyRates", source)
