#!/usr/bin/env bash
set -euo pipefail

package_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
node_bin="$(command -v node)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin" "$tmp_dir/config/transcribe"

cat > "$tmp_dir/bin/brew" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$tmp_dir/bin/brew"
touch "$tmp_dir/model.bin"
cat > "$tmp_dir/config/transcribe/config.toml" <<EOF
whisper_command = "whisper-cli"
whisper_model = "$tmp_dir/model.bin"
EOF

PATH="$tmp_dir/bin:/usr/bin:/bin" \
HOME="$tmp_dir/home" \
XDG_CONFIG_HOME="$tmp_dir/config" \
"$node_bin" "$package_dir/dist/index.js" setup --dry-run --json > "$tmp_dir/dry-run.json"
grep -q '"action": "install_ffmpeg"' "$tmp_dir/dry-run.json"
grep -A1 '"action": "install_ffmpeg"' "$tmp_dir/dry-run.json" | grep -q '"required": true'

set +e
PATH="$tmp_dir/bin:/usr/bin:/bin" \
HOME="$tmp_dir/home" \
XDG_CONFIG_HOME="$tmp_dir/config" \
"$node_bin" "$package_dir/dist/index.js" setup --json > "$tmp_dir/setup.json"
exit_code=$?
set -e
[[ "$exit_code" -eq 1 ]]
grep -q '"status": "failed"' "$tmp_dir/setup.json"

echo "transcribe setup test passed"
