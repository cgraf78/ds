# shellcheck shell=bash
# ds connect method: autossh — persistent SSH with auto-reconnect
_connect_autossh() { exec autossh -M0 "$1" -t "$2"; }
