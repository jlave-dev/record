#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  run-capture.sh start --app APP [--output DIR] [--width PX] [--height PX] [--video-bitrate KBPS]
  run-capture.sh stop
  run-capture.sh status
  run-capture.sh pause
  run-capture.sh resume
  run-capture.sh doctor
  run-capture.sh setup [--force] [--dry-run]
  run-capture.sh apps
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

require_capture() {
  if ! command -v capture >/dev/null 2>&1; then
    fail "capture binary was not found on PATH." "run \`npm run setup:capture\` from the record repo, or install capture so \`capture --help\` works." 127
  fi
}

positive_int() {
  local label="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    fail "$label must be a positive integer." "retry with a positive integer, for example \`$label 1920\`."
  fi
}

run_capture() {
  local context="$1"
  shift
  if capture "$@"; then
    return 0
  fi
  local status=$?

  case "$context" in
    start)
      echo "capture start failed." >&2
      echo "Next: run \`capture doctor --json\`; for app resolution failures, run \`capture apps --json\`." >&2
      ;;
    doctor)
      echo "capture doctor reported setup or environment problems." >&2
      echo "Next: run \`npm run setup:capture\`, restart OBS if needed, then run \`capture doctor --json\`." >&2
      ;;
    apps)
      echo "capture could not list capturable apps." >&2
      echo "Next: run \`capture doctor --json\` to check OBS, WebSocket, and macOS permissions." >&2
      ;;
    *)
      echo "capture $context failed." >&2
      echo "Next: run \`capture doctor --json\` and retry after resolving the reported setup issue." >&2
      ;;
  esac

  exit "$status"
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

command_name="$1"
shift
require_capture

case "$command_name" in
  start)
    args=(start --json)
    saw_app=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --app)
          [[ $# -ge 2 ]] || fail "--app requires a value." "retry with \`--app APP\`, or run \`capture apps --json\` to list visible apps."
          saw_app=1
          args+=(--app "$2")
          shift 2
          ;;
        --output)
          [[ $# -ge 2 ]] || fail "--output requires a value." "retry with \`--output DIR\`."
          args+=(--output "$2")
          shift 2
          ;;
        --width|--height|--video-bitrate)
          [[ $# -ge 2 ]] || fail "$1 requires a value." "retry with a positive integer value."
          positive_int "$1" "$2"
          args+=("$1" "$2")
          shift 2
          ;;
        *)
          usage
          fail "Unknown start argument: $1" "retry with one of the documented start flags."
          ;;
      esac
    done
    [[ "$saw_app" -eq 1 ]] || fail "start requires --app APP." "run \`capture apps --json\` to list visible apps, then retry with \`--app APP\`."
    run_capture start "${args[@]}"
    ;;
  stop|status|pause|resume|doctor|apps)
    [[ $# -eq 0 ]] || fail "$command_name does not accept extra arguments." "retry as \`run-capture.sh $command_name\`."
    run_capture "$command_name" "$command_name" --json
    ;;
  setup)
    args=(setup --json)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --force|--dry-run)
          args+=("$1")
          shift
          ;;
        *)
          usage
          fail "Unknown setup argument: $1" "retry with \`--force\`, \`--dry-run\`, or no setup flags."
          ;;
      esac
    done
    run_capture setup "${args[@]}"
    ;;
  *)
    usage
    fail "Unknown capture helper command: $command_name" "retry with start, stop, status, pause, resume, doctor, setup, or apps."
    ;;
esac
