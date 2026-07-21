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
INSTALL_PARENT="$(dirname "$INSTALL_DIR")"
mkdir -p "$INSTALL_PARENT"
INSTALL_PREFIX="$(cd "$INSTALL_PARENT" && pwd)"
# The installed binary follows its own symlink and discovers bundled plugins at
# ../lib/ds/plugins. Keep the installer default aligned with that namespaced
# runtime lookup so a normal install works without exporting DS_LIB_DIR in every
# shell and does not claim a generic plugin directory.
LIB_DIR="${DS_LIB_DIR:-$INSTALL_PREFIX/lib/ds/plugins}"
MAN_DIR="${DS_MAN_DIR:-$HOME/.local/share/man/man1}"

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
  repo_url="https://github.com/$REPO.git"
  ssh_url="git@github.com:$REPO.git"
  if ! git clone --depth 1 "$repo_url" "$tmpdir/ds" >/dev/null; then
    rm -rf "$tmpdir/ds"
    # Release assets are intentionally gone now, so a standalone install has to
    # get source from git. Private or auth-required repos fail anonymous HTTPS
    # clones in non-interactive shells, while SSH works with the user's normal
    # GitHub key setup. Keep HTTPS as the fast public path, then retry SSH.
    echo "  HTTPS clone failed, retrying SSH..."
    git clone --depth 1 "$ssh_url" "$tmpdir/ds" >/dev/null
  fi
  cd "$tmpdir/ds"
  echo "  resolved commit $(git rev-parse --short HEAD)"
fi

echo "Installing ds..."

mkdir -p "$INSTALL_DIR"
mkdir -p "$LIB_DIR"
mkdir -p "$MAN_DIR"

cp bin/ds "$INSTALL_DIR/ds"
chmod +x "$INSTALL_DIR/ds"

# Install bundled plugins
for f in lib/plugins/*; do
  [ -f "$f" ] || continue
  cp "$f" "$LIB_DIR/"
done

if [[ -f man/man1/ds.1 ]]; then
  cp man/man1/ds.1 "$MAN_DIR/ds.1"
  echo "Installed manpage to $MAN_DIR/ds.1"
fi

echo "Installed ds to $INSTALL_DIR/ds"
echo "Installed plugins to $LIB_DIR/"

if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
  echo ""
  echo "Add to your PATH if not already present:"
  echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
fi

echo ""
echo "User config goes in ${XDG_CONFIG_HOME:-$HOME/.config}/ds/"
echo "See examples/ for templates."
