# Local Live-Transcription Replay

Replay prerecorded meeting audio at source speed through FluidAudio, emit timestamped partial and committed transcript events, and optionally have Codex generate grounded context and questions while the meeting plays.

This is a test harness, not live ScreenCaptureKit capture or a production `record live` command.

## Privacy

- Input media is read in place and never modified.
- Normalized audio is stored in a private temporary directory and deleted on exit.
- FluidAudio transcription runs locally; first use downloads its source and model.
- Results use private permissions in the output directory you choose.
- `--questions` sends rolling committed transcript text—not raw audio—to OpenAI through the installed Codex CLI. Each request is ephemeral, read-only, schema-constrained, and isolated from repository rules and user configuration.
- Keep private outputs outside this checkout and never commit them.

## Requirements

- Apple-silicon Mac with macOS 15 or newer.
- Xcode 16 or newer.
- Homebrew ffmpeg: `brew install ffmpeg`.
- English audio.
- Network access for the first FluidAudio build and model download.
- Installed and authenticated Codex CLI only when using `--questions`.

## Run

Start with a two-minute excerpt. Without `--questions`, audio and transcript data remain local:

```bash
./tools/live-transcription-replay/run-replay.sh \
  --input "/absolute/path/to/meeting.mp4" \
  --output "$HOME/record-live-results/meeting-opening" \
  --duration 120
```

Add `--questions` only when the transcript may be sent to OpenAI:

```bash
./tools/live-transcription-replay/run-replay.sh \
  --questions \
  --input "/absolute/path/to/meeting.mp4" \
  --output "$HOME/record-live-results/meeting-opening-with-questions" \
  --duration 120
```

The replay is timestamp-paced, so two minutes of input take about two minutes after setup. Omit `--duration` to replay the complete meeting.

FluidAudio's repeated native end-of-utterance callback is unreliable in the pinned version. The harness commits on native EOU, after a partial remains stable for 1.5 seconds, or after 15 seconds of continuous speech. Override the fallback thresholds with `--stable-partial-ms` and `--max-utterance-ms` when measuring them.

The output directory contains:

- `events.jsonl`: ordered partial and committed transcript events.
- `replay-summary.json`: event counts, commit reasons, and delivery latency.
- `questions.jsonl`: optional Codex feedback with evidence cursors and latency.

## Public fixture

The development proof used GitLab's public product-marketing meeting:

```bash
brew install yt-dlp
yt-dlp -f 18 \
  -o "$HOME/Downloads/product-marketing-meeting.%(ext)s" \
  "https://www.youtube.com/watch?v=lBVtvOpU80Q"

./tools/live-transcription-replay/run-replay.sh \
  --questions \
  --input "$HOME/Downloads/product-marketing-meeting.mp4" \
  --output "$HOME/record-live-results/public-opening" \
  --duration 120
```

## Validate

These checks use no meeting data:

```bash
python3 -m unittest discover -s tools/live-transcription-replay/tests -v
bash -n tools/live-transcription-replay/run-replay.sh
swift build --package-path tools/live-transcription-replay -c release --product fluid-transcribe
```
