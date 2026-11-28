#!/bin/sh
# Compile locally with Apple's tools. An alternate output directory is useful for checks.
set -eu
R="$(cd "$(dirname "$0")/.." && pwd)"
C="${READ_ALOUD_CACHE:-$HOME/.cache/read-aloud}"
mkdir -p "$C"
SWIFT_TARGET="$(uname -m)-apple-macosx14.0"
stale() { [ ! -e "$1" ] || [ "$2" -nt "$1" ]; }
if stale "$C/read-aloud-bar" "$R/bin/build.sh" || stale "$C/read-aloud-bar" "$R/bin/bar.swift" || stale "$C/read-aloud-bar" "$R/bin/VoiceCore.swift" || stale "$C/read-aloud-bar" "$R/bin/Threads.swift"; then
  swiftc -O -target "$SWIFT_TARGET" "$R/bin/VoiceCore.swift" "$R/bin/Threads.swift" "$R/bin/bar.swift" -o "$C/read-aloud-bar.new"
  mv "$C/read-aloud-bar.new" "$C/read-aloud-bar"
fi
if stale "$C/read-aloud-keys" "$R/bin/build.sh" || stale "$C/read-aloud-keys" "$R/keys.swift"; then
  swiftc -O -target "$SWIFT_TARGET" "$R/keys.swift" -o "$C/read-aloud-keys.new"
  mv "$C/read-aloud-keys.new" "$C/read-aloud-keys"
fi
A="$C/ReadAloudListen.app"
if stale "$A/Contents/MacOS/read-aloud-listen" "$R/bin/build.sh" || stale "$A/Contents/MacOS/read-aloud-listen" "$R/bin/listen.swift" || stale "$A/Contents/MacOS/read-aloud-listen" "$R/bin/VoiceCore.swift" || stale "$A/Contents/Info.plist" "$R/bin/listen-Info.plist"; then
  mkdir -p "$A/Contents/MacOS"
  swiftc -O -target "$SWIFT_TARGET" "$R/bin/VoiceCore.swift" "$R/bin/listen.swift" -o "$A/Contents/MacOS/read-aloud-listen.new"
  mv "$A/Contents/MacOS/read-aloud-listen.new" "$A/Contents/MacOS/read-aloud-listen"
  cp "$R/bin/listen-Info.plist" "$A/Contents/Info.plist"
  codesign --force --sign - "$A"
fi

# A separate sandbox process and directory cannot feed transcripts to the live helper.
L="$C/ReadAloudDemoListen.app"
if stale "$L/Contents/MacOS/read-aloud-demo-listen" "$A/Contents/MacOS/read-aloud-listen" || stale "$L/Contents/Info.plist" "$R/bin/listen-Info.plist"; then
  mkdir -p "$L/Contents/MacOS"
  cp "$A/Contents/MacOS/read-aloud-listen" "$L/Contents/MacOS/read-aloud-demo-listen"
  cp "$R/bin/listen-Info.plist" "$L/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.read-aloud.listen.demo' "$L/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable read-aloud-demo-listen' "$L/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleName Conversation Demo Microphone' "$L/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :NSSpeechRecognitionUsageDescription Recognise speech on this Mac for the offline conversation demo. No speech is sent to Claude.' "$L/Contents/Info.plist"
  codesign --force --sign - "$L"
fi

P="$C/ReadAloudConversation.app"
if stale "$P/Contents/Resources/ReadAloudListen.app/Contents/MacOS/read-aloud-listen" "$A/Contents/MacOS/read-aloud-listen" || stale "$P/Contents/MacOS/read-aloud-bar" "$C/read-aloud-bar" || stale "$P/Contents/Info.plist" "$R/bin/panel-Info.plist"; then
  mkdir -p "$P/Contents/MacOS"
  cp "$C/read-aloud-bar" "$P/Contents/MacOS/read-aloud-bar"
  cp "$R/bin/panel-Info.plist" "$P/Contents/Info.plist"
  mkdir -p "$P/Contents/Resources"
  rm -rf "$P/Contents/Resources/ReadAloudListen.app"
  cp -R "$A" "$P/Contents/Resources/"
  codesign --force --sign - "$P"
fi
D="$C/ReadAloudDemo.app"
if stale "$D/Contents/Resources/ReadAloudDemoListen.app/Contents/MacOS/read-aloud-demo-listen" "$L/Contents/MacOS/read-aloud-demo-listen" || stale "$D/Contents/MacOS/read-aloud-demo" "$C/read-aloud-bar" || stale "$D/Contents/Info.plist" "$R/bin/panel-Info.plist"; then
  mkdir -p "$D/Contents/MacOS"
  rm -f "$D/Contents/MacOS/read-aloud-bar"
  cp "$C/read-aloud-bar" "$D/Contents/MacOS/read-aloud-demo"
  cp "$R/bin/panel-Info.plist" "$D/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.read-aloud.conversation.demo' "$D/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable read-aloud-demo' "$D/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :LSUIElement false' "$D/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleName Claude Hands Free Demo' "$D/Contents/Info.plist"
  mkdir -p "$D/Contents/Resources"
  rm -rf "$D/Contents/Resources/ReadAloudDemoListen.app"
  cp -R "$L" "$D/Contents/Resources/"
  codesign --force --sign - "$D"
fi
# Types a spoken reply into a project thread in the Claude desktop app. It holds the Accessibility permission, which macOS
# ties to this exact build, so it is rebuilt only when its own source changes (not when this script does).
S="$C/ReadAloudSend.app"
if stale "$S/Contents/MacOS/read-aloud-send" "$R/bin/send.swift" || stale "$S/Contents/Info.plist" "$R/bin/send-Info.plist"; then
  mkdir -p "$S/Contents/MacOS"
  swiftc -O -target "$SWIFT_TARGET" "$R/bin/send.swift" -o "$S/Contents/MacOS/read-aloud-send.new"
  mv "$S/Contents/MacOS/read-aloud-send.new" "$S/Contents/MacOS/read-aloud-send"
  cp "$R/bin/send-Info.plist" "$S/Contents/Info.plist"
  codesign --force --sign - "$S"
fi
for app in "$A" "$L" "$P" "$D" "$S"; do
  codesign --verify --deep --strict "$app"
done
