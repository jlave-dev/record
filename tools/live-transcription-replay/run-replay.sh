#!/usr/bin/env bash
set -euo pipefail
umask 077

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
input_path=""
output_dir=""
questions=false
start_seconds=""
duration_seconds=""
stable_partial_ms=1500
max_utterance_ms=15000

usage() {
  cat <<'EOF'
Usage:
  run-replay.sh --input MEDIA --output EMPTY_DIR [--start SEC] [--duration SEC]
                [--questions] [--stable-partial-ms 1500] [--max-utterance-ms 15000]

The source media is read in place. Temporary normalized audio is deleted on exit.
Transcript results remain only in OUTPUT_DIR.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input) input_path="${2:-}"; shift 2 ;;
    --output) output_dir="${2:-}"; shift 2 ;;
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
  command -v codex >/dev/null 2>&1 || { echo "Codex CLI is required for --questions" >&2; exit 127; }
fi

mkdir -p "$output_dir"
chmod 700 "$output_dir"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/record-live-replay.XXXXXX")"
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
done_path="$work_dir/replay.done"

echo "Normalizing audio locally..."
ffmpeg_args=(-hide_banner -loglevel error -nostdin -y)
[[ -n "$start_seconds" ]] && ffmpeg_args+=(-ss "$start_seconds")
ffmpeg_args+=(-i "$input_path")
[[ -n "$duration_seconds" ]] && ffmpeg_args+=(-t "$duration_seconds")
ffmpeg "${ffmpeg_args[@]}" -vn -ac 1 -ar 16000 -c:a pcm_f32le "$canonical_audio"

echo "Building FluidAudio replay tool (first build downloads FluidAudio source)..."
swift build --package-path "$script_dir" -c release --product fluid-transcribe

if [[ "$questions" == true ]]; then
  echo "Starting Codex context/question consumer..."
  python3 "$script_dir/question_consumer.py" \
    --events "$output_dir/events.jsonl" \
    --done "$done_path" \
    --output "$output_dir/questions.jsonl" &
  consumer_pid=$!
fi

echo "Replaying FluidAudio at source speed..."
swift run --package-path "$script_dir" -c release --skip-build fluid-transcribe \
  --input "$canonical_audio" \
  --events "$output_dir/events.jsonl" \
  --stable-partial-ms "$stable_partial_ms" \
  --max-utterance-ms "$max_utterance_ms"

if [[ -n "$consumer_pid" ]]; then
  touch "$done_path"
  wait "$consumer_pid"
  consumer_pid=""
fi

replay_summary="$(python3 "$script_dir/summarize_events.py" \
  --events "$output_dir/events.jsonl" \
  --output "$output_dir/replay-summary.json")"
echo "Done. Private results: $output_dir"
echo "Replay summary: $replay_summary"
