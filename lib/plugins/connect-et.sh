# shellcheck shell=bash
# ds connect method: et — persistent eternal terminal connection
_connect_et() {
  local host="$1" arg remote_cmd
  shift 5
  local -a args=("$@")
  # Seed attach-next so the shell snippet (ds init bash) execs into the
  # requested ds action when the ET connection opens an interactive shell.
  # One argument per line keeps shell metacharacters inert and preserves spaces.
  # Newlines are rejected because the line-oriented file cannot encode them.
  for arg in "${args[@]}"; do
    if [[ "$arg" == *$'\n'* ]]; then
      echo "ds: ET handoff arguments cannot contain newlines" >&2
      return 2
    fi
  done
  remote_cmd="$(_remote_state_write_command attach-next)"
  # shellcheck disable=SC2029 # remote policy is deliberately expanded by the peer shell.
  if ! printf '%s\n' "${args[@]}" | ssh "$host" "$remote_cmd"; then
    echo "ds: failed to seed ET handoff state on $host" >&2
    return 1
  fi
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
