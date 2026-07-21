import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "question_consumer.py"
SPEC = importlib.util.spec_from_file_location("question_consumer", MODULE_PATH)
question_consumer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(question_consumer)


class QuestionConsumerTests(unittest.TestCase):
    def test_context_window(self):
        events = [
            {"source_audio_ms": 10_000},
            {"source_audio_ms": 40_000},
            {"source_audio_ms": 100_000},
        ]
        self.assertEqual(question_consumer.context_window(events, 100_000, 60_000), events[1:])


if __name__ == "__main__":
    unittest.main()
