# shellcheck shell=bash
# ds connect method: et — persistent eternal terminal connection
_connect_et() {
  local host="$1" args="$5"
  # Seed attach-next so the shell snippet (ds init bash) execs into the
  # requested ds action when the ET connection opens an interactive shell.
  # The normalized argument string covers session modifiers and non-session
  # actions such as list/kill; the session-only plugin argument cannot.
  ssh "$host" "mkdir -p ~/.local/state/ds && cat > ~/.local/state/ds/attach-next" <<<"$args"
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
