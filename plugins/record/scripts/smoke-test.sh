#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
plugin_root="$(cd -- "$script_dir/.." && pwd)"
codex_home="${CODEX_HOME:-$HOME/.codex}"
plugin_validator="${PLUGIN_VALIDATOR:-$codex_home/skills/.system/plugin-creator/scripts/validate_plugin.py}"
skill_validator="${SKILL_VALIDATOR:-$codex_home/skills/.system/skill-creator/scripts/quick_validate.py}"

fail() {
  echo "smoke-test failed: $1" >&2
  exit 1
}

run() {
  echo "==> $*"
  "$@"
}

expect_failure_contains() {
  local label="$1"
  local expected_status="$2"
  local expected_text="$3"
  shift 3

  set +e
  local output
  output="$("$@" 2>&1)"
  local status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    echo "$output" >&2
    fail "$label unexpectedly succeeded"
  fi
  if [[ "$expected_status" != "*" && "$status" -ne "$expected_status" ]]; then
    echo "$output" >&2
    fail "$label exited $status, expected $expected_status"
  fi
  if [[ "$output" != *"$expected_text"* ]]; then
    echo "$output" >&2
    fail "$label did not include expected text: $expected_text"
  fi
}

[[ -f "$plugin_root/.codex-plugin/plugin.json" ]] || fail "missing plugin manifest"
[[ -x "$script_dir/run-capture.sh" ]] || fail "run-capture.sh is not executable"
[[ -x "$script_dir/run-transcribe.sh" ]] || fail "run-transcribe.sh is not executable"

python3 -m json.tool "$plugin_root/.codex-plugin/plugin.json" >/dev/null

if [[ -f "$plugin_validator" ]]; then
  run python3 "$plugin_validator" "$plugin_root"
fi
if [[ -f "$skill_validator" ]]; then
  run python3 "$skill_validator" "$plugin_root/skills/capture"
  run python3 "$skill_validator" "$plugin_root/skills/transcribe"
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
tmp_input="$tmp_dir/input.wav"
touch "$tmp_input"

safe_path="/usr/bin:/bin"

expect_failure_contains \
  "missing record CLI for capture" \
  127 \
  "brew install jlave-dev/tap/record" \
  env PATH="$safe_path" /bin/bash "$script_dir/run-capture.sh" status

expect_failure_contains \
  "missing record CLI for transcribe" \
  127 \
  "brew install jlave-dev/tap/record" \
  env PATH="$safe_path" /bin/bash "$script_dir/run-transcribe.sh" --input "$tmp_input" --output "$tmp_dir/out"

expect_failure_contains \
  "missing transcribe input" \
  2 \
  "--input PATH is required" \
  env PATH="$safe_path" /bin/bash "$script_dir/run-transcribe.sh" --output "$tmp_dir/out"

expect_failure_contains \
  "conflicting source flags" \
  2 \
  "Conflicting source flags" \
  env PATH="$safe_path" /bin/bash "$script_dir/run-transcribe.sh" --input "$tmp_input" --output "$tmp_dir/out" --copy-source --move-source

echo "Plugin smoke test passed: $plugin_root"
