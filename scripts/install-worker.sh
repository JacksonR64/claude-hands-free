#!/bin/bash
# Installs a per-user LaunchAgent that runs scripts/start-worker.sh at login, and starts the worker now.
# --print writes the filled-in plist to stdout and changes nothing. Undo with scripts/uninstall-worker.sh.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="${HF_WORKER_LABEL:-local.$(id -un).claude-hands-free-worker}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="${HF_WORKER_LOG:-$HOME/Library/Logs/claude-hands-free-worker.log}"
esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/[|\\&]/\\&/g'; }
render() {
  sed -e "s|__LABEL__|$(esc "$LABEL")|" -e "s|__SCRIPT__|$(esc "$REPO/scripts/start-worker.sh")|" \
      -e "s|__LOG__|$(esc "$LOG")|g" "$REPO/scripts/worker.plist.template"
}
if [ "${1:-}" = --print ]; then render; exit 0; fi
mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
render > "$PLIST"
plutil -lint "$PLIST" >/dev/null
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed $PLIST (log: $LOG)"
