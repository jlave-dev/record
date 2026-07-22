#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  run-live.sh start --app APP [--output DIR]
  run-live.sh next --after CURSOR [--timeout SECONDS]
  run-live.sh status
  run-live.sh stop
  run-live.sh setup
  run-live.sh doctor
USAGE
}

fail() {
  echo "$1" >&2
  echo "Next: $2" >&2
  exit "${3:-2}"
}

command -v record >/dev/null 2>&1 || fail \
  "record CLI was not found on PATH." \
  "run \`brew install jlave-dev/tap/record\`." \
  127

[[ $# -gt 0 ]] || { usage; exit 2; }
command_name="$1"
shift

case "$command_name" in
  start)
    args=(start --json)
    saw_app=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --app)
          [[ $# -ge 2 ]] || fail "--app requires a value." "retry with --app APP."
          args+=(--app "$2")
          saw_app=1
          shift 2
          ;;
        --output)
          [[ $# -ge 2 ]] || fail "--output requires a value." "retry with --output DIR."
          args+=(--output "$2")
          shift 2
          ;;
        *) usage; fail "Unknown live start argument: $1" "retry with --app APP and optional --output DIR." ;;
      esac
    done
    [[ "$saw_app" -eq 1 ]] || fail "live start requires --app APP." "run record capture apps --json, then retry."
    record live "${args[@]}"
    ;;
  next)
    args=(next --json)
    saw_after=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --after)
          [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || fail "--after requires a non-negative cursor." "start with --after 0."
          args+=(--after "$2")
          saw_after=1
          shift 2
          ;;
        --timeout)
          [[ $# -ge 2 && "$2" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "--timeout requires non-negative seconds." "retry with --timeout 20."
          args+=(--timeout "$2")
          shift 2
          ;;
        *) usage; fail "Unknown live next argument: $1" "retry with --after CURSOR and optional --timeout SECONDS." ;;
      esac
    done
    [[ "$saw_after" -eq 1 ]] || fail "live next requires --after CURSOR." "start with --after 0."
    record live "${args[@]}"
    ;;
  status|stop|setup|doctor)
    [[ $# -eq 0 ]] || fail "$command_name does not accept extra arguments." "retry as run-live.sh $command_name."
    record live "$command_name" --json
    ;;
  *) usage; fail "Unknown live helper command: $command_name" "retry with start, next, status, stop, setup, or doctor." ;;
esac
