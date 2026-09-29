import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "lib"))
from wsbb import restore, typed  # noqa: E402


class ChooseIdTest(unittest.TestCase):
    def test_recorded_id_when_free_else_lowest_free(self):
        self.assertEqual(restore.choose_workspace_id("m", 2, [{"id": 1, "name": "a"}]), 2)
        self.assertEqual(restore.choose_workspace_id("m", 2, [{"id": 1, "name": "a"}, {"id": 2, "name": "b"}]), 3)
        self.assertEqual(restore.choose_workspace_id("m", None, []), 1)

    def test_refuses_when_already_open_or_full(self):
        with self.assertRaises(typed.Refused):
            restore.choose_workspace_id("m", 2, [{"id": 5, "name": "m"}])
        with self.assertRaises(typed.Refused):
            restore.choose_workspace_id("m", 2, [{"id": i, "name": str(i)} for i in range(1, 11)])


class DispatchTest(unittest.TestCase):
    def test_only_integers_and_hex_reach_the_lua_string(self):
        s = restore.spawn_dispatch(4, "/home/user/.local/bin/ws-blackbox", "0123456789abcdef")
        self.assertEqual(s, 'hl.dsp.exec_cmd("[workspace 4 silent] /home/user/.local/bin/ws-blackbox _spawn 0123456789abcdef")')
        with self.assertRaises(typed.Refused):
            restore.spawn_dispatch(4, '/home/us"er/ws-blackbox', "0123456789abcdef")
        with self.assertRaises(ValueError):
            restore.spawn_dispatch(4, "/x", "not-hex")

    def test_spawn_argv_matches_ws_attach_creation(self):
        argv = restore.spawn_argv({"name": "night\U0001f916shift", "attach_only": False,
                                   "cwd": "/home/user/it's", "window_name": "-agent"})
        self.assertEqual(argv, ["xdg-terminal-exec", "--", "tmux", "new-session", "-A", "-s",
                                "night\U0001f916shift", "-c", "/home/user/it's", "-n", "-agent",
                                ";", "set-option", "detach-on-destroy", "on"])
        attach = restore.spawn_argv({"name": "m", "attach_only": True, "cwd": "/x", "window_name": "w"})
        self.assertEqual(attach, ["xdg-terminal-exec", "--", "tmux", "new-session", "-A", "-s", "m",
                                  ";", "set-option", "detach-on-destroy", "on"])


class SpawnExecTest(unittest.TestCase):
    def test_spawn_reads_record_once_and_execs(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            (base / "bin").mkdir()
            out = base / "argv.txt"
            stub = base / "bin" / "xdg-terminal-exec"
            stub.write_text(f"#!/bin/sh\nprintf '%s\\n' \"$@\" > '{out}'\n")
            stub.chmod(0o755)
            state_dir = base / "state"
            state_dir.mkdir(mode=0o700)
            rid = "00112233aabbccdd"
            (state_dir / f"spawn-{rid}.json").write_text(json.dumps(
                {"name": "m", "attach_only": False, "cwd": "/tmp", "window_name": None}))
            env = dict(os.environ, WS_BLACKBOX_STATE=str(state_dir),
                       PATH=f"{base / 'bin'}:{os.environ['PATH']}")
            res = subprocess.run([sys.executable, str(REPO / "bin/ws-blackbox"), "_spawn", rid],
                                 env=env, capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, res.stderr)
            self.assertEqual(out.read_text().split("\n")[:7],
                             ["--", "tmux", "new-session", "-A", "-s", "m", "-c"])
            self.assertFalse((state_dir / f"spawn-{rid}.json").exists())
            again = subprocess.run([sys.executable, str(REPO / "bin/ws-blackbox"), "_spawn", rid],
                                   env=env, capture_output=True, text=True)
            self.assertEqual(again.returncode, 1)


if __name__ == "__main__":
    unittest.main()
