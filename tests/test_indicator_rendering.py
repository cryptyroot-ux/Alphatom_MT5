import unittest
from pathlib import Path


SOURCE_PATH = (
    Path(__file__).resolve().parents[1]
    / "MQL5"
    / "Indicators"
    / "Alphatom_MSNR_MTF.mq5"
)


class IndicatorRenderingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SOURCE_PATH.read_text(encoding="utf-8")

    def test_object_names_are_stable_and_timeframe_qualified(self):
        self.assertIn("string TimeframeTag(", self.source)
        self.assertIn("string TimeframePrefix(", self.source)
        self.assertIn('"ATMSNR_"', self.source)
        self.assertIn("TimeframeTag(timeframe)", self.source)
        self.assertRegex(self.source, r"IntegerToString\(\(int\)created\)")

    def test_cleanup_is_scoped_to_indicator_prefix(self):
        self.assertRegex(
            self.source,
            r"ObjectsDeleteAll\(0\s*,\s*prefix\s*\)",
        )
        self.assertIn("ClearTimeframeObjects(prefix)", self.source)

    def test_missing_history_clears_source_objects_before_return(self):
        self.assertRegex(self.source, r"copied\s*<=\s*0")
        self.assertRegex(
            self.source,
            r"if\s*\(copied\s*<=\s*0\)\s*\{\s*ClearTimeframeObjects\(prefix\);",
        )

    def test_unsynchronized_history_is_cleared_before_copy_rates(self):
        start = self.source.index("void ProcessTimeframe(")
        end = self.source.index("\n  }", start)
        body = self.source[start:end]
        clear_position = body.index("ClearTimeframeObjects(prefix)")
        sync_position = body.index("SERIES_SYNCHRONIZED")
        copy_position = body.index("CopyRates(")
        self.assertLess(clear_position, sync_position)
        self.assertLess(sync_position, copy_position)

    def test_gap_bands_and_level_states_have_distinct_visuals(self):
        self.assertIn("OBJ_RECTANGLE", self.source)
        self.assertIn("OBJ_HLINE", self.source)
        self.assertIn("MSNR_STATE_UNFRESH", self.source)
        self.assertIn("MSNR_STATE_FLIPPED_FRESH", self.source)
        self.assertIn("OBJPROP_COLOR", self.source)


if __name__ == "__main__":
    unittest.main()
