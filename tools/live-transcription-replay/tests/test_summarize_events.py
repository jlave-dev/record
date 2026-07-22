import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "summarize_events.py"
SPEC = importlib.util.spec_from_file_location("summarize_events", MODULE_PATH)
summarize_events = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(summarize_events)


class EventSummaryTests(unittest.TestCase):
    def test_summary_and_cursor_validation(self):
        events = [
            {"cursor": 1, "type": "transcript.partial", "source_audio_ms": 640, "delivery_latency_ms": 20},
            {"cursor": 2, "type": "transcript.partial", "source_audio_ms": 960, "delivery_latency_ms": 40},
            {
                "cursor": 3,
                "type": "transcript.final",
                "source_audio_ms": 2240,
                "delivery_latency_ms": 80,
                "final_reason": "end_of_utterance",
            },
        ]

        summary = summarize_events.summarize(events)
        self.assertEqual(summary["first_partial_source_audio_ms"], 640)
        self.assertEqual(summary["eou_final_count"], 1)
        self.assertEqual(summary["final_reasons"], {"end_of_utterance": 1})
        self.assertEqual(summary["partial_delivery_latency"]["p95_ms"], 40)

        events[1]["cursor"] = 3
        with self.assertRaises(ValueError):
            summarize_events.summarize(events)


if __name__ == "__main__":
    unittest.main()
