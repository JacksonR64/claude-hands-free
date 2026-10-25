#!/usr/bin/env python3
"""Find a mod-capable local Claude Code without changing the user's CLI."""
from pathlib import Path
import re
import shutil
import subprocess
import sys

candidates = list((Path.home() / 'Library/Application Support/Claude/claude-code').glob('*/**/claude.app/Contents/MacOS/claude'))
cli = shutil.which('claude')
if cli:
    candidates.append(Path(cli))
valid = []
for path in candidates:
    try:
        result = subprocess.run([str(path), '--version'], text=True, capture_output=True, timeout=10, check=True)
        match = re.search(r'(\d+)\.(\d+)\.(\d+)', result.stdout)
        if match:
            version = tuple(map(int, match.groups()))
            if version >= (2, 1, 308):
                valid.append((version, str(path)))
    except (OSError, subprocess.SubprocessError):
        pass
if not valid:
    sys.exit('Claude Code 2.1.308 or later is required. No installed matching host was found.')
print(max(valid)[1])
