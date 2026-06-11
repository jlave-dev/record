#!/usr/bin/env bash
set -euo pipefail

package_name="${1:?package name is required}"
package_dir="${2:?package directory is required}"
binary_name="${3:?binary name is required}"

cd "$package_dir"
npm run build >/dev/null

mkdir -p dist/binary
launcher="dist/binary/${binary_name}-macos-arm64"
cat > "$launcher" <<SH
#!/usr/bin/env bash
set -euo pipefail
exec node "\$(cd "\$(dirname "\$0")/.." && pwd)/index.js" "\$@"
SH
chmod +x "$launcher"

echo "Created ${package_name} macOS arm64 launcher at ${package_dir}/${launcher}"
echo "This package produces a Node-backed local launcher; native single-file packaging can be added later without changing the CLI surface."
