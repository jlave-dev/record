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

    def test_codex_command_is_ephemeral_read_only_and_schema_constrained(self):
        command = question_consumer.codex_command(
            Path("/tmp/work"), Path("/tmp/schema.json"), Path("/tmp/response.json")
        )
        self.assertEqual(command[:2], ["codex", "exec"])
        self.assertIn("--ephemeral", command)
        self.assertIn("--ignore-user-config", command)
        self.assertIn('model_reasoning_effort="low"', command)
        self.assertEqual(command[command.index("--sandbox") + 1], "read-only")
        self.assertIn("--output-schema", command)
        self.assertIn("--output-last-message", command)


if __name__ == "__main__":
    unittest.main()
