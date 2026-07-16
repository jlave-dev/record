#!/usr/bin/env bash
set -euo pipefail

package_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
command -v bun >/dev/null 2>&1 || {
  echo "bun is required to build the self-contained transcribe executable." >&2
  exit 127
}

mkdir -p "$package_dir/dist/binary"
bun build "$package_dir/src/index.ts" \
  --compile \
  --target=bun-darwin-arm64 \
  --outfile "$package_dir/dist/binary/transcribe-macos-arm64"

echo "Built $package_dir/dist/binary/transcribe-macos-arm64"
