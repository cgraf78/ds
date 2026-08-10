# shellcheck shell=bash
# Copy to ${XDG_CONFIG_HOME:-$HOME/.config}/ds/profile-workspace.sh.

# Build a small editor-and-shell workspace when ds creates a new session.
# ds invokes a profile only during initial session creation, so this function
# can describe the layout directly without probing or mutating existing tmux
# sessions. The session name is supplied by ds; callers may select the working
# directory without editing the example.
_profile_workspace() {
  local session="$1"
  local dir="${DS_WORKSPACE_DIR:-$HOME}"

  tmux rename-window -t "$session:1" editor
  # tmux send-keys receives shell source, so quote the directory as one Bash
  # word instead of relying on the caller's current directory or path shape.
  tmux send-keys -t "$session:1" "cd $(printf '%q' "$dir")" C-m
  tmux send-keys -t "$session:1" "nvim ." C-m
  tmux split-window -h -t "$session:1" -c "$dir"
  tmux new-window -d -t "$session" -n shell -c "$dir"
  tmux select-window -t "$session:1"
}
