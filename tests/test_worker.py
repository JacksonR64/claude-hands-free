from pathlib import Path
import os
import plistlib
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).parents[1]


class WorkerLaunchAgentTests(unittest.TestCase):
    def test_print_renders_valid_plist_for_awkward_home(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory) / 'a&b|c <d>'
            env = {**os.environ, 'HOME': str(home)}
            output = subprocess.run(['bash', ROOT / 'scripts/install-worker.sh', '--print'],
                                    env=env, check=True, capture_output=True).stdout
            plist = plistlib.loads(output)
            self.assertEqual(plist['ProgramArguments'][1], str(ROOT / 'scripts/start-worker.sh'))
            self.assertEqual(plist['StandardOutPath'], f'{home}/Library/Logs/claude-hands-free-worker.log')
            self.assertTrue(plist['AbandonProcessGroup'])
            self.assertFalse((home / 'Library').exists())

    def test_worker_files_carry_no_personal_paths(self):
        for name in ['start-worker.sh', 'install-worker.sh', 'uninstall-worker.sh',
                     'worker-brief.md', 'worker.plist.template']:
            self.assertNotIn('/Users/', (ROOT / 'scripts' / name).read_text(), name)


if __name__ == '__main__':
    unittest.main()
