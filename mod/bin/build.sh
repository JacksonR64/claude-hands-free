#!/bin/sh
# Compile locally with Apple's tools. An alternate output directory is useful for checks.
set -eu
R="$(cd "$(dirname "$0")/.." && pwd)"
C="${READ_ALOUD_CACHE:-$HOME/.cache/read-aloud}"
mkdir -p "$C"
stale() { [ ! -e "$1" ] || [ "$2" -nt "$1" ]; }
if stale "$C/read-aloud-bar" "$R/bin/bar.swift" || stale "$C/read-aloud-bar" "$R/bin/VoiceCore.swift"; then
  swiftc -O "$R/bin/VoiceCore.swift" "$R/bin/bar.swift" -o "$C/read-aloud-bar.new"
  mv "$C/read-aloud-bar.new" "$C/read-aloud-bar"
fi
if stale "$C/read-aloud-keys" "$R/keys.swift"; then
  swiftc -O "$R/keys.swift" -o "$C/read-aloud-keys.new"
  mv "$C/read-aloud-keys.new" "$C/read-aloud-keys"
fi
A="$C/ReadAloudListen.app"
if stale "$A/Contents/MacOS/read-aloud-listen" "$R/bin/listen.swift" || stale "$A/Contents/Info.plist" "$R/bin/listen-Info.plist"; then
  mkdir -p "$A/Contents/MacOS"
  swiftc -O "$R/bin/listen.swift" -o "$A/Contents/MacOS/read-aloud-listen.new"
  mv "$A/Contents/MacOS/read-aloud-listen.new" "$A/Contents/MacOS/read-aloud-listen"
  cp "$R/bin/listen-Info.plist" "$A/Contents/Info.plist"
  codesign --force --sign - "$A"
fi

P="$C/ReadAloudConversation.app"
if stale "$P/Contents/MacOS/read-aloud-bar" "$C/read-aloud-bar" || stale "$P/Contents/Info.plist" "$R/bin/panel-Info.plist"; then
  mkdir -p "$P/Contents/MacOS"
  cp "$C/read-aloud-bar" "$P/Contents/MacOS/read-aloud-bar"
  cp "$R/bin/panel-Info.plist" "$P/Contents/Info.plist"
  codesign --force --sign - "$P"
fi
