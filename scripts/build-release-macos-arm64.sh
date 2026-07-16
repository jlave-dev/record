#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
version="$(node -p "require('$repo_root/package.json').version")"
bundle_name="record-${version}-macos-arm64"
release_dir="$repo_root/dist/release"
bundle_dir="$release_dir/$bundle_name"
codesign_identity="${CAPTURE_CODESIGN_IDENTITY:-}"
codesign_keychain="${CAPTURE_CODESIGN_KEYCHAIN:-}"

npm --prefix "$repo_root" --workspace capture run build
npm --prefix "$repo_root" --workspace transcribe run build:binary:macos-arm64

transcribe_binary="$repo_root/packages/transcribe/dist/binary/transcribe-macos-arm64"
if [[ -n "$codesign_identity" ]]; then
  transcribe_codesign_args=(
    --force
    --options runtime
    --timestamp
    --entitlements "$repo_root/packages/transcribe/macos-entitlements.plist"
    --sign "$codesign_identity"
  )
  if [[ -n "$codesign_keychain" ]]; then
    transcribe_codesign_args+=(--keychain "$codesign_keychain")
  fi
  codesign "${transcribe_codesign_args[@]}" "$transcribe_binary"
fi

capture_app="$repo_root/packages/capture/dist/CaptureAgent.app"
capture_cli="$repo_root/packages/capture/dist/capture"
developer_id_signed=1
for signed_path in "$capture_app" "$capture_cli" "$transcribe_binary"; do
  if ! codesign -dv --verbose=4 "$signed_path" 2>&1 | grep -F "Authority=Developer ID Application" >/dev/null; then
    developer_id_signed=0
  fi
done

if [[ "$developer_id_signed" != "1" ]]; then
  if [[ "${RECORD_REQUIRE_DEVELOPER_ID:-0}" == "1" ]]; then
    echo "Release requires Developer ID Application signatures for CaptureAgent, capture, and transcribe." >&2
    exit 1
  fi
  echo "Warning: release executables are not all Developer ID-signed; this archive is suitable for local testing only." >&2
fi

rm -rf "$bundle_dir"
mkdir -p \
  "$bundle_dir/bin" \
  "$bundle_dir/libexec/record/capture" \
  "$bundle_dir/share/record/marketplace/plugins"

cp "$repo_root/scripts/record" "$bundle_dir/bin/record"
cp "$capture_cli" "$bundle_dir/libexec/record/capture/capture"
ditto "$capture_app" "$bundle_dir/libexec/record/capture/CaptureAgent.app"
cp "$transcribe_binary" "$bundle_dir/libexec/record/transcribe"
ditto "$repo_root/packaging/marketplace" "$bundle_dir/share/record/marketplace"
ditto "$repo_root/plugins/record" "$bundle_dir/share/record/marketplace/plugins/record"
chmod +x "$bundle_dir/bin/record" "$bundle_dir/libexec/record/capture/capture" "$bundle_dir/libexec/record/transcribe"

if [[ "${RECORD_NOTARIZE:-0}" == "1" ]]; then
  "$repo_root/scripts/notarize-release-bundle.sh" "$bundle_dir"
fi

if [[ "${RECORD_SKIP_ARCHIVE:-0}" == "1" ]]; then
  echo "Built $bundle_dir"
  exit 0
fi

archive="$release_dir/$bundle_name.tar.gz"
rm -f "$archive"
COPYFILE_DISABLE=1 tar -czf "$archive" -C "$release_dir" "$bundle_name"

if [[ "${RECORD_UPDATE_FORMULA:-0}" == "1" ]]; then
  node "$repo_root/scripts/update-formula-sha.mjs" "$archive"
fi

echo "Built $archive"
shasum -a 256 "$archive"
