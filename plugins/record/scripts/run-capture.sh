#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  run-capture.sh start --app APP [--output DIR] [--width PX] [--height PX]
  run-capture.sh stop
  run-capture.sh status
  run-capture.sh doctor
  run-capture.sh setup
  run-capture.sh apps
USAGE
}

fail() {
  local message="$1"
  local next="$2"
  local code="${3:-2}"
  echo "$message" >&2
  echo "Next: $next" >&2
  exit "$code"
}

require_record() {
  if ! command -v record >/dev/null 2>&1; then
    fail "record CLI was not found on PATH." "run \`brew install jlave-dev/tap/record\`." 127
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
  if record capture "$@"; then
    return 0
  fi
  local status=$?

  case "$context" in
    start)
      echo "capture start failed." >&2
      echo "Next: run \`record capture doctor --json\`; for app resolution failures, run \`record capture apps --json\`." >&2
      ;;
    doctor)
      echo "capture doctor reported setup or environment problems." >&2
      echo "Next: run \`record capture setup\`, enable CaptureAgent in Screen & System Audio Recording if requested, then run \`record capture doctor --json\`." >&2
      ;;
    apps)
      echo "capture could not list capturable apps." >&2
      echo "Next: run \`record capture doctor --json\` to check ScreenCaptureKit and macOS permission." >&2
      ;;
    *)
      echo "capture $context failed." >&2
      echo "Next: run \`record capture doctor --json\` and retry after resolving the reported setup issue." >&2
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
require_record

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
        --width|--height)
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
  stop|status|doctor|apps|setup)
    [[ $# -eq 0 ]] || fail "$command_name does not accept extra arguments." "retry as \`run-capture.sh $command_name\`."
    run_capture "$command_name" "$command_name" --json
    ;;
  *)
    usage
    fail "Unknown capture helper command: $command_name" "retry with start, stop, status, doctor, setup, or apps."
    ;;
esac
