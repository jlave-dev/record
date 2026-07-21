#!/usr/bin/env python3
import argparse
import json
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path


SCHEMA = {
    "type": "object",
    "properties": {
        "context": {"type": "string"},
        "question": {"type": "string"},
    },
    "required": ["context", "question"],
    "additionalProperties": False,
}


def context_window(finals: list[dict], end_ms: int, window_ms: int) -> list[dict]:
    return [event for event in finals if event["source_audio_ms"] >= end_ms - window_ms]


def timestamp(milliseconds: int) -> str:
    seconds = milliseconds // 1000
    return f"{seconds // 60:02d}:{seconds % 60:02d}"


def ask_claude(events: list[dict], prior_questions: list[str]) -> tuple[dict, int]:
    transcript = "\n".join(
        f"[{timestamp(event['source_audio_ms'])}] {event['text']}" for event in events
    )
    prior = "\n".join(f"- {question}" for question in prior_questions[-5:]) or "- none"
    prompt = f"""You are assisting during a meeting. Use only the timestamped transcript evidence below.
Return one concise sentence of current context and one useful question the participants have not already answered.
The question should expose a missing decision, owner, constraint, risk, or next step. Return an empty question if nothing is useful yet.
Do not repeat a prior question.

Prior questions:
{prior}

Transcript evidence:
{transcript}
"""
    command = [
        "claude", "-p", "--safe-mode", "--model", "haiku", "--tools", "", "--no-session-persistence",
        "--output-format", "json", "--json-schema", json.dumps(SCHEMA, separators=(",", ":")),
    ]
    started = time.monotonic()
    result = subprocess.run(command, input=prompt, text=True, capture_output=True, timeout=30)
    generation_ms = round((time.monotonic() - started) * 1000)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "Claude exited unsuccessfully")
    payload = json.loads(result.stdout)
    if payload.get("is_error"):
        raise RuntimeError(payload.get("result") or "Claude returned an error")
    return payload["structured_output"], generation_ms


def event_age_ms(created_at: str) -> int:
    created = datetime.fromisoformat(created_at.replace("Z", "+00:00"))
    return max(0, round((datetime.now(timezone.utc) - created).total_seconds() * 1000))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--events", type=Path, required=True)
    parser.add_argument("--done", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--interval-ms", type=int, default=30_000)
    parser.add_argument("--context-ms", type=int, default=90_000)
    args = parser.parse_args()

    if args.output.exists():
        raise SystemExit(f"refusing existing output: {args.output}")
    args.output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    args.output.touch(mode=0o600)

    seen = 0
    finals: list[dict] = []
    prior_questions: list[str] = []
    last_generation_audio_ms = 0
    output_cursor = 0

    with args.output.open("a") as output:
        while True:
            event_data = args.events.read_text() if args.events.exists() else ""
            lines = event_data.splitlines()
            if event_data and not event_data.endswith("\n"):
                lines = lines[:-1]
            for line in lines[seen:]:
                event = json.loads(line)
                if event["type"] != "transcript.final":
                    continue
                finals.append(event)
                audio_ms = event["source_audio_ms"]
                if audio_ms - last_generation_audio_ms < args.interval_ms:
                    continue

                evidence = context_window(finals, audio_ms, args.context_ms)
                response, generation_ms = ask_claude(evidence, prior_questions)
                question = response["question"].strip()
                if question:
                    prior_questions.append(question)
                last_generation_audio_ms = audio_ms
                output_cursor += 1
                feedback = {
                    "schema_version": 1,
                    "cursor": output_cursor,
                    "type": "assistant.feedback",
                    "source_audio_ms": audio_ms,
                    "created_at": datetime.now(timezone.utc).isoformat(),
                    "generation_ms": generation_ms,
                    "event_to_feedback_ms": event_age_ms(event["created_at"]),
                    "context": response["context"].strip(),
                    "question": question,
                    "evidence_cursors": [item["cursor"] for item in evidence],
                    "evidence_start_ms": evidence[0]["source_audio_ms"],
                    "evidence_end_ms": evidence[-1]["source_audio_ms"],
                }
                output.write(json.dumps(feedback, separators=(",", ":")) + "\n")
                output.flush()

            seen = len(lines)
            if args.done.exists() and seen == len(lines):
                break
            time.sleep(0.2)

    print(f"Generated {output_cursor} context/question events: {args.output}")


if __name__ == "__main__":
    main()
