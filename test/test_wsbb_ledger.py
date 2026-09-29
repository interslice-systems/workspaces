import copy
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "lib"))
from wsbb import ledger as L  # noqa: E402

UUID_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
UUID_B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"


def window(wid="@1", index=1, name="w", claude=None, session="s", pane="%1", cmd="bash"):
    return {"window_id": wid, "session": session, "index": index, "name": name,
            "automatic_rename": False, "layout": "L", "server_pid": 7, "server_start": 70,
            "night_shift": False,
            "panes": [{"pane_id": pane, "index": 1, "cwd": "/home/user/p", "pid": 9,
                       "command": cmd, "claude": claude, "children": []}]}


def obs(*windows, clients=None):
    return {"boot8": "b00b1e55", "clients": clients if clients is not None else
            {"s": {"id": 2, "name": "s"}}, "windows": list(windows)}


def empty():
    return {"version": 1, "windows": {}, "workspaces": {}}


class UpsertTest(unittest.TestCase):
    def test_key_includes_incarnation(self):
        self.assertEqual(L.window_key("b00b1e55", 7, 70, "@1"), "b00b1e55:7:70:@1")

    def test_new_window_recorded_with_workspace(self):
        led = empty()
        self.assertTrue(L.upsert(led, obs(window()), 1000))
        e = led["windows"]["b00b1e55:7:70:@1"]
        self.assertEqual(e["workspace"], {"id": 2, "name": "s"})
        self.assertEqual(e["first_seen"], 1000)
        self.assertEqual(led["workspaces"]["s"], {"id": 2, "last_seen": 1000})

    def test_unchanged_within_ten_minutes_is_not_rewritten(self):
        led = empty()
        L.upsert(led, obs(window()), 1000)
        before = copy.deepcopy(led)
        self.assertFalse(L.upsert(led, obs(window()), 1300))
        self.assertEqual(led, before)
        self.assertTrue(L.upsert(led, obs(window()), 1600))
        self.assertEqual(led["windows"]["b00b1e55:7:70:@1"]["last_seen"], 1600)

    def test_claude_block_is_sticky_per_pane(self):
        led = empty()
        L.upsert(led, obs(window(claude={"session_id": UUID_A, "name": "n", "status": "idle", "pid": 5})), 1000)
        L.upsert(led, obs(window(claude=None)), 1100)          # claude died, pane lives
        e = led["windows"]["b00b1e55:7:70:@1"]
        self.assertEqual(e["panes"][0]["claude"]["session_id"], UUID_A)
        L.upsert(led, obs(window(claude={"session_id": UUID_B, "name": "m", "status": "busy", "pid": 6})), 1200)
        self.assertEqual(led["windows"]["b00b1e55:7:70:@1"]["panes"][0]["claude"]["session_id"], UUID_B)

    def test_unknown_join_for_same_process_keeps_known_id(self):
        led = empty()
        L.upsert(led, obs(window(claude={"session_id": UUID_A, "name": "n", "status": "idle", "pid": 5})), 1000)
        L.upsert(led, obs(window(claude={"session_id": None, "name": None, "status": None, "pid": 5})), 1100)
        self.assertEqual(led["windows"]["b00b1e55:7:70:@1"]["panes"][0]["claude"]["session_id"], UUID_A)

    def test_unobserved_windows_are_frozen(self):
        led = empty()
        L.upsert(led, obs(window(), window(wid="@2", index=2)), 1000)
        frozen = copy.deepcopy(led["windows"]["b00b1e55:7:70:@2"])
        L.upsert(led, obs(window()), 5000)
        self.assertEqual(led["windows"]["b00b1e55:7:70:@2"], frozen)

    def test_missing_client_keeps_previous_mapping(self):
        led = empty()
        L.upsert(led, obs(window()), 1000)
        L.upsert(led, obs(window(name="renamed"), clients={}), 1100)
        self.assertEqual(led["windows"]["b00b1e55:7:70:@1"]["workspace"], {"id": 2, "name": "s"})
        L.upsert(led, obs(window(name="again"), clients=None), 1200)   # clients source failed
        self.assertEqual(led["windows"]["b00b1e55:7:70:@1"]["workspace"], {"id": 2, "name": "s"})


class LiveAndDismissTest(unittest.TestCase):
    def test_ghosts_and_workspace_dismiss(self):
        led = empty()
        L.upsert(led, obs(window(), window(wid="@2", index=2)), 1000)
        live = {"b00b1e55:7:70:@1"}
        self.assertEqual(L.ghost_keys(led, live), ["b00b1e55:7:70:@2"])
        self.assertEqual(L.dismiss_workspace(led, "s", live), 1)
        self.assertIn("s", led["workspaces"])            # a live window still maps to it
        self.assertEqual(L.dismiss_workspace(led, "s", set()), 1)
        self.assertNotIn("s", led["workspaces"])


class TickTest(unittest.TestCase):
    def test_tick_with_no_server_writes_full_heartbeat_and_no_windows(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(os.environ, WS_BLACKBOX_STATE=f"{tmp}/state", TMUX_TMPDIR=tmp,
                       WS_BLACKBOX_CLIENTS="/bin/false")
            env.pop("TMUX", None)
            res = subprocess.run([sys.executable, str(REPO / "bin/ws-blackbox"), "tick"],
                                 env=env, capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, res.stderr)
            hb = json.loads(Path(f"{tmp}/state/heartbeat.json").read_text())
            self.assertEqual(hb["partial_sources"], [])
            self.assertEqual(hb["last_full"], hb["last_attempt"])


if __name__ == "__main__":
    unittest.main()
