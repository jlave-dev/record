import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "compare.py"
SPEC = importlib.util.spec_from_file_location("compare", MODULE_PATH)
compare = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(compare)


class WordErrorRateTests(unittest.TestCase):
    def test_exact_and_punctuation(self):
        self.assertEqual(compare.word_error_rate("Hello, world!", "hello world"), 0)

    def test_insertion_deletion_and_substitution(self):
        self.assertEqual(compare.word_error_rate("one two three", "one four extra"), 2 / 3)

    def test_empty_reference(self):
        self.assertEqual(compare.word_error_rate("", ""), 0)
        self.assertEqual(compare.word_error_rate("", "word"), 1)


if __name__ == "__main__":
    unittest.main()
