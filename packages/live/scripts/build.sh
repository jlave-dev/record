#!/usr/bin/env bash
set -euo pipefail

package_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
native_dir="$package_dir/native"
dist_dir="$package_dir/dist"

rm -rf "$dist_dir"
swift build --package-path "$native_dir" -c release
bin_dir="$(swift build --package-path "$native_dir" -c release --show-bin-path)"
mkdir -p "$dist_dir"
cp "$bin_dir/live" "$dist_dir/live"
cp "$bin_dir/live-worker" "$dist_dir/live-worker"
chmod +x "$dist_dir/live" "$dist_dir/live-worker"
codesign --force --options runtime --sign - "$dist_dir/live" "$dist_dir/live-worker"
echo "Built live CLI and worker in $dist_dir"
