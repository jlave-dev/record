#!/usr/bin/env python3
import argparse
import json
import math
from pathlib import Path
from typing import Optional


def percentile(values: list[int], percent: int) -> Optional[int]:
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(0, math.ceil(percent / 100 * len(ordered)) - 1)]


def summarize(events: list[dict]) -> dict:
    expected_cursors = list(range(1, len(events) + 1))
    if [event.get("cursor") for event in events] != expected_cursors:
        raise ValueError("event cursors must be contiguous and start at 1")

    for event in events:
        if event.get("type") not in {"transcript.partial", "transcript.final"}:
            raise ValueError(f"unsupported event type: {event.get('type')}")
        if event.get("source_audio_ms", -1) < 0 or event.get("delivery_latency_ms", -1) < 0:
            raise ValueError("event timings must be non-negative")

    partials = [event for event in events if event["type"] == "transcript.partial"]
    finals = [event for event in events if event["type"] == "transcript.final"]
    reasons = sorted({event.get("final_reason") for event in finals if event.get("final_reason")})

    def latency(events_for_type: list[dict]) -> dict:
        values = [event["delivery_latency_ms"] for event in events_for_type]
        return {
            "p50_ms": percentile(values, 50),
            "p95_ms": percentile(values, 95),
            "max_ms": max(values) if values else None,
        }

    return {
        "schema_version": 1,
        "engine": "fluidaudio-parakeet-eou-replay",
        "model": "FluidAudio 0.15.5 / Parakeet EOU 120M 320ms",
        "event_count": len(events),
        "partial_count": len(partials),
        "final_count": len(finals),
        "eou_final_count": sum(event.get("final_reason") == "end_of_utterance" for event in finals),
        "final_reasons": {
            reason: sum(event.get("final_reason") == reason for event in finals) for reason in reasons
        },
        "first_partial_source_audio_ms": partials[0]["source_audio_ms"] if partials else None,
        "first_final_source_audio_ms": finals[0]["source_audio_ms"] if finals else None,
        "partial_delivery_latency": latency(partials),
        "final_delivery_latency": latency(finals),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--events", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    events = [json.loads(line) for line in args.events.read_text().splitlines() if line.strip()]
    args.output.write_text(json.dumps(summarize(events), indent=2, sort_keys=True) + "\n")
    args.output.chmod(0o600)
    print(args.output)


if __name__ == "__main__":
    main()
