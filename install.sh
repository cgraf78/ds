#!/usr/bin/env bash
# install.sh — install ds to ~/.local/bin/ with bundled plugins
set -euo pipefail

INSTALL_DIR="${DS_INSTALL_DIR:-$HOME/.local/bin}"
LIB_DIR="${DS_LIB_DIR:-$HOME/.local/lib/ds/plugins}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing ds..."

mkdir -p "$INSTALL_DIR"
mkdir -p "$LIB_DIR"

cp "$SCRIPT_DIR/bin/ds" "$INSTALL_DIR/ds"
chmod +x "$INSTALL_DIR/ds"

# Install bundled plugins
for f in "$SCRIPT_DIR"/lib/plugins/*; do
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
