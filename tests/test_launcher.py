from pathlib import Path
import os
import subprocess
import tempfile
import unittest


LAUNCHER = Path(__file__).parents[1] / 'mod/bin/launch-panel.sh'


class LauncherTests(unittest.TestCase):
    def test_quit_marker_blocks_repeated_background_starts(self):
        with tempfile.TemporaryDirectory() as temporary:
            cache = Path(temporary)
            (cache / 'conversation').mkdir()
            marker = cache / 'conversation/panel-disabled'
            marker.touch()
            env = dict(os.environ, READ_ALOUD_CACHE=temporary, PATH='/usr/bin:/bin')
            for _ in range(3):
                result = subprocess.run(['sh', str(LAUNCHER)], env=env, capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 0)
            self.assertTrue(marker.exists())
            self.assertFalse((cache / 'ReadAloudConversation.app').exists())

    def test_running_panel_is_not_reopened_or_rebuilt(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stub = root / 'pgrep'
            stub.write_text('#!/bin/sh\nexit 0\n')
            stub.chmod(0o755)
            env = dict(os.environ, READ_ALOUD_CACHE=str(root / 'cache'), PATH=temporary + ':/usr/bin:/bin')
            result = subprocess.run(['sh', str(LAUNCHER)], env=env, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0)
            self.assertFalse((root / 'cache').exists())


if __name__ == '__main__':
    unittest.main()
