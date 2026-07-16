#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
version="${1:?Usage: prepare-release.sh VERSION}"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "The macOS arm64 release must be built on an arm64 runner." >&2
  exit 1
fi

node "$repo_root/scripts/update-release-version.mjs" "$version"
RECORD_REQUIRE_DEVELOPER_ID=1 \
RECORD_NOTARIZE=1 \
RECORD_UPDATE_FORMULA=1 \
  "$repo_root/scripts/build-release-macos-arm64.sh"
