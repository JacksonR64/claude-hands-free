from pathlib import Path
import subprocess
import sys
import unittest


HOOK = Path(__file__).parents[1] / 'handy/transcription'


def correct(text):
    result = subprocess.run([sys.executable, '-I', str(HOOK)], input=text.encode(), capture_output=True, timeout=5)
    return result.stdout.decode()


class HandyHookTests(unittest.TestCase):
    def test_macz_mishearings_become_macz(self):
        for heard in ['Max', 'max', 'Maxes', 'Max Z', 'Mac Z', 'Mack Z', 'Mac Zed', 'Max Zed', 'max zed', 'MacZ']:
            with self.subTest(heard=heard):
                self.assertEqual(correct(f'open {heard} now'), 'open macZ now')

    def test_bare_mac_is_unchanged(self):
        self.assertEqual(correct('my Mac and the mac mini'), 'my Mac and the mac mini')

    def test_whole_words_only(self):
        self.assertEqual(correct('maximum Maxwell'), 'maximum Maxwell')

    def test_possessive_keeps_suffix(self):
        self.assertEqual(correct("Max's fans"), "macZ's fans")

    def test_existing_pairs_still_apply(self):
        self.assertEqual(correct('clawed code on brainzy'), 'Claude Code on brainZ')


if __name__ == '__main__':
    unittest.main()
