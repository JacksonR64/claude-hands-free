from pathlib import Path
import importlib.util
import tempfile
import unittest


spec = importlib.util.spec_from_file_location('installer', Path(__file__).parents[1] / 'scripts/install.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class ApplicationLinkTests(unittest.TestCase):
    def test_install_and_rollback_only_owned_links(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / 'Applications' / 'Conversation.app'
            destination = root / 'cache' / 'Conversation.app'
            links = {app: destination}
            installer.install_application_links(links)
            self.assertEqual(app.readlink(), destination)
            installer.install_application_links(links)
            installer.remove_application_links({str(app): str(destination)})
            self.assertFalse(app.is_symlink())
            app.write_text('an unrelated application')
            installer.install_application_links(links)
            installer.remove_application_links({str(app): str(destination)})
            self.assertEqual(app.read_text(), 'an unrelated application')

    def test_rollback_preserves_replaced_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            link = Path(directory) / 'Conversation.app'
            link.symlink_to('/different/application')
            installer.remove_application_links({str(link): '/original/application'})
            self.assertEqual(str(link.readlink()), '/different/application')
