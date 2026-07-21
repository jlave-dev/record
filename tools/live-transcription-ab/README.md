# Local Live-Transcription A/B Test

Compare Apple SpeechTranscriber with FluidAudio's Parakeet EOU model on a meeting recording without uploading the recording or transcript anywhere.

This is an engine-selection harness, not the finished live-capture feature. It measures final transcript output and processing speed from identical normalized audio. It does not claim to measure live end-of-utterance latency yet.

## Privacy

- The input media is read from its existing path and never copied into this repository.
- ffmpeg creates normalized audio in a private temporary directory and the script deletes it on exit.
- Transcripts and comparison results are written only to the output directory you choose.
- The script makes no transcription API calls. Apple SpeechTranscriber runs on-device; FluidAudio runs its open-source Core ML model on-device.
- First use may download an Apple language asset and the FluidAudio model. Those downloads contain no meeting data.
- Do not put the output directory inside this checkout. Do not commit, push, paste, or upload its contents unless company policy explicitly allows it.

## Requirements

- Apple-silicon Mac.
- macOS 26 or newer. Apple SpeechTranscriber is unavailable on older macOS releases.
- Xcode 26 or newer: `xcodebuild -version`.
- Homebrew ffmpeg: `brew install ffmpeg`.
- Network access for the first build/model installation. Subsequent runs use cached source/models.
- English meeting audio for this first comparison.

No OpenAI, Anthropic, FluidAudio, or Hugging Face API key is used.

## Get the branch on the work laptop

```bash
git clone --branch feat/live-transcription-ab --single-branch \
  https://github.com/jlave-dev/record.git record-live-ab
cd record-live-ab
```

If the repository already exists:

```bash
git fetch origin
git switch --track origin/feat/live-transcription-ab
```

If you previously created that local branch, use `git switch feat/live-transcription-ab && git pull --ff-only` instead.

## Run the comparison

Choose an output directory outside the repository:

```bash
./tools/live-transcription-ab/run-ab.sh \
  --input "/absolute/path/to/meeting.mp4" \
  --output "$HOME/record-ab-results/meeting-1"
```

The output directory must be empty. Source media is never moved or modified.

The first run takes longer because Swift resolves/builds FluidAudio, Apple may install its English speech asset, and FluidAudio downloads the Parakeet EOU model. Neither engine receives the meeting over the network.

## Add accuracy scores

A side-by-side diff shows disagreement but cannot determine which engine is correct. If the meeting platform already produced a transcript, save a corrected excerpt locally and pass it as the reference:

```bash
./tools/live-transcription-ab/run-ab.sh \
  --input "/absolute/path/to/meeting.mp4" \
  --reference "/absolute/path/to/corrected-reference.txt" \
  --output "$HOME/record-ab-results/meeting-1-with-reference"
```

The summary will include word error rate for each engine. A lower value is better.

## Results

The private output directory contains:

- `apple.txt`: Apple final transcript.
- `fluid.txt`: FluidAudio final transcript.
- `apple-vs-fluid.diff`: direct output difference.
- `summary.json`: processing time, realtime factor, word counts, and optional WER.
- `apple.json` and `fluid.json`: engine metadata and detailed local results.

Inspect locally:

```bash
open "$HOME/record-ab-results/meeting-1"
python3 -m json.tool "$HOME/record-ab-results/meeting-1/summary.json"
```

If company policy prevents sharing transcripts or derived metrics, do not send anything back. You can make the selection on the work laptop using transcript accuracy, WER, and processing speed.

## Clean up

Delete only the explicit result directory after reviewing it:

```bash
rm -r "$HOME/record-ab-results/meeting-1"
```

FluidAudio models remain in the user's Application Support cache for later runs. The Apple speech asset is managed by macOS.

## Validate the harness

These checks use no meeting data:

```bash
python3 -m unittest discover -s tools/live-transcription-ab/tests -v
bash -n tools/live-transcription-ab/run-ab.sh
swift build --package-path tools/live-transcription-ab -c release
```
