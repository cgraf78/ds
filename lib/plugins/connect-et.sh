# shellcheck shell=bash
# ds connect method: et — persistent eternal terminal connection
_connect_et() {
  local host="$1" session="$3"
  # Seed attach-next so the shell snippet (ds init bash) execs into the
  # right session when the ET connection opens an interactive shell.
  ssh "$host" "mkdir -p ~/.local/state/ds && cat > ~/.local/state/ds/attach-next" <<<"$session"
  local -a fwd=()
  if [[ -n "${DS_FORWARDS:-}" ]]; then
    # et takes -t as a comma-separated list of local:remote pairs.
    local joined="${DS_FORWARDS// /,}"
    fwd=("-t" "$joined")
  fi
  exec et "${fwd[@]+"${fwd[@]}"}" "$host"
}
