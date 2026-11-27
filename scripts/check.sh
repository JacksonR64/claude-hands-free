#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
HOST="$(python3 scripts/host.py)"
python3 -m unittest discover -s tests -p 'test_*.py' -v
"$HOST" plugin validate mod
"$HOST" plugin test mod
READ_ALOUD_CACHE="$PWD/work/build" sh mod/bin/build.sh
swiftc -D TESTING mod/bin/VoiceCore.swift mod/bin/Threads.swift mod/bin/bar.swift tests/PanelTests.swift -o work/panel-tests
./work/panel-tests --demo
