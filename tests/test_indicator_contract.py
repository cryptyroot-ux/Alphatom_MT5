import re
import unittest
from pathlib import Path


SOURCE_PATH = (
    Path(__file__).resolve().parents[1]
    / "MQL5"
    / "Indicators"
    / "Alphatom_MSNR_MTF.mq5"
)


class IndicatorContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SOURCE_PATH.read_text(encoding="utf-8")

    def test_poi_period_list_is_exactly_m15_m30_h1(self):
        match = re.search(
            r"ENUM_TIMEFRAMES\s+MSNR_SOURCE_PERIODS\s*\[\s*3\s*\]\s*="
            r"\s*\{([^}]*)\}",
            self.source,
        )
        self.assertIsNotNone(match, "explicit three-timeframe source list missing")
        periods = re.findall(r"PERIOD_[A-Z0-9]+", match.group(1))
        self.assertEqual(periods, ["PERIOD_M15", "PERIOD_M30", "PERIOD_H1"])

    def test_no_timeframe_above_h1_is_requested(self):
        self.assertNotRegex(
            self.source,
            r"\bPERIOD_(?:H4|D1|W1|MN1)\b",
            "H4 is a ceiling only; higher periods must not be POI sources",
        )

    def test_observed_defaults_are_set_for_implemented_controls(self):
        expected = {
            "InpSwingLeft": "3",
            "InpSwingRight": "3",
            "InpGapDetection": "true",
            "InpGapToleranceTicks": "2",
            "InpTouchTolerancePoints": "0.0",
            "InpATRPeriod": "14",
            "InpMergeToleranceATR": "0.1",
            "InpFreshReplacesUnfresh": "false",
            "InpKeepUnfresh": "true",
            "InpFlipBroken": "true",
            "InpShowAV": "true",
            "InpMaxLevelsPerTF": "8",
        }
        for name, value in expected.items():
            with self.subTest(name=name):
                self.assertRegex(
                    self.source,
                    rf"\b{name}\s*=\s*{re.escape(value)}\s*;",
                )

    def test_source_bars_are_copied_and_latest_forming_bar_is_excluded(self):
        self.assertIn("CopyRates(", self.source)
        self.assertRegex(self.source, r"closed_count\s*=\s*copied\s*-\s*1\s*;")

    def test_each_required_timeframe_is_processed(self):
        for index, name in enumerate(("m15", "m30", "h1")):
            with self.subTest(timeframe=name):
                self.assertRegex(
                    self.source,
                    rf"ProcessTimeframe\(MSNR_SOURCE_PERIODS\[{index}\],\s*"
                    rf"g_{name}_levels,\s*g_{name}_level_count\)",
                )

    def test_copied_bars_are_validated_before_level_calculation(self):
        self.assertIn("MSNR_IsValidBar", self.source)
        self.assertRegex(
            self.source,
            r"if\s*\(!MSNR_IsValidBar\(bars\[i\]\)\)\s*\{\s*"
            r"ArrayResize\(outLevels,\s*0\);\s*outCount\s*=\s*0;\s*"
            r"ClearTimeframeObjects\(prefix\);\s*return;",
        )

    def test_hidden_candidates_are_filtered_before_the_level_cap(self):
        start = self.source.index("void AddCandidate(")
        end = self.source.index("\n  }", start)
        body = self.source[start:end]
        self.assertLess(
            body.index("MSNR_IsVisibleState("),
            body.index("MSNR_CanRetainCandidate("),
        )

    def test_swings_and_gaps_share_newest_first_level_cap(self):
        start = self.source.index("void ProcessTimeframe(")
        end = self.source.index("\nint OnInit()", start)
        body = self.source[start:end]
        self.assertIn("swingCandidates", body)
        self.assertIn("gapCandidates", body)
        self.assertIn("MSNR_CandidatePrecedes(", body)
        self.assertLess(body.index("MSNR_DetectGap("),
                        body.index("MSNR_CandidatePrecedes("))
        self.assertLess(body.index("MSNR_IsPivotHigh("),
                        body.index("MSNR_CandidatePrecedes("))
        self.assertIn("AddCandidate(outLevels, outCount", body)

    def test_indicator_does_not_call_trade_apis(self):
        self.assertNotRegex(
            self.source,
            r"\b(?:CTrade|OrderSend|PositionOpen|PositionClose|trade\.Buy|trade\.Sell)\b",
        )

if __name__ == "__main__":
    unittest.main()
