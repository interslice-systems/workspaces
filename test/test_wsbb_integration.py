"""End-to-end on a PRIVATE tmux server: TMUX_TMPDIR points every tmux call (ours and
tmux-local-clients') at a temp socket. The real server is never touched."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BIN = REPO / "bin" / "ws-blackbox"
UUID = "c0ffee00-1234-4abc-8def-0123456789ab"
SESSION = "night\U0001f916shift"


@unittest.skipUnless(shutil.which("tmux") and shutil.which("sleep"), "needs tmux")
class RestoreIntegrationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.base = base
        for sub in ("tmux", "home", "bin", "claude/sessions", "claude/projects/p", "work/it's dir"):
            (base / sub).mkdir(parents=True, exist_ok=True)
        shutil.copy(shutil.which("sleep"), base / "bin" / "claude")      # comm == "claude"
        (base / "claude/projects/p" / f"{UUID}.jsonl").write_text("{}\n")
        clients = base / "clients"
        clients.write_text("#!/bin/sh\nprintf '%s' '" + json.dumps(
            [{"session": SESSION, "workspace": {"id": 4, "name": SESSION}, "focusHistoryID": 1}]) + "'\n")
        clients.chmod(0o755)
        self.env = dict(os.environ)
        self.env.pop("TMUX", None)
        self.env.update(TMUX_TMPDIR=str(base / "tmux"), HOME=str(base / "home"),
                        PATH=f"{base / 'bin'}:{os.environ['PATH']}",
                        WS_BLACKBOX_STATE=str(base / "state"), WS_BLACKBOX_CLAUDE_DIR=str(base / "claude"),
                        WS_BLACKBOX_CLIENTS=str(clients), WS_BLACKBOX_NO_NOTIFY="1")
        self.tmux("-f", "/dev/null", "new-session", "-d", "-s", SESSION, "-x", "160", "-y", "40",
                  "bash --norc --noprofile")
        sock = self.tmux("display-message", "-p", "#{socket_path}").strip()
        self.assertTrue(sock.startswith(str(base / "tmux")), f"refusing to run against {sock}")
        self.cwd = str(base / "work/it's dir")

    def tearDown(self):
        subprocess.run(["tmux", "kill-server"], env=self.env, capture_output=True)   # private socket only
        self.tmp.cleanup()

    def tmux(self, *args):
        return subprocess.run(["tmux", *args], env=self.env, check=True, capture_output=True, text=True).stdout

    def bb(self, *args):
        return subprocess.run([sys.executable, str(BIN), *args], env=self.env, capture_output=True, text=True)

    def wait(self, predicate, timeout=5.0):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if predicate():
                return True
            time.sleep(0.1)
        return False

    def start_agent_window(self):
        self.tmux("new-window", "-d", "-t", f"={SESSION}:5", "-n", "agent", "-c", self.cwd,
                  "bash --norc --noprofile")
        self.tmux("send-keys", "-t", f"={SESSION}:5", "claude 600", "Enter")   # the test harness may press Enter
        self.assertTrue(self.wait(lambda: self.tmux("display-message", "-p", "-t", f"={SESSION}:5",
                                                    "#{pane_current_command}").strip() == "claude"))
        pane_pid = int(self.tmux("display-message", "-p", "-t", f"={SESSION}:5", "#{pane_pid}"))
        kid = int(subprocess.run(["pgrep", "-P", str(pane_pid)], capture_output=True, text=True).stdout.split()[0])
        stat = Path(f"/proc/{kid}/stat").read_text()
        start = stat[stat.rfind(")") + 2:].split()[19]
        (self.base / "claude/sessions" / f"{kid}.json").write_text(json.dumps(
            {"pid": kid, "sessionId": UUID, "procStart": start, "name": "agent", "status": "idle"}))
        return kid

    def ledger(self):
        return json.loads((self.base / "state/ledger.json").read_text())

    def agent_key(self):
        return next(k for k, e in self.ledger()["windows"].items() if e["name"] == "agent")

    def test_gone_window_restores_with_line_typed_but_not_run(self):
        kid = self.start_agent_window()
        self.assertEqual(self.bb("tick").returncode, 0)
        key = self.agent_key()
        entry = self.ledger()["windows"][key]
        self.assertEqual(entry["workspace"], {"id": 4, "name": SESSION})
        self.assertEqual(entry["panes"][0]["claude"]["session_id"], UUID)
        os.kill(kid, 15)
        self.tmux("kill-window", "-t", f"={SESSION}:5")                        # harness, private server

        what = self.bb("what")
        self.assertIn("gone", what.stdout)
        self.assertIn(f"claude --resume {UUID}", what.stdout)

        res = self.bb("restore", key)
        self.assertEqual(res.returncode, 0, res.stderr)
        names = self.tmux("list-windows", "-t", f"={SESSION}", "-F", "#{window_index}:#{window_name}")
        self.assertIn("5:agent", names)
        self.assertTrue(self.wait(lambda: "claude --resume" in self.tmux("capture-pane", "-p", "-t", f"={SESSION}:5")))
        screen = self.tmux("capture-pane", "-p", "-t", f"={SESSION}:5")
        self.assertIn(f"cd '{self.base}/work/it'\"'\"'s dir' && claude --resume {UUID}", screen)
        time.sleep(0.5)
        self.assertEqual(self.tmux("display-message", "-p", "-t", f"={SESSION}:5",
                                   "#{pane_current_command}").strip(), "bash")     # typed, NOT run
        self.assertNotIn(key, self.ledger()["windows"])
        # the rebuilt window inherits the Claude record, and keeps it through a tick at a bare
        # shell: until Enter is pressed the row still offers to resume it
        for _ in range(2):
            carried = [e for e in self.ledger()["windows"].values() if e["name"] == "agent"]
            self.assertEqual(len(carried), 1)
            self.assertEqual(carried[0]["panes"][0]["claude"]["session_id"], UUID)
            self.assertEqual(self.bb("tick").returncode, 0)

        again = self.bb("restore", key)                                         # double click
        self.assertEqual(again.returncode, 1)
        self.assertIn("no such entry", again.stderr)

    def test_dry_run_creates_nothing(self):
        kid = self.start_agent_window()
        self.bb("tick")
        key = self.agent_key()
        os.kill(kid, 15)
        self.tmux("kill-window", "-t", f"={SESSION}:5")
        before = self.tmux("list-windows", "-t", f"={SESSION}")
        res = self.bb("restore", "--dry-run", key)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("tmux -N new-window", res.stdout)
        self.assertIn("send-keys", res.stdout)
        self.assertNotIn("Enter", res.stdout)
        self.assertEqual(self.tmux("list-windows", "-t", f"={SESSION}"), before)
        self.assertIn(key, self.ledger()["windows"])

    def test_agent_gone_pane_gets_line_in_place(self):
        kid = self.start_agent_window()
        self.bb("tick")
        key = self.agent_key()
        pane = self.ledger()["windows"][key]["panes"][0]["pane_id"]
        os.kill(kid, 15)
        self.assertTrue(self.wait(lambda: self.tmux("display-message", "-p", "-t", pane,
                                                    "#{pane_current_command}").strip() == "bash"))
        res = self.bb("restore", "--pane", key, pane)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertTrue(self.wait(lambda: f"claude --resume {UUID}" in self.tmux("capture-pane", "-p", "-J", "-t", pane)))

    def test_double_click_on_agent_gone_types_once(self):
        kid = self.start_agent_window()
        self.bb("tick")
        key = self.agent_key()
        pane = self.ledger()["windows"][key]["panes"][0]["pane_id"]
        os.kill(kid, 15)
        self.assertTrue(self.wait(lambda: self.tmux("display-message", "-p", "-t", pane,
                                                    "#{pane_current_command}").strip() == "bash"))
        self.assertEqual(self.bb("restore", "--pane", key, pane).returncode, 0)
        second = self.bb("restore", "--pane", key, pane)
        self.assertEqual(second.returncode, 0, second.stderr)   # nothing to refuse: it's done
        time.sleep(0.3)
        self.assertEqual(self.tmux("capture-pane", "-p", "-J", "-t", pane).count("claude --resume"), 1)

    def exited_agent_pane(self):
        kid = self.start_agent_window()
        self.bb("tick")
        key = self.agent_key()
        pane = self.ledger()["windows"][key]["panes"][0]["pane_id"]
        os.kill(kid, 15)
        self.assertTrue(self.wait(lambda: self.tmux("display-message", "-p", "-t", pane,
                                                    "#{pane_current_command}").strip() == "bash"))
        return key, pane

    def test_restore_again_later_finds_the_line_already_typed(self):
        key, pane = self.exited_agent_pane()
        self.assertEqual(self.bb("restore", "--pane", key, pane).returncode, 0)
        self.assertTrue(self.wait(lambda: "claude --resume" in self.tmux("capture-pane", "-p", "-J", "-t", pane)))
        (self.base / "state/recent.json").unlink()              # past the double-click guard
        self.tmux("select-window", "-t", f"={SESSION}:0")
        again = self.bb("restore", "--pane", key, pane)
        self.assertEqual(again.returncode, 0, again.stderr)
        time.sleep(0.3)
        self.assertEqual(self.tmux("capture-pane", "-p", "-J", "-t", pane).count("claude --resume"), 1)
        self.assertEqual(self.active_window(), "5")             # still brought to it

    def test_an_old_resume_line_in_the_scrollback_does_not_count(self):
        key, pane = self.exited_agent_pane()
        self.assertEqual(self.bb("restore", "--pane", key, pane).returncode, 0)
        self.assertTrue(self.wait(lambda: "claude --resume" in self.tmux("capture-pane", "-p", "-J", "-t", pane)))
        self.tmux("send-keys", "-t", pane, "Enter")             # ran it; the fake claude exits at once
        time.sleep(0.5)
        self.assertEqual(self.tmux("display-message", "-p", "-t", pane, "#{pane_current_command}").strip(), "bash")
        (self.base / "state/recent.json").unlink()
        self.assertEqual(self.bb("restore", "--pane", key, pane).returncode, 0)
        self.assertTrue(self.wait(lambda: self.tmux("capture-pane", "-p", "-J", "-t", pane).count("claude --resume") == 2))

    def test_restore_types_again_once_the_line_was_cleared(self):
        key, pane = self.exited_agent_pane()
        self.assertEqual(self.bb("restore", "--pane", key, pane).returncode, 0)
        self.assertTrue(self.wait(lambda: "claude --resume" in self.tmux("capture-pane", "-p", "-J", "-t", pane)))
        self.tmux("send-keys", "-t", pane, "C-e", "C-u")        # the person declined with Ctrl+U
        self.assertTrue(self.wait(lambda: "claude --resume" not in self.tmux("capture-pane", "-p", "-J", "-t", pane)))
        (self.base / "state/recent.json").unlink()
        self.assertEqual(self.bb("restore", "--pane", key, pane).returncode, 0)
        self.assertTrue(self.wait(lambda: "claude --resume" in self.tmux("capture-pane", "-p", "-J", "-t", pane)))

    def active_window(self):
        rows = self.tmux("list-windows", "-t", f"={SESSION}", "-F", "#{window_active} #{window_index}").split("\n")
        return next(r.split()[1] for r in rows if r.startswith("1 "))

    def test_pane_restore_activates_its_window(self):
        kid = self.start_agent_window()
        self.bb("tick")
        key = self.agent_key()
        pane = self.ledger()["windows"][key]["panes"][0]["pane_id"]
        self.assertNotEqual(self.active_window(), "5")
        os.kill(kid, 15)
        self.assertTrue(self.wait(lambda: self.tmux("display-message", "-p", "-t", pane,
                                                    "#{pane_current_command}").strip() == "bash"))
        self.assertEqual(self.bb("restore", "--pane", key, pane).returncode, 0)
        self.assertEqual(self.active_window(), "5")

    def test_window_restore_activates_the_new_window(self):
        kid = self.start_agent_window()
        self.bb("tick")
        key = self.agent_key()
        os.kill(kid, 15)
        self.tmux("kill-window", "-t", f"={SESSION}:5")
        self.assertEqual(self.bb("restore", key).returncode, 0)
        self.assertEqual(self.active_window(), "5")

    def test_dismiss_agent_forgets_the_exited_claude(self):
        kid = self.start_agent_window()
        self.bb("tick")
        key = self.agent_key()
        pane = self.ledger()["windows"][key]["panes"][0]["pane_id"]
        os.kill(kid, 15)
        self.assertTrue(self.wait(lambda: self.tmux("display-message", "-p", "-t", pane,
                                                    "#{pane_current_command}").strip() == "bash"))
        res = self.bb("dismiss", "--agent", key, pane)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIsNone(self.ledger()["windows"][key]["panes"][0]["claude"])
        self.bb("tick")
        self.assertIsNone(self.ledger()["windows"][key]["panes"][0]["claude"])
        self.assertIn(key, self.ledger()["windows"])            # the window itself is kept

    def test_live_session_is_refused(self):
        self.start_agent_window()
        self.bb("tick")
        key = self.agent_key()
        pane = self.ledger()["windows"][key]["panes"][0]["pane_id"]
        self.assertNotEqual(self.active_window(), "5")
        res = self.bb("restore", "--pane", key, pane)                   # claude still running
        self.assertEqual(res.returncode, 1)
        self.assertEqual(self.active_window(), "5")                     # refused, but brought there

    def test_dismiss_workspace_keeps_live_windows(self):
        kid = self.start_agent_window()
        self.bb("tick")
        os.kill(kid, 15)
        self.tmux("kill-window", "-t", f"={SESSION}:5")
        self.assertEqual(self.bb("dismiss", "--workspace", SESSION).returncode, 0)
        names = [e["name"] for e in self.ledger()["windows"].values()]
        self.assertNotIn("agent", names)
        self.assertEqual(len(names), 1)                                 # the live first window

    def test_deleted_worktree_cwd_still_restores(self):
        gone_dir = self.base / "work/removed-worktree"
        gone_dir.mkdir()
        self.cwd = str(gone_dir)
        kid = self.start_agent_window()
        self.bb("tick")
        key = self.agent_key()
        os.kill(kid, 15)
        self.tmux("kill-window", "-t", f"={SESSION}:5")
        gone_dir.rmdir()
        res = self.bb("restore", key)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("5:agent", self.tmux("list-windows", "-t", f"={SESSION}", "-F", "#{window_index}:#{window_name}"))
        self.assertTrue(self.wait(lambda: "claude --resume" in self.tmux("capture-pane", "-p", "-t", f"={SESSION}:5")))

    def fake_desktop(self):
        """hyprctl, the terminal and the identity lib, faked: dispatch runs `_spawn`, and the
        'terminal' starts the session detached on the same private socket."""
        b = self.base / "bin"
        (b / "hyprctl").write_text(
            "#!/bin/sh\n"
            "case \"$1\" in\n"
            "  workspaces) echo '[]' ;;\n"
            "  dispatch) id=$(printf '%s' \"$2\" | sed -n 's/.*_spawn \\([0-9a-f]*\\).*/\\1/p')\n"
            "            \"$WS_BLACKBOX_SELF\" _spawn \"$id\" >/dev/null 2>&1 &\n"
            "            echo ok ;;\n"
            "esac\n")
        (b / "xdg-terminal-exec").write_text('#!/bin/sh\nshift 3\nexec tmux new-session -d "$@"\n')
        for f in ("hyprctl", "xdg-terminal-exec"):
            (b / f).chmod(0o755)
        lib = self.base / "identity-lib.sh"
        lib.write_text("wsid_reject_name() { return 1; }\nwsid_rename_workspace() { :; }\n")
        self.env.update(WS_BLACKBOX_SELF=str(BIN), WS_BLACKBOX_IDENTITY_LIB=str(lib))

    def test_workspace_restore_rebuilds_the_session_and_keeps_its_claude(self):
        self.fake_desktop()
        kid = self.start_agent_window()
        self.tmux("kill-window", "-t", f"={SESSION}:0")                  # the agent is the only window
        self.assertEqual(self.bb("tick").returncode, 0)
        os.kill(kid, 15)
        subprocess.run(["tmux", "kill-server"], env=self.env, capture_output=True)   # private socket
        res = self.bb("restore", "--workspace", SESSION)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("5:agent", self.tmux("list-windows", "-t", f"={SESSION}", "-F", "#{window_index}:#{window_name}"))
        self.assertTrue(self.wait(lambda: f"claude --resume {UUID}" in
                                  self.tmux("capture-pane", "-p", "-J", "-t", f"={SESSION}:5")))
        for _ in range(2):                                               # survives a tick at the shell
            carried = [e for e in self.ledger()["windows"].values() if e["name"] == "agent"]
            self.assertEqual(len(carried), 1)
            self.assertEqual(carried[0]["panes"][0]["claude"]["session_id"], UUID)
            self.assertEqual(self.bb("tick").returncode, 0)

    def test_no_server_tick_freezes_ledger(self):
        self.start_agent_window()
        self.bb("tick")
        before = self.ledger()
        subprocess.run(["tmux", "kill-server"], env=self.env, capture_output=True)
        self.assertEqual(self.bb("tick").returncode, 0)
        self.assertEqual(self.ledger(), before)
        hb = json.loads((self.base / "state/heartbeat.json").read_text())
        self.assertEqual(hb["partial_sources"], [])


if __name__ == "__main__":
    unittest.main()
