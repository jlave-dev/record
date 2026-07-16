#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
version="$(node -p "require('$repo_root/package.json').version")"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
prefix="$tmp_dir/prefix"
log="$tmp_dir/calls.log"

mkdir -p "$prefix/bin" "$prefix/libexec/record/capture" "$prefix/share/record/marketplace/.agents/plugins"
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
cat > "$tmp_dir/codex" <<SH
#!/usr/bin/env bash
echo "codex \$*" >> "$log"
SH
chmod +x "$prefix/libexec/record/capture/capture" "$prefix/libexec/record/transcribe" "$tmp_dir/codex"
printf '{"name":"record-cli","plugins":[]}\n' > "$prefix/share/record/marketplace/.agents/plugins/marketplace.json"

[[ "$("$prefix/bin/record" --version)" == "$version" ]]
"$prefix/bin/record" capture status --json
"$prefix/bin/record" transcribe doctor --json
RECORD_PLUGIN_MARKETPLACE="$tmp_dir/plugin-marketplace" PATH="$tmp_dir:/usr/bin:/bin" "$prefix/bin/record" plugin install >/dev/null

grep -qx 'capture status --json' "$log"
grep -qx 'transcribe doctor --json' "$log"
grep -qx "codex plugin marketplace add $tmp_dir/plugin-marketplace --json" "$log"
grep -qx 'codex plugin add record@record-cli --json' "$log"

echo "record CLI test passed"
