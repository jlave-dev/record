#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  run-transcribe.sh --input PATH --output DIR [--copy-source|--move-source]
USAGE
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
plugin_root="$(cd -- "$script_dir/.." && pwd)"

fail() {
  local message="$1"
  local next="$2"
  local code="${3:-2}"
  echo "$message" >&2
  echo "Next: $next" >&2
  exit "$code"
}

require_transcribe() {
  if ! command -v transcribe >/dev/null 2>&1; then
    fail "transcribe binary was not found on PATH." "run \`npm run setup:transcribe\` from the record repo, or install transcribe so \`transcribe --help\` works." 127
  fi
}

run_transcribe() {
  if transcribe "$@"; then
    return 0
  fi
  local status=$?
  echo "transcribe failed." >&2
  echo "Next: run \`transcribe doctor --json\`; if Whisper or the model is missing, run \`npm run setup:transcribe\`." >&2
  exit "$status"
}

input_path=""
output_dir=""
copy_source=0
move_source=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)
      [[ $# -ge 2 ]] || fail "--input requires a value." "retry with \`--input /path/to/media --output /path/to/output-dir\`."
      input_path="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || fail "--output requires a value." "retry with \`--output /path/to/output-dir\`."
      output_dir="$2"
      shift 2
      ;;
    --copy-source)
      copy_source=1
      shift
      ;;
    --move-source)
      move_source=1
      shift
      ;;
    *)
      usage
      fail "Unknown argument: $1" "retry with \`--input PATH --output DIR\` and at most one source handling flag."
      ;;
  esac
done

if [[ "$copy_source" -eq 1 && "$move_source" -eq 1 ]]; then
  fail "Conflicting source flags: pass only one of --copy-source or --move-source." "retry with only one source handling flag, or neither."
fi
[[ -n "$input_path" ]] || fail "--input PATH is required." "retry with \`--input /path/to/media --output /path/to/output-dir\`."
[[ -n "$output_dir" ]] || fail "--output DIR is required." "retry with \`--output /path/to/output-dir\`."
[[ -r "$input_path" ]] || fail "Input path is not readable: $input_path" "check the path with \`ls -l '$input_path'\`, or choose a readable local media file."
if [[ -e "$output_dir" && ! -d "$output_dir" ]]; then
  fail "Output path exists and is not a directory: $output_dir" "choose a directory path for \`--output\`, or move the existing file."
fi

args=(--input "$input_path" --output "$output_dir" --json)
[[ "$copy_source" -eq 1 ]] && args+=(--copy-source)
[[ "$move_source" -eq 1 ]] && args+=(--move-source)

require_transcribe
run_transcribe "${args[@]}"
