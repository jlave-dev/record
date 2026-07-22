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
chmod +x "$prefix/bin/record"

cat > "$prefix/libexec/record/capture/capture" <<SH
#!/usr/bin/env bash
echo "capture \$*" >> "$log"
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
if [[ "\$*" == "plugin list --json" ]]; then
  if [[ "\${MOCK_RECORD_PLUGINS_INSTALLED:-0}" == "1" ]]; then
    printf '[{"pluginId":"record@record-cli"}]\n'
  else
    printf '[]\n'
  fi
fi
SH
cat > "$tmp_dir/claude" <<SH
#!/usr/bin/env bash
echo "claude \$*" >> "$log"
if [[ "\$*" == "plugin marketplace list --json" ]]; then
  printf '[]\n'
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

echo "record CLI test passed"
