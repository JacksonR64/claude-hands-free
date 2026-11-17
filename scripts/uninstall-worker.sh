#!/bin/bash
# Removes the worker LaunchAgent. --stop also ends the running worker's tmux session.
set -u
LABEL="${HF_WORKER_LABEL:-local.$(id -un).claude-hands-free-worker}"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" && echo "removed $LABEL"
if [ "${1:-}" = --stop ]; then
  CONF="${HF_WORKER_CONFIG:-$HOME/.config/claude-hands-free/worker.env}"
  [ -f "$CONF" ] && . "$CONF"
  T="${HF_WORKER_TMUX:-hands-free}"
  PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" tmux kill-session -t "=$T" 2>/dev/null && echo "stopped tmux session $T"
fi
exit 0
