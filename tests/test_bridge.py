import importlib.util
import json
from pathlib import Path
import tempfile
import time
import unittest

spec = importlib.util.spec_from_file_location("bridge", Path(__file__).parents[1] / "mod/bin/bridge.py")
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.now = time.time() * 1000

    def tearDown(self):
        self.temp.cleanup()

    def command(self, **overrides):
        command = dict(id="c-1", session="printers", instance="instance-1", ts=self.now, verb="reply", text="Hello")
        command.update(overrides)
        bridge.atomic(self.root / f"cmd-printers-{command['id']}.json", command)
        return command

    def test_exact_session_and_instance_delivery_once(self):
        expected = self.command()
        self.assertEqual(bridge.drain(self.root, "other", "instance-1", self.now), [])
        self.assertEqual(bridge.drain(self.root, "printers", "instance-1", self.now), [expected])
        self.assertEqual(bridge.drain(self.root, "printers", "instance-1", self.now), [])

    def test_expired_or_reloaded_session_never_gets_message(self):
        self.command(instance="old-instance")
        self.assertEqual(bridge.drain(self.root, "printers", "instance-1", self.now), [])
        self.assertEqual(bridge.read(self.root / "ack-c-1.json")["status"], "failed")
        self.command(ts=self.now - 30001)
        self.assertEqual(bridge.drain(self.root, "printers", "instance-1", self.now), [])

    def test_commands_keep_time_order_instead_of_random_uuid_order(self):
        self.command(id="z-first", verb="stop", ts=self.now - 1)
        self.command(id="a-second", verb="read", ts=self.now)
        commands = bridge.drain(self.root, "printers", "instance-1", self.now)
        self.assertEqual([command["verb"] for command in commands], ["stop", "read"])

    def test_unknown_commands_and_oversize_text_are_rejected(self):
        self.command(verb="run-shell")
        self.assertEqual(bridge.drain(self.root, "printers", "instance-1", self.now), [])
        self.command(text="x" * 16001)
        self.assertEqual(bridge.drain(self.root, "printers", "instance-1", self.now), [])

    def test_answers_bind_to_request_and_instance(self):
        answer = dict(session="printers", instance="instance-1", request="q-1", text="approve action", ts=self.now)
        bridge.atomic(self.root / "answer-q-1.json", answer)
        self.assertEqual(bridge.wait_for_answer(self.root, "printers", "instance-1", "q-1", 0.2), answer)
        self.assertEqual(bridge.read(self.root / "ack-q-1.json")["status"], "answered")
        bridge.atomic(self.root / "answer-q-1.json", dict(answer, instance="old-instance"))
        self.assertIn("error", bridge.wait_for_answer(self.root, "printers", "instance-1", "q-1", 0.1))

    def test_stale_answers_cannot_approve_later_request(self):
        bridge.atomic(self.root / "answer-q-1.json", dict(session="printers", instance="instance-1", request="q-1", text="approve action", ts=self.now - 31000))
        self.assertIn("error", bridge.wait_for_answer(self.root, "printers", "instance-1", "q-1", 0.1))

    def test_identifiers_cannot_escape_private_directory(self):
        for invalid in ["../other", "a/b", "", "$(touch anything)", None]:
            with self.assertRaises(ValueError):
                bridge.key(invalid)

    def test_atomic_file_contains_only_complete_json(self):
        path = self.root / "state.json"
        for n in range(10):
            bridge.atomic(path, {"n": n, "message": "A literal `quote` and $(no shell)\n"})
            self.assertEqual(json.loads(path.read_text())["n"], n)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)


class PanelAliveTests(unittest.TestCase):
    def test_alive_only_while_the_panel_holds_its_lock(self):
        import fcntl, os
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.assertFalse(bridge.panel_alive(root))          # no lock file: no panel
            fd = os.open(root / "panel.lock", os.O_CREAT | os.O_RDWR, 0o600)
            self.assertFalse(bridge.panel_alive(root))          # file left behind by an exited panel
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertTrue(bridge.panel_alive(root))           # a running panel holds the lock
            os.close(fd)
            self.assertFalse(bridge.panel_alive(root))


if __name__ == "__main__":
    unittest.main()
