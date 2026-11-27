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
ARTIFACTS = ['read-aloud-bar', 'read-aloud-keys', 'ReadAloudListen.app', 'ReadAloudConversation.app', 'ReadAloudDemo.app', 'ReadAloudDemoListen.app', 'ReadAloudSend.app']


def copy(source, target):
    if source.is_dir():
        shutil.copytree(source, target, dirs_exist_ok=True)
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)


def stop_helpers():
    for name in ['read-aloud-bar', 'read-aloud-demo', 'read-aloud-listen', 'read-aloud-demo-listen']:
        subprocess.run(['pkill', '-x', name], check=False)


def install_application_links(links):
    for link, destination in links.items():
        if os.path.lexists(link):
            continue
        link.parent.mkdir(parents=True, exist_ok=True)
        link.symlink_to(destination, target_is_directory=True)


def remove_application_links(links):
    for name, destination in links.items():
        link = Path(name)
        if link.is_symlink() and os.readlink(link) == str(destination):
            link.unlink()


def restore(backup):
    stop_helpers()
    metadata = json.loads((backup / 'snapshot.json').read_text())
    remove_application_links(metadata.get('applicationLinks', {}))
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


def main():
    if len(sys.argv) > 1:
        if len(sys.argv) != 3 or sys.argv[1] != '--rollback':
            sys.exit('Usage: install.py [--rollback BACKUP_DIRECTORY]')
        restore(Path(sys.argv[2]).resolve())
        return

    # Build and validate before changing the installed source.
    host = subprocess.check_output([sys.executable, str(PROJECT / 'scripts/host.py')], text=True).strip()
    subprocess.run([host, 'plugin', 'validate', str(PROJECT / 'mod')], check=True)
    env = dict(os.environ, READ_ALOUD_CACHE=str(PROJECT / 'work/build'))
    subprocess.run(['sh', str(PROJECT / 'mod/bin/build.sh')], env=env, check=True)
    backup = PROJECT / 'work/backups' / datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    backup.mkdir(parents=True, mode=0o700)
    applications = Path.home() / 'Applications'
    links = {applications / 'Claude Hands Free.app': CACHE / 'ReadAloudConversation.app',
             applications / 'Claude Hands Free Demo.app': CACHE / 'ReadAloudDemo.app'}
    metadata = {'settingsExisted': SETTINGS.exists(), 'target': str(TARGET),
                'applicationLinks': {str(k): str(v) for k, v in links.items() if not os.path.lexists(k)}}
    if TARGET.exists(): copy(TARGET, backup / 'mod')
    for name in ARTIFACTS:
        if (CACHE / name).exists(): copy(CACHE / name, backup / 'helpers' / name)
    if SETTINGS.exists(): copy(SETTINGS, backup / 'settings.json')
    (backup / 'snapshot.json').write_text(json.dumps(metadata))
    try:
        stop_helpers()
        copy(PROJECT / 'mod', TARGET)
        for name in ARTIFACTS:
            destination = CACHE / name
            # Replace generated bundles completely; old executables can invalidate signatures.
            if destination.is_dir(): shutil.rmtree(destination)
            copy(PROJECT / 'work/build' / name, destination)
        # Starting a new version must not silently turn its microphone on.
        settings = json.loads(SETTINGS.read_text()) if SETTINGS.exists() else {}
        settings['voice'] = False
        SETTINGS.parent.mkdir(parents=True, exist_ok=True)
        SETTINGS.write_text(json.dumps(settings))
        SETTINGS.chmod(0o600)
        install_application_links(links)
    except Exception:
        restore(backup)
        raise
    (PROJECT / 'work/last-backup.txt').write_text(str(backup))
    print('Installed local MVP. Microphone is off.')
    print('Backup:', backup)
    print('Open ~/Applications/Claude Hands Free.app. Reload the plugin in existing Claude Code sessions.')


if __name__ == '__main__':
    main()
