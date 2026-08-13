# shellcheck shell=bash
# ds share backend: upterm — share a tmux session via upterm
#
# Required interface:
#   _share_start <session>   — start sharing, call _write_share_info with connection info
#   _share_stop <session>    — stop sharing, clean up
#   _share_info              — print current share connection info (or empty)
#   _share_running           — return 0 if currently sharing
#   _share_current_session   — print name of currently shared session
#   _share_load_config       — load backend-specific config from share-upterm.conf
#
# Config: $XDG_CONFIG_HOME/ds/share-upterm.conf when the XDG root is absolute;
#         $HOME/.config/ds/share-upterm.conf otherwise
#         (key=value, env vars override config)
#   server             upterm server host:port (default: uptermd.upterm.dev:22)
#   known-hosts        known_hosts file for server verification
#   private-key        SSH private key for upterm (auto-detected if unset)
#   github-user        GitHub user for ACL
#   authorized-keys    authorized_keys file for SSH-key-based ACL
#   push               user@host target for pushing share info via SCP
#   proxy-session      (deprecated, ignored) previously used to create a proxy
#                      tmux session for connecting clients. Connecting clients
#                      now get a plain bash -l shell directly.
#   share-ttl          seconds before the share automatically expires (default:
#                      3600). Set to 0 to disable auto-expiry. Calling
#                      `ds --share` resets the timer.
#
# Env vars (all optional, override config):
#   DS_UPTERM_HOST           maps to server
#   DS_UPTERM_PRIVATE_KEY    maps to private-key
#   DS_UPTERM_KNOWN_HOSTS    maps to known-hosts
#   DS_UPTERM_GITHUB_USER    maps to github-user
#   DS_UPTERM_AUTHORIZED_KEYS maps to authorized-keys
#   DS_UPTERM_PUSH           maps to push
#   DS_UPTERM_PID_FILE       override PID file path
#   DS_UPTERM_PROXY_SESSION  maps to proxy-session
#   DS_UPTERM_SHARE_TTL      maps to share-ttl

DS_UPTERM_HOST="${DS_UPTERM_HOST:-}"
DS_UPTERM_PRIVATE_KEY="${DS_UPTERM_PRIVATE_KEY:-}"
DS_UPTERM_KNOWN_HOSTS="${DS_UPTERM_KNOWN_HOSTS:-}"
DS_UPTERM_GITHUB_USER="${DS_UPTERM_GITHUB_USER:-}"
DS_UPTERM_AUTHORIZED_KEYS="${DS_UPTERM_AUTHORIZED_KEYS:-}"
DS_UPTERM_PID_FILE="${DS_UPTERM_PID_FILE:-}"
DS_UPTERM_PUSH="${DS_UPTERM_PUSH:-}"
DS_UPTERM_PROXY_SESSION="${DS_UPTERM_PROXY_SESSION:-}"
DS_UPTERM_SHARE_TTL="${DS_UPTERM_SHARE_TTL:-}"

# --- State file helpers ---

_upterm_pid_file() {
  if [[ -n "$DS_UPTERM_PID_FILE" ]]; then
    echo "$DS_UPTERM_PID_FILE"
  else
    echo "$(_state_file_prefix).upterm.pid"
  fi
}

_upterm_session_file() {
  echo "$(_state_file_prefix).upterm.session"
}

_upterm_admin_file() {
  echo "$(_state_file_prefix).upterm.admin"
}

_upterm_log_file() {
  echo "$(_state_file_prefix).upterm.log"
}

_upterm_ttl_control_dir() {
  local token="$1"
  [[ "$token" =~ ^[[:xdigit:]]{32}$ ]] || return 1
  printf '%s.upterm.ttl.%s\n' "$(_state_file_prefix)" "$token"
}

_upterm_launch_gate_file() {
  local token="$1"
  [[ "$token" =~ ^[[:xdigit:]]{32}$ ]] || return 1
  printf '%s.upterm.launch.%s\n' "$(_state_file_prefix)" "$token"
}

_upterm_control_dir() {
  local token="$1"
  [[ "$token" =~ ^[[:xdigit:]]{32}$ ]] || return 1
  printf '%s.upterm.control.%s\n' "$(_state_file_prefix)" "$token"
}

_upterm_operation_lock_dir() {
  printf '%s.upterm.operation.lock\n' "$(_state_file_prefix)"
}

_upterm_operation_lock_file() {
  local lock_dir="$1" target="$2" candidate owner_name found=""
  [[ -d "$lock_dir" && ! -L "$lock_dir" ]] || return 1
  for candidate in "$lock_dir/owner" "$lock_dir"/owner.*; do
    [[ -e "$candidate" || -L "$candidate" ]] || continue
    if [[ ! -f "$candidate" || -L "$candidate" ]]; then
      # A regular owner can disappear between the existence and type probes
      # during a normal release. Retry that turnover, but keep every extant
      # non-regular or symlinked candidate fail-closed.
      [[ ! -e "$candidate" && ! -L "$candidate" ]] && continue
      return 1
    fi
    owner_name=${candidate##*/}
    if [[ "$owner_name" != owner ]]; then
      owner_name=${owner_name#owner.}
      [[ "$owner_name" =~ ^[[:xdigit:]]{32}$ ]] || return 1
    fi
    # More than one owner means publication or manual recovery is incomplete.
    # Picking either one would let file ordering decide lifecycle ownership.
    [[ -z "$found" ]] || return 1
    found="$candidate"
  done
  # No owner can be a short publication/turnover window. Report it separately
  # so acquisition can retry without treating ordinary contention as corrupt
  # state; an extant invalid or second candidate still fails closed above.
  [[ -n "$found" ]] || return 2
  printf -v "$target" '%s' "$found"
}

_upterm_read_operation_lock() {
  local lock_file="$1" key value owner_name seen_version=0 seen_pid=0
  local seen_identity=0 seen_token=0
  _UPTERM_LOCK_PID=""
  _UPTERM_LOCK_IDENTITY=""
  _UPTERM_LOCK_TOKEN=""
  [[ -f "$lock_file" && ! -L "$lock_file" ]] || return 1
  while IFS='=' read -r key value; do
    case "$key" in
      version)
        ((seen_version == 0)) || return 1
        seen_version=1
        [[ "$value" == 1 ]] || return 1
        ;;
      pid)
        ((seen_pid == 0)) || return 1
        seen_pid=1
        _UPTERM_LOCK_PID="$value"
        ;;
      identity)
        ((seen_identity == 0)) || return 1
        seen_identity=1
        _UPTERM_LOCK_IDENTITY="$value"
        ;;
      token)
        ((seen_token == 0)) || return 1
        seen_token=1
        _UPTERM_LOCK_TOKEN="$value"
        ;;
      *) return 1 ;;
    esac
  done <"$lock_file" || return 1
  owner_name=${lock_file##*/}
  [[ "$seen_version$seen_pid$seen_identity$seen_token" == 1111 &&
    "$_UPTERM_LOCK_PID" =~ ^[0-9]+$ &&
    ${#_UPTERM_LOCK_IDENTITY} -eq 48 &&
    "$_UPTERM_LOCK_IDENTITY" != *[!0-9a-f]* &&
    "$_UPTERM_LOCK_TOKEN" =~ ^[[:xdigit:]]{32}$ ]] &&
    { [[ "$owner_name" == owner ]] ||
      [[ "$owner_name" == "owner.$_UPTERM_LOCK_TOKEN" ]]; }
}

# Start, stop, and TTL-triggered stop all mutate the same Upterm ownership and
# lifecycle files, so they coordinate through one atomic-directory operation
# lock rather than separate launch and cleanup locks. Bind ownership to PID plus
# process-start identity so PID reuse cannot make a dead owner appear live. The
# random token is also part of the owner filename: stale reclaimers and delayed
# releases can unlink only the exact generation they observed, never a
# successor that reused the lock directory. A contender attempts bounded stale
# recovery only after a well-formed owner is proven gone. Malformed or
# uninspectable ownership fails closed and remains for explicit recovery.
_upterm_acquire_operation_lock() {
  local target="$1" lock_dir lock_file="" operation_pid="" operation_identity=""
  local _upo_token attempt old_umask operation_file_status
  _ensure_state_dir
  lock_dir=$(_upterm_operation_lock_dir)
  _upterm_current_pid operation_pid || return 1
  _upterm_process_identity "$operation_pid" operation_identity || return 1
  _upo_token=$(_upterm_snapshot_token) || return 1
  for attempt in 1 2; do
    old_umask=$(umask)
    umask 077
    if mkdir "$lock_dir" 2>/dev/null; then
      lock_file="$lock_dir/owner.$_upo_token"
      if ! printf 'version=1\npid=%s\nidentity=%s\ntoken=%s\n' \
        "$operation_pid" "$operation_identity" "$_upo_token" >"$lock_file" ||
        ! chmod 600 "$lock_file" || ! chmod 700 "$lock_dir"; then
        rm -f "$lock_file"
        rmdir "$lock_dir" 2>/dev/null || true
        umask "$old_umask"
        echo "ds: failed to publish Upterm lifecycle operation ownership" >&2
        return 1
      fi
      umask "$old_umask"
      printf -v "$target" '%s' "$_upo_token"
      return 0
    fi
    umask "$old_umask"
    if _upterm_operation_lock_file "$lock_dir" lock_file; then
      :
    else
      operation_file_status=$?
      if ((operation_file_status == 2)); then
        continue
      fi
      echo "ds: malformed Upterm lifecycle operation lock; state retained" >&2
      return 1
    fi
    if ! _upterm_read_operation_lock "$lock_file"; then
      # The selected generation may release just before this read. Retry the
      # directory protocol only when that exact pathname vanished; malformed
      # content that still exists remains a hard, fail-closed error.
      if [[ ! -e "$lock_file" && ! -L "$lock_file" ]]; then
        continue
      fi
      echo "ds: malformed Upterm lifecycle operation lock; state retained" >&2
      return 1
    fi
    _upterm_pid_matches_identity \
      "$_UPTERM_LOCK_PID" "$_UPTERM_LOCK_IDENTITY"
    case $? in
      0) return 2 ;;
      1) ;;
      *)
        echo "ds: cannot verify the existing Upterm lifecycle operation owner; state retained" >&2
        return 1
        ;;
    esac
    # A fixed-name owner was published by an older ds. It is safe to honor
    # while live, but once stale there is no generation-specific pathname on
    # which to perform compare-and-remove. Retain it for explicit recovery
    # rather than reintroducing the successor-deletion race during an upgrade.
    if [[ "${lock_file##*/}" == owner ]]; then
      echo "ds: stale legacy Upterm lifecycle operation lock cannot be recovered safely; state retained" >&2
      return 1
    fi
    # Only the contender that unlinks the exact observed generation may remove
    # the directory. A losing reclaimer sees the path disappear and reports the
    # winning lifecycle operation as busy without touching its replacement.
    if ! rm "$lock_file" 2>/dev/null; then
      if [[ ! -e "$lock_file" && ! -L "$lock_file" ]]; then
        return 2
      fi
      echo "ds: failed to recover a stale Upterm lifecycle operation lock" >&2
      return 1
    fi
    if ! rmdir "$lock_dir"; then
      echo "ds: failed to recover a stale Upterm lifecycle operation lock" >&2
      return 1
    fi
  done
  return 2
}

_upterm_release_operation_lock() {
  local expected_token="$1" lock_dir lock_file=""
  lock_dir=$(_upterm_operation_lock_dir)
  if ! _upterm_operation_lock_file "$lock_dir" lock_file ||
    ! _upterm_read_operation_lock "$lock_file" ||
    [[ "$_UPTERM_LOCK_TOKEN" != "$expected_token" ]] ||
    [[ "${lock_file##*/}" != "owner.$expected_token" ]]; then
    echo "ds: refusing to release another Upterm lifecycle operation" >&2
    return 1
  fi
  if ! rm "$lock_file" || ! rmdir "$lock_dir"; then
    echo "ds: failed to release Upterm lifecycle operation ownership" >&2
    return 1
  fi
}

_upterm_known_hosts_snapshot_base() {
  echo "$(_state_file_prefix).upterm.known_hosts"
}

_upterm_known_hosts_owner_file() {
  echo "$(_upterm_known_hosts_snapshot_base).owner"
}

_upterm_process_identity() {
  local pid="$1" target="$2" started identity
  local weekday month day clock year extra
  [[ "$pid" =~ ^[0-9]+$ ]] || return 2
  if ! started=$(LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null); then
    kill -0 "$pid" 2>/dev/null && return 2
    return 1
  fi
  [[ "$started" != *$'\n'* ]] || return 2
  # BSD ps pads lstart to its display width; hash a canonical five-field value.
  read -r weekday month day clock year extra <<<"$started" || return 2
  [[ -n "$weekday" && -n "$month" && -n "$day" && -n "$clock" &&
    -n "$year" && -z "$extra" ]] || return 2
  printf -v started '%s %s %2s %s %s' \
    "$weekday" "$month" "$day" "$clock" "$year"
  [[ "$started" =~ ^[A-Z][a-z][a-z][[:space:]][A-Z][a-z][a-z][[:space:]]([[:space:]][0-9]|[0-9]{2})[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2}[[:space:]][0-9]{4}$ ]] || return 2
  identity=$(printf '%s' "$started" | od -An -tx1 | tr -d '[:space:]') || return 2
  [[ ${#identity} -eq 48 && "$identity" != *[!0-9a-f]* ]] || return 2
  printf -v "$target" '%s' "$identity"
}

_upterm_pid_matches_identity() {
  local pid="$1" expected="$2" actual="" identity_status
  if _upterm_process_identity "$pid" actual; then
    identity_status=0
  else
    identity_status=$?
  fi
  ((identity_status == 0)) || return "$identity_status"
  [[ "$actual" == "$expected" ]]
}

_upterm_snapshot_owner_temp_file() {
  local pid="$1" identity="$2" token="$3"
  [[ "$pid" =~ ^[0-9]+$ &&
    ${#identity} -eq 48 && "$identity" != *[!0-9a-f]* &&
    "$token" =~ ^[[:xdigit:]]{32}$ ]] || return 1
  printf '%s.%s.%s.%s.new\n' \
    "$(_upterm_known_hosts_owner_file)" "$pid" "$identity" "$token"
}

_upterm_parse_snapshot_owner_temp_file() {
  local path="$1" pid_var="$2" identity_var="$3" token_var="$4"
  local owner_file rest _upsot_pid _upsot_identity _upsot_token
  owner_file=$(_upterm_known_hosts_owner_file)
  [[ "$path" == "${owner_file}."*.new ]] || return 1
  rest="${path#"${owner_file}."}"
  rest="${rest%.new}"
  _upsot_pid="${rest%%.*}"
  rest="${rest#*.}"
  _upsot_identity="${rest%%.*}"
  _upsot_token="${rest#*.}"
  [[ "$rest" == "${_upsot_identity}.${_upsot_token}" &&
    "$_upsot_pid" =~ ^[0-9]+$ &&
    ${#_upsot_identity} -eq 48 && "$_upsot_identity" != *[!0-9a-f]* &&
    "$_upsot_token" =~ ^[[:xdigit:]]{32}$ ]] || return 1
  printf -v "$pid_var" '%s' "$_upsot_pid"
  printf -v "$identity_var" '%s' "$_upsot_identity"
  printf -v "$token_var" '%s' "$_upsot_token"
}

_upterm_known_hosts_snapshot_file() {
  local token="${1:-}"
  [[ "$token" =~ ^[[:xdigit:]]{32}$ ]] || return 1
  printf '%s.%s\n' "$(_upterm_known_hosts_snapshot_base)" "$token"
}

# --- Internal helpers ---

_upterm_resolve_key() {
  if [[ -n "${DS_UPTERM_PRIVATE_KEY:-}" && -f "$DS_UPTERM_PRIVATE_KEY" ]]; then
    echo "$DS_UPTERM_PRIVATE_KEY"
    return 0
  fi
  local candidate
  for candidate in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa" "$HOME/.ssh/id_ecdsa"; do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

_upterm_is_wsl() {
  grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null
}

_upterm_fd_is_open() {
  case "$1" in
    9) : <&9 ;;
    8) : <&8 ;;
    7) : <&7 ;;
    6) : <&6 ;;
    5) : <&5 ;;
    4) : <&4 ;;
    3) : <&3 ;;
    *) return 1 ;;
  esac
}

_upterm_open_read_fd() {
  local path="$1" target="$2" _upso_fd
  for _upso_fd in 9 8 7 6 5 4 3; do
    _upterm_fd_is_open "$_upso_fd" 2>/dev/null && continue
    case "$_upso_fd" in
      9) exec 9<"$path" || return 1 ;;
      8) exec 8<"$path" || return 1 ;;
      7) exec 7<"$path" || return 1 ;;
      6) exec 6<"$path" || return 1 ;;
      5) exec 5<"$path" || return 1 ;;
      4) exec 4<"$path" || return 1 ;;
      3) exec 3<"$path" || return 1 ;;
    esac
    printf -v "$target" '%s' "$_upso_fd"
    return 0
  done
  echo "ds: no free file descriptor is available for Upterm host trust" >&2
  return 1
}

_upterm_close_fd() {
  [[ -n "${1:-}" ]] || return 0
  case "$1" in
    9) exec 9<&- ;;
    8) exec 8<&- ;;
    7) exec 7<&- ;;
    6) exec 6<&- ;;
    5) exec 5<&- ;;
    4) exec 4<&- ;;
    3) exec 3<&- ;;
    *) return 1 ;;
  esac
}

_upterm_copy_fd() {
  local fd="$1" target="$2"
  case "$fd" in
    9) cat <&9 >"$target" ;;
    8) cat <&8 >"$target" ;;
    7) cat <&7 >"$target" ;;
    6) cat <&6 >"$target" ;;
    5) cat <&5 >"$target" ;;
    4) cat <&4 >"$target" ;;
    3) cat <&3 >"$target" ;;
    *) return 1 ;;
  esac
}

_upterm_snapshot_token() {
  local token
  token=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d '[:space:]')
  if [[ "${#token}" -eq 32 && "$token" =~ ^[[:xdigit:]]+$ ]]; then
    printf '%s\n' "$token"
  else
    printf '%04x%04x%04x%04x%04x%04x%04x%04x\n' \
      "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM" \
      "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM"
  fi
}

_upterm_current_pid() {
  local target="$1" _upcp_pid="${BASHPID:-}" temporary old_umask
  if [[ "$_upcp_pid" =~ ^[0-9]+$ ]]; then
    printf -v "$target" '%s' "$_upcp_pid"
    return 0
  fi

  # Bash 3.2 has no BASHPID. Launching sh directly and reading its PPID avoids
  # the inherited-$$ behavior of Bash subshells without relying on /proc.
  old_umask=$(umask)
  umask 077
  temporary=$(mktemp "${TMPDIR:-/tmp}/ds-upterm-pid.XXXXXX") || {
    umask "$old_umask"
    return 1
  }
  if ! sh -c 'printf "%s\n" "$PPID"' >"$temporary" ||
    ! IFS= read -r _upcp_pid <"$temporary" ||
    [[ ! "$_upcp_pid" =~ ^[0-9]+$ ]]; then
    rm -f "$temporary"
    umask "$old_umask"
    return 1
  fi
  if ! rm -f "$temporary"; then
    umask "$old_umask"
    return 1
  fi
  umask "$old_umask"
  printf -v "$target" '%s' "$_upcp_pid"
}

_upterm_read_snapshot_owner() {
  local owner_file="$1" key value seen_version=0 seen_phase=0 seen_pid=0
  local seen_identity=0 seen_token=0 seen_snapshot=0
  _UPTERM_SNAPSHOT_VERSION=""
  _UPTERM_SNAPSHOT_PHASE=""
  _UPTERM_SNAPSHOT_PID=""
  _UPTERM_SNAPSHOT_IDENTITY=""
  _UPTERM_SNAPSHOT_TOKEN=""
  _UPTERM_SNAPSHOT_BASENAME=""
  [[ -f "$owner_file" && ! -L "$owner_file" ]] || return 1
  while IFS='=' read -r key value; do
    case "$key" in
      version)
        ((seen_version == 0)) || return 1
        seen_version=1
        _UPTERM_SNAPSHOT_VERSION="$value"
        ;;
      phase)
        ((seen_phase == 0)) || return 1
        seen_phase=1
        _UPTERM_SNAPSHOT_PHASE="$value"
        ;;
      pid)
        ((seen_pid == 0)) || return 1
        seen_pid=1
        _UPTERM_SNAPSHOT_PID="$value"
        ;;
      identity)
        ((seen_identity == 0)) || return 1
        seen_identity=1
        _UPTERM_SNAPSHOT_IDENTITY="$value"
        ;;
      token)
        ((seen_token == 0)) || return 1
        seen_token=1
        _UPTERM_SNAPSHOT_TOKEN="$value"
        ;;
      snapshot)
        ((seen_snapshot == 0)) || return 1
        seen_snapshot=1
        _UPTERM_SNAPSHOT_BASENAME="$value"
        ;;
      *) return 1 ;;
    esac
  done <"$owner_file" || return 1
  [[ "$seen_version$seen_phase$seen_pid$seen_identity$seen_token$seen_snapshot" == 111111 &&
    "$_UPTERM_SNAPSHOT_VERSION" == 2 &&
    ("$_UPTERM_SNAPSHOT_PHASE" == starting ||
    "$_UPTERM_SNAPSHOT_PHASE" == active ||
    "$_UPTERM_SNAPSHOT_PHASE" == stopping) &&
    "$_UPTERM_SNAPSHOT_PID" =~ ^[0-9]+$ &&
    ${#_UPTERM_SNAPSHOT_IDENTITY} -eq 48 &&
    "$_UPTERM_SNAPSHOT_IDENTITY" != *[!0-9a-f]* &&
    "$_UPTERM_SNAPSHOT_TOKEN" =~ ^[[:xdigit:]]{32}$ ]] || return 1
  local expected
  expected="$(_upterm_known_hosts_snapshot_base)"
  expected="${expected##*/}.${_UPTERM_SNAPSHOT_TOKEN}"
  [[ "$_UPTERM_SNAPSHOT_BASENAME" == "$expected" ]]
}

_upterm_write_snapshot_owner() {
  local mode="$1" phase="$2" pid="$3" token="$4" snapshot="$5"
  local supplied_identity="${6:-}"
  local owner_file owner_temp old_umask snapshot_basename
  local publisher_pid="" publisher_identity="" record_identity=""
  owner_file=$(_upterm_known_hosts_owner_file)
  _upterm_current_pid publisher_pid || return 1
  _upterm_process_identity "$publisher_pid" publisher_identity || return 1
  if [[ -n "$supplied_identity" ]]; then
    [[ ${#supplied_identity} -eq 48 &&
      "$supplied_identity" != *[!0-9a-f]* ]] || return 1
    record_identity="$supplied_identity"
  else
    _upterm_process_identity "$pid" record_identity || return 1
  fi
  owner_temp=$(_upterm_snapshot_owner_temp_file \
    "$publisher_pid" "$publisher_identity" "$token") || return 1
  snapshot_basename="${snapshot##*/}"
  old_umask=$(umask)
  umask 077
  if ! (
    set -o noclobber
    printf 'version=2\nphase=%s\npid=%s\nidentity=%s\ntoken=%s\nsnapshot=%s\n' \
      "$phase" "$pid" "$record_identity" "$token" "$snapshot_basename" >"$owner_temp"
  ) 2>/dev/null || ! chmod 600 "$owner_temp"; then
    umask "$old_umask"
    echo "ds: failed to prepare Upterm snapshot ownership metadata" >&2
    return 1
  fi
  if [[ "$mode" == create ]]; then
    if ! ln "$owner_temp" "$owner_file" 2>/dev/null; then
      if ! rm -f "$owner_temp"; then
        umask "$old_umask"
        echo "ds: failed to remove unpublished Upterm snapshot ownership metadata: $owner_temp" >&2
        return 1
      fi
      umask "$old_umask"
      if [[ -e "$owner_file" || -L "$owner_file" ]]; then
        return 2
      fi
      echo "ds: failed to publish Upterm startup reservation metadata" >&2
      return 1
    fi
    if ! rm -f "$owner_temp"; then
      umask "$old_umask"
      echo "ds: failed to remove published Upterm snapshot ownership metadata: $owner_temp" >&2
      return 1
    fi
  else
    if ! _upterm_read_snapshot_owner "$owner_file" ||
      [[ "$_UPTERM_SNAPSHOT_TOKEN" != "$token" ]] ||
      ! mv -f "$owner_temp" "$owner_file"; then
      umask "$old_umask"
      echo "ds: failed to update Upterm snapshot ownership" >&2
      return 1
    fi
  fi
  umask "$old_umask"
}

_upterm_cleanup_snapshot_owner_temps() {
  local token="$1" owner_file candidate candidate_pid candidate_identity candidate_token
  owner_file=$(_upterm_known_hosts_owner_file)
  for candidate in "${owner_file}".*.*."${token}".new; do
    [[ -e "$candidate" || -L "$candidate" ]] || continue
    if ! _upterm_parse_snapshot_owner_temp_file \
      "$candidate" candidate_pid candidate_identity candidate_token ||
      [[ "$candidate_token" != "$token" ]]; then
      echo "ds: refusing to remove invalid Upterm ownership preparation: $candidate" >&2
      return 1
    fi
    if ! rm -f "$candidate"; then
      echo "ds: failed to remove Upterm ownership preparation: $candidate" >&2
      return 1
    fi
  done
}

_upterm_cleanup_known_hosts_snapshot() {
  local token="${1:-}" snapshot="${2:-}" owner_file gate control_dir owner_matches=0
  local expected
  [[ "$token" =~ ^[[:xdigit:]]{32}$ ]] || {
    echo "ds: refusing tokenless Upterm snapshot cleanup" >&2
    return 1
  }
  expected=$(_upterm_known_hosts_snapshot_file "$token") || return 1
  if [[ -z "$snapshot" || "$snapshot" != "$expected" ]]; then
    echo "ds: refusing to remove an invalid Upterm snapshot path" >&2
    return 1
  fi
  owner_file=$(_upterm_known_hosts_owner_file)
  if [[ -e "$owner_file" || -L "$owner_file" ]]; then
    if ! _upterm_read_snapshot_owner "$owner_file"; then
      echo "ds: malformed Upterm snapshot ownership state: $owner_file" >&2
      return 1
    fi
    if [[ "$_UPTERM_SNAPSHOT_TOKEN" != "$token" ||
      "$(dirname "$owner_file")/$_UPTERM_SNAPSHOT_BASENAME" != "$snapshot" ]]; then
      echo "ds: refusing to remove an Upterm snapshot owned by another start" >&2
      return 1
    fi
    owner_matches=1
  fi
  if ! rm -f "${snapshot}.tmp" "${snapshot}.tmp.anchor"; then
    echo "ds: failed to remove the owned temporary Upterm trust snapshot: ${snapshot}.tmp" >&2
    return 1
  fi
  if ! rm -f "$snapshot"; then
    echo "ds: failed to remove the owned Upterm trust snapshot: $snapshot" >&2
    return 1
  fi
  gate=$(_upterm_launch_gate_file "$token") || return 1
  if ! rm -f "$gate"; then
    echo "ds: failed to remove the owned Upterm launch gate: $gate" >&2
    return 1
  fi
  control_dir=$(_upterm_control_dir "$token") || return 1
  if [[ -e "$control_dir" || -L "$control_dir" ]]; then
    if [[ ! -d "$control_dir" || -L "$control_dir" ]]; then
      echo "ds: invalid Upterm supervisor control directory: $control_dir" >&2
      return 1
    fi
    if ! rm -f "$control_dir/stop.new" "$control_dir/stop" \
      "$control_dir/waiting" "$control_dir/crossed" \
      "$control_dir/monitor" "$control_dir/ready" "$control_dir/done" \
      "$control_dir/monitor.jobs" "$control_dir/supervisor.jobs" \
      "$control_dir/owner.pipe" ||
      ! rmdir "$control_dir"; then
      echo "ds: failed to remove the owned Upterm supervisor control state: $control_dir" >&2
      return 1
    fi
  fi
  _upterm_cleanup_snapshot_owner_temps "$token" || return 1
  if ((owner_matches)) && ! rm -f "$owner_file"; then
    echo "ds: failed to remove Upterm snapshot ownership state: $owner_file" >&2
    return 1
  fi
}

_upterm_reconcile_snapshot_owner_temps() {
  local owner_file candidate candidate_pid candidate_identity candidate_token
  local fixed_token="" fixed_valid=0 identity_status
  owner_file=$(_upterm_known_hosts_owner_file)
  if [[ -e "$owner_file" || -L "$owner_file" ]] &&
    _upterm_read_snapshot_owner "$owner_file"; then
    fixed_valid=1
    fixed_token="$_UPTERM_SNAPSHOT_TOKEN"
  fi
  for candidate in "${owner_file}".*.*.*.new; do
    [[ -e "$candidate" || -L "$candidate" ]] || continue
    if ! _upterm_parse_snapshot_owner_temp_file \
      "$candidate" candidate_pid candidate_identity candidate_token; then
      echo "ds: malformed Upterm ownership preparation: $candidate" >&2
      return 1
    fi
    if ((fixed_valid)) &&
      { [[ "$candidate_token" != "$fixed_token" ]] || [[ "$candidate" -ef "$owner_file" ]]; }; then
      : # The fixed owner makes loser or post-publication residue safe to unlink.
    else
      if _upterm_pid_matches_identity "$candidate_pid" "$candidate_identity"; then
        identity_status=0
      else
        identity_status=$?
      fi
      case "$identity_status" in
        0)
          echo "ds: another Upterm owner preparation is still in progress" >&2
          return 1
          ;;
        1) ;;
        *)
          echo "ds: cannot verify an Upterm owner preparation; state retained" >&2
          return 1
          ;;
      esac
    fi
    if ! rm -f "$candidate"; then
      echo "ds: failed to remove stale Upterm ownership preparation: $candidate" >&2
      return 1
    fi
  done
}

_upterm_reconcile_snapshot_owner() {
  local owner_file control_dir gate done_token="" done_result=""
  local identity_status supervisor_status
  owner_file=$(_upterm_known_hosts_owner_file)
  _upterm_reconcile_snapshot_owner_temps || return 1
  [[ -e "$owner_file" || -L "$owner_file" ]] || return 0
  if ! _upterm_read_snapshot_owner "$owner_file"; then
    if [[ -f "$owner_file" && ! -L "$owner_file" && ! -s "$owner_file" ]]; then
      if rm -f "$owner_file"; then
        return 0
      fi
      echo "ds: failed to remove an empty Upterm snapshot ownership state: $owner_file" >&2
      return 1
    fi
    echo "ds: malformed Upterm snapshot ownership state: $owner_file" >&2
    return 1
  fi
  if [[ "$_UPTERM_SNAPSHOT_PHASE" == active ]]; then
    if _upterm_supervisor_matches \
      "$_UPTERM_SNAPSHOT_PID" "$_UPTERM_SNAPSHOT_IDENTITY" \
      "$_UPTERM_SNAPSHOT_TOKEN"; then
      supervisor_status=0
    else
      supervisor_status=$?
    fi
    case "$supervisor_status" in
      0) return 0 ;;
      1) ;;
      *)
        echo "ds: cannot verify the Upterm supervisor identity; state retained" >&2
        return 1
        ;;
    esac
    control_dir=$(_upterm_control_dir "$_UPTERM_SNAPSHOT_TOKEN") || return 1
    gate="$control_dir/crossed"
    if [[ ! -e "$gate" && ! -L "$gate" ]] &&
      _upterm_read_token_state \
        "$control_dir/waiting" result done_token done_result &&
      [[ "$done_token" == "$_UPTERM_SNAPSHOT_TOKEN" &&
        "$done_result" == waiting ]]; then
      : # The verified supervisor never crossed the child-launch boundary.
    elif ! _upterm_read_token_state \
      "$control_dir/done" result done_token done_result ||
      [[ "$done_token" != "$_UPTERM_SNAPSHOT_TOKEN" ||
        ("$done_result" != stopped && "$done_result" != exited &&
        "$done_result" != owner-lost) ]]; then
      echo "ds: Upterm supervisor exited without verified child completion; state retained" >&2
      return 1
    fi
  elif [[ "$_UPTERM_SNAPSHOT_PHASE" == stopping ]]; then
    return 0
  else
    if _upterm_pid_matches_identity \
      "$_UPTERM_SNAPSHOT_PID" "$_UPTERM_SNAPSHOT_IDENTITY"; then
      identity_status=0
    else
      identity_status=$?
    fi
    case "$identity_status" in
      0) return 0 ;;
      1) ;;
      *)
        echo "ds: cannot verify the Upterm startup owner; state retained" >&2
        return 1
        ;;
    esac
  fi
  local stale_pid="$_UPTERM_SNAPSHOT_PID"
  local stale_identity="$_UPTERM_SNAPSHOT_IDENTITY"
  local stale_token="$_UPTERM_SNAPSHOT_TOKEN"
  local stale_snapshot
  stale_snapshot="$(dirname "$owner_file")/$_UPTERM_SNAPSHOT_BASENAME"
  if [[ "$_UPTERM_SNAPSHOT_PHASE" == active ]] &&
    ! _upterm_write_snapshot_owner replace stopping "$stale_pid" \
      "$stale_token" "$stale_snapshot" "$stale_identity"; then
    return 1
  fi
  if [[ "${DS_UPTERM_TTL_EXPIRY_TOKEN:-}" != "$stale_token" ]] &&
    ! _upterm_cancel_ttl_watcher "$stale_token"; then
    echo "ds: stale Upterm lifecycle retained because its TTL watcher could not be cancelled" >&2
    return 1
  fi
  _upterm_cleanup_lifecycle_files "$stale_token" || return 1
  _upterm_cleanup_known_hosts_snapshot \
    "$stale_token" "$stale_snapshot"
}

_upterm_acquire_snapshot_owner() {
  local token_var="$1" snapshot_var="$2" owner_file _upso_pid _upso_token _upso_snapshot attempt write_status
  _ensure_state_dir
  _upterm_current_pid _upso_pid || {
    echo "ds: failed to identify the Upterm startup owner process" >&2
    return 1
  }
  owner_file=$(_upterm_known_hosts_owner_file)
  for attempt in 1 2; do
    _upterm_reconcile_snapshot_owner || return 1
    if [[ -e "$owner_file" || -L "$owner_file" ]]; then
      if _upterm_read_snapshot_owner "$owner_file" &&
        [[ "$_UPTERM_SNAPSHOT_PHASE" == starting ]]; then
        echo "ds: another Upterm start is already in progress" >&2
      else
        echo "ds: Upterm snapshot ownership is already active" >&2
      fi
      return 1
    fi
    _upso_token=$(_upterm_snapshot_token) || return 1
    _upso_snapshot=$(_upterm_known_hosts_snapshot_file "$_upso_token") || return 1
    if _upterm_write_snapshot_owner create starting "$_upso_pid" \
      "$_upso_token" "$_upso_snapshot"; then
      write_status=0
    else
      write_status=$?
    fi
    if ((write_status == 0)); then
      printf -v "$token_var" '%s' "$_upso_token"
      printf -v "$snapshot_var" '%s' "$_upso_snapshot"
      return 0
    fi
    if ((write_status == 1)); then
      _upterm_cleanup_known_hosts_snapshot "$_upso_token" "$_upso_snapshot" || true
      return 1
    fi
  done
  echo "ds: another Upterm start acquired the startup reservation" >&2
  return 1
}

_upterm_valid_ipv4_tail() {
  local value="$1" dots octet octet_number
  local -a octets

  dots="${value//[^.]/}"
  ((${#dots} == 3)) || return 1
  IFS=. read -r -a octets <<<"$value"
  ((${#octets[@]} == 4)) || return 1
  for octet in "${octets[@]}"; do
    case "$octet" in "" | *[!0-9]*) return 1 ;; esac
    ((${#octet} <= 3)) || return 1
    [[ ${#octet} -eq 1 || "$octet" != 0* ]] || return 1
    octet_number=$((10#$octet))
    ((octet_number <= 255)) || return 1
  done
}

_upterm_ipv6_side_slots() {
  local value="$1" target="$2" component index _uph_slots=0
  local -a components

  if [[ -z "$value" ]]; then
    printf -v "$target" '%s' 0
    return 0
  fi
  [[ "$value" != :* && "$value" != *: ]] || return 1
  IFS=: read -r -a components <<<"$value"
  for ((index = 0; index < ${#components[@]}; index++)); do
    component="${components[$index]}"
    if [[ "$component" == *.* ]]; then
      ((index == ${#components[@]} - 1)) || return 1
      _upterm_valid_ipv4_tail "$component" || return 1
      _uph_slots=$((_uph_slots + 2))
    else
      case "$component" in "" | *[!0-9A-Fa-f]*) return 1 ;; esac
      ((${#component} <= 4)) || return 1
      _uph_slots=$((_uph_slots + 1))
    fi
  done
  printf -v "$target" '%s' "$_uph_slots"
}

_upterm_valid_ipv6_literal() {
  local value="$1" prefix suffix _uph_prefix_slots _uph_suffix_slots slots

  if [[ "$value" == *.* && "${value##*:}" != *.* ]]; then
    return 1
  fi
  if [[ "$value" == *::* ]]; then
    prefix="${value%%::*}"
    suffix="${value#*::}"
    [[ "$suffix" != *::* ]] || return 1
    _upterm_ipv6_side_slots "$prefix" _uph_prefix_slots || return 1
    _upterm_ipv6_side_slots "$suffix" _uph_suffix_slots || return 1
    slots=$((_uph_prefix_slots + _uph_suffix_slots))
    ((slots < 8))
  else
    _upterm_ipv6_side_slots "$value" slots || return 1
    ((slots == 8))
  fi
}

_upterm_parse_server() {
  local server="$1" host_var="$2" port_var="$3" _uph_host _uph_port rest colons port_number
  local _uph_bracketed=0
  local LC_ALL=C

  case "$server" in
    \[*\]*)
      _uph_bracketed=1
      _uph_host="${server#\[}"
      _uph_host="${_uph_host%%\]*}"
      rest="${server#*\]}"
      case "$rest" in
        "") _uph_port=22 ;;
        :*) _uph_port="${rest#:}" ;;
        *) return 1 ;;
      esac
      ;;
    *)
      colons="${server//[^:]/}"
      if ((${#colons} > 1)); then
        # An IPv6 literal must be bracketed so the resulting ssh:// URI is
        # unambiguous to Upterm.
        return 1
      elif [[ "$server" == *:* ]]; then
        _uph_host="${server%%:*}"
        _uph_port="${server##*:}"
      else
        _uph_host="$server"
        _uph_port=22
      fi
      ;;
  esac

  [[ -n "$_uph_host" && "$_uph_host" != -* && "$_uph_host" != *[[:space:]]* ]] || return 1
  if ((_uph_bracketed)); then
    _upterm_valid_ipv6_literal "$_uph_host" || return 1
  else
    case "$_uph_host" in *[!$'\041'-$'\176']*) return 1 ;; esac
    case "$_uph_host" in
      *'['* | *']'* | *$'\\'* | *'"'* | *'<'* | *'>'* | *'^'* | *'`'* | *'{'* | *'|'* | *'}'*) return 1 ;;
    esac
  fi
  # These characters change the authority or endpoint when embedded in the
  # ssh:// URI passed to Upterm. Percent escapes are rejected for the same
  # reason; accept a literal host only, not an alternate URI representation.
  case "$_uph_host" in *[@/?#%]*) return 1 ;; esac
  case "$_uph_host$_uph_port" in *[$'\001'-$'\037'$'\177']*) return 1 ;; esac
  case "$_uph_port" in "" | *[!0-9]*) return 1 ;; esac
  while [[ "$_uph_port" == 0* && ${#_uph_port} -gt 1 ]]; do
    _uph_port="${_uph_port#0}"
  done
  ((${#_uph_port} <= 5)) || return 1
  port_number=$((10#$_uph_port))
  ((port_number >= 1 && port_number <= 65535)) || return 1
  printf -v "$host_var" '%s' "$_uph_host"
  printf -v "$port_var" '%s' "$port_number"
}

_upterm_server_uri() {
  local server="$1" host port
  _upterm_parse_server "$server" host port || return 1
  if [[ "$host" == *:* ]]; then
    printf 'ssh://[%s]:%s\n' "$host" "$port"
  else
    printf 'ssh://%s:%s\n' "$host" "$port"
  fi
}

_upterm_valid_key_record() {
  printf '%s %s\n' "$1" "$2" | ssh-keygen -lf - >/dev/null 2>&1
}

_upterm_valid_base64_field() {
  local value="$1" unpadded
  [[ -n "$value" ]] || return 1
  case "$value" in *[!A-Za-z0-9+/=]*) return 1 ;; esac
  ((${#value} % 4 == 0)) || return 1
  case "$value" in
    *==) unpadded="${value%==}" ;;
    *=) unpadded="${value%=}" ;;
    *) unpadded="$value" ;;
  esac
  [[ "$unpadded" != *=* ]]
}

_upterm_valid_known_host_pattern() {
  local value="$1" rest salt hash pattern host_part port index
  local -a patterns

  if [[ "$value" == \|* ]]; then
    [[ "$value" == \|1\|*\|* ]] || return 1
    rest="${value#|1|}"
    salt="${rest%%|*}"
    hash="${rest#*|}"
    [[ "$hash" != *'|'* ]] || return 1
    _upterm_valid_base64_field "$salt" && _upterm_valid_base64_field "$hash"
    return
  fi

  IFS=, read -r -a patterns <<<"$value"
  ((${#patterns[@]} > 0)) || return 1
  for ((index = 0; index < ${#patterns[@]}; index++)); do
    pattern="${patterns[$index]}"
    [[ -n "$pattern" ]] || continue
    [[ "$pattern" != '!' ]] || return 1
    pattern="${pattern#!}"
    if [[ "$pattern" == \[* ]]; then
      host_part="${pattern#\[}"
      [[ "${host_part%%\]*}" != "$host_part" ]] || return 1
      rest="${host_part#*\]}"
      host_part="${host_part%%\]*}"
      [[ "$rest" == :* && "$rest" != *']'* ]] || return 1
      port="${rest#:}"
      [[ -n "$host_part" && -n "$port" && "$port" != *:* ]] || return 1
      case "$port" in *[!0-9]*) return 1 ;; esac
    fi
  done
}

_upterm_validate_known_hosts_bytes() {
  local known_hosts="$1" known_hosts_label="${2:-$1}" original_size stripped_size

  original_size=$(LC_ALL=C wc -c <"$known_hosts") || {
    echo "ds: failed to read known-hosts file: $known_hosts_label" >&2
    return 1
  }
  stripped_size=$(
    set -o pipefail
    LC_ALL=C tr -d '\000' <"$known_hosts" | LC_ALL=C wc -c
  ) || {
    echo "ds: failed to inspect known-hosts file: $known_hosts_label" >&2
    return 1
  }
  original_size=$((original_size + 0))
  stripped_size=$((stripped_size + 0))
  if ((original_size != stripped_size)); then
    echo "ds: known-hosts file contains a NUL byte: $known_hosts_label" >&2
    return 1
  fi
}

_upterm_snapshot_known_hosts() {
  local source="$1" _upso_snapshot_path="$2" handoff_var="$3" validation_var="${4:-}"
  local temporary validation_anchor old_umask
  local _upso_source_fd="" _upso_handoff_fd=""

  if [[ ! -f "$source" || -L "$source" || ! -r "$source" ]]; then
    echo "ds: known-hosts source must be a readable non-symlink regular file: $source" >&2
    return 1
  fi
  # Bind the source inode by descriptor; private hard links below bind the
  # copied validation and handoff inode without requiring a shared filesystem.
  if ! _upterm_open_read_fd "$source" _upso_source_fd; then
    echo "ds: failed to open known-hosts source: $source" >&2
    return 1
  fi
  if [[ ! -f "$source" || -L "$source" || ! -r "$source" ]]; then
    _upterm_close_fd "$_upso_source_fd"
    echo "ds: known-hosts source changed to an unsafe file before it could be read: $source" >&2
    return 1
  fi

  old_umask=$(umask)
  umask 077
  temporary="${_upso_snapshot_path}.tmp"
  validation_anchor="${temporary}.anchor"
  if ! (
    set -o noclobber
    : >"$temporary"
  ) 2>/dev/null; then
    _upterm_close_fd "$_upso_source_fd"
    umask "$old_umask"
    echo "ds: failed to create a private known-hosts snapshot" >&2
    return 1
  fi
  if ! _upterm_copy_fd "$_upso_source_fd" "$temporary"; then
    _upterm_close_fd "$_upso_source_fd"
    umask "$old_umask"
    echo "ds: failed to read known-hosts source: $source" >&2
    return 1
  fi
  _upterm_close_fd "$_upso_source_fd"
  if ! chmod 600 "$temporary" ||
    ! ln "$temporary" "$validation_anchor" 2>/dev/null ||
    ! ln "$temporary" "$_upso_snapshot_path" 2>/dev/null ||
    ! _upterm_open_read_fd "$validation_anchor" _upso_handoff_fd; then
    _upterm_close_fd "$_upso_handoff_fd"
    umask "$old_umask"
    echo "ds: failed to install the private known-hosts snapshot" >&2
    return 1
  fi
  if [[ -z "$validation_var" ]] && ! rm -f "$temporary" "$validation_anchor"; then
    _upterm_close_fd "$_upso_handoff_fd"
    umask "$old_umask"
    echo "ds: failed to remove a temporary known-hosts snapshot" >&2
    return 1
  fi
  umask "$old_umask"
  printf -v "$handoff_var" '%s' "$_upso_handoff_fd"
  if [[ -n "$validation_var" ]]; then
    printf -v "$validation_var" '%s' "$temporary"
  fi
}

_upterm_validate_known_hosts() {
  local known_hosts="$1" line line_number=0 first second third fourth rest
  local has_hashed_var="$2" marker hosts key_type key_data
  local known_hosts_label="${3:-$known_hosts}"
  local _uph_has_hashed=0
  local LC_ALL=C

  command -v ssh-keygen >/dev/null 2>&1 || {
    echo "ds: ssh-keygen is required to validate $known_hosts_label" >&2
    return 1
  }
  _upterm_validate_known_hosts_bytes "$known_hosts" "$known_hosts_label" || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    if ((${#line} > 65535)); then
      echo "ds: known-hosts line is too long at $known_hosts_label:$line_number" >&2
      return 1
    fi
    line="${line%$'\r'}"
    first=""
    second=""
    third=""
    fourth=""
    rest=""
    read -r first second third fourth rest <<<"$line"
    [[ -n "$first" && "$first" != \#* ]] || continue

    marker=""
    if [[ "$first" == @* ]]; then
      marker="$first"
      hosts="$second"
      key_type="$third"
      key_data="$fourth"
      case "$marker" in
        @cert-authority | @revoked) ;;
        *)
          echo "ds: unsupported known-hosts marker outside DS's supported known-hosts subset at $known_hosts_label:$line_number" >&2
          return 1
          ;;
      esac
    else
      hosts="$first"
      key_type="$second"
      key_data="$third"
    fi

    if [[ -z "$hosts" ]] ||
      { [[ "$marker" != @revoked ]] && ! _upterm_valid_known_host_pattern "$hosts"; }; then
      echo "ds: malformed known-hosts pattern outside DS's supported known-hosts subset at $known_hosts_label:$line_number" >&2
      return 1
    fi
    if [[ -z "$key_type" || -z "$key_data" ]] ||
      ! _upterm_valid_key_record "$key_type" "$key_data"; then
      echo "ds: malformed known-hosts key outside DS's supported known-hosts subset at $known_hosts_label:$line_number" >&2
      return 1
    fi
    if [[ "$marker" != @revoked && "$hosts" == \|* ]]; then
      _uph_has_hashed=1
    fi
  done <"$known_hosts"
  printf -v "$has_hashed_var" '%s' "$_uph_has_hashed"
}

_upterm_record_in_set() {
  local needle="$1" records="$2" record
  while IFS= read -r record; do
    [[ "$record" == "$needle" ]] && return 0
  done <<<"$records"
  return 1
}

_upterm_append_record() {
  local target="$1" key_type="$2" key_data="$3" current
  current="${!target}"
  printf -v "$target" '%s%s%s %s' "$current" "${current:+$'\n'}" "$key_type" "$key_data"
}

_upterm_wildcard_match() {
  local pattern="$1" value="$2" pattern_index=0 value_index=0
  local star_index=-1 retry_index=0 pattern_length value_length pattern_char value_char
  local LC_ALL=C

  pattern_length=${#pattern}
  value_length=${#value}
  while ((value_index < value_length)); do
    pattern_char=""
    ((pattern_index < pattern_length)) && pattern_char="${pattern:pattern_index:1}"
    value_char="${value:value_index:1}"
    if [[ "$pattern_char" == '?' || "$pattern_char" == "$value_char" ]]; then
      pattern_index=$((pattern_index + 1))
      value_index=$((value_index + 1))
    elif [[ "$pattern_char" == '*' ]]; then
      star_index=$pattern_index
      retry_index=$value_index
      pattern_index=$((pattern_index + 1))
    elif ((star_index >= 0)); then
      pattern_index=$((star_index + 1))
      retry_index=$((retry_index + 1))
      value_index=$retry_index
    else
      return 1
    fi
  done
  ((pattern_index == pattern_length))
}

_upterm_plain_pattern_component_matches() {
  local pattern="$1" host="$2" port="$3" pattern_host pattern_port rest colons

  if [[ "$pattern" == \[* ]]; then
    pattern_host="${pattern#\[}"
    [[ "${pattern_host%%\]*}" != "$pattern_host" ]] || return 1
    rest="${pattern_host#*\]}"
    pattern_host="${pattern_host%%\]*}"
    [[ "$rest" == :* && "$rest" != *']'* ]] || return 1
    pattern_port="${rest#:}"
  else
    colons="${pattern//[^:]/}"
    if ((${#colons} == 1)) && [[ "$pattern" != *'['* && "$pattern" != *']'* ]]; then
      pattern_host="${pattern%%:*}"
      pattern_port="${pattern#*:}"
    else
      pattern_host="$pattern"
      pattern_port=22
    fi
  fi
  [[ "$pattern_port" == "$port" ]] || return 1
  _upterm_wildcard_match "$pattern_host" "$host"
}

_upterm_plain_pattern_matches() {
  local value="$1" host="$2" port="$3" pattern index matched=0
  local -a patterns

  IFS=, read -r -a patterns <<<"$value"
  for ((index = 0; index < ${#patterns[@]}; index++)); do
    pattern="${patterns[$index]}"
    [[ -n "$pattern" ]] || continue
    if [[ "$pattern" == !* ]]; then
      pattern="${pattern#!}"
      if _upterm_plain_pattern_component_matches "$pattern" "$host" "$port"; then
        return 1
      fi
    elif _upterm_plain_pattern_component_matches "$pattern" "$host" "$port"; then
      matched=1
    fi
  done
  ((matched))
}

_upterm_hashed_record_matches() {
  local marker="$1" hosts="$2" key_type="$3" key_data="$4" matching="$5"
  local line first second third fourth rest candidate_marker candidate_hosts
  local candidate_type candidate_data

  while IFS= read -r line; do
    line="${line%$'\r'}"
    read -r first second third fourth rest <<<"$line"
    [[ -n "$first" && "$first" != \#* ]] || continue
    if [[ "$first" == @* ]]; then
      candidate_marker="$first"
      candidate_hosts="$second"
      candidate_type="$third"
      candidate_data="$fourth"
    else
      candidate_marker=""
      candidate_hosts="$first"
      candidate_type="$second"
      candidate_data="$third"
    fi
    if [[ "$candidate_marker" == "$marker" && "$candidate_hosts" == "$hosts" &&
      "$candidate_type" == "$key_type" && "$candidate_data" == "$key_data" ]]; then
      return 0
    fi
  done <<<"$matching"
  return 1
}

_upterm_pattern_matches() {
  local marker="$1" hosts="$2" key_type="$3" key_data="$4"
  local host="$5" port="$6" hashed_matching="$7"

  if [[ "$hosts" == \|* ]]; then
    _upterm_hashed_record_matches \
      "$marker" "$hosts" "$key_type" "$key_data" "$hashed_matching"
  else
    _upterm_plain_pattern_matches "$hosts" "$host" "$port"
  fi
}

_upterm_scan_host_keys() {
  local host="$1" port="$2" mode="$3" ed_var="$4" rsa_var="${5:-}"
  local output status line first second third rest expected_ed expected_rsa
  local _uph_ed_records="" _uph_rsa_records="" record scanned_type scanned_data

  if [[ "$mode" == certificate ]]; then
    expected_ed=ssh-ed25519-cert-v01@openssh.com
    expected_rsa=ssh-rsa-cert-v01@openssh.com
    if output=$(ssh-keyscan -T 5 -c -t ed25519,rsa -p "$port" "$host" 2>/dev/null); then
      status=0
    else
      status=$?
    fi
  else
    expected_ed=ssh-ed25519
    expected_rsa=""
    if output=$(ssh-keyscan -T 5 -t ed25519 -p "$port" "$host" 2>/dev/null); then
      status=0
    else
      status=$?
    fi
  fi
  if ((status > 1)); then
    echo "ds: ssh-keyscan failed while probing $mode host keys from $host:$port" >&2
    return 1
  fi

  while IFS= read -r line; do
    read -r first second third rest <<<"$line"
    [[ -n "$first" && "$first" != \#* ]] || continue
    if [[ "$mode" == certificate && -z "$third" ]]; then
      scanned_type="$first"
      scanned_data="$second"
    else
      scanned_type="$second"
      scanned_data="$third"
    fi
    if [[ -z "$scanned_type" || -z "$scanned_data" ]] ||
      ! _upterm_valid_key_record "$scanned_type" "$scanned_data"; then
      echo "ds: could not parse the scanned host keys from $host:$port" >&2
      return 1
    fi
    record="$scanned_type $scanned_data"
    case "$scanned_type" in
      "$expected_ed")
        _upterm_record_in_set "$record" "$_uph_ed_records" ||
          _upterm_append_record _uph_ed_records "$scanned_type" "$scanned_data"
        ;;
      "$expected_rsa")
        _upterm_record_in_set "$record" "$_uph_rsa_records" ||
          _upterm_append_record _uph_rsa_records "$scanned_type" "$scanned_data"
        ;;
      *)
        echo "ds: unexpected host key type from $host:$port: $scanned_type" >&2
        return 1
        ;;
    esac
  done <<<"$output"
  printf -v "$ed_var" '%s' "$_uph_ed_records"
  if [[ -n "$rsa_var" ]]; then
    printf -v "$rsa_var" '%s' "$_uph_rsa_records"
  fi
}

_upterm_single_record() {
  local records="$1" target="$2" record selected=""
  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    if [[ -n "$selected" && "$record" != "$selected" ]]; then
      return 1
    fi
    selected="$record"
  done <<<"$records"
  [[ -n "$selected" ]] || return 1
  printf -v "$target" '%s' "$selected"
}

_upterm_verify_known_host() {
  local server="$1" known_hosts="$2" host port lookup hashed_matching=""
  local known_hosts_label="${3:-$known_hosts}"
  local direct_records="" revoked_records="" record selected_record
  local cert_ed="" cert_rsa="" raw_ed="" selected_records=""
  local line first second third fourth rest marker hosts key_type key_data
  local lookup_status has_hashed=0 matching_ca=0

  if [[ ! -f "$known_hosts" || ! -r "$known_hosts" ]]; then
    echo "ds: known-hosts file is not a readable regular file: $known_hosts_label" >&2
    return 1
  fi
  if ! _upterm_parse_server "$server" host port; then
    echo "ds: invalid upterm server address: $server" >&2
    return 1
  fi
  _upterm_validate_known_hosts "$known_hosts" has_hashed "$known_hosts_label" || return 1

  lookup="$host"
  [[ "$port" == 22 ]] || lookup="[$host]:$port"
  if ((has_hashed)); then
    if hashed_matching=$(ssh-keygen -F "$lookup" -f "$known_hosts" 2>/dev/null); then
      lookup_status=0
    else
      lookup_status=$?
    fi
    if ((lookup_status > 1)) || { ((lookup_status != 0)) && [[ -n "$hashed_matching" ]]; }; then
      echo "ds: failed to search hashed records in $known_hosts_label for $lookup" >&2
      return 1
    fi
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    read -r first second third fourth rest <<<"$line"
    [[ -n "$first" && "$first" != \#* ]] || continue
    marker=""
    if [[ "$first" == @* ]]; then
      marker="$first"
      hosts="$second"
      key_type="$third"
      key_data="$fourth"
    else
      hosts="$first"
      key_type="$second"
      key_data="$third"
    fi
    if [[ "$marker" == @revoked ]]; then
      _upterm_append_record revoked_records "$key_type" "$key_data"
      continue
    fi
    _upterm_pattern_matches \
      "$marker" "$hosts" "$key_type" "$key_data" "$host" "$port" "$hashed_matching" || continue
    if [[ "$marker" == @cert-authority ]]; then
      matching_ca=1
    else
      _upterm_append_record direct_records "$key_type" "$key_data"
    fi
  done <"$known_hosts"

  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    key_type="${record%% *}"
    if [[ "$key_type" == *-cert-v01@openssh.com ]]; then
      echo "ds: direct certificate pins are not supported for $lookup; configure a raw host key" >&2
      return 1
    fi
    case "$key_type" in
      ssh-ed25519) ;;
      ssh-rsa)
        echo "ds: unsupported direct host key type: ssh-rsa; only ssh-ed25519 can be verified before launch" >&2
        return 1
        ;;
      *)
        echo "ds: unsupported direct host key type: $key_type" >&2
        return 1
        ;;
    esac
  done <<<"$direct_records"

  if ((matching_ca)); then
    echo "ds: certificate-authority verification is not supported before launch for $lookup; configure a direct ssh-ed25519 host key" >&2
    return 1
  fi
  if [[ -z "$direct_records" ]]; then
    echo "ds: no trusted host key entry for $lookup in $known_hosts_label" >&2
    return 1
  fi

  command -v ssh-keyscan >/dev/null 2>&1 || {
    echo "ds: ssh-keyscan is required to verify $host:$port" >&2
    return 1
  }
  _upterm_scan_host_keys "$host" "$port" certificate cert_ed cert_rsa || return 1
  if [[ -n "$cert_ed" || -n "$cert_rsa" ]]; then
    echo "ds: host certificates are not supported by the pre-launch verifier for $host:$port; configure the server to present a directly pinned raw ED25519 host key" >&2
    return 1
  fi

  _upterm_scan_host_keys "$host" "$port" raw raw_ed || return 1
  if [[ -n "$raw_ed" ]]; then
    selected_records="$raw_ed"
  else
    echo "ds: could not scan a host key from $host:$port; refusing to continue" >&2
    return 1
  fi
  if ! _upterm_single_record "$selected_records" selected_record; then
    echo "ds: multiple host keys were returned for Upterm's selected algorithm at $host:$port" >&2
    return 1
  fi

  if _upterm_record_in_set "$selected_record" "$revoked_records"; then
    echo "ds: the configured host key for $lookup is revoked" >&2
    return 1
  fi
  _upterm_record_in_set "$selected_record" "$direct_records" && return 0

  echo "ds: scanned host keys for $host:$port do not match $known_hosts_label" >&2
  return 1
}

_upterm_normalize_info() {
  local content="$1"
  # Extract the SSH connection command from upterm output.
  # Supports multiple formats:
  #   "➤ SSH:\n    ssh SESSION@HOST"
  #   "ssh session: ssh SESSION@HOST"
  #   "Command: ssh SESSION@HOST"
  local ssh_cmd
  ssh_cmd=$(printf '%s\n' "$content" | grep -E '^\s+ssh\s+\S+@\S+' | head -1 | sed 's/^[[:space:]]*//' || true)
  if [[ -z "$ssh_cmd" ]]; then
    ssh_cmd=$(printf '%s\n' "$content" | sed -n 's/^ssh session: //p' | head -1 || true)
  fi
  if [[ -z "$ssh_cmd" ]]; then
    ssh_cmd=$(printf '%s\n' "$content" | grep -Eo 'ssh[[:space:]]+[^[:space:]]+@[^[:space:]]+' | head -1 || true)
  fi
  if [[ -n "$ssh_cmd" ]]; then
    printf 'ssh: %s\n' "$ssh_cmd"
  else
    printf '%s\n' "$content"
  fi
}

_upterm_read_info_from_log() {
  local log_file="$1"
  [[ -s "$log_file" ]] || return 1
  local raw normalized
  raw=$(cat "$log_file" 2>/dev/null || true)
  [[ -n "$raw" ]] || return 1
  normalized=$(_upterm_normalize_info "$raw")
  if [[ "$normalized" == ssh:* ]]; then
    printf '%s\n' "$normalized"
    return 0
  fi
  return 1
}

_upterm_source_host() {
  local host
  if command -v hostname >/dev/null 2>&1; then
    host=$(hostname -s 2>/dev/null || hostname) || return 1
  elif command -v uname >/dev/null 2>&1; then
    host=$(uname -n) || return 1
    host="${host%%.*}"
  else
    return 1
  fi
  [[ -n "$host" ]] || return 1
  printf '%s\n' "$host"
}

# Push share info to the state directory selected on the remote host.
_upterm_push_share_info() {
  local session="$1"
  [[ -n "$DS_UPTERM_PUSH" ]] || return 0
  [[ -n "${DS_SHARE_INFO_FILE:-}" && -f "$DS_SHARE_INFO_FILE" ]] || return 0

  local src_host
  src_host=$(_upterm_source_host) || {
    echo "ds: cannot determine the source host for Upterm share state" >&2
    return 1
  }
  local remote_file="ds.upterm-${src_host}-${session}.share"
  local remote_cmd
  remote_cmd="$(_remote_state_write_command "$remote_file")" || return

  # shellcheck disable=SC2029 # remote policy is deliberately expanded by the peer shell.
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$DS_UPTERM_PUSH" "$remote_cmd" \
    <"$DS_SHARE_INFO_FILE" 2>/dev/null || {
    echo "ds: failed to push share info to $DS_UPTERM_PUSH" >&2
    return 1
  }
  echo "ds: pushed share info to $DS_UPTERM_PUSH:$remote_file"
}

_upterm_unpush_share_info() {
  local session="$1"
  [[ -n "$DS_UPTERM_PUSH" ]] || return 0
  local src_host
  src_host=$(_upterm_source_host) || return 0
  local remote_cmd
  remote_cmd="$(_remote_state_remove_command "ds.upterm-${src_host}-${session}.share")" || return
  # shellcheck disable=SC2029 # remote policy is deliberately expanded by the peer shell.
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$DS_UPTERM_PUSH" "$remote_cmd" 2>/dev/null || true
}

# --- Required interface ---

_share_load_config() {
  local conf="$CONF_DIR/share-upterm.conf"
  [[ -f "$conf" ]] || return 0
  while IFS='=' read -r key val; do
    key=$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    val=$(echo "$val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -z "$key" || "$key" == \#* ]] && continue
    case "$key" in
      server) [[ -z "$DS_UPTERM_HOST" ]] && DS_UPTERM_HOST="$val" ;;
      known-hosts) [[ -z "$DS_UPTERM_KNOWN_HOSTS" ]] && DS_UPTERM_KNOWN_HOSTS="${val/#\~/$HOME}" ;;
      private-key) [[ -z "$DS_UPTERM_PRIVATE_KEY" ]] && DS_UPTERM_PRIVATE_KEY="${val/#\~/$HOME}" ;;
      github-user) [[ -z "$DS_UPTERM_GITHUB_USER" ]] && DS_UPTERM_GITHUB_USER="$val" ;;
      authorized-keys) [[ -z "$DS_UPTERM_AUTHORIZED_KEYS" ]] && DS_UPTERM_AUTHORIZED_KEYS="${val/#\~/$HOME}" ;;
      push) [[ -z "$DS_UPTERM_PUSH" ]] && DS_UPTERM_PUSH="$val" ;;
      proxy-session) [[ -z "$DS_UPTERM_PROXY_SESSION" ]] && DS_UPTERM_PROXY_SESSION="$val" ;;
      share-ttl) [[ -z "$DS_UPTERM_SHARE_TTL" ]] && DS_UPTERM_SHARE_TTL="$val" ;;
    esac
  done <"$conf" || true
}

_upterm_create_ttl_control_dir() {
  local token="$1" control_dir old_umask
  control_dir=$(_upterm_ttl_control_dir "$token") || return 1
  old_umask=$(umask)
  umask 077
  if ! mkdir "$control_dir" 2>/dev/null || ! chmod 700 "$control_dir"; then
    umask "$old_umask"
    echo "ds: failed to create private Upterm TTL watcher state" >&2
    return 1
  fi
  umask "$old_umask"
}

_upterm_ttl_watcher_matches() {
  local pid="$1" identity="$2" token="$3" command_line identity_status
  if _upterm_pid_matches_identity "$pid" "$identity"; then
    identity_status=0
  else
    identity_status=$?
  fi
  ((identity_status == 0)) || return "$identity_status"
  command_line=$(LC_ALL=C ps -ww -o command= -p "$pid" 2>/dev/null) || return 2
  [[ "$command_line" == *"ds-upterm-ttl-$token"* ]]
}

_upterm_validate_ttl_control() {
  local token="$1" control_dir="${2:-}" artifact basename
  local watcher_pid="" watcher_identity="" watcher_token=""
  local state_token="" state_value=""
  if [[ -z "$control_dir" ]]; then
    control_dir=$(_upterm_ttl_control_dir "$token") || return 1
  fi
  [[ "$control_dir" == *.upterm.ttl."$token" ]] || return 1
  [[ -d "$control_dir" && ! -L "$control_dir" ]] || return 1
  for artifact in "$control_dir"/*; do
    [[ -e "$artifact" || -L "$artifact" ]] || continue
    basename=${artifact##*/}
    case "$basename" in
      watcher | ready | cancel | done) ;;
      *) return 1 ;;
    esac
    [[ -f "$artifact" && ! -L "$artifact" ]] || return 1
  done
  _upterm_read_pid_file \
    "$control_dir/watcher" watcher_pid watcher_identity watcher_token || return 1
  [[ "$watcher_token" == "$token" ]] || return 1
  if [[ -e "$control_dir/ready" || -L "$control_dir/ready" ]]; then
    _upterm_read_token_state \
      "$control_dir/ready" result state_token state_value || return 1
    [[ "$state_token" == "$token" && "$state_value" == ready ]] || return 1
  fi
  if [[ -e "$control_dir/cancel" || -L "$control_dir/cancel" ]]; then
    _upterm_read_token_state \
      "$control_dir/cancel" request state_token state_value || return 1
    [[ "$state_token" == "$token" && "$state_value" == cancel ]] || return 1
  fi
  if [[ -e "$control_dir/done" || -L "$control_dir/done" ]]; then
    _upterm_read_token_state \
      "$control_dir/done" result state_token state_value || return 1
    [[ "$state_token" == "$token" ]] || return 1
    case "$state_value" in
      cancelled | expired | stale) ;;
      *) return 1 ;;
    esac
  fi
}

_upterm_cleanup_ttl_control() {
  local token="$1" control_dir="${2:-}"
  if [[ -z "$control_dir" ]]; then
    control_dir=$(_upterm_ttl_control_dir "$token") || return 1
  fi
  [[ "$control_dir" == *.upterm.ttl."$token" ]] || return 1
  [[ -e "$control_dir" || -L "$control_dir" ]] || return 0
  if ! _upterm_validate_ttl_control "$token" "$control_dir"; then
    echo "ds: malformed Upterm TTL watcher state retained" >&2
    return 1
  fi
  if ! rm -f "$control_dir/cancel" "$control_dir/done" \
    "$control_dir/ready" "$control_dir/watcher" ||
    ! rmdir "$control_dir"; then
    echo "ds: failed to remove exact Upterm TTL watcher state" >&2
    return 1
  fi
}

_upterm_ttl_watcher_main() {
  local ttl="$1" session="$2" token="$3" control_dir="$4" ds_bin="$5"
  local watcher_pid="" deadline request_token="" request="" result
  set +e
  umask 077
  [[ "$ttl" =~ ^[0-9]+$ && "$ttl" -gt 0 && -n "$session" &&
    "$session" != *$'\n'* && "$token" =~ ^[[:xdigit:]]{32}$ &&
    "$control_dir" == *.upterm.ttl."$token" &&
    -d "$control_dir" && ! -L "$control_dir" ]] || return 1
  _upterm_current_pid watcher_pid || return 1
  _upterm_write_pid_file "$control_dir/watcher" "$watcher_pid" "$token" || return 1
  _upterm_supervisor_write_status "$control_dir/ready" "$token" ready || return 1
  # SECONDS is integer-valued, so add one tick to avoid expiring before the TTL.
  deadline=$((SECONDS + ttl + 1))
  while ((SECONDS < deadline)); do
    if [[ -e "$control_dir/cancel" || -L "$control_dir/cancel" ]]; then
      if _upterm_read_token_state \
        "$control_dir/cancel" request request_token request &&
        [[ "$request_token" == "$token" && "$request" == cancel ]]; then
        _upterm_supervisor_write_status \
          "$control_dir/done" "$token" cancelled || return 1
        return 0
      fi
      return 1
    fi
    sleep 0.05
  done
  if DS_UPTERM_EXPECTED_TOKEN="$token" DS_UPTERM_TTL_EXPIRY_TOKEN="$token" \
    "$ds_bin" --unshare "$session"; then
    result=expired
  else
    result=stale
  fi
  if [[ -e "$control_dir/cancel" || -L "$control_dir/cancel" ]]; then
    _upterm_supervisor_write_status \
      "$control_dir/done" "$token" cancelled || return 1
    return 0
  fi
  _upterm_supervisor_write_status "$control_dir/done" "$token" "$result" || return 1
  _upterm_cleanup_ttl_control "$token" "$control_dir"
}

_upterm_ttl_watcher_exec() {
  local ttl="$1" session="$2" token="$3" control_dir="$4" ds_bin="$5"
  local plugin_source watcher_name
  plugin_source="${BASH_SOURCE[0]}"
  [[ "$plugin_source" == /* ]] || plugin_source="$PWD/$plugin_source"
  watcher_name="ds-upterm-ttl-$token"
  # shellcheck disable=SC2016 # The detached watcher expands its own arguments.
  exec nohup bash -c \
    'source "$1" || exit; shift; _upterm_ttl_watcher_main "$@"' \
    "$watcher_name" "$plugin_source" "$ttl" "$session" "$token" \
    "$control_dir" "$ds_bin"
}

_upterm_wait_for_ttl_watcher() {
  local pid="$1" identity="$2" token="$3" control_dir state_token="" result="" attempt status
  control_dir=$(_upterm_ttl_control_dir "$token") || return 1
  for ((attempt = 0; attempt < 500; attempt++)); do
    if _upterm_read_token_state \
      "$control_dir/ready" result state_token result &&
      [[ "$state_token" == "$token" && "$result" == ready ]]; then
      _upterm_ttl_watcher_matches "$pid" "$identity" "$token"
      return
    fi
    if _upterm_pid_matches_identity "$pid" "$identity"; then
      status=0
    else
      status=$?
    fi
    case "$status" in
      0) ;;
      1)
        echo "ds: Upterm TTL watcher exited before its ready handshake" >&2
        return 1
        ;;
      *)
        echo "ds: cannot verify the Upterm TTL watcher while starting" >&2
        return 1
        ;;
    esac
    sleep 0.01
  done
  echo "ds: timed out waiting for the Upterm TTL watcher ready handshake" >&2
  return 1
}

_upterm_cancel_ttl_watcher() {
  local token="$1" control_dir watcher_pid="" watcher_identity="" watcher_token=""
  local state_token="" result="" attempt status
  control_dir=$(_upterm_ttl_control_dir "$token") || return 1
  [[ -e "$control_dir" || -L "$control_dir" ]] || return 0
  if ! _upterm_validate_ttl_control "$token"; then
    echo "ds: malformed Upterm TTL watcher state retained" >&2
    return 1
  fi
  _upterm_read_pid_file \
    "$control_dir/watcher" watcher_pid watcher_identity watcher_token || return 1
  if [[ -e "$control_dir/done" || -L "$control_dir/done" ]]; then
    if _upterm_read_token_state \
      "$control_dir/done" result state_token result &&
      [[ "$state_token" == "$token" ]] &&
      { [[ "$result" == cancelled || "$result" == expired ||
        "$result" == stale ]]; }; then
      wait "$watcher_pid" 2>/dev/null || true
      _upterm_cleanup_ttl_control "$token"
      return
    fi
    echo "ds: malformed Upterm TTL completion state retained" >&2
    return 1
  fi
  if ! _upterm_ttl_watcher_matches \
    "$watcher_pid" "$watcher_identity" "$token"; then
    echo "ds: cannot verify the exact Upterm TTL watcher; state retained" >&2
    return 1
  fi
  _upterm_write_token_state \
    "$control_dir/cancel" request "$token" cancel || return 1
  for ((attempt = 0; attempt < 500; attempt++)); do
    if _upterm_read_token_state \
      "$control_dir/done" result state_token result &&
      [[ "$state_token" == "$token" && "$result" == cancelled ]]; then
      wait "$watcher_pid" 2>/dev/null || true
      _upterm_cleanup_ttl_control "$token"
      return
    fi
    if _upterm_pid_matches_identity "$watcher_pid" "$watcher_identity"; then
      status=0
    else
      status=$?
    fi
    case "$status" in
      0) ;;
      1)
        # The watcher can acknowledge and exit between the state and identity
        # probes, so completion gets one exact-token recheck before failure.
        if _upterm_read_token_state \
          "$control_dir/done" result state_token result &&
          [[ "$state_token" == "$token" && "$result" == cancelled ]]; then
          wait "$watcher_pid" 2>/dev/null || true
          _upterm_cleanup_ttl_control "$token"
          return
        fi
        echo "ds: Upterm TTL watcher exited without acknowledging cancellation; state retained" >&2
        return 1
        ;;
      *)
        echo "ds: cannot verify the Upterm TTL watcher during cancellation; state retained" >&2
        return 1
        ;;
    esac
    sleep 0.01
  done
  echo "ds: timed out waiting for Upterm TTL cancellation; state retained" >&2
  return 1
}

_upterm_start_ttl_watcher() {
  local ttl="$1" session="$2" token="$3" control_dir ds_bin watcher_pid watcher_identity=""
  [[ "$ttl" =~ ^[0-9]+$ && "$ttl" -gt 0 && -n "$session" &&
    "$session" != *$'\n'* && "$token" =~ ^[[:xdigit:]]{32}$ ]] || return 1
  control_dir=$(_upterm_ttl_control_dir "$token") || return 1
  _upterm_cancel_ttl_watcher "$token" || return 1
  _upterm_create_ttl_control_dir "$token" || return 1
  ds_bin=$(command -v ds 2>/dev/null || true)
  [[ -n "$ds_bin" ]] || ds_bin=ds
  _upterm_ttl_watcher_exec \
    "$ttl" "$session" "$token" "$control_dir" "$ds_bin" \
    </dev/null >/dev/null 2>&1 &
  watcher_pid=$!
  if ! _upterm_process_identity "$watcher_pid" watcher_identity ||
    ! _upterm_wait_for_ttl_watcher \
      "$watcher_pid" "$watcher_identity" "$token"; then
    echo "ds: failed to start the exact Upterm TTL watcher; state retained" >&2
    return 1
  fi
}

# Start TTL watcher if share-ttl > 0; print expiry message. No-op if TTL=0.
_upterm_maybe_start_ttl_watcher() {
  local session="$1" token="$2"
  local ttl="${DS_UPTERM_SHARE_TTL:-3600}"
  if [[ "$ttl" =~ ^[0-9]+$ && "$ttl" -gt 0 ]]; then
    _upterm_start_ttl_watcher "$ttl" "$session" "$token" || return 1
    echo "ds: share will auto-expire in ${ttl}s (run 'ds --share' to reset)"
  fi
}

_upterm_close_inherited_fds() {
  local path fd found=0
  for path in /dev/fd/*; do
    fd="${path##*/}"
    [[ "$fd" =~ ^[0-9]+$ ]] || continue
    ((fd >= 4)) || continue
    ((fd == 255)) && continue
    found=1
    eval "exec ${fd}>&-"
  done
  if ((found == 0)); then
    for ((fd = 4; fd <= 255; fd++)); do
      eval "exec ${fd}>&-"
    done
  fi
}

_upterm_wait_for_launch_gate() {
  local gate="$1" parent_pid="$2" parent_identity="$3"
  while [[ ! -e "$gate" && ! -L "$gate" ]]; do
    _upterm_pid_matches_identity "$parent_pid" "$parent_identity" || return 1
    sleep 0.01
  done
  [[ -f "$gate" && ! -L "$gate" ]] || return 1
  _upterm_consume_launch_gate "$gate"
}

_upterm_consume_launch_gate() {
  rm -f "$1"
}

_upterm_create_control_dir() {
  local token="$1" control_dir old_umask
  control_dir=$(_upterm_control_dir "$token") || return 1
  old_umask=$(umask)
  umask 077
  if ! mkdir "$control_dir" 2>/dev/null || ! chmod 700 "$control_dir"; then
    umask "$old_umask"
    echo "ds: failed to create private Upterm supervisor control state" >&2
    return 1
  fi
  umask "$old_umask"
}

_upterm_direct_child_running() {
  local child="$1" candidate jobs_file="${_UPTERM_JOBS_FILE:-}"
  [[ -n "$jobs_file" && "$jobs_file" == *.upterm.control.*/*.jobs &&
    ! -L "$jobs_file" ]] || return 2
  if ! jobs -pr >"$jobs_file" || ! chmod 600 "$jobs_file"; then
    return 2
  fi
  while IFS= read -r candidate; do
    [[ "$candidate" == "$child" ]] && return 0
  done <"$jobs_file"
  return 1
}

_upterm_monitor_stop_child() {
  local deadline
  [[ "${_UPTERM_MONITOR_CHILD:-}" =~ ^[0-9]+$ ]] || return 0
  if _upterm_direct_child_running "$_UPTERM_MONITOR_CHILD"; then
    kill -TERM "$_UPTERM_MONITOR_CHILD" 2>/dev/null || true
    deadline=$((SECONDS + 5))
    while _upterm_direct_child_running "$_UPTERM_MONITOR_CHILD"; do
      ((SECONDS < deadline)) || break
      sleep 0.01
    done
    if _upterm_direct_child_running "$_UPTERM_MONITOR_CHILD"; then
      kill -KILL "$_UPTERM_MONITOR_CHILD" 2>/dev/null || true
    fi
  fi
  wait "$_UPTERM_MONITOR_CHILD" 2>/dev/null || true
  _UPTERM_MONITOR_CHILD=""
}

_upterm_write_token_state() {
  local path="$1" field="$2" token="$3" value="$4" temporary
  [[ "$field" =~ ^[a-z]+$ && -n "$value" && "$value" != *$'\n'* ]] || return 1
  temporary="${path}.new"
  if [[ -e "$temporary" || -L "$temporary" || -L "$path" ]]; then
    return 1
  fi
  if ! printf 'version=1\ntoken=%s\n%s=%s\n' \
    "$token" "$field" "$value" >"$temporary" || ! chmod 600 "$temporary" ||
    ! mv -f "$temporary" "$path"; then
    rm -f "$temporary"
    return 1
  fi
}

_upterm_supervisor_write_status() {
  _upterm_write_token_state "$1" result "$2" "$3"
}

_upterm_monitor_main() {
  local token="$1" control_dir="$2" channel="$3" child_status=1
  local monitor_command="" monitor_pid="" read_status result="exited"
  shift 3
  set +e
  umask 077
  [[ "$token" =~ ^[[:xdigit:]]{32}$ &&
    "$control_dir" == *.upterm.control."$token" &&
    -d "$control_dir" && ! -L "$control_dir" ]] || return 1
  exec 4<"$channel" || return 1
  _UPTERM_JOBS_FILE="$control_dir/monitor.jobs"
  _UPTERM_MONITOR_CHILD=""
  trap '_upterm_monitor_stop_child; exit 129' HUP
  trap '_upterm_monitor_stop_child; exit 130' INT
  trap '_upterm_monitor_stop_child; exit 143' TERM
  trap '_upterm_monitor_stop_child' EXIT
  _upterm_current_pid monitor_pid || return 1
  _upterm_write_pid_file "$control_dir/monitor" "$monitor_pid" "$token" || return 1

  "$@" &
  _UPTERM_MONITOR_CHILD=$!
  exec 3<&-
  _upterm_supervisor_write_status "$control_dir/ready" "$token" ready || return 1
  while _upterm_direct_child_running "$_UPTERM_MONITOR_CHILD"; do
    if IFS= read -r -t 1 monitor_command <&4; then
      if [[ "$monitor_command" == stop ]]; then
        result="stopped"
      else
        result="owner-lost"
      fi
      _upterm_monitor_stop_child
      _upterm_supervisor_write_status "$control_dir/done" "$token" "$result" || return 1
      return 0
    else
      read_status=$?
    fi
    # Bash returns a status above 128 for a timeout. EOF and channel errors
    # are owner loss and must stop the direct child.
    if ((read_status <= 128)); then
      _upterm_monitor_stop_child
      _upterm_supervisor_write_status \
        "$control_dir/done" "$token" owner-lost || return 1
      return 0
    fi
  done
  wait "$_UPTERM_MONITOR_CHILD"
  child_status=$?
  _UPTERM_MONITOR_CHILD=""
  _upterm_supervisor_write_status "$control_dir/done" "$token" exited || return 1
  return "$child_status"
}

_upterm_supervisor_stop_monitor() {
  local write_status=0
  [[ "${_UPTERM_SUPERVISOR_MONITOR:-}" =~ ^[0-9]+$ ]] || return 0
  printf 'stop\n' >&4 2>/dev/null || write_status=$?
  exec 4>&-
  if ((write_status != 0)) &&
    _upterm_direct_child_running "$_UPTERM_SUPERVISOR_MONITOR"; then
    kill -TERM "$_UPTERM_SUPERVISOR_MONITOR" 2>/dev/null || true
  fi
  wait "$_UPTERM_SUPERVISOR_MONITOR" 2>/dev/null || true
  _UPTERM_SUPERVISOR_MONITOR=""
}

_upterm_supervisor_main() {
  local token="$1" control_dir="$2" gate="$3" parent_pid="$4"
  local parent_identity="$5" monitor_status=1 channel
  shift 5
  set +e
  umask 077
  [[ "$token" =~ ^[[:xdigit:]]{32}$ &&
    "$control_dir" == *.upterm.control."$token" &&
    -d "$control_dir" && ! -L "$control_dir" ]] || return 1
  _UPTERM_SUPERVISOR_MONITOR=""
  _UPTERM_JOBS_FILE="$control_dir/supervisor.jobs"
  trap '_upterm_supervisor_stop_monitor; exit 129' HUP
  trap '_upterm_supervisor_stop_monitor; exit 130' INT
  trap '_upterm_supervisor_stop_monitor; exit 143' TERM
  trap '_upterm_supervisor_stop_monitor' EXIT
  _upterm_supervisor_write_status \
    "$control_dir/waiting" "$token" waiting || return 1
  while [[ ! -e "$gate" && ! -L "$gate" ]]; do
    [[ ! -e "$control_dir/stop" && ! -L "$control_dir/stop" ]] || return 0
    _upterm_pid_matches_identity "$parent_pid" "$parent_identity" || return 1
    sleep 0.01
  done
  [[ -f "$gate" && ! -L "$gate" ]] || return 1
  _upterm_consume_launch_gate "$gate" || return 1
  [[ ! -e "$control_dir/stop" && ! -L "$control_dir/stop" ]] || return 0
  _upterm_supervisor_write_status \
    "$control_dir/crossed" "$token" crossed || return 1

  channel="$control_dir/owner.pipe"
  if [[ -e "$channel" || -L "$channel" ]] ||
    ! mkfifo "$channel" || ! chmod 600 "$channel"; then
    return 1
  fi
  _upterm_monitor_main "$token" "$control_dir" "$channel" "$@" &
  _UPTERM_SUPERVISOR_MONITOR=$!
  exec 4>"$channel" || return 1
  rm -f "$channel" || return 1
  exec 3<&-
  while _upterm_direct_child_running "$_UPTERM_SUPERVISOR_MONITOR"; do
    if [[ -f "$control_dir/stop" && ! -L "$control_dir/stop" ]]; then
      printf 'stop\n' >&4 2>/dev/null || true
      break
    fi
    sleep 0.05
  done
  exec 4>&-
  wait "$_UPTERM_SUPERVISOR_MONITOR"
  monitor_status=$?
  _UPTERM_SUPERVISOR_MONITOR=""
  return "$monitor_status"
}

_upterm_supervisor_matches() {
  local pid="$1" identity="$2" token="$3" command_line identity_status
  if _upterm_pid_matches_identity "$pid" "$identity"; then
    identity_status=0
  else
    identity_status=$?
  fi
  ((identity_status == 0)) || return "$identity_status"
  if ! command_line=$(LC_ALL=C ps -ww -o command= -p "$pid" 2>/dev/null); then
    # The process may exit between the lifetime and command probes. Recheck so
    # token-bound completion can distinguish that race from an inspection error.
    if _upterm_pid_matches_identity "$pid" "$identity"; then
      return 2
    else
      identity_status=$?
    fi
    return "$identity_status"
  fi
  [[ "$command_line" == *"ds-upterm-supervisor-$token"* ]]
}

_upterm_publish_supervisor_stop() {
  local token="$1" control_dir temporary stop old_umask
  control_dir=$(_upterm_control_dir "$token") || return 1
  temporary="$control_dir/stop.new"
  stop="$control_dir/stop"
  [[ -d "$control_dir" && ! -L "$control_dir" && ! -L "$stop" ]] || return 1
  [[ -f "$stop" ]] && return 0
  old_umask=$(umask)
  umask 077
  if ! (
    set -o noclobber
    printf 'version=1\ntoken=%s\n' "$token" >"$temporary"
  ) 2>/dev/null || ! chmod 600 "$temporary" || ! mv -f "$temporary" "$stop"; then
    umask "$old_umask"
    echo "ds: failed to publish the private Upterm supervisor stop request" >&2
    return 1
  fi
  umask "$old_umask"
}

_upterm_request_supervisor_stop() {
  local pid="$1" identity="$2" token="$3" attempt identity_status supervisor_status
  local control_dir done_token="" done_result=""
  control_dir=$(_upterm_control_dir "$token") || return 1
  if ! _upterm_read_snapshot_owner "$(_upterm_known_hosts_owner_file)" ||
    [[ "$_UPTERM_SNAPSHOT_TOKEN" != "$token" ]] ||
    { [[ "$_UPTERM_SNAPSHOT_PHASE" != starting ]] &&
      [[ "$_UPTERM_SNAPSHOT_PID" != "$pid" ||
        "$_UPTERM_SNAPSHOT_IDENTITY" != "$identity" ]]; }; then
    echo "ds: Upterm ownership changed before the supervisor stop request" >&2
    return 1
  fi
  if _upterm_pid_matches_identity "$pid" "$identity"; then
    identity_status=0
  else
    identity_status=$?
  fi
  case "$identity_status" in
    0) ;;
    1)
      if _upterm_read_token_state \
        "$control_dir/done" result done_token done_result &&
        [[ "$done_token" == "$token" &&
          ("$done_result" == stopped || "$done_result" == exited ||
          "$done_result" == owner-lost) ]]; then
        return 0
      fi
      echo "ds: Upterm supervisor exited without verified child completion; state retained" >&2
      return 1
      ;;
    *)
      echo "ds: cannot verify the Upterm supervisor before stopping; state retained" >&2
      return 1
      ;;
  esac
  if _upterm_supervisor_matches "$pid" "$identity" "$token"; then
    supervisor_status=0
  else
    supervisor_status=$?
  fi
  case "$supervisor_status" in
    0) ;;
    1)
      if _upterm_read_token_state \
        "$control_dir/done" result done_token done_result &&
        [[ "$done_token" == "$token" &&
          ("$done_result" == stopped || "$done_result" == exited ||
          "$done_result" == owner-lost) ]]; then
        return 0
      fi
      echo "ds: refusing to stop a process that is not the exact Upterm supervisor" >&2
      return 1
      ;;
    *)
      echo "ds: cannot inspect the exact Upterm supervisor; state retained" >&2
      return 1
      ;;
  esac
  _upterm_publish_supervisor_stop "$token" || return 1
  for ((attempt = 0; attempt < 500; attempt++)); do
    if _upterm_pid_matches_identity "$pid" "$identity"; then
      identity_status=0
    else
      identity_status=$?
    fi
    if ((identity_status == 1)); then
      if _upterm_read_token_state \
        "$control_dir/done" result done_token done_result &&
        [[ "$done_token" == "$token" &&
          ("$done_result" == stopped || "$done_result" == exited ||
          "$done_result" == owner-lost) ]]; then
        return 0
      fi
      echo "ds: Upterm supervisor exited without verified child completion; state retained" >&2
      return 1
    elif ((identity_status != 0)); then
      echo "ds: cannot verify the Upterm supervisor while stopping; state retained" >&2
      return 1
    fi
    if _upterm_supervisor_matches "$pid" "$identity" "$token"; then
      :
    else
      supervisor_status=$?
      if ((supervisor_status == 2)); then
        echo "ds: cannot inspect the Upterm supervisor while stopping; state retained" >&2
      elif _upterm_read_token_state \
        "$control_dir/done" result done_token done_result &&
        [[ "$done_token" == "$token" &&
          ("$done_result" == stopped || "$done_result" == exited ||
          "$done_result" == owner-lost) ]]; then
        return 0
      else
        echo "ds: Upterm supervisor identity changed while stopping" >&2
      fi
      return 1
    fi
    sleep 0.01
  done
  echo "ds: timed out waiting for the exact Upterm supervisor to stop" >&2
  return 1
}

_upterm_write_pid_file() {
  local pid_file="$1" pid="$2" token="$3" old_umask pid_identity=""
  [[ "$token" =~ ^[[:xdigit:]]{32}$ ]] || return 1
  _upterm_process_identity "$pid" pid_identity || return 1
  old_umask=$(umask)
  umask 077
  if ! printf 'version=2\npid=%s\nidentity=%s\ntoken=%s\n' \
    "$pid" "$pid_identity" "$token" >"$pid_file" ||
    ! chmod 600 "$pid_file"; then
    umask "$old_umask"
    return 1
  fi
  umask "$old_umask"
}

_upterm_read_pid_file() {
  local pid_file="$1" pid_var="$2" identity_var="$3" token_var="${4:-}" key value
  local seen_version=0 seen_pid=0 seen_identity=0 seen_token=0
  local _uprp_pid="" _uprp_identity="" _uprp_token=""
  [[ -f "$pid_file" && ! -L "$pid_file" ]] || return 1
  while IFS='=' read -r key value; do
    case "$key" in
      version)
        ((seen_version == 0)) || return 1
        seen_version=1
        [[ "$value" == 2 ]] || return 1
        ;;
      pid)
        ((seen_pid == 0)) || return 1
        seen_pid=1
        _uprp_pid="$value"
        ;;
      identity)
        ((seen_identity == 0)) || return 1
        seen_identity=1
        _uprp_identity="$value"
        ;;
      token)
        ((seen_token == 0)) || return 1
        seen_token=1
        _uprp_token="$value"
        ;;
      *) return 1 ;;
    esac
  done <"$pid_file" || return 1
  [[ "$seen_version$seen_pid$seen_identity$seen_token" == 1111 &&
    "$_uprp_pid" =~ ^[0-9]+$ &&
    ${#_uprp_identity} -eq 48 && "$_uprp_identity" != *[!0-9a-f]* &&
    "$_uprp_token" =~ ^[[:xdigit:]]{32}$ ]] || return 1
  printf -v "$pid_var" '%s' "$_uprp_pid"
  printf -v "$identity_var" '%s' "$_uprp_identity"
  [[ -z "$token_var" ]] || printf -v "$token_var" '%s' "$_uprp_token"
}

_upterm_write_session_file() {
  local session_file="$1" token="$2" session="$3" old_umask
  [[ "$token" =~ ^[[:xdigit:]]{32}$ && -n "$session" &&
    "$session" != *$'\n'* ]] || return 1
  old_umask=$(umask)
  umask 077
  if ! (
    set -o noclobber
    printf 'version=1\ntoken=%s\nsession=%s\n' \
      "$token" "$session" >"$session_file"
  ) 2>/dev/null || ! chmod 600 "$session_file"; then
    umask "$old_umask"
    return 1
  fi
  umask "$old_umask"
}

_upterm_read_token_state() {
  local path="$1" field="$2" token_var="$3" value_var="$4" key value
  local seen_version=0 seen_token=0 seen_value=0 _uprts_token="" _uprts_value=""
  [[ -f "$path" && ! -L "$path" ]] || return 1
  while IFS='=' read -r key value; do
    case "$key" in
      version)
        ((seen_version == 0)) || return 1
        seen_version=1
        [[ "$value" == 1 ]] || return 1
        ;;
      token)
        ((seen_token == 0)) || return 1
        seen_token=1
        _uprts_token="$value"
        ;;
      "$field")
        ((seen_value == 0)) || return 1
        seen_value=1
        _uprts_value="$value"
        ;;
      *) return 1 ;;
    esac
  done <"$path" || return 1
  [[ "$seen_version$seen_token$seen_value" == 111 &&
    "$_uprts_token" =~ ^[[:xdigit:]]{32}$ && -n "$_uprts_value" ]] || return 1
  printf -v "$token_var" '%s' "$_uprts_token"
  [[ -z "$value_var" ]] || printf -v "$value_var" '%s' "$_uprts_value"
}

_upterm_read_log_token() {
  local path="$1" token_var="$2" version_line token_line token
  [[ -f "$path" && ! -L "$path" ]] || return 1
  {
    IFS= read -r version_line
    IFS= read -r token_line
  } <"$path" || return 1
  [[ "$version_line" == version=1 && "$token_line" == token=* ]] || return 1
  token="${token_line#token=}"
  [[ "$token" =~ ^[[:xdigit:]]{32}$ ]] || return 1
  printf -v "$token_var" '%s' "$token"
}

_upterm_cleanup_lifecycle_files() {
  local token="$1" pid_file pid="" identity="" pid_token=""
  local state_token="" state_file state_field
  local -a files
  pid_file=$(_upterm_pid_file)
  [[ "$token" =~ ^[[:xdigit:]]{32}$ ]] || return 1
  if [[ -e "$pid_file" || -L "$pid_file" ]]; then
    if ! _upterm_read_pid_file "$pid_file" pid identity pid_token ||
      [[ "$pid_token" != "$token" ]]; then
      echo "ds: refusing to remove Upterm process state owned by another lifecycle" >&2
      return 1
    fi
  fi
  for state_file in "$(_upterm_session_file)" "$(_upterm_admin_file)"; do
    [[ -e "$state_file" || -L "$state_file" ]] || continue
    if [[ "$state_file" == "$(_upterm_session_file)" ]]; then
      state_field="session"
    else
      state_field="admin"
    fi
    if ! _upterm_read_token_state \
      "$state_file" "$state_field" state_token "" ||
      [[ "$state_token" != "$token" ]]; then
      echo "ds: refusing to remove Upterm state owned by another lifecycle" >&2
      return 1
    fi
  done
  state_file=$(_upterm_log_file)
  if [[ -e "$state_file" || -L "$state_file" ]]; then
    if ! _upterm_read_log_token "$state_file" state_token ||
      [[ "$state_token" != "$token" ]]; then
      echo "ds: refusing to remove an Upterm log owned by another lifecycle" >&2
      return 1
    fi
  fi
  files=("$pid_file" "$(_upterm_admin_file)" "$(_upterm_session_file)"
  "$(_upterm_log_file)")
  [[ -z "${DS_SHARE_INFO_FILE:-}" ]] || files+=("$DS_SHARE_INFO_FILE")
  if ! rm -f "${files[@]}"; then
    echo "ds: failed to remove exact Upterm lifecycle state" >&2
    return 1
  fi
}

_upterm_release_launch_gate() {
  local gate="$1" child_pid="$2" child_identity="$3" old_umask attempt
  old_umask=$(umask)
  umask 077
  # Redirection creates 0666 & ~077 = 0600. That is the final mode because
  # the waiting child may consume and unlink the gate immediately.
  if ! (
    set -o noclobber
    : >"$gate"
  ) 2>/dev/null; then
    umask "$old_umask"
    echo "ds: failed to publish the private Upterm launch gate" >&2
    return 1
  fi
  umask "$old_umask"
  for ((attempt = 0; attempt < 500; attempt++)); do
    [[ ! -e "$gate" && ! -L "$gate" ]] && return 0
    _upterm_pid_matches_identity "$child_pid" "$child_identity" || {
      [[ ! -e "$gate" && ! -L "$gate" ]] && return 0
      echo "ds: Upterm launcher exited before observing its launch gate" >&2
      return 1
    }
    sleep 0.01
  done
  echo "ds: timed out waiting for Upterm to observe its launch gate" >&2
  return 1
}

_upterm_child_exec() {
  local trust_fd="$1" gate="$2" parent_pid="$3" parent_identity="$4"
  shift 4
  case "$trust_fd" in
    "") exec 3<&- ;;
    9) exec 3<&9 ;;
    8) exec 3<&8 ;;
    7) exec 3<&7 ;;
    6) exec 3<&6 ;;
    5) exec 3<&5 ;;
    4) exec 3<&4 ;;
    3) : ;;
    *) return 1 ;;
  esac
  _upterm_close_inherited_fds
  _upterm_wait_for_launch_gate "$gate" "$parent_pid" "$parent_identity" || return 1
  _upterm_exec_command "$@"
}

_upterm_exec_command() {
  exec "$@"
}

_upterm_spawn_with_trust_fd() {
  local trust_fd="$1" log_file="$2" gate="$3" parent_pid="$4" parent_identity="$5"
  shift 5
  _upterm_child_exec "$trust_fd" "$gate" "$parent_pid" "$parent_identity" "$@" \
    </dev/null >>"$log_file" 2>&1 &
  _UPTERM_SPAWN_PID=$!
}

_upterm_supervisor_exec() {
  local trust_fd="$1" token="$2" gate="$3" parent_pid="$4" parent_identity="$5"
  local control_dir plugin_source supervisor_name
  shift 5
  case "$trust_fd" in
    "") exec 3<&- ;;
    9) exec 3<&9 ;;
    8) exec 3<&8 ;;
    7) exec 3<&7 ;;
    6) exec 3<&6 ;;
    5) exec 3<&5 ;;
    4) exec 3<&4 ;;
    3) : ;;
    *) return 1 ;;
  esac
  _upterm_close_inherited_fds
  control_dir=$(_upterm_control_dir "$token") || return 1
  plugin_source="${BASH_SOURCE[0]}"
  [[ "$plugin_source" == /* ]] || plugin_source="$PWD/$plugin_source"
  supervisor_name="ds-upterm-supervisor-$token"
  if command -v setsid >/dev/null 2>&1 && ! _upterm_is_wsl; then
    # shellcheck disable=SC2016 # The isolated supervisor expands its own arguments.
    exec setsid bash -c \
      'source "$1" || exit; shift; _upterm_supervisor_main "$@"' \
      "$supervisor_name" "$plugin_source" "$token" "$control_dir" \
      "$gate" "$parent_pid" "$parent_identity" "$@"
  else
    # shellcheck disable=SC2016 # The isolated supervisor expands its own arguments.
    exec nohup bash -c \
      'source "$1" || exit; shift; _upterm_supervisor_main "$@"' \
      "$supervisor_name" "$plugin_source" "$token" "$control_dir" \
      "$gate" "$parent_pid" "$parent_identity" "$@"
  fi
}

_upterm_spawn_supervisor() {
  local trust_fd="$1" log_file="$2" token="$3" gate="$4"
  local parent_pid="$5" parent_identity="$6"
  shift 6
  _upterm_supervisor_exec "$trust_fd" "$token" "$gate" \
    "$parent_pid" "$parent_identity" "$@" </dev/null >>"$log_file" 2>&1 &
  _UPTERM_SPAWN_PID=$!
}

_upterm_wait_for_supervisor_waiting() {
  local pid="$1" identity="$2" token="$3" control_dir
  local max_attempts="${4:-500}" state_token="" result="" attempt identity_status
  [[ "$max_attempts" =~ ^[0-9]+$ && "$max_attempts" -gt 0 ]] || return 1
  control_dir=$(_upterm_control_dir "$token") || return 1
  for ((attempt = 0; attempt < max_attempts; attempt++)); do
    if _upterm_read_token_state \
      "$control_dir/waiting" result state_token result &&
      [[ "$state_token" == "$token" && "$result" == waiting ]]; then
      if _upterm_pid_matches_identity "$pid" "$identity"; then
        return 0
      fi
      identity_status=$?
      if ((identity_status == 1)); then
        echo "ds: Upterm supervisor exited after its waiting handshake" >&2
      else
        echo "ds: cannot verify the Upterm supervisor after its waiting handshake" >&2
      fi
      return 1
    fi
    if _upterm_pid_matches_identity "$pid" "$identity"; then
      identity_status=0
    else
      identity_status=$?
    fi
    case "$identity_status" in
      0) ;;
      1)
        echo "ds: Upterm supervisor exited before its waiting handshake" >&2
        return 1
        ;;
      *)
        echo "ds: cannot verify the Upterm supervisor before its waiting handshake" >&2
        return 1
        ;;
    esac
    sleep 0.01
  done
  echo "ds: timed out waiting for the Upterm supervisor waiting handshake" >&2
  return 1
}

_upterm_cleanup_failed_start() {
  local pid="${1:-}" identity="${2:-}" token="${3:-}" snapshot="${4:-}"
  local gate="${5:-}" owner_file
  owner_file=$(_upterm_known_hosts_owner_file)
  if [[ ! "$token" =~ ^[[:xdigit:]]{32}$ ]] ||
    [[ ! -e "$owner_file" && ! -L "$owner_file" ]] ||
    ! _upterm_read_snapshot_owner "$owner_file" ||
    [[ "$_UPTERM_SNAPSHOT_TOKEN" != "$token" ]]; then
    echo "ds: failed-start cleanup no longer owns the exact Upterm lifecycle" >&2
    return 1
  fi
  if [[ "$_UPTERM_SNAPSHOT_PHASE" == active ]]; then
    if [[ "$_UPTERM_SNAPSHOT_PID" != "$pid" ||
      "$_UPTERM_SNAPSHOT_IDENTITY" != "$identity" ]] ||
      ! _upterm_write_snapshot_owner replace stopping "$pid" \
        "$token" "$snapshot" "$identity"; then
      echo "ds: failed-start cleanup could not reserve the exact Upterm lifecycle" >&2
      return 1
    fi
  fi
  if [[ "$pid" =~ ^[0-9]+$ ]]; then
    if [[ ${#identity} -ne 48 || "$identity" == *[!0-9a-f]* ]] ||
      ! _upterm_request_supervisor_stop "$pid" "$identity" "$token"; then
      echo "ds: failed-start cleanup retained an unverified Upterm supervisor" >&2
      return 1
    fi
  fi
  if ! _upterm_cleanup_lifecycle_files "$token" ||
    { [[ -n "$gate" ]] && ! rm -f "$gate"; }; then
    echo "ds: failed to remove exact Upterm state after startup failure" >&2
    return 1
  fi
  _upterm_cleanup_known_hosts_snapshot "$token" "$snapshot"
}

_upterm_share_running_locked() {
  local pid_file pid="" pid_identity="" pid_token="" identity_status supervisor_status
  pid_file=$(_upterm_pid_file)
  if [[ ! -f "$pid_file" ]]; then
    _upterm_reconcile_snapshot_owner || return 2
    return 1
  fi
  if ! _upterm_read_pid_file "$pid_file" pid pid_identity pid_token; then
    _upterm_reconcile_snapshot_owner || return 2
    return 1
  fi
  if _upterm_pid_matches_identity "$pid" "$pid_identity"; then
    identity_status=0
  else
    identity_status=$?
  fi
  if ((identity_status == 2)); then
    echo "ds: cannot verify the recorded Upterm process identity; state retained" >&2
    return 2
  elif ((identity_status == 1)); then
    _upterm_reconcile_snapshot_owner || return 2
    return 1
  fi
  local owner_file
  owner_file=$(_upterm_known_hosts_owner_file)
  if [[ -e "$owner_file" || -L "$owner_file" ]]; then
    if ! _upterm_read_snapshot_owner "$owner_file"; then
      return 2
    fi
    if [[ "$_UPTERM_SNAPSHOT_PHASE" != active ||
      "$_UPTERM_SNAPSHOT_PID" != "$pid" ||
      "$_UPTERM_SNAPSHOT_IDENTITY" != "$pid_identity" ||
      "$_UPTERM_SNAPSHOT_TOKEN" != "$pid_token" ]]; then
      _upterm_reconcile_snapshot_owner || return 2
      return 1
    fi
    if _upterm_supervisor_matches "$pid" "$pid_identity" "$pid_token"; then
      supervisor_status=0
    else
      supervisor_status=$?
    fi
    if ((supervisor_status == 2)); then
      echo "ds: cannot inspect the recorded Upterm supervisor; state retained" >&2
      return 2
    elif ((supervisor_status == 1)); then
      _upterm_reconcile_snapshot_owner || return 2
      return 1
    fi
  fi
  return 0
}

_upterm_has_lifecycle_evidence() {
  local state_prefix="$DS_STATE_DIR/ds"
  local pid_file="${DS_UPTERM_PID_FILE:-${state_prefix}.upterm.pid}"
  local owner_file="${state_prefix}.upterm.known_hosts.owner"
  local candidate

  for candidate in \
    "$pid_file" \
    "$owner_file" \
    "${state_prefix}.upterm.operation.lock"; do
    [[ -e "$candidate" || -L "$candidate" ]] && return 0
  done
  for candidate in \
    "${owner_file}."*.*.*.new \
    "${state_prefix}.upterm.launch."* \
    "${state_prefix}.upterm.control."* \
    "${state_prefix}.upterm.ttl."*; do
    [[ -e "$candidate" || -L "$candidate" ]] && return 0
  done
  return 1
}

_share_obviously_inactive() {
  ! _upterm_has_lifecycle_evidence
}

_share_running() {
  local operation_token="" running_status
  if ! _upterm_acquire_operation_lock operation_token; then
    return 2
  fi
  if _upterm_share_running_locked; then
    running_status=0
  else
    running_status=$?
  fi
  _upterm_release_operation_lock "$operation_token" || return 2
  return "$running_status"
}

_share_current_session() {
  local f session_token="" session=""
  f=$(_upterm_session_file)
  _upterm_read_snapshot_owner "$(_upterm_known_hosts_owner_file)" || return 1
  _upterm_read_token_state "$f" session session_token session || return 1
  [[ "$session_token" == "$_UPTERM_SNAPSHOT_TOKEN" ]] || return 1
  printf '%s\n' "$session"
}

_share_info() {
  _show_share_info
}

_upterm_share_start_locked() {
  local session="$1"
  local running_status

  if _upterm_share_running_locked; then
    running_status=0
  else
    running_status=$?
  fi
  if ((running_status == 0)); then
    local current_session
    current_session=$(_share_current_session)
    if [[ "$current_session" == "$session" ]]; then
      # Reset the TTL timer if configured.
      local ttl="${DS_UPTERM_SHARE_TTL:-3600}"
      if [[ "$ttl" =~ ^[0-9]+$ && "$ttl" -gt 0 ]]; then
        if ! _upterm_start_ttl_watcher \
          "$ttl" "$session" "$_UPTERM_SNAPSHOT_TOKEN"; then
          echo "ds: failed to reset the exact Upterm TTL watcher" >&2
          return 1
        fi
        echo "ds: already sharing session '$session' (TTL reset to ${ttl}s)"
      else
        echo "ds: already sharing session '$session'"
      fi
      _share_info
      return 0
    else
      echo "ds: already sharing session '${current_session:-unknown}' — run 'ds --unshare' first" >&2
      return 1
    fi
  elif ((running_status > 1)); then
    echo "ds: failed to reconcile stale Upterm snapshot state" >&2
    return 1
  fi

  local key
  key=$(_upterm_resolve_key) || {
    echo "ds: no usable SSH private key found for upterm" >&2
    return 1
  }

  if [[ -z "${DS_UPTERM_GITHUB_USER:-}" && -z "${DS_UPTERM_AUTHORIZED_KEYS:-}" ]]; then
    echo "" >&2
    echo "  WARNING: No github-user or authorized-keys set. Anyone with" >&2
    echo "  the share URL will have full access to your terminal session." >&2
    echo "" >&2
    read -r -p "  Share without authentication? [y/N] " answer </dev/tty
    if [[ "$answer" != [yY] ]]; then
      echo "ds: aborted — set github-user or authorized-keys in $CONF_DIR/share-upterm.conf" >&2
      return 1
    fi
  fi

  # Apply default server after config has been loaded
  : "${DS_UPTERM_HOST:=uptermd.upterm.dev:22}"

  local server_uri
  if ! server_uri=$(_upterm_server_uri "$DS_UPTERM_HOST"); then
    echo "ds: invalid upterm server address: $DS_UPTERM_HOST" >&2
    return 1
  fi

  # Validation reopens a private hard link so every pass starts at byte zero;
  # the untouched descriptor remains bound to the same inode for child handoff.
  local known_hosts_token="" known_hosts_snapshot="" known_hosts_fd=""
  local known_hosts_validation_path="" known_hosts_validation_anchor=""
  local launch_gate="" validation_status=0
  _upterm_acquire_snapshot_owner known_hosts_token known_hosts_snapshot || return 1
  if [[ -n "${DS_UPTERM_KNOWN_HOSTS:-}" ]]; then
    if ! _upterm_snapshot_known_hosts \
      "$DS_UPTERM_KNOWN_HOSTS" "$known_hosts_snapshot" \
      known_hosts_fd known_hosts_validation_path; then
      _upterm_cleanup_known_hosts_snapshot "$known_hosts_token" "$known_hosts_snapshot" || true
      return 1
    fi
    known_hosts_validation_anchor="${known_hosts_validation_path}.anchor"
    if [[ ! -f "$known_hosts_validation_path" ||
      -L "$known_hosts_validation_path" ||
      ! -f "$known_hosts_validation_anchor" ||
      -L "$known_hosts_validation_anchor" ||
      ! "$known_hosts_validation_path" -ef "$known_hosts_validation_anchor" ]]; then
      echo "ds: private known-hosts validation snapshot changed before verification" >&2
      validation_status=1
    elif ! _upterm_verify_known_host \
      "$DS_UPTERM_HOST" "$known_hosts_validation_path" \
      "$DS_UPTERM_KNOWN_HOSTS"; then
      validation_status=1
    elif [[ ! -f "$known_hosts_validation_path" ||
      -L "$known_hosts_validation_path" ||
      ! -f "$known_hosts_validation_anchor" ||
      -L "$known_hosts_validation_anchor" ||
      ! "$known_hosts_validation_path" -ef "$known_hosts_validation_anchor" ]]; then
      echo "ds: private known-hosts validation snapshot changed during verification" >&2
      validation_status=1
    fi
    if ! rm -f "$known_hosts_validation_path" "$known_hosts_validation_anchor"; then
      echo "ds: failed to remove the private known-hosts validation snapshot" >&2
      validation_status=1
    fi
    known_hosts_validation_path=""
    known_hosts_validation_anchor=""
    if ((validation_status)); then
      _upterm_close_fd "$known_hosts_fd"
      _upterm_cleanup_known_hosts_snapshot "$known_hosts_token" "$known_hosts_snapshot" || true
      return 1
    fi
  fi

  local host_args=(--accept --server "$server_uri" --private-key "$key")
  if [[ -n "$known_hosts_fd" ]]; then
    host_args+=(--known-hosts /dev/fd/3)
  elif [[ "$DS_UPTERM_HOST" != "uptermd.upterm.dev:22" ]]; then
    # Non-default server without host key verification — MITM risk
    echo "" >&2
    echo "  WARNING: Connecting to '$DS_UPTERM_HOST' without host key" >&2
    echo "  verification. Set known-hosts in share-upterm.conf to fix." >&2
    echo "" >&2
    read -r -p "  Skip host key check? [y/N] " answer </dev/tty
    if [[ "$answer" != [yY] ]]; then
      echo "ds: aborted — set known-hosts in $CONF_DIR/share-upterm.conf" >&2
      _upterm_cleanup_known_hosts_snapshot \
        "$known_hosts_token" "$known_hosts_snapshot" || true
      return 1
    fi
    host_args+=(--skip-host-key-check)
  else
    host_args+=(--skip-host-key-check)
  fi
  [[ -n "${DS_UPTERM_GITHUB_USER:-}" ]] && host_args+=(--github-user "$DS_UPTERM_GITHUB_USER")
  [[ -n "${DS_UPTERM_AUTHORIZED_KEYS:-}" ]] && host_args+=(--authorized-keys "$DS_UPTERM_AUTHORIZED_KEYS")

  local pid_file admin_file log_file session_file
  pid_file=$(_upterm_pid_file)
  admin_file=$(_upterm_admin_file)
  log_file=$(_upterm_log_file)
  session_file=$(_upterm_session_file)
  if [[ -e "$pid_file" || -L "$pid_file" ||
    -e "$admin_file" || -L "$admin_file" ||
    -e "$log_file" || -L "$log_file" ||
    -e "$session_file" || -L "$session_file" ||
    (-n "${DS_SHARE_INFO_FILE:-}" &&
    (-e "$DS_SHARE_INFO_FILE" || -L "$DS_SHARE_INFO_FILE")) ]]; then
    echo "ds: unowned Upterm state exists; refusing to replace it" >&2
    _upterm_close_fd "$known_hosts_fd"
    _upterm_cleanup_known_hosts_snapshot \
      "$known_hosts_token" "$known_hosts_snapshot" || true
    return 1
  fi

  local old_umask
  old_umask=$(umask)
  umask 077
  if ! (
    set -o noclobber
    printf 'version=1\ntoken=%s\n' "$known_hosts_token" >"$log_file"
  ) 2>/dev/null ||
    ! chmod 600 "$log_file" ||
    ! _upterm_write_session_file \
      "$session_file" "$known_hosts_token" "$session"; then
    umask "$old_umask"
    echo "ds: failed to create private Upterm state" >&2
    _upterm_close_fd "$known_hosts_fd"
    _upterm_cleanup_failed_start "" "" "$known_hosts_token" "$known_hosts_snapshot" || true
    return 1
  fi
  umask "$old_umask"

  # Fully detach upterm from the controlling terminal.
  local hosted_cmd force_cmd
  local escaped_admin_file
  escaped_admin_file=$(printf '%q' "$admin_file")
  hosted_cmd="umask 077; printf 'version=1\\ntoken=$known_hosts_token\\nadmin=%s\\n' \"\$UPTERM_ADMIN_SOCKET\" > $escaped_admin_file; chmod 600 $escaped_admin_file; while true; do sleep 86400; done"
  # Connecting clients get a plain login shell. They can interact with the
  # host's tmux sessions non-destructively via tmux send-keys/capture-pane.
  force_cmd=$(_shell_login_cmd) || {
    echo "ds: failed to resolve the hosted login shell" >&2
    _upterm_close_fd "$known_hosts_fd"
    _upterm_cleanup_failed_start "" "" "$known_hosts_token" "$known_hosts_snapshot" || true
    return 1
  }

  local upterm_pid="" upterm_identity="" launcher_pid="" launcher_identity="" launch_token
  _upterm_current_pid launcher_pid || {
    echo "ds: failed to identify the Upterm launcher process" >&2
    _upterm_close_fd "$known_hosts_fd"
    _upterm_cleanup_failed_start "" "" "$known_hosts_token" "$known_hosts_snapshot" || true
    return 1
  }
  _upterm_process_identity "$launcher_pid" launcher_identity || {
    echo "ds: failed to identify the Upterm launcher lifetime" >&2
    _upterm_close_fd "$known_hosts_fd"
    _upterm_cleanup_failed_start "" "" "$known_hosts_token" "$known_hosts_snapshot" || true
    return 1
  }
  launch_token="$known_hosts_token"
  [[ -n "$launch_token" ]] || launch_token=$(_upterm_snapshot_token) || return 1
  launch_gate=$(_upterm_launch_gate_file "$launch_token") || return 1
  if [[ -e "$launch_gate" || -L "$launch_gate" ]]; then
    echo "ds: refusing to reuse an existing Upterm launch gate: $launch_gate" >&2
    _upterm_close_fd "$known_hosts_fd"
    _upterm_cleanup_failed_start "" "" "$known_hosts_token" \
      "$known_hosts_snapshot" "$launch_gate" || true
    return 1
  fi
  if ! _upterm_create_control_dir "$launch_token"; then
    _upterm_close_fd "$known_hosts_fd"
    _upterm_cleanup_failed_start "" "" "$known_hosts_token" \
      "$known_hosts_snapshot" "$launch_gate" || true
    return 1
  fi
  _upterm_spawn_supervisor "$known_hosts_fd" "$log_file" \
    "$launch_token" "$launch_gate" "$launcher_pid" "$launcher_identity" \
    env -u TMUX upterm host \
    "${host_args[@]}" \
    --force-command "$force_cmd" \
    -- bash -c "$hosted_cmd"
  upterm_pid="$_UPTERM_SPAWN_PID"
  if ! _upterm_process_identity "$upterm_pid" upterm_identity; then
    echo "ds: failed to identify the gated Upterm supervisor" >&2
    _upterm_close_fd "$known_hosts_fd"
    _upterm_publish_supervisor_stop "$known_hosts_token" || true
    return 1
  fi
  if ! _upterm_wait_for_supervisor_waiting \
    "$upterm_pid" "$upterm_identity" "$known_hosts_token"; then
    echo "ds: gated Upterm supervisor did not become ready" >&2
    _upterm_close_fd "$known_hosts_fd"
    _upterm_publish_supervisor_stop "$known_hosts_token" || true
    return 1
  fi
  _upterm_close_fd "$known_hosts_fd"
  known_hosts_fd=""

  if ! _upterm_supervisor_matches "$upterm_pid" "$upterm_identity" \
    "$known_hosts_token" ||
    ! _upterm_write_snapshot_owner replace active "$upterm_pid" \
      "$known_hosts_token" "$known_hosts_snapshot"; then
    echo "ds: failed to bind Upterm ownership to the exact supervisor" >&2
    _upterm_cleanup_failed_start "$upterm_pid" "$upterm_identity" \
      "$known_hosts_token" "$known_hosts_snapshot" "$launch_gate" || true
    return 1
  fi

  if ! _upterm_write_pid_file "$pid_file" "$upterm_pid" "$known_hosts_token"; then
    echo "ds: failed to record the Upterm process" >&2
    _upterm_cleanup_failed_start "$upterm_pid" "$upterm_identity" \
      "$known_hosts_token" "$known_hosts_snapshot" "$launch_gate" || true
    return 1
  fi
  if ! _upterm_release_launch_gate "$launch_gate" "$upterm_pid" "$upterm_identity"; then
    _upterm_cleanup_failed_start "$upterm_pid" "$upterm_identity" \
      "$known_hosts_token" "$known_hosts_snapshot" "$launch_gate" || true
    return 1
  fi

  # Wait for admin socket, then collect share info.
  local admin_sock content attempt admin_token=""
  for ((attempt = 0; attempt < 30; attempt++)); do
    if _upterm_read_token_state \
      "$admin_file" admin admin_token admin_sock 2>/dev/null &&
      [[ "$admin_token" == "$known_hosts_token" ]]; then
      break
    fi
    if ! _upterm_supervisor_matches "$upterm_pid" "$upterm_identity" \
      "$known_hosts_token"; then
      echo "ds: upterm exited before publishing share info" >&2
      _upterm_cleanup_failed_start "$upterm_pid" "$upterm_identity" \
        "$known_hosts_token" "$known_hosts_snapshot" || true
      return 1
    fi
    sleep 0.5
  done

  if [[ -z "${admin_sock:-}" ]]; then
    if ! _upterm_supervisor_matches "$upterm_pid" "$upterm_identity" \
      "$known_hosts_token"; then
      echo "ds: upterm exited before publishing share info" >&2
      _upterm_cleanup_failed_start "$upterm_pid" "$upterm_identity" \
        "$known_hosts_token" "$known_hosts_snapshot" || true
      return 1
    fi
    if content=$(_upterm_read_info_from_log "$log_file"); then
      _write_share_info "$content"
      printf '%s\n' "$content"
      _upterm_push_share_info "$session"
      _upterm_maybe_start_ttl_watcher \
        "$session" "$known_hosts_token" || return 1
      return 0
    fi
    echo "ds: timed out waiting for upterm share info" >&2
    _upterm_cleanup_failed_start "$upterm_pid" "$upterm_identity" \
      "$known_hosts_token" "$known_hosts_snapshot" || true
    return 1
  fi

  for ((attempt = 0; attempt < 30; attempt++)); do
    if ! _upterm_supervisor_matches "$upterm_pid" "$upterm_identity" \
      "$known_hosts_token"; then
      echo "ds: upterm exited before publishing share info" >&2
      _upterm_cleanup_failed_start "$upterm_pid" "$upterm_identity" \
        "$known_hosts_token" "$known_hosts_snapshot" || true
      return 1
    fi
    content=$(upterm session current --admin-socket "$admin_sock" 2>/dev/null || true)
    if [[ -n "$content" ]]; then
      content=$(_upterm_normalize_info "$content")
      _write_share_info "$content"
      printf '%s\n' "$content"
      _upterm_push_share_info "$session"
      _upterm_maybe_start_ttl_watcher \
        "$session" "$known_hosts_token" || return 1
      return 0
    fi
    sleep 0.5
  done

  if ! _upterm_supervisor_matches "$upterm_pid" "$upterm_identity" \
    "$known_hosts_token"; then
    echo "ds: upterm exited before publishing share info" >&2
    _upterm_cleanup_failed_start "$upterm_pid" "$upterm_identity" \
      "$known_hosts_token" "$known_hosts_snapshot" || true
    return 1
  fi
  if content=$(_upterm_read_info_from_log "$log_file"); then
    _write_share_info "$content"
    printf '%s\n' "$content"
    _upterm_push_share_info "$session"
    _upterm_maybe_start_ttl_watcher \
      "$session" "$known_hosts_token" || return 1
    return 0
  fi

  echo "ds: upterm started but couldn't retrieve share info" >&2
  _upterm_cleanup_failed_start "$upterm_pid" "$upterm_identity" \
    "$known_hosts_token" "$known_hosts_snapshot" || true
  return 1
}

_share_start() {
  local operation_token="" start_status acquire_status
  if _upterm_acquire_operation_lock operation_token; then
    acquire_status=0
  else
    acquire_status=$?
  fi
  if ((acquire_status != 0)); then
    ((acquire_status == 2)) &&
      echo "ds: another Upterm start is already in progress" >&2
    return 1
  fi
  if _upterm_share_start_locked "$@"; then
    start_status=0
  else
    start_status=$?
  fi
  _upterm_release_operation_lock "$operation_token" || return 1
  return "$start_status"
}

_upterm_share_stop_locked() {
  local session="$1"
  _share_load_config
  local pid_file cleanup_status=0 owner_file stop_pid="" stop_identity=""
  local stop_phase="" stop_token="" stop_snapshot=""
  local expected_token="${DS_UPTERM_EXPECTED_TOKEN:-}"
  local expiry_token="${DS_UPTERM_TTL_EXPIRY_TOKEN:-}"
  pid_file=$(_upterm_pid_file)
  owner_file=$(_upterm_known_hosts_owner_file)

  if ! _upterm_reconcile_snapshot_owner; then
    echo "ds: failed to reconcile Upterm snapshot ownership while stopping" >&2
    return 1
  fi
  if [[ ! -e "$owner_file" && ! -L "$owner_file" ]]; then
    echo "ds: not currently sharing"
    _upterm_unpush_share_info "$session"
    return 0
  fi
  if ! _upterm_read_snapshot_owner "$owner_file"; then
    echo "ds: live Upterm snapshot ownership has malformed process state; state retained" >&2
    return 1
  fi
  stop_phase="$_UPTERM_SNAPSHOT_PHASE"
  stop_pid="$_UPTERM_SNAPSHOT_PID"
  stop_identity="$_UPTERM_SNAPSHOT_IDENTITY"
  stop_token="$_UPTERM_SNAPSHOT_TOKEN"
  stop_snapshot="$(dirname "$owner_file")/$_UPTERM_SNAPSHOT_BASENAME"
  if [[ -n "$expected_token" ]] &&
    { [[ ! "$expected_token" =~ ^[[:xdigit:]]{32}$ ]] ||
      [[ "$expected_token" != "$stop_token" ]]; }; then
    echo "ds: TTL expiry no longer owns the active Upterm lifecycle; state retained" >&2
    return 1
  fi
  if [[ "$stop_phase" == starting ]]; then
    echo "ds: another Upterm start is still in progress; its trust state was not removed" >&2
    return 1
  fi
  if [[ "$expiry_token" != "$stop_token" ]] &&
    ! _upterm_cancel_ttl_watcher "$stop_token"; then
    echo "ds: failed to cancel the exact Upterm TTL watcher; state retained" >&2
    return 1
  fi
  if [[ "$stop_phase" == active ]]; then
    if ! _upterm_write_snapshot_owner replace stopping "$stop_pid" \
      "$stop_token" "$stop_snapshot" "$stop_identity"; then
      echo "ds: failed to reserve exact Upterm state for stopping" >&2
      return 1
    fi
  fi

  # Re-read exact ownership at the last boundary before publishing the
  # token-scoped stop request. Only the persistent supervisor signals its own
  # still-recorded child, so a reused PID or process group is never targeted.
  if ! _upterm_read_snapshot_owner "$owner_file" ||
    [[ "$_UPTERM_SNAPSHOT_PHASE" != stopping ||
      "$_UPTERM_SNAPSHOT_TOKEN" != "$stop_token" ||
      "$_UPTERM_SNAPSHOT_PID" != "$stop_pid" ||
      "$_UPTERM_SNAPSHOT_IDENTITY" != "$stop_identity" ]]; then
    echo "ds: Upterm ownership changed while stopping; state retained" >&2
    return 1
  fi
  if ! _upterm_request_supervisor_stop \
    "$stop_pid" "$stop_identity" "$stop_token"; then
    echo "ds: failed to stop the exact Upterm supervisor; state retained" >&2
    return 1
  fi
  echo "ds: stopped sharing"

  if ! _upterm_cleanup_lifecycle_files "$stop_token"; then
    echo "ds: failed to remove Upterm process state while stopping" >&2
    return 1
  fi
  if ! _upterm_cleanup_known_hosts_snapshot "$stop_token" "$stop_snapshot"; then
    cleanup_status=1
  fi
  _upterm_unpush_share_info "$session"
  return "$cleanup_status"
}

_share_stop() {
  local operation_token="" stop_status acquire_status
  if _upterm_acquire_operation_lock operation_token; then
    acquire_status=0
  else
    acquire_status=$?
  fi
  if ((acquire_status != 0)); then
    ((acquire_status == 2)) &&
      echo "ds: another Upterm start is still in progress; state retained" >&2
    return 1
  fi
  if _upterm_share_stop_locked "$@"; then
    stop_status=0
  else
    stop_status=$?
  fi
  _upterm_release_operation_lock "$operation_token" || return 1
  return "$stop_status"
}
