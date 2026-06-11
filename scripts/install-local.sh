#!/usr/bin/env bash
set -euo pipefail

package_dir="${1:?package directory is required}"
binary_name="${2:?binary name is required}"

cd "$package_dir"
npm run build >/dev/null

install_dir="${HOME}/.local/bin"
mkdir -p "$install_dir"
target="${install_dir}/${binary_name}"

cat > "$target" <<SH
#!/usr/bin/env bash
set -euo pipefail
exec node "${package_dir}/dist/index.js" "\$@"
SH
chmod +x "$target"

echo "Installed ${binary_name} to ${target}"
case ":${PATH}:" in
  *":${install_dir}:"*) ;;
  *) echo "Warning: ${install_dir} is not on PATH." >&2 ;;
esac
