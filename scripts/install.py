#!/usr/bin/env python3
"""Install locally with a restorable source/helper/settings snapshot. Never publishes."""
from datetime import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

PROJECT = Path(__file__).resolve().parents[1]
TARGET = Path.home() / '.claude/mods/read-aloud'
CACHE = Path.home() / '.cache/read-aloud'
SETTINGS = Path.home() / '.config/read-aloud/settings.json'
ARTIFACTS = ['read-aloud-bar', 'read-aloud-keys', 'ReadAloudListen.app', 'ReadAloudConversation.app']


def copy(source, target):
    if source.is_dir():
        shutil.copytree(source, target, dirs_exist_ok=True)
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)


def stop_helpers():
    for name in ['read-aloud-bar', 'read-aloud-listen']:
        subprocess.run(['pkill', '-x', name], check=False)


def restore(backup):
    stop_helpers()
    metadata = json.loads((backup / 'snapshot.json').read_text())
    for name in ARTIFACTS:
        destination = CACHE / name
        if destination.is_dir(): shutil.rmtree(destination)
        elif destination.exists(): destination.unlink()
        saved = backup / 'helpers' / name
        if saved.exists(): copy(saved, destination)
    if TARGET.exists(): shutil.rmtree(TARGET)
    if (backup / 'mod').exists(): copy(backup / 'mod', TARGET)
    if metadata['settingsExisted']:
        copy(backup / 'settings.json', SETTINGS)
    elif SETTINGS.exists():
        SETTINGS.unlink()
    print('Restored the previous mod and helpers. Reload the plugin in your Claude Code sessions.')


if len(sys.argv) > 1:
    if len(sys.argv) != 3 or sys.argv[1] != '--rollback':
        sys.exit('Usage: install.py [--rollback BACKUP_DIRECTORY]')
    restore(Path(sys.argv[2]).resolve())
    sys.exit(0)

# Build and validate before changing the installed source.
host = subprocess.check_output([sys.executable, str(PROJECT / 'scripts/host.py')], text=True).strip()
subprocess.run([host, 'plugin', 'validate', str(PROJECT / 'mod')], check=True)
env = dict(os.environ, READ_ALOUD_CACHE=str(PROJECT / 'work/build'))
subprocess.run(['sh', str(PROJECT / 'mod/bin/build.sh')], env=env, check=True)
backup = PROJECT / 'work/backups' / datetime.now().strftime('%Y%m%d-%H%M%S-%f')
backup.mkdir(parents=True, mode=0o700)
metadata = {'settingsExisted': SETTINGS.exists(), 'target': str(TARGET)}
if TARGET.exists(): copy(TARGET, backup / 'mod')
for name in ARTIFACTS:
    if (CACHE / name).exists(): copy(CACHE / name, backup / 'helpers' / name)
if SETTINGS.exists(): copy(SETTINGS, backup / 'settings.json')
(backup / 'snapshot.json').write_text(json.dumps(metadata))
try:
    stop_helpers()
    copy(PROJECT / 'mod', TARGET)
    for name in ARTIFACTS:
        copy(PROJECT / 'work/build' / name, CACHE / name)
    # Starting a new version must not silently turn its microphone on.
    settings = json.loads(SETTINGS.read_text()) if SETTINGS.exists() else {}
    settings['voice'] = False
    SETTINGS.parent.mkdir(parents=True, exist_ok=True)
    SETTINGS.write_text(json.dumps(settings))
    SETTINGS.chmod(0o600)
except Exception:
    restore(backup)
    raise
(PROJECT / 'work/last-backup.txt').write_text(str(backup))
print('Installed local MVP. Microphone is off.')
print('Backup:', backup)
print('Reload the plugin in existing Claude Code sessions, then enable the panel microphone.')
