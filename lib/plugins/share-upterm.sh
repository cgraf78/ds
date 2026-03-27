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
#   proxy-session      tmux session name to share instead of the real session
#                      (default: _share). A dedicated background session is
#                      created and shared so connecting clients get a shell
#                      without mirroring into the user's active session.
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

_upterm_ttl_pid_file() {
    echo "$(_state_file_prefix).upterm.ttl.pid"
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
            proxy-session)   [[ -z "$DS_UPTERM_PROXY_SESSION" ]]   && DS_UPTERM_PROXY_SESSION="$val" ;;
            share-ttl)       [[ -z "$DS_UPTERM_SHARE_TTL" ]]       && DS_UPTERM_SHARE_TTL="$val" ;;
        esac
    done < "$conf" || true
}

# Cancel any running TTL expiry watcher.
_upterm_cancel_ttl_watcher() {
    local ttl_pid_file
    ttl_pid_file=$(_upterm_ttl_pid_file)
    if [[ -f "$ttl_pid_file" ]]; then
        local pid
        pid=$(cat "$ttl_pid_file" 2>/dev/null || true)
        if [[ "$pid" =~ ^[0-9]+$ ]]; then
            # SIGTERM the process group (kills sleep child too); fall back to
            # killing just the PID if the group signal fails.
            kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
        fi
        rm -f "$ttl_pid_file"
    fi
}

# Spawn a background watcher that calls `ds --unshare` after $ttl seconds.
# Stores the watcher's PID in the TTL pid file for later cancellation.
_upterm_start_ttl_watcher() {
    local ttl="$1"
    local session="$2"
    local ttl_pid_file
    ttl_pid_file=$(_upterm_ttl_pid_file)

    _upterm_cancel_ttl_watcher

    # Resolve the ds binary path before forking.
    local ds_bin
    ds_bin=$(command -v ds 2>/dev/null || true)
    [[ -z "$ds_bin" ]] && ds_bin="ds"

    local esc_bin esc_session
    esc_bin=$(printf '%q' "$ds_bin")
    esc_session=$(printf '%q' "$session")

    # setsid gives the subshell its own process group so killing the group
    # also kills the sleep child. Fall back to a plain subshell if unavailable.
    if command -v setsid >/dev/null 2>&1; then
        setsid bash -c "sleep ${ttl} && ${esc_bin} --unshare ${esc_session}" >/dev/null 2>&1 &
    else
        ( sleep "$ttl" && "$ds_bin" --unshare "$session" ) >/dev/null 2>&1 &
    fi
    local watcher_pid=$!
    local old_umask
    old_umask=$(umask)
    umask 077
    echo "$watcher_pid" > "$ttl_pid_file"
    umask "$old_umask"
}

# Start TTL watcher if share-ttl > 0; print expiry message. No-op if TTL=0.
_upterm_maybe_start_ttl_watcher() {
    local session="$1"
    local ttl="${DS_UPTERM_SHARE_TTL:-3600}"
    if [[ "$ttl" =~ ^[0-9]+$ && "$ttl" -gt 0 ]]; then
        _upterm_start_ttl_watcher "$ttl" "$session"
        echo "ds: share will auto-expire in ${ttl}s (run 'ds --share' to reset)"
    fi
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
            # Reset the TTL timer if configured.
            local ttl="${DS_UPTERM_SHARE_TTL:-3600}"
            if [[ "$ttl" =~ ^[0-9]+$ && "$ttl" -gt 0 ]]; then
                _upterm_start_ttl_watcher "$ttl" "$session"
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

    # Pre-flight host key check while we still have a TTY. upterm is launched
    # fully detached (</dev/null), so any SSH host-key prompt sent there hangs
    # forever with no way for the user to respond. Catch mismatches now.
    #
    # Uses ssh-keyscan to compare fingerprints rather than an SSH login attempt,
    # since uptermd may present a host certificate (@cert-authority trust model)
    # which OpenSSH BatchMode probes cannot validate.
    if [[ -n "${DS_UPTERM_KNOWN_HOSTS:-}" ]]; then
        local _pf_host _pf_port
        _pf_host="${DS_UPTERM_HOST%%:*}"
        _pf_port="${DS_UPTERM_HOST##*:}"
        [[ "$_pf_port" == "$_pf_host" ]] && _pf_port=22

        # Fetch the server's current key fingerprint.
        local _live_fp
        _live_fp=$(ssh-keyscan -p "$_pf_port" "$_pf_host" 2>/dev/null \
            | grep -v '^#' | ssh-keygen -lf - 2>/dev/null | awk '{print $2}' | head -1)

        # Extract stored key fingerprint (strip @cert-authority and host field).
        local _stored_fp
        _stored_fp=$(grep -v '^#' "$DS_UPTERM_KNOWN_HOSTS" 2>/dev/null \
            | sed 's/^@cert-authority[[:space:]]*//' \
            | awk '{print $2, $3}' \
            | ssh-keygen -lf - 2>/dev/null | awk '{print $2}' | head -1)

        if [[ -z "$_live_fp" ]]; then
            echo "ds: warning: could not reach $_pf_host:$_pf_port to verify host key" >&2
        elif [[ "$_live_fp" != "$_stored_fp" ]]; then
            echo "" >&2
            echo "  The upterm server host key has changed or is not in known-hosts." >&2
            echo "  known-hosts file: $DS_UPTERM_KNOWN_HOSTS" >&2
            echo "  current fingerprint:  $_live_fp" >&2
            echo "  stored fingerprint:   ${_stored_fp:-(none)}" >&2
            echo "" >&2
            read -r -p "  Update known-hosts automatically and continue? [y/N] " answer </dev/tty
            if [[ "$answer" == [yY] ]]; then
                local new_keys
                new_keys=$(ssh-keyscan -p "$_pf_port" "$_pf_host" 2>/dev/null | grep -v '^#')
                if [[ -z "$new_keys" ]]; then
                    echo "ds: failed to scan host keys from $_pf_host:$_pf_port" >&2
                    return 1
                fi
                # Strip old entries for this host:port (escape brackets for grep).
                local _esc_host
                _esc_host=$(printf '%s' "$_pf_host" | sed 's/[.[\*^$]/\\&/g')
                local tmp_kh
                tmp_kh=$(mktemp)
                grep -Ev "(^|[[:space:]])\[?${_esc_host}\]?(:${_pf_port})?" \
                    "$DS_UPTERM_KNOWN_HOSTS" > "$tmp_kh" 2>/dev/null || true
                # Append new entries with @cert-authority prefix.
                while IFS= read -r line; do
                    [[ -z "$line" ]] && continue
                    printf '@cert-authority %s\n' "$line"
                done <<< "$new_keys" >> "$tmp_kh"
                mv "$tmp_kh" "$DS_UPTERM_KNOWN_HOSTS"
                echo "ds: known-hosts updated for $_pf_host:$_pf_port"
            else
                echo "ds: aborted — update $DS_UPTERM_KNOWN_HOSTS manually" >&2
                return 1
            fi
        fi
    fi

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

    # Create (or reuse) a dedicated proxy tmux session to share instead of the
    # user's real session. Connecting clients land in this background session
    # and can use tmux commands (capture-pane, send-keys) to interact with the
    # real session without mirroring into it or shrinking its pane.
    local proxy_session="${DS_UPTERM_PROXY_SESSION:-_share}"
    if ! tmux has-session -t "=$proxy_session" 2>/dev/null; then
        tmux new-session -d -s "$proxy_session"
    fi

    # Fully detach upterm from the controlling terminal.
    local hosted_cmd force_cmd
    local escaped_admin_file escaped_proxy
    escaped_admin_file=$(printf '%q' "$admin_file")
    escaped_proxy=$(printf '%q' "$proxy_session")
    hosted_cmd="umask 077; echo \"\$UPTERM_ADMIN_SOCKET\" > $escaped_admin_file; while true; do sleep 86400; done"
    # Force-command attaches to the proxy session, keeping the user's real
    # session untouched. The proxy session is a plain background shell.
    # Fall back to bash -l if the proxy session has been killed externally.
    force_cmd="bash -c 'tmux attach -t =$escaped_proxy || bash -l'"

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
            _upterm_maybe_start_ttl_watcher "$session"
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
            _upterm_maybe_start_ttl_watcher "$session"
            return 0
        fi
        sleep 0.5
    done

    if content=$(_upterm_read_info_from_log "$log_file"); then
        _write_share_info "$content"
        printf '%s\n' "$content"
        _upterm_push_share_info "$session"
        _upterm_maybe_start_ttl_watcher "$session"
        return 0
    fi

    echo "ds: upterm started but couldn't retrieve share info (log: $log_file)" >&2
    return 1
}

_share_stop() {
    local session="$1"
    _share_load_config
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
    _upterm_cancel_ttl_watcher
    _upterm_unpush_share_info "$session"
    # Kill the proxy session if it exists.
    local proxy_session="${DS_UPTERM_PROXY_SESSION:-_share}"
    if tmux has-session -t "=$proxy_session" 2>/dev/null; then
        tmux kill-session -t "=$proxy_session"
    fi
}
