#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
version="$(node -p "require('$repo_root/package.json').version")"
bundle_dir="$repo_root/dist/release/record-${version}-macos-arm64"
install_prefix="${RECORD_INSTALL_PREFIX:-$HOME/.local/libexec/record}"
bin_dir="${RECORD_BIN_DIR:-$HOME/.local/bin}"

RECORD_SKIP_ARCHIVE=1 "$repo_root/scripts/build-release-macos-arm64.sh" >/dev/null
rm -rf "$install_prefix"
mkdir -p "$install_prefix" "$bin_dir"
ditto "$bundle_dir" "$install_prefix"
ln -sfn "$install_prefix/bin/record" "$bin_dir/record"

cat > "$bin_dir/capture" <<SH
#!/usr/bin/env bash
set -euo pipefail
exec "$bin_dir/record" capture "\$@"
SH
cat > "$bin_dir/transcribe" <<SH
#!/usr/bin/env bash
set -euo pipefail
exec "$bin_dir/record" transcribe "\$@"
SH
chmod +x "$bin_dir/capture" "$bin_dir/transcribe"

echo "Installed record to $install_prefix and $bin_dir/record"
case ":${PATH}:" in
  *":${bin_dir}:"*) ;;
  *) echo "Warning: $bin_dir is not on PATH." >&2 ;;
esac
