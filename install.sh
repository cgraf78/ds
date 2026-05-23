#!/usr/bin/env bash
# install.sh — install ds to ~/.local/bin/ with bundled plugins.
#
# Two modes:
#   From source tree:  cd ds && bash install.sh
#   Standalone:        curl -sL https://raw.githubusercontent.com/cgraf78/ds/main/install.sh | bash
#
# ds is repo-versioned rather than release-versioned. Standalone installs clone
# the current main branch into a temp directory and install from that checkout,
# matching the same source-of-truth used by shdeps' github:repo method.
set -euo pipefail

REPO="cgraf78/ds"
INSTALL_DIR="${DS_INSTALL_DIR:-$HOME/.local/bin}"
LIB_DIR="${DS_LIB_DIR:-$HOME/.local/lib/ds/plugins}"

# If not in a source tree, clone the current repo snapshot.
cleanup=""
if [[ ! -f bin/ds ]]; then
  if ! command -v git >/dev/null 2>&1; then
    echo "error: git is required for standalone install" >&2
    exit 1
  fi
  echo "Cloning latest ds..."
  tmpdir=$(mktemp -d)
  cleanup="$tmpdir"
  trap 'rm -rf "$cleanup"' EXIT
  git clone --depth 1 "https://github.com/$REPO.git" "$tmpdir/ds" >/dev/null
  cd "$tmpdir/ds"
  echo "  resolved commit $(git rev-parse --short HEAD)"
fi

echo "Installing ds..."

mkdir -p "$INSTALL_DIR"
mkdir -p "$LIB_DIR"

cp bin/ds "$INSTALL_DIR/ds"
chmod +x "$INSTALL_DIR/ds"

# Install bundled plugins
for f in lib/plugins/*; do
  [ -f "$f" ] || continue
  cp "$f" "$LIB_DIR/"
done

echo "Installed ds to $INSTALL_DIR/ds"
echo "Installed plugins to $LIB_DIR/"

if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
  echo ""
  echo "Add to your PATH if not already present:"
  echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
fi

echo ""
echo "User config goes in ~/.config/ds/"
echo "See examples/ for templates."
