#!/usr/bin/env python3
import argparse
import difflib
import json
import re
from pathlib import Path


def words(text: str) -> list[str]:
    return re.findall(r"[a-z0-9]+(?:'[a-z0-9]+)?", text.lower())


def word_error_rate(reference: str, hypothesis: str) -> float:
    expected = words(reference)
    actual = words(hypothesis)
    if not expected:
        return 0.0 if not actual else 1.0

    previous = list(range(len(actual) + 1))
    for expected_word in expected:
        current = [previous[0] + 1]
        for index, actual_word in enumerate(actual, start=1):
            current.append(min(
                current[-1] + 1,
                previous[index] + 1,
                previous[index - 1] + (expected_word != actual_word),
            ))
        previous = current
    return previous[-1] / len(expected)


def load(path: Path) -> dict:
    return json.loads(path.read_text())


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--apple", type=Path, required=True)
    parser.add_argument("--fluid", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--reference", type=Path)
    args = parser.parse_args()

    apple = load(args.apple)
    fluid = load(args.fluid)
    args.output.mkdir(mode=0o700, parents=True, exist_ok=True)
    apple_text = apple["transcript"].strip() + "\n"
    fluid_text = fluid["transcript"].strip() + "\n"

    (args.output / "apple.txt").write_text(apple_text)
    (args.output / "fluid.txt").write_text(fluid_text)
    diff = difflib.unified_diff(
        apple_text.splitlines(keepends=True),
        fluid_text.splitlines(keepends=True),
        fromfile="apple.txt",
        tofile="fluid.txt",
    )
    (args.output / "apple-vs-fluid.diff").write_text("".join(diff))

    summary = {
        "schema_version": 1,
        "input_file": apple["inputFile"],
        "audio_duration_seconds": apple["audioDurationSeconds"],
        "apple": {
            "engine": apple["engine"],
            "model": apple["model"],
            "processing_seconds": apple["processingSeconds"],
            "realtime_factor": apple["audioDurationSeconds"] / apple["processingSeconds"],
            "word_count": len(words(apple_text)),
        },
        "fluid": {
            "engine": fluid["engine"],
            "model": fluid["model"],
            "processing_seconds": fluid["processingSeconds"],
            "realtime_factor": fluid["audioDurationSeconds"] / fluid["processingSeconds"],
            "word_count": len(words(fluid_text)),
        },
    }

    if args.reference:
        reference = args.reference.read_text()
        summary["reference"] = {
            "word_count": len(words(reference)),
            "apple_wer": word_error_rate(reference, apple_text),
            "fluid_wer": word_error_rate(reference, fluid_text),
        }

    summary_path = args.output / "summary.json"
    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    for path in args.output.iterdir():
        path.chmod(0o600)
    print(summary_path)


if __name__ == "__main__":
    main()
