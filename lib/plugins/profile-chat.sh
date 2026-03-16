# ds profile: chat — single window running a chatbot (DS_CHAT_CHATBOT)
_profile_chat() {
    local session="$1"
    local chatbot="${DS_CHAT_CHATBOT:-}"
    local dir="${DS_CHAT_DIR:-$HOME}"
    tmux send-keys -t "$session:1" "cd '$dir'" C-m
    if [[ -n "$chatbot" ]]; then
        tmux rename-window -t "$session:1" "$chatbot"
        tmux send-keys -t "$session:1" "$chatbot" C-m
    fi
}
