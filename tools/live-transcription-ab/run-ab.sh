#!/usr/bin/env bash
set -euo pipefail
umask 077

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
input_path=""
output_dir=""
reference_path=""
locale="en-US"
fluid_replay=false
questions=false
start_seconds=""
duration_seconds=""
stable_partial_ms=1500
max_utterance_ms=15000

usage() {
  cat <<'EOF'
Usage:
  run-ab.sh --input MEDIA --output EMPTY_DIR [--reference TEXT] [--locale en-US]
  run-ab.sh --fluid-replay --input MEDIA --output EMPTY_DIR [--start SEC] [--duration SEC]
            [--questions] [--stable-partial-ms 1500] [--max-utterance-ms 15000]

The source media is read in place. Temporary normalized audio is deleted on exit.
Transcript results remain only in OUTPUT_DIR.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input) input_path="${2:-}"; shift 2 ;;
    --output) output_dir="${2:-}"; shift 2 ;;
    --reference) reference_path="${2:-}"; shift 2 ;;
    --locale) locale="${2:-}"; shift 2 ;;
    --fluid-replay) fluid_replay=true; shift ;;
    --questions) questions=true; shift ;;
    --start) start_seconds="${2:-}"; shift 2 ;;
    --duration) duration_seconds="${2:-}"; shift 2 ;;
    --stable-partial-ms) stable_partial_ms="${2:-}"; shift 2 ;;
    --max-utterance-ms) max_utterance_ms="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$input_path" ]] || { echo "--input is required" >&2; exit 2; }
[[ -r "$input_path" ]] || { echo "Input is not readable: $input_path" >&2; exit 2; }
[[ -n "$output_dir" ]] || { echo "--output is required" >&2; exit 2; }
if [[ -e "$output_dir" && -n "$(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
  echo "Refusing non-empty output directory: $output_dir" >&2
  exit 2
fi
if [[ -n "$reference_path" && ! -r "$reference_path" ]]; then
  echo "Reference is not readable: $reference_path" >&2
  exit 2
fi
if [[ "$fluid_replay" == false && "$questions" == true ]]; then
  echo "--questions requires --fluid-replay" >&2
  exit 2
fi
for numeric_value in "$start_seconds" "$duration_seconds"; do
  [[ -z "$numeric_value" || "$numeric_value" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
    echo "--start and --duration require non-negative seconds" >&2
    exit 2
  }
done
for integer_value in "$stable_partial_ms" "$max_utterance_ms"; do
  [[ "$integer_value" =~ ^[1-9][0-9]*$ ]] || {
    echo "streaming timing values require positive integers" >&2
    exit 2
  }
done

command -v ffmpeg >/dev/null 2>&1 || { echo "ffmpeg is required: brew install ffmpeg" >&2; exit 127; }
command -v swift >/dev/null 2>&1 || { echo "Swift/Xcode is required" >&2; exit 127; }
if [[ "$questions" == true ]]; then
  command -v claude >/dev/null 2>&1 || { echo "Claude Code is required for --questions" >&2; exit 127; }
fi

macos_major="$(sw_vers -productVersion | cut -d. -f1)"
if [[ "$fluid_replay" == false && "$macos_major" -lt 26 ]]; then
  echo "Apple vs FluidAudio requires macOS 26 or newer; use --fluid-replay on macOS 15" >&2
  exit 2
fi

mkdir -p "$output_dir"
chmod 700 "$output_dir"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/record-live-ab.XXXXXX")"
consumer_pid=""
cleanup() {
  if [[ -n "$consumer_pid" ]] && kill -0 "$consumer_pid" 2>/dev/null; then
    kill "$consumer_pid" 2>/dev/null || true
    wait "$consumer_pid" 2>/dev/null || true
  fi
  rm -rf "$work_dir"
}
trap cleanup EXIT
canonical_audio="$work_dir/canonical.wav"

echo "Normalizing audio locally..."
ffmpeg_args=(-hide_banner -loglevel error -nostdin -y)
[[ -n "$start_seconds" ]] && ffmpeg_args+=(-ss "$start_seconds")
ffmpeg_args+=(-i "$input_path")
[[ -n "$duration_seconds" ]] && ffmpeg_args+=(-t "$duration_seconds")
ffmpeg "${ffmpeg_args[@]}" -vn -ac 1 -ar 16000 -c:a pcm_f32le "$canonical_audio"

if [[ "$fluid_replay" == true ]]; then
  echo "Building FluidAudio replay tool (first build downloads FluidAudio source)..."
  swift build --package-path "$script_dir" -c release --product fluid-transcribe

  if [[ "$questions" == true ]]; then
    echo "Starting Claude context/question consumer..."
    python3 "$script_dir/question_consumer.py" \
      --events "$output_dir/events.jsonl" \
      --done "$output_dir/fluid.json" \
      --output "$output_dir/questions.jsonl" &
    consumer_pid=$!
  fi

  echo "Replaying FluidAudio at source speed..."
  swift run --package-path "$script_dir" -c release --skip-build fluid-transcribe \
    --input "$canonical_audio" \
    --output "$output_dir/fluid.json" \
    --locale "$locale" \
    --replay-events "$output_dir/events.jsonl" \
    --stable-partial-ms "$stable_partial_ms" \
    --max-utterance-ms "$max_utterance_ms"

  if [[ -n "$consumer_pid" ]]; then
    wait "$consumer_pid"
    consumer_pid=""
  fi

  replay_summary="$(python3 "$script_dir/summarize_events.py" \
    --events "$output_dir/events.jsonl" \
    --output "$output_dir/replay-summary.json")"
  echo "Done. Private results: $output_dir"
  echo "Replay summary: $replay_summary"
  exit 0
fi

echo "Building test tools (first build downloads FluidAudio source)..."
swift build --package-path "$script_dir" -c release --product apple-transcribe
swift build --package-path "$script_dir" -c release --product fluid-transcribe

echo "Running Apple SpeechTranscriber (macOS may download its language asset)..."
swift run --package-path "$script_dir" -c release --skip-build apple-transcribe \
  --input "$canonical_audio" --output "$output_dir/apple.json" --locale "$locale"

echo "Running FluidAudio (first run downloads the Parakeet model)..."
swift run --package-path "$script_dir" -c release --skip-build fluid-transcribe \
  --input "$canonical_audio" --output "$output_dir/fluid.json" --locale "$locale"

compare_args=(
  --apple "$output_dir/apple.json"
  --fluid "$output_dir/fluid.json"
  --output "$output_dir"
)
if [[ -n "$reference_path" ]]; then
  compare_args+=(--reference "$reference_path")
fi

summary_path="$(python3 "$script_dir/compare.py" "${compare_args[@]}")"
echo "Done. Private results: $output_dir"
echo "Summary: $summary_path"
