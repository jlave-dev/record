#!/usr/bin/env bash
set -euo pipefail

package_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
native_dir="$package_dir/native"
dist_dir="$package_dir/dist"
version="$(node -p "require('$package_dir/package.json').version")"

rm -rf "$dist_dir"
swift build --package-path "$native_dir" -c release
bin_dir="$(swift build --package-path "$native_dir" -c release --show-bin-path)"

mkdir -p "$dist_dir/CaptureAgent.app/Contents/MacOS"
cp "$bin_dir/capture" "$dist_dir/capture"
cp "$bin_dir/CaptureAgent" "$dist_dir/CaptureAgent.app/Contents/MacOS/CaptureAgent"
chmod +x "$dist_dir/capture" "$dist_dir/CaptureAgent.app/Contents/MacOS/CaptureAgent"

cat > "$dist_dir/CaptureAgent.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>CaptureAgent</string>
  <key>CFBundleIdentifier</key><string>dev.jlave.record.capture-agent</string>
  <key>CFBundleName</key><string>CaptureAgent</string>
  <key>CFBundleDisplayName</key><string>CaptureAgent</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

sign_identity="${CAPTURE_CODESIGN_IDENTITY:-}"
if [[ -z "$sign_identity" ]]; then
  preferred_team="$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null | sed -n 's/^[[:space:]]*teamID = \([^;]*\);/\1/p' | head -1)"
  while IFS= read -r candidate; do
    [[ -z "$sign_identity" ]] && sign_identity="$candidate"
    certificate_team="$(security find-certificate -c "$candidate" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU=\([^,]*\).*/\1/p')"
    if [[ -n "$preferred_team" && "$certificate_team" == "$preferred_team" ]]; then
      sign_identity="$candidate"
      break
    fi
  done < <(
    security find-identity -v -p codesigning 2>/dev/null |
      sed -n \
        -e 's/.*"\(Developer ID Application:[^"]*\)"/\1/p' \
        -e 's/.*"\(Apple Development:[^"]*\)"/\1/p'
  )
fi

codesign_args=(--force --options runtime --sign "${sign_identity:--}")
if [[ "$sign_identity" == Developer\ ID\ Application:* || "${CAPTURE_CODESIGN_TIMESTAMP:-0}" == "1" ]]; then
  codesign_args+=(--timestamp)
fi
if [[ -n "${CAPTURE_CODESIGN_KEYCHAIN:-}" ]]; then
  codesign_args+=(--keychain "$CAPTURE_CODESIGN_KEYCHAIN")
fi

codesign "${codesign_args[@]}" "$dist_dir/capture"
codesign "${codesign_args[@]}" "$dist_dir/CaptureAgent.app"
codesign --verify --deep --strict --verbose=2 "$dist_dir/CaptureAgent.app"
echo "Built native capture CLI and agent in $dist_dir"
