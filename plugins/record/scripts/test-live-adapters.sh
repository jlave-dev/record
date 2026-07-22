#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
plugin_root="$(cd -- "$script_dir/.." && pwd)"
codex_skill="$plugin_root/skills/live/SKILL.md"
claude_skill="$plugin_root/claude/skills/live/SKILL.md"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

for skill in "$codex_skill" "$claude_skill"; do
  grep -q 'transcript.final' "$skill"
  grep -q 'source_audio_ms' "$skill"
  grep -qi 'Debounce semantic repeats' "$skill"
  grep -qi 'sensitive local artifacts' "$skill"
done
grep -q 'run-live.sh start' "$codex_skill"
grep -q 'run-live.sh next' "$codex_skill"
grep -q 'record live start' "$claude_skill"
grep -q 'record live next' "$claude_skill"

cat > "$tmp_dir/record" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LIVE_TEST_CALLS"
printf '{"events":[],"next_cursor":7,"terminal":false}\n'
SH
chmod +x "$tmp_dir/record"

LIVE_TEST_CALLS="$tmp_dir/calls" PATH="$tmp_dir:/usr/bin:/bin" \
  "$script_dir/run-live.sh" start --app "QuickTime Player" --output "$tmp_dir/output" >/dev/null
LIVE_TEST_CALLS="$tmp_dir/calls" PATH="$tmp_dir:/usr/bin:/bin" \
  "$script_dir/run-live.sh" next --after 7 --timeout 20 >/dev/null

grep -qx "live start --json --app QuickTime Player --output $tmp_dir/output" "$tmp_dir/calls"
grep -qx 'live next --json --after 7 --timeout 20' "$tmp_dir/calls"

echo "Live adapter contract test passed"
