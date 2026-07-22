# Local Live-Transcription Replay and A/B Test

Replay a prerecorded meeting at source speed through FluidAudio, emit timestamped transcript events, and optionally have Codex generate grounded context and questions while the meeting plays. On macOS 26, the same tool can also compare final FluidAudio output with Apple SpeechTranscriber.

This is a test harness, not live ScreenCaptureKit capture. It proves the transcription-to-feedback loop with prerecorded media before capture code changes.

## Privacy

- The input media is read in place and never modified.
- ffmpeg writes normalized audio to a private temporary directory that is deleted on exit.
- FluidAudio transcription runs locally with an open-source Core ML model.
- Replay events and results are mode `600` in the output directory you choose.
- First use downloads FluidAudio source and its model; no meeting audio is uploaded.
- `--questions` sends the rolling committed transcript excerpt—not raw audio—to OpenAI through the installed Codex CLI. Use it only when company policy permits that text to leave the machine.
- Each Codex request is ephemeral, read-only, schema-constrained, and isolated from repository rules and user configuration; the user's existing Codex authentication is still used.
- Never put private results in this checkout or commit, push, paste, or upload them.

## Requirements

FluidAudio replay:

- Apple-silicon Mac with macOS 15 or newer.
- Xcode 16 or newer: `xcodebuild -version`.
- Homebrew ffmpeg: `brew install ffmpeg`.
- English audio.
- Network access for the first build/model download.
- Installed and authenticated Codex CLI only when using `--questions`.

Apple-vs-FluidAudio batch comparison additionally requires macOS 26 and Xcode 26. On an older SDK, the Apple executable builds as an actionable unsupported stub instead of failing on missing symbols.

## Get the branch

```bash
git clone --branch feat/live-transcription-ab --single-branch \
  https://github.com/jlave-dev/record.git record-live-ab
cd record-live-ab
```

For an existing checkout:

```bash
git fetch origin
git switch --track origin/feat/live-transcription-ab
```

If that local branch already exists, use `git switch feat/live-transcription-ab && git pull --ff-only`.

## Test private meeting audio locally

Start with a two-minute excerpt. Without `--questions`, everything remains local:

```bash
./tools/live-transcription-ab/run-ab.sh \
  --fluid-replay \
  --input "/absolute/path/to/meeting.mp4" \
  --output "$HOME/record-live-results/meeting-opening" \
  --start 0 \
  --duration 120
```

The replay is timestamp-paced, so a two-minute excerpt takes about two minutes after model setup. Omit `--start` and `--duration` only when you intend to replay the complete meeting in real time.

If transcript text is approved for Codex:

```bash
./tools/live-transcription-ab/run-ab.sh \
  --fluid-replay \
  --questions \
  --input "/absolute/path/to/meeting.mp4" \
  --output "$HOME/record-live-results/meeting-opening-with-questions" \
  --start 0 \
  --duration 120
```

FluidAudio's repeated EOU behavior is not reliable enough by itself in the pinned version. The harness therefore commits an utterance when the engine reports EOU, when a partial remains stable for 1.5 seconds, or after 15 seconds of continuous speech. Every final event records the reason. These calibration values can be changed with `--stable-partial-ms` and `--max-utterance-ms`.

## Replay results

The private output directory contains:

- `events.jsonl`: ordered `transcript.partial` and `transcript.final` events.
- `replay-summary.json`: first partial/final timing and P50/P95/max delivery latency.
- `fluid.json`: final replay transcript and engine metadata.
- `questions.jsonl`: optional timestamped Codex context/questions with transcript evidence cursors and generation latency.

Inspect locally:

```bash
python3 -m json.tool "$HOME/record-live-results/meeting-opening/replay-summary.json"
jq . "$HOME/record-live-results/meeting-opening-with-questions/questions.jsonl"
```

## Reproduce with the public meeting fixture

The development proof used GitLab's public 42-minute product-marketing meeting:

```bash
brew install yt-dlp
yt-dlp -f 18 \
  -o "$HOME/Downloads/product-marketing-meeting.%(ext)s" \
  "https://www.youtube.com/watch?v=lBVtvOpU80Q"

./tools/live-transcription-ab/run-ab.sh \
  --fluid-replay \
  --questions \
  --input "$HOME/Downloads/product-marketing-meeting.mp4" \
  --output "$HOME/record-live-results/public-opening" \
  --duration 120
```

## Current public-fixture proof

On a two-minute timestamp-paced replay, the harness emitted 168 partials and 13 committed finals. First partial text appeared at 3.52 seconds of source audio; partial and final delivery P95 were 82 ms and 113 ms. Codex produced three distinct evidence-linked context/question events at 4.85, 9.93, and 9.43 seconds after their triggering commits.

This proves the prerecorded local-ASR-to-Codex loop. It does not yet prove live ScreenCaptureKit delivery, cursor resume, or the plan's stricter 8-second P95 agent-feedback gate; Codex CLI latency needs more repeated measurement and optimization before release readiness.

## Run the macOS 26 A/B comparison

Choose an empty output directory outside the repository:

```bash
./tools/live-transcription-ab/run-ab.sh \
  --input "/absolute/path/to/meeting.mp4" \
  --output "$HOME/record-ab-results/meeting-1"
```

To calculate directional word error rates, add a locally corrected reference:

```bash
./tools/live-transcription-ab/run-ab.sh \
  --input "/absolute/path/to/meeting.mp4" \
  --reference "/absolute/path/to/corrected-reference.txt" \
  --output "$HOME/record-ab-results/meeting-1-with-reference"
```

The A/B directory contains `apple.txt`, `fluid.txt`, their diff, engine JSON, and `summary.json`. Lower WER is better.

## Clean up

Delete only the explicit result directory after review:

```bash
rm -r "$HOME/record-live-results/meeting-opening"
```

FluidAudio models remain under the user's Application Support cache. Apple speech assets are managed by macOS.

## Validate

These checks use no meeting data:

```bash
python3 -m unittest discover -s tools/live-transcription-ab/tests -v
bash -n tools/live-transcription-ab/run-ab.sh
swift build --package-path tools/live-transcription-ab -c release --product fluid-transcribe
```

On macOS 26/Xcode 26, also run:

```bash
swift build --package-path tools/live-transcription-ab -c release
```
