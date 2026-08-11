#!/usr/bin/env bash
# Install public entry points as links to this checkout. The command discovers
# its bundled plugins relative to the resolved checkout path, so keeping the
# command, manpage, and provider-owned lib/plugins tree together avoids a
# second installed tree that could drift from the active implementation.

set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="${BIN_DIR:-$PREFIX/bin}"
MAN_DIR="${MAN_DIR:-$PREFIX/share/man/man1}"
ROOT=$(cd -P -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

# Keep the public inventory explicit. Adding an entry point should require one
# deliberate installer change instead of silently matching an unrelated file.
COMMANDS=(
  ds
)
MANPAGES=(
  ds.1
)

# A checkout-backed install is usable only while every advertised source is
# present. Validate the entire provider side before creating directories or
# changing links so an incomplete checkout cannot publish half an interface.
for command in "${COMMANDS[@]}"; do
  source="$ROOT/bin/$command"
  if [[ ! -f "$source" || ! -x "$source" ]]; then
    printf 'ds: command source is not executable: %s\n' "$source" >&2
    exit 1
  fi
done
for manpage in "${MANPAGES[@]}"; do
  source="$ROOT/man/man1/$manpage"
  if [[ ! -f "$source" ]]; then
    printf 'ds: manpage source is missing: %s\n' "$source" >&2
    exit 1
  fi
done

# These links are installer-owned and may be retargeted when the checkout
# moves. A real file or directory may belong to the user or another package;
# reject every such collision up front so a late manpage conflict cannot leave
# the command updated on its own.
for command in "${COMMANDS[@]}"; do
  target="$BIN_DIR/$command"
  if [[ (-e "$target" || -L "$target") && ! -L "$target" ]]; then
    printf 'ds: refusing to replace non-symlink path: %s\n' "$target" >&2
    exit 1
  fi
done
for manpage in "${MANPAGES[@]}"; do
  target="$MAN_DIR/$manpage"
  if [[ (-e "$target" || -L "$target") && ! -L "$target" ]]; then
    printf 'ds: refusing to replace non-symlink path: %s\n' "$target" >&2
    exit 1
  fi
done

# Remember exactly what each installer-owned link selected before publication.
# Destination preflight prevents predictable collisions, but it cannot make a
# sequence of ln calls atomic: a filesystem error on a later link must not
# leave earlier links selecting the new checkout. Bash 3.2 has indexed arrays,
# so parallel arrays keep this small and portable without a transaction file.
LINK_SOURCES=()
LINK_TARGETS=()
LINK_MESSAGES=()
for command in "${COMMANDS[@]}"; do
  LINK_SOURCES+=("$ROOT/bin/$command")
  LINK_TARGETS+=("$BIN_DIR/$command")
  LINK_MESSAGES+=("installed $command to $BIN_DIR/$command")
done
for manpage in "${MANPAGES[@]}"; do
  LINK_SOURCES+=("$ROOT/man/man1/$manpage")
  LINK_TARGETS+=("$MAN_DIR/$manpage")
  LINK_MESSAGES+=("installed ds manpage to $MAN_DIR/$manpage")
done

LINK_WAS_SYMLINK=()
LINK_OLD_TARGETS=()
for target in "${LINK_TARGETS[@]}"; do
  if [[ -L "$target" ]]; then
    LINK_WAS_SYMLINK+=(1)
    LINK_OLD_TARGETS+=("$(readlink "$target")")
  else
    LINK_WAS_SYMLINK+=(0)
    LINK_OLD_TARGETS+=("")
  fi
done

_rollback_links() {
  local last="$1" index target

  for ((index = last; index >= 0; index--)); do
    target="${LINK_TARGETS[index]}"
    # Never turn a path that became a real file or directory into installer
    # state during recovery. That path may have been created by another actor.
    if [[ (-e "$target" || -L "$target") && ! -L "$target" ]]; then
      printf 'ds: rollback preserved non-symlink path: %s\n' "$target" >&2
      continue
    fi
    if [[ "${LINK_WAS_SYMLINK[index]}" -eq 1 ]]; then
      if ! ln -sfn -- "${LINK_OLD_TARGETS[index]}" "$target"; then
        printf 'ds: rollback could not restore symlink: %s\n' "$target" >&2
      fi
    elif [[ -L "$target" ]] && ! rm -f -- "$target"; then
      printf 'ds: rollback could not remove new symlink: %s\n' "$target" >&2
    fi
  done
}

mkdir -p "$BIN_DIR" "$MAN_DIR"
for ((link_index = 0; link_index < ${#LINK_TARGETS[@]}; link_index++)); do
  if ln -sfn -- "${LINK_SOURCES[link_index]}" "${LINK_TARGETS[link_index]}"; then
    continue
  else
    link_status=$?
    _rollback_links "$link_index"
    exit "$link_status"
  fi
done

for message in "${LINK_MESSAGES[@]}"; do
  printf '%s\n' "$message"
done
