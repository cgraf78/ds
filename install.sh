#!/usr/bin/env bash
# install.sh — install ds to ~/.local/bin/ with bundled plugins.
#
# Two modes:
#   From source tree:  cd ds && bash install.sh
#   Standalone:        curl -sL https://raw.githubusercontent.com/cgraf78/ds/main/install.sh | bash
#
# When run standalone (no bin/ds in the current directory), the script
# fetches the latest release tarball, extracts to a temp directory, and
# installs from there.
set -euo pipefail

REPO="cgraf78/ds"
INSTALL_DIR="${DS_INSTALL_DIR:-$HOME/.local/bin}"
LIB_DIR="${DS_LIB_DIR:-$HOME/.local/lib/ds/plugins}"

# If not in a source tree, fetch the latest release tarball.
cleanup=""
if [[ ! -f bin/ds ]]; then
    echo "Fetching latest release..."
    tag=$(curl -sL "https://api.github.com/repos/$REPO/releases/latest" | grep -o '"tag_name": *"[^"]*"' | cut -d'"' -f4)
    if [[ -z "$tag" ]]; then
        echo "error: failed to determine latest release" >&2
        exit 1
    fi
    tmpdir=$(mktemp -d)
    cleanup="$tmpdir"
    trap 'rm -rf "$cleanup"' EXIT
    curl -sL "https://github.com/$REPO/releases/download/${tag}/ds-${tag}.tar.gz" | tar xz -C "$tmpdir"
    cd "$tmpdir/ds-${tag}"
    echo "  resolved $tag"
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
