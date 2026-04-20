# shellcheck shell=bash
# ds connect method: et — persistent eternal terminal connection
_connect_et() {
  local host="$1" session="$3"
  # Seed attach-next so the shell snippet (ds init bash) execs into the
  # right session when the ET connection opens an interactive shell.
  ssh "$host" "mkdir -p ~/.local/state/ds && cat > ~/.local/state/ds/attach-next" <<<"$session"
  local -a fwd=()
  # et's `-t local:remote` matches our DS_FORWARDS spec directly.
  # et's `-r source:destination` (bind-on-remote : target-on-client)
  # matches our DS_R_FORWARDS (REMOTE:LOCAL) directly.
  if [[ -n "${DS_FORWARDS:-}" ]]; then
    fwd+=("-t" "${DS_FORWARDS// /,}")
  fi
  if [[ -n "${DS_R_FORWARDS:-}" ]]; then
    fwd+=("-r" "${DS_R_FORWARDS// /,}")
  fi
  exec et "${fwd[@]+"${fwd[@]}"}" "$host"
}
