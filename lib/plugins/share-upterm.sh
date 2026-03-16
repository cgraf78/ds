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
# Config: ~/.config/ds/share-upterm.conf (key=value, env vars override config)
#   server             upterm server host:port (default: uptermd.upterm.dev:22)
#   known-hosts        known_hosts file for server verification
#   private-key        SSH private key for upterm (auto-detected if unset)
#   github-user        GitHub user for ACL
#   authorized-keys    authorized_keys file for SSH-key-based ACL
#   push               user@host target for pushing share info via SCP
#
# Env vars (all optional, override config):
#   DS_UPTERM_HOST           maps to server
#   DS_UPTERM_PRIVATE_KEY    maps to private-key
#   DS_UPTERM_KNOWN_HOSTS    maps to known-hosts
#   DS_UPTERM_GITHUB_USER    maps to github-user
#   DS_UPTERM_AUTHORIZED_KEYS maps to authorized-keys
#   DS_UPTERM_PUSH           maps to push
#   DS_UPTERM_PID_FILE       override PID file path

DS_UPTERM_HOST="${DS_UPTERM_HOST:-}"
DS_UPTERM_PRIVATE_KEY="${DS_UPTERM_PRIVATE_KEY:-}"
DS_UPTERM_KNOWN_HOSTS="${DS_UPTERM_KNOWN_HOSTS:-}"
DS_UPTERM_GITHUB_USER="${DS_UPTERM_GITHUB_USER:-}"
DS_UPTERM_AUTHORIZED_KEYS="${DS_UPTERM_AUTHORIZED_KEYS:-}"
DS_UPTERM_PID_FILE="${DS_UPTERM_PID_FILE:-}"
DS_UPTERM_PUSH="${DS_UPTERM_PUSH:-}"

_UPTERM_REMOTE_STATE_DIR=".local/state/ds"

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

# Push share info to a remote host via SCP.
_upterm_push_share_info() {
    local session="$1"
    [[ -n "$DS_UPTERM_PUSH" ]] || return 0
    [[ -n "${DS_SHARE_INFO_FILE:-}" && -f "$DS_SHARE_INFO_FILE" ]] || return 0

    local src_host
    src_host=$(hostname -s 2>/dev/null || hostname)
    local remote_file="ds.upterm-${src_host}-${session}.share"
    local escaped_dir
    escaped_dir=$(printf '%q' "$_UPTERM_REMOTE_STATE_DIR")

    ssh -o BatchMode=yes -o ConnectTimeout=5 "$DS_UPTERM_PUSH" "mkdir -p ~/$escaped_dir" 2>/dev/null || {
        echo "ds: failed to create remote state dir on $DS_UPTERM_PUSH" >&2
        return 1
    }
    scp -o BatchMode=yes -o ConnectTimeout=5 -q \
        "$DS_SHARE_INFO_FILE" "$DS_UPTERM_PUSH:~/$_UPTERM_REMOTE_STATE_DIR/$remote_file" 2>/dev/null || {
        echo "ds: failed to push share info to $DS_UPTERM_PUSH" >&2
        return 1
    }
    echo "ds: pushed share info to $DS_UPTERM_PUSH:~/$_UPTERM_REMOTE_STATE_DIR/$remote_file"
}

_upterm_unpush_share_info() {
    local session="$1"
    [[ -n "$DS_UPTERM_PUSH" ]] || return 0
    local src_host
    src_host=$(hostname -s 2>/dev/null || hostname)
    local escaped_file
    escaped_file=$(printf '%q' "$_UPTERM_REMOTE_STATE_DIR/ds.upterm-${src_host}-${session}.share")
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$DS_UPTERM_PUSH" "rm -f ~/$escaped_file" 2>/dev/null || true
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
            server)          [[ -z "$DS_UPTERM_HOST" ]]            && DS_UPTERM_HOST="$val" ;;
            known-hosts)     [[ -z "$DS_UPTERM_KNOWN_HOSTS" ]]     && DS_UPTERM_KNOWN_HOSTS="${val/#\~/$HOME}" ;;
            private-key)     [[ -z "$DS_UPTERM_PRIVATE_KEY" ]]     && DS_UPTERM_PRIVATE_KEY="${val/#\~/$HOME}" ;;
            github-user)     [[ -z "$DS_UPTERM_GITHUB_USER" ]]     && DS_UPTERM_GITHUB_USER="$val" ;;
            authorized-keys) [[ -z "$DS_UPTERM_AUTHORIZED_KEYS" ]] && DS_UPTERM_AUTHORIZED_KEYS="${val/#\~/$HOME}" ;;
            push)            [[ -z "$DS_UPTERM_PUSH" ]]            && DS_UPTERM_PUSH="$val" ;;
        esac
    done < "$conf" || true
}

_share_running() {
    local pid_file
    pid_file=$(_upterm_pid_file)
    [[ -f "$pid_file" ]] || return 1
    local pid
    pid=$(cat "$pid_file" 2>/dev/null || true)
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null
}

_share_current_session() {
    local f
    f=$(_upterm_session_file)
    [[ -f "$f" ]] && cat "$f"
}

_share_info() {
    _show_share_info
}

_share_start() {
    local session="$1"

    if _share_running; then
        local current_session
        current_session=$(_share_current_session)
        if [[ "$current_session" == "$session" ]]; then
            echo "ds: already sharing session '$session'"
            _share_info
            return 0
        else
            echo "ds: already sharing session '${current_session:-unknown}' — run 'ds --unshare' first" >&2
            return 1
        fi
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
            echo "ds: aborted — set github-user or authorized-keys in ~/.config/ds/share-upterm.conf" >&2
            return 1
        fi
    fi

    # Apply default server after config has been loaded
    : "${DS_UPTERM_HOST:=uptermd.upterm.dev:22}"

    local host_args=(--accept --server "ssh://$DS_UPTERM_HOST" --private-key "$key")
    if [[ -n "${DS_UPTERM_KNOWN_HOSTS:-}" ]]; then
        host_args+=(--known-hosts "$DS_UPTERM_KNOWN_HOSTS")
    elif [[ "$DS_UPTERM_HOST" != "uptermd.upterm.dev:22" ]]; then
        # Non-default server without host key verification — MITM risk
        echo "" >&2
        echo "  WARNING: Connecting to '$DS_UPTERM_HOST' without host key" >&2
        echo "  verification. Set known-hosts in share-upterm.conf to fix." >&2
        echo "" >&2
        read -r -p "  Skip host key check? [y/N] " answer </dev/tty
        if [[ "$answer" != [yY] ]]; then
            echo "ds: aborted — set known-hosts in ~/.config/ds/share-upterm.conf" >&2
            return 1
        fi
        host_args+=(--skip-host-key-check)
    else
        host_args+=(--skip-host-key-check)
    fi
    [[ -n "${DS_UPTERM_GITHUB_USER:-}" ]] && host_args+=(--github-user "$DS_UPTERM_GITHUB_USER")
    [[ -n "${DS_UPTERM_AUTHORIZED_KEYS:-}" ]] && host_args+=(--authorized-keys "$DS_UPTERM_AUTHORIZED_KEYS")

    _ensure_state_dir

    local pid_file admin_file log_file session_file
    pid_file=$(_upterm_pid_file)
    admin_file=$(_upterm_admin_file)
    log_file=$(_upterm_log_file)
    session_file=$(_upterm_session_file)
    rm -f "$admin_file" "$log_file"

    local old_umask
    old_umask=$(umask)
    umask 077
    : > "$log_file"
    echo "$session" > "$session_file"
    umask "$old_umask"

    # Fully detach upterm from the controlling terminal.
    local hosted_cmd force_cmd
    local escaped_admin_file
    escaped_admin_file=$(printf '%q' "$admin_file")
    hosted_cmd="umask 077; echo \"\$UPTERM_ADMIN_SOCKET\" > $escaped_admin_file; while true; do sleep 86400; done"
    local escaped_session
    escaped_session=$(printf '%q' "$session")
    force_cmd="bash -lc \"tmux attach -t =$escaped_session || tmux attach -t $escaped_session\""

    local upterm_pid
    if command -v setsid >/dev/null 2>&1 && ! _upterm_is_wsl; then
        setsid env -u TMUX upterm host \
            "${host_args[@]}" \
            --force-command "$force_cmd" \
            -- bash -c "$hosted_cmd" \
            </dev/null >>"$log_file" 2>&1 &
        upterm_pid=$!
    else
        nohup env -u TMUX upterm host \
            "${host_args[@]}" \
            --force-command "$force_cmd" \
            -- bash -c "$hosted_cmd" \
            </dev/null >>"$log_file" 2>&1 &
        upterm_pid=$!
    fi

    if [[ -n "${upterm_pid:-}" ]]; then
        umask 077
        echo "$upterm_pid" > "$pid_file"
        umask "$old_umask"
    fi

    # Wait for admin socket, then collect share info.
    local admin_sock content
    for _ in $(seq 1 30); do
        if [[ -s "$admin_file" ]]; then
            admin_sock=$(cat "$admin_file")
            break
        fi
        sleep 0.5
    done

    if [[ -z "${admin_sock:-}" ]]; then
        if content=$(_upterm_read_info_from_log "$log_file"); then
            _write_share_info "$content"
            printf '%s\n' "$content"
            _upterm_push_share_info "$session"
            return 0
        fi
        echo "ds: timed out waiting for upterm share info (admin socket unavailable; log: $log_file)" >&2
        return 1
    fi

    for _ in $(seq 1 30); do
        content=$(upterm session current --admin-socket "$admin_sock" 2>/dev/null || true)
        if [[ -n "$content" ]]; then
            content=$(_upterm_normalize_info "$content")
            _write_share_info "$content"
            printf '%s\n' "$content"
            _upterm_push_share_info "$session"
            return 0
        fi
        sleep 0.5
    done

    if content=$(_upterm_read_info_from_log "$log_file"); then
        _write_share_info "$content"
        printf '%s\n' "$content"
        _upterm_push_share_info "$session"
        return 0
    fi

    echo "ds: upterm started but couldn't retrieve share info (log: $log_file)" >&2
    return 1
}

_share_stop() {
    local session="$1"
    local pid_file
    pid_file=$(_upterm_pid_file)

    if _share_running; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null || true)
        if [[ "$pid" =~ ^[0-9]+$ ]]; then
            kill "$pid" 2>/dev/null || true
            kill -TERM -"$pid" 2>/dev/null || true
        fi
        echo "ds: stopped sharing"
    else
        echo "ds: not currently sharing"
    fi
    rm -f "$pid_file" "$DS_SHARE_INFO_FILE" \
        "$(_upterm_admin_file)" "$(_upterm_session_file)" "$(_upterm_log_file)"
    _upterm_unpush_share_info "$session"
}
