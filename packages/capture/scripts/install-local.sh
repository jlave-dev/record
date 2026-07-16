#!/usr/bin/env bash
set -euo pipefail

package_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir="$package_dir/dist"
install_dir="$HOME/.local/libexec/record/capture"
bin_dir="$HOME/.local/bin"

[[ -x "$source_dir/capture" && -d "$source_dir/CaptureAgent.app" ]] || {
  echo "capture build output is missing; run npm --workspace capture run build first." >&2
  exit 1
}

rm -rf "$install_dir"
mkdir -p "$install_dir" "$bin_dir"
cp "$source_dir/capture" "$install_dir/capture"
ditto "$source_dir/CaptureAgent.app" "$install_dir/CaptureAgent.app"

cat > "$bin_dir/capture" <<SH
#!/usr/bin/env bash
set -euo pipefail
exec "$install_dir/capture" "\$@"
SH
chmod +x "$bin_dir/capture"

echo "Installed capture to $install_dir and $bin_dir/capture"
