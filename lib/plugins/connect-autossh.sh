# shellcheck shell=bash
# ds connect method: autossh — persistent SSH with auto-reconnect
_connect_autossh() {
  local host="$1" cmd="$2"
  local -a fwd=()
  local spec a b
  # ssh needs the 3-part form (port:host:port); port:port is rejected.
  # DS_FORWARDS is LOCAL:REMOTE (-L bind:target); DS_R_FORWARDS is
  # REMOTE:LOCAL (-R bind:target). Both pass through directly.
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
  exec autossh -M0 "${fwd[@]+"${fwd[@]}"}" "$host" -t "$cmd"
}
