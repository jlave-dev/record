#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
version="$(node -p "require('$repo_root/package.json').version")"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
prefix="$tmp_dir/prefix"
log="$tmp_dir/calls.log"
plugin_state_dir="$tmp_dir/plugin-state"

run_record() {
  env \
    MOCK_FAIL_COMMAND="${MOCK_FAIL_COMMAND:-}" \
    MOCK_OLD_CODEX="${MOCK_OLD_CODEX:-0}" \
    MOCK_CLAUDE_MARKETPLACE="${MOCK_CLAUDE_MARKETPLACE:-0}" \
    MOCK_FAIL_SWAP="${MOCK_FAIL_SWAP:-0}" \
    MOCK_FAIL_STATE_COMMIT="${MOCK_FAIL_STATE_COMMIT:-0}" \
    MOCK_FAIL_COPY="${MOCK_FAIL_COPY:-0}" \
    MOCK_RUNTIME_EXIT="${MOCK_RUNTIME_EXIT:-0}" \
    MOCK_RECORD_PLUGINS_INSTALLED="${MOCK_RECORD_PLUGINS_INSTALLED:-0}" \
    RECORD_PLUGIN_MARKETPLACE="$tmp_dir/plugin-marketplace" \
    RECORD_PLUGIN_STATE_DIR="$plugin_state_dir" \
    PATH="$tmp_dir:/usr/bin:/bin" \
    "$prefix/bin/record" "$@"
}

mkdir -p \
  "$prefix/bin" \
  "$prefix/libexec/record/capture" \
  "$prefix/libexec/record/live" \
  "$prefix/share/record/marketplace/.agents/plugins" \
  "$prefix/share/record/marketplace/.claude-plugin"
cp "$repo_root/scripts/record" "$prefix/bin/record"
cat > "$tmp_dir/ditto" <<'SH'
#!/usr/bin/env bash
[[ "${MOCK_FAIL_COPY:-0}" != 1 ]] || exit 42
exec /usr/bin/ditto "$@"
SH
cat > "$tmp_dir/mv" <<'SH'
#!/usr/bin/env bash
if [[ "${MOCK_FAIL_SWAP:-0}" == 1 && "$1" == *.staging-* ]]; then
  exit 42
fi
if [[ "${MOCK_FAIL_STATE_COMMIT:-0}" == 1 && "$1" == *.version.tmp-* && "$(<"$1")" != pending ]]; then
  exit 42
fi
exec /bin/mv "$@"
SH
chmod +x "$tmp_dir/ditto" "$tmp_dir/mv"
chmod +x "$prefix/bin/record"

cat > "$prefix/libexec/record/capture/capture" <<SH
#!/usr/bin/env bash
echo "capture \$*" >> "$log"
exit "\${MOCK_RUNTIME_EXIT:-0}"
SH
cat > "$prefix/libexec/record/transcribe" <<SH
#!/usr/bin/env bash
echo "transcribe \$*" >> "$log"
SH
cat > "$prefix/libexec/record/live/live" <<SH
#!/usr/bin/env bash
echo "live \$*" >> "$log"
SH
cat > "$tmp_dir/codex" <<SH
#!/usr/bin/env bash
echo "codex \$*" >> "$log"
[[ "\${MOCK_FAIL_COMMAND:-}" != "codex \$*" ]] || exit 42
if [[ "\$*" == "plugin list --json" ]]; then
  if [[ "\${MOCK_OLD_CODEX:-0}" == "1" ]]; then
    printf '[{"pluginId":"record@record"}]\n'
  elif [[ "\${MOCK_RECORD_PLUGINS_INSTALLED:-0}" == "1" ]]; then
    printf '[{"pluginId":"record@record-cli"}]\n'
  else
    printf '[]\n'
  fi
fi
SH
cat > "$tmp_dir/claude" <<SH
#!/usr/bin/env bash
echo "claude \$*" >> "$log"
[[ "\${MOCK_FAIL_COMMAND:-}" != "claude \$*" ]] || exit 42
if [[ "\$*" == "plugin marketplace list --json" ]]; then
  if [[ "\${MOCK_CLAUDE_MARKETPLACE:-0}" == "1" ]]; then
    printf '[{"name":"record-cli"}]\n'
  else
    printf '[]\n'
  fi
elif [[ "\$*" == "plugin list --json" ]]; then
  if [[ "\${MOCK_RECORD_PLUGINS_INSTALLED:-0}" == "1" ]]; then
    printf '[{"id":"record@record-cli"}]\n'
  else
    printf '[]\n'
  fi
fi
SH
chmod +x "$prefix/libexec/record/capture/capture" "$prefix/libexec/record/transcribe" "$prefix/libexec/record/live/live" "$tmp_dir/codex" "$tmp_dir/claude"
printf '{"name":"record-cli","plugins":[]}\n' > "$prefix/share/record/marketplace/.agents/plugins/marketplace.json"
printf '{"name":"record-cli","plugins":[]}\n' > "$prefix/share/record/marketplace/.claude-plugin/marketplace.json"

[[ "$("$prefix/bin/record" --version)" == "$version" ]]
run_record capture status --json
run_record transcribe doctor --json
run_record live next --after 0 --json
run_record plugin install >/dev/null

grep -qx 'capture status --json' "$log"
grep -qx 'transcribe doctor --json' "$log"
grep -qx 'live next --after 0 --json' "$log"
grep -qx "codex plugin marketplace add $tmp_dir/plugin-marketplace --json" "$log"
grep -qx 'codex plugin add record@record-cli --json' "$log"
grep -qx 'claude plugin marketplace list --json' "$log"
grep -qx "claude plugin marketplace add $tmp_dir/plugin-marketplace --scope user" "$log"
grep -qx 'claude plugin install record@record-cli --scope user' "$log"
[[ "$(<"$plugin_state_dir/codex.version")" == "$version" ]]
[[ "$(<"$plugin_state_dir/claude.version")" == "$version" ]]

: > "$log"
run_record plugin install --codex >/dev/null
grep -qx 'codex plugin add record@record-cli --json' "$log"
if grep -q '^claude ' "$log"; then
  echo "--codex invoked Claude Code" >&2
  exit 1
fi

: > "$log"
run_record plugin install --claude >/dev/null
grep -qx 'claude plugin install record@record-cli --scope user' "$log"
if grep -q '^codex ' "$log"; then
  echo "--claude invoked Codex" >&2
  exit 1
fi

rm -rf "$plugin_state_dir"
: > "$log"
MOCK_RECORD_PLUGINS_INSTALLED=1 run_record capture status --json 2>/dev/null
grep -qx 'codex plugin add record@record-cli --json' "$log"
grep -qx 'claude plugin install record@record-cli --scope user' "$log"
[[ "$(<"$plugin_state_dir/codex.version")" == "$version" ]]
[[ "$(<"$plugin_state_dir/claude.version")" == "$version" ]]

printf '0.0.0\n' > "$plugin_state_dir/codex.version"
printf '0.0.0\n' > "$plugin_state_dir/claude.version"
: > "$log"
MOCK_RECORD_PLUGINS_INSTALLED=1 run_record plugin refresh 2>/dev/null
grep -qx 'codex plugin add record@record-cli --json' "$log"
grep -qx 'claude plugin install record@record-cli --scope user' "$log"
[[ "$(<"$plugin_state_dir/codex.version")" == "$version" ]]
[[ "$(<"$plugin_state_dir/claude.version")" == "$version" ]]

printf '0.0.0\n' > "$plugin_state_dir/codex.version"
printf '0.0.0\n' > "$plugin_state_dir/claude.version"
: > "$log"
run_record capture status --json
if grep -Eq '^(codex plugin add|claude plugin install)' "$log"; then
  echo "removed plugins were reinstalled during refresh" >&2
  exit 1
fi
[[ ! -f "$plugin_state_dir/codex.version" ]]
[[ ! -f "$plugin_state_dir/claude.version" ]]
[[ "$(<"$plugin_state_dir/codex.scan")" == "$version" ]]
[[ "$(<"$plugin_state_dir/claude.scan")" == "$version" ]]

if "$prefix/bin/record" plugin install --unknown >"$tmp_dir/invalid.out" 2>&1; then
  echo "invalid plugin target unexpectedly succeeded" >&2
  exit 1
fi
grep -q 'Usage: record plugin install \[--codex|--claude\]' "$tmp_dir/invalid.out"

expect_failure() {
  local result=0
  "$@" >"$tmp_dir/failure.out" 2>&1 || result=$?
  [[ "$result" -ne 0 ]] || { echo "Expected failure: $*" >&2; exit 1; }
  if grep -Eq 'Record plugin installed|Record plugins refreshed' "$tmp_dir/failure.out"; then
    echo "Failure was reported as success" >&2
    exit 1
  fi
}

# A failed same-version manual install must invalidate the success marker,
# then retry even if a partial install left the host listing empty.
for failed_command in \
  "codex plugin marketplace add $tmp_dir/plugin-marketplace --json" \
  "codex plugin list --json" \
  "codex plugin remove record@record --json" \
  "codex plugin add record@record-cli --json" \
  "claude plugin marketplace list --json" \
  "claude plugin marketplace remove record-cli --scope user" \
  "claude plugin marketplace add $tmp_dir/plugin-marketplace --scope user" \
  "claude plugin install record@record-cli --scope user"; do
  host="${failed_command%% *}"
  printf '%s\n' "$version" > "$plugin_state_dir/codex.version"
  printf '%s\n' "$version" > "$plugin_state_dir/claude.version"
  MOCK_FAIL_COMMAND="$failed_command" MOCK_OLD_CODEX=1 MOCK_CLAUDE_MARKETPLACE=1 \
    expect_failure run_record plugin install "--$host"
  [[ "$(<"$plugin_state_dir/$host.version")" == pending ]] || exit 1
  MOCK_FAIL_COMMAND="$failed_command" MOCK_OLD_CODEX=1 MOCK_CLAUDE_MARKETPLACE=1 \
    expect_failure run_record plugin refresh
  [[ "$(<"$plugin_state_dir/$host.version")" == pending ]] || exit 1
  : > "$log"
  run_record plugin refresh 2>/dev/null
  [[ "$(<"$plugin_state_dir/$host.version")" == "$version" ]] || exit 1
  grep -q "^$host plugin " "$log"
  : > "$log"
  run_record plugin refresh
  [[ ! -s "$log" ]] || exit 1
done

# One host can succeed while the other fails; only the failure is retried.
printf '0.0.0\n' > "$plugin_state_dir/codex.version"
printf '0.0.0\n' > "$plugin_state_dir/claude.version"
MOCK_RECORD_PLUGINS_INSTALLED=1 MOCK_FAIL_COMMAND='codex plugin add record@record-cli --json' \
  expect_failure run_record plugin refresh
[[ "$(<"$plugin_state_dir/codex.version")" == pending ]] || exit 1
[[ "$(<"$plugin_state_dir/claude.version")" == "$version" ]] || exit 1
: > "$log"
run_record plugin refresh 2>/dev/null
grep -qx 'codex plugin add record@record-cli --json' "$log"
! grep -q '^claude ' "$log" || exit 1

# Automatic refresh warns but never blocks the runtime or masks its exit code.
printf 'pending\n' > "$plugin_state_dir/codex.version"
MOCK_FAIL_COMMAND='codex plugin add record@record-cli --json' \
  run_record capture status --json 2>"$tmp_dir/warning.out"
grep -q 'Warning:' "$tmp_dir/warning.out"
result=0
MOCK_FAIL_COMMAND='codex plugin add record@record-cli --json' MOCK_RUNTIME_EXIT=37 \
  run_record capture status --json 2>/dev/null || result=$?
[[ "$result" -eq 37 ]] || exit 1
run_record capture status --json 2>/dev/null
[[ "$(<"$plugin_state_dir/codex.version")" == "$version" ]] || exit 1

# Discovery failure preserves old state and remains retryable.
printf '0.0.0\n' > "$plugin_state_dir/codex.version"
MOCK_FAIL_COMMAND='codex plugin list --json' expect_failure run_record plugin refresh
[[ "$(<"$plugin_state_dir/codex.version")" == 0.0.0 ]] || exit 1
MOCK_RECORD_PLUGINS_INSTALLED=1 run_record plugin refresh 2>/dev/null
[[ "$(<"$plugin_state_dir/codex.version")" == "$version" ]] || exit 1

# Failed staging must leave the previous marketplace and version untouched.
printf 'old content\n' > "$tmp_dir/plugin-marketplace/preserved"
MOCK_FAIL_COPY=1 expect_failure run_record plugin install --codex
[[ "$(<"$tmp_dir/plugin-marketplace/preserved")" == 'old content' ]] || exit 1
[[ "$(<"$plugin_state_dir/codex.version")" == "$version" ]] || exit 1
run_record plugin install --codex >/dev/null
[[ ! -f "$tmp_dir/plugin-marketplace/preserved" ]] || exit 1

# Failed marketplace replacement restores the old contents before returning.
printf 'old content\n' > "$tmp_dir/plugin-marketplace/preserved"
MOCK_FAIL_SWAP=1 expect_failure run_record plugin install --codex
[[ "$(<"$tmp_dir/plugin-marketplace/preserved")" == 'old content' ]] || exit 1
run_record plugin install --codex >/dev/null
[[ ! -f "$tmp_dir/plugin-marketplace/preserved" ]] || exit 1

# Failure to commit the successful version must not hide the pending retry.
MOCK_FAIL_STATE_COMMIT=1 expect_failure run_record plugin install --codex
[[ "$(<"$plugin_state_dir/codex.version")" == pending ]] || exit 1
run_record plugin refresh 2>/dev/null
[[ "$(<"$plugin_state_dir/codex.version")" == "$version" ]] || exit 1

# A missing host CLI does not erase pending work or prevent the other refresh.
printf 'pending\n' > "$plugin_state_dir/codex.version"
printf '0.0.0\n' > "$plugin_state_dir/claude.version"
mv "$tmp_dir/codex" "$tmp_dir/codex.unavailable"
MOCK_RECORD_PLUGINS_INSTALLED=1 expect_failure run_record plugin refresh
[[ "$(<"$plugin_state_dir/codex.version")" == pending ]] || exit 1
[[ "$(<"$plugin_state_dir/claude.version")" == "$version" ]] || exit 1
mv "$tmp_dir/codex.unavailable" "$tmp_dir/codex"
run_record plugin refresh 2>/dev/null
[[ "$(<"$plugin_state_dir/codex.version")" == "$version" ]] || exit 1

# A state write failure must stop before modifying the host installation.
rm -rf "$plugin_state_dir"
touch "$plugin_state_dir"
: > "$log"
expect_failure run_record plugin install --codex
! grep -q '^codex ' "$log" || exit 1
rm "$plugin_state_dir"
run_record plugin install --codex >/dev/null
[[ "$(<"$plugin_state_dir/codex.version")" == "$version" ]] || exit 1

echo "record CLI test passed"
