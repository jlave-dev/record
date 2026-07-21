#!/usr/bin/env bash
set -euo pipefail
umask 077

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
input_path=""
output_dir=""
reference_path=""
locale="en-US"

usage() {
  cat <<'EOF'
Usage: run-ab.sh --input MEDIA --output EMPTY_DIR [--reference TEXT] [--locale en-US]

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

command -v ffmpeg >/dev/null 2>&1 || { echo "ffmpeg is required: brew install ffmpeg" >&2; exit 127; }
command -v swift >/dev/null 2>&1 || { echo "Swift/Xcode 26 is required" >&2; exit 127; }

macos_major="$(sw_vers -productVersion | cut -d. -f1)"
[[ "$macos_major" -ge 26 ]] || { echo "Apple vs FluidAudio requires macOS 26 or newer" >&2; exit 2; }

mkdir -p "$output_dir"
chmod 700 "$output_dir"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/record-live-ab.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
canonical_audio="$work_dir/canonical.wav"

echo "Normalizing audio locally..."
ffmpeg -hide_banner -loglevel error -nostdin -y -i "$input_path" -vn -ac 1 -ar 16000 -c:a pcm_f32le "$canonical_audio"

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
