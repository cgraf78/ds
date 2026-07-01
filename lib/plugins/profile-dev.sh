# shellcheck shell=bash
# ds profile: dev — chatbot in top pane (if DS_DEV_CHATBOT set), login shell
# below, separate login shell window
_profile_dev() {
  local session="$1"
  local chatbot="${DS_DEV_CHATBOT:-}"
  local dir="${DS_DEV_DIR:-$HOME}"
  local shell_name

  shell_name="$(_shell_name)"

  # %q-quote so a dir with spaces/quotes/specials produces a valid `cd`.
  tmux send-keys -t "$session:1" "cd $(printf '%q' "$dir")" C-m
  if [[ -n "$chatbot" ]]; then
    tmux rename-window -t "$session:1" "$chatbot"
    tmux send-keys -t "$session:1" "$chatbot" C-m
  fi
  tmux split-window -v -t "$session:1" -c "$dir" "$(_shell_login_cmd)"
  tmux new-window -t "$session" -n "$shell_name" -c "$dir" "$(_shell_login_cmd)"
  tmux select-window -t "$session:1"
}
