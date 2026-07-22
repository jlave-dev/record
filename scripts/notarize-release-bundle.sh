#!/usr/bin/env bash
set -euo pipefail

bundle_dir="${1:?Usage: notarize-release-bundle.sh BUNDLE_DIR}"
[[ -d "$bundle_dir" ]] || {
  echo "Release bundle was not found at $bundle_dir." >&2
  exit 1
}

notary_args=()
if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  notary_args+=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
else
  for required_name in APPLE_NOTARIZATION_KEY_PATH APPLE_NOTARIZATION_KEY_ID APPLE_NOTARIZATION_ISSUER_ID; do
    if [[ -z "${!required_name:-}" ]]; then
      echo "$required_name is required when NOTARY_KEYCHAIN_PROFILE is not set." >&2
      exit 1
    fi
  done
  [[ -f "$APPLE_NOTARIZATION_KEY_PATH" ]] || {
    echo "Notarization key was not found at $APPLE_NOTARIZATION_KEY_PATH." >&2
    exit 1
  }
  notary_args+=(
    --key "$APPLE_NOTARIZATION_KEY_PATH"
    --key-id "$APPLE_NOTARIZATION_KEY_ID"
    --issuer "$APPLE_NOTARIZATION_ISSUER_ID"
  )
fi

capture_app="$bundle_dir/libexec/record/capture/CaptureAgent.app"
capture_cli="$bundle_dir/libexec/record/capture/capture"
transcribe_cli="$bundle_dir/libexec/record/transcribe"
live_cli="$bundle_dir/libexec/record/live/live"
live_worker="$bundle_dir/libexec/record/live/live-worker"

for signed_path in "$capture_app" "$capture_cli" "$transcribe_cli" "$live_cli" "$live_worker"; do
  codesign --verify --deep --strict --verbose=2 "$signed_path"
  codesign -dv --verbose=4 "$signed_path" 2>&1 | grep -F "Authority=Developer ID Application" >/dev/null || {
    echo "$signed_path is not signed with a Developer ID Application certificate." >&2
    exit 1
  }
done

notary_dir="$(mktemp -d "${TMPDIR:-/tmp}/record-notary.XXXXXX")"
notary_zip="$notary_dir/record.zip"
notary_json="$notary_dir/result.json"
cleanup() {
  rm -rf "$notary_dir"
}
trap cleanup EXIT

ditto -c -k --keepParent "$bundle_dir" "$notary_zip"
xcrun notarytool submit "$notary_zip" \
  "${notary_args[@]}" \
  --output-format json \
  --wait > "$notary_json"

notary_status="$(node -e 'const fs=require("fs"); const value=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); process.stdout.write(value.status ?? "Unknown")' "$notary_json")"
submission_id="$(node -e 'const fs=require("fs"); const value=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); process.stdout.write(value.id ?? "")' "$notary_json")"

if [[ "$notary_status" != "Accepted" ]]; then
  echo "Notarization failed with status $notary_status (submission ${submission_id:-unknown})." >&2
  if [[ -n "$submission_id" ]]; then
    xcrun notarytool log "$submission_id" "${notary_args[@]}" || true
  fi
  exit 1
fi

xcrun stapler staple "$capture_app"
xcrun stapler validate "$capture_app"
spctl --assess --type execute --verbose=4 "$capture_app"
echo "Notarized release bundle (submission $submission_id)."
