# shellcheck shell=bash
# ds connect method: et — persistent eternal terminal connection
_connect_et() {
    local host="$1" session="$3"
    # Seed attach-next so the shell snippet (ds init bash) execs into the
    # right session when the ET connection opens an interactive shell.
    ssh "$host" "mkdir -p ~/.local/state/ds && cat > ~/.local/state/ds/attach-next" <<< "$session"
    exec et "$host"
}
