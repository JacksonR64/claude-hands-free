#!/bin/sh
# Quit is persistent until the user explicitly opens the app again.
set -eu
R="$(cd "$(dirname "$0")/.." && pwd)"
C="${READ_ALOUD_CACHE:-$HOME/.cache/read-aloud}"
[ ! -e "$C/conversation/panel-disabled" ] || exit 0
pgrep -x read-aloud-bar >/dev/null && exit 0
sh "$R/bin/build.sh"
open -g -a "$C/ReadAloudConversation.app" --args --background
