# ds profile: dev — chatbot in top pane (if DS_DEV_CHATBOT set), bash below, separate bash window
_profile_dev() {
    local session="$1"
    local chatbot="${DS_DEV_CHATBOT:-}"
    local dir="${DS_DEV_DIR:-$HOME}"
    tmux send-keys -t "$session:1" "cd '$dir'" C-m
    if [[ -n "$chatbot" ]]; then
        tmux rename-window -t "$session:1" "$chatbot"
        tmux send-keys -t "$session:1" "$chatbot" C-m
    fi
    tmux split-window -v -t "$session:1" -c "$dir"
    tmux new-window -t "$session" -n bash -c "$dir"
    tmux select-window -t "$session:1"
}
