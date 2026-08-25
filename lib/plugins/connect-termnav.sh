# shellcheck shell=bash
# ds connect method: termnav — SSH with parent-navigation relay forwarding
_connect_termnav() {
  local host="$1" cmd="$2"
  local -a fwd=()
  local spec a b

  if ! command -v termnav-relay >/dev/null 2>&1; then
    echo "ds: termnav-relay is required for the termnav connect method" >&2
    return 127
  fi

  # Match the built-in SSH and autossh forwarding contract. The explicit
  # --relay-command marker opts this commanded TTY session into Termnav's
  # per-session RemoteForward without changing ordinary ssh command behavior.
  for spec in ${DS_FORWARDS:-}; do
    a="${spec%%:*}"
    b="${spec##*:}"
    fwd+=("-L" "${a}:localhost:${b}")
  done
  for spec in ${DS_R_FORWARDS:-}; do
    a="${spec%%:*}"
    b="${spec##*:}"
    fwd+=("-R" "${a}:localhost:${b}")
  done
  exec termnav-relay ssh --relay-command -t \
    "${fwd[@]+"${fwd[@]}"}" -- "$host" "$cmd"
}
