# shellcheck shell=bash
# ds connect method: autossh — persistent SSH with auto-reconnect
_connect_autossh() {
  local host="$1" cmd="$2"
  local -a fwd=()
  local spec
  for spec in ${DS_FORWARDS:-}; do
    fwd+=("-L" "$spec")
  done
  exec autossh -M0 "${fwd[@]+"${fwd[@]}"}" "$host" -t "$cmd"
}
