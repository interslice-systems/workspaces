import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))
from wsbb import state  # noqa: E402


class StateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name) / "s"
        os.environ["WS_BLACKBOX_STATE"] = str(self.dir)

    def tearDown(self):
        del os.environ["WS_BLACKBOX_STATE"]
        self.tmp.cleanup()

    def test_state_dir_is_0700(self):
        d = state.ensure_state_dir()
        self.assertEqual(stat.S_IMODE(d.stat().st_mode), 0o700)

    def test_atomic_write_is_0600_and_readable(self):
        d = state.ensure_state_dir()
        state.atomic_write_json(d / "x.json", {"a": "night\U0001f916shift"})
        self.assertEqual(stat.S_IMODE((d / "x.json").stat().st_mode), 0o600)
        self.assertEqual(state.read_json(d / "x.json", None), {"a": "night\U0001f916shift"})
        self.assertEqual([p.name for p in d.iterdir()], ["x.json"])  # no temp litter

    def test_missing_ledger_is_empty(self):
        d = state.ensure_state_dir()
        ledger, problem = state.load_ledger(d, 100, repair=True)
        self.assertEqual(ledger, {"version": 1, "windows": {}, "workspaces": {}})
        self.assertIsNone(problem)

    def test_corrupt_ledger_is_moved_aside_when_repairing(self):
        d = state.ensure_state_dir()
        (d / state.LEDGER).write_text("{not json")
        ledger, problem = state.load_ledger(d, 123, repair=True)
        self.assertEqual(problem, "ledger-corrupt")
        self.assertEqual(ledger["windows"], {})
        self.assertTrue((d / "ledger.json.corrupt-123").exists())
        self.assertFalse((d / state.LEDGER).exists())

    def test_corrupt_ledger_left_alone_when_reading(self):
        d = state.ensure_state_dir()
        (d / state.LEDGER).write_text(json.dumps({"version": 2}))
        ledger, problem = state.load_ledger(d, 5, repair=False)
        self.assertEqual(problem, "ledger-corrupt")
        self.assertTrue((d / state.LEDGER).exists())

    def test_malformed_entry_makes_the_ledger_corrupt(self):
        d = state.ensure_state_dir()
        bad = {"version": 1, "workspaces": {}, "windows": {"k": {"index": "x", "panes": "nope"}}}
        (d / state.LEDGER).write_text(json.dumps(bad))
        ledger, problem = state.load_ledger(d, 9, repair=True)
        self.assertEqual(problem, "ledger-corrupt")
        self.assertTrue((d / "ledger.json.corrupt-9").exists())

    def test_claim_refuses_a_repeat_within_the_window(self):
        d = state.ensure_state_dir()
        self.assertTrue(state.claim(d, "pane:k:%1", now=100))
        self.assertFalse(state.claim(d, "pane:k:%1", now=110))
        self.assertTrue(state.claim(d, "pane:k:%2", now=110))
        self.assertTrue(state.claim(d, "pane:k:%1", now=200))

    def test_a_short_claim_does_not_expire_a_longer_one(self):
        d = state.ensure_state_dir()
        self.assertTrue(state.claim(d, "workspace:x", now=0))              # 30 s: a spawn in flight
        self.assertTrue(state.claim(d, "pane:a", now=10, window=5))
        self.assertFalse(state.claim(d, "workspace:x", now=12))            # still guarded
        self.assertTrue(state.claim(d, "pane:a", now=16, window=5))

    def test_lock_times_out_when_held(self):
        d = state.ensure_state_dir()
        with state.locked(d):
            with self.assertRaises(state.LockTimeout):
                with state.locked(d, timeout=0.3):
                    pass


if __name__ == "__main__":
    unittest.main()
