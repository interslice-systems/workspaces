import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))
from wsbb import observe  # noqa: E402
from wsbb.procs import ProcTable  # noqa: E402

CLK = os.sysconf("SC_CLK_TCK")
UUID = "0f0e0d0c-0b0a-4908-8706-050403020100"


class FakeProc:
    """Builds a synthetic /proc tree. uptime is 10000 s; start is given in seconds since boot."""

    def __init__(self, root):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        (self.root / "uptime").write_text("10000.00 50000.00\n")

    def add(self, pid, ppid, comm, argv, started_at=100.0):
        d = self.root / str(pid)
        d.mkdir()
        start_ticks = int(started_at * CLK)
        fields = ["S", str(ppid)] + ["0"] * 17 + [str(start_ticks)] + ["0"] * 10
        (d / "stat").write_text(f"{pid} ({comm}) " + " ".join(fields) + "\n")
        (d / "cmdline").write_bytes(b"\0".join(a.encode() for a in argv) + b"\0")
        return start_ticks


class ProcTableTest(unittest.TestCase):
    def test_tree_and_age(self):
        with tempfile.TemporaryDirectory() as tmp:
            fp = FakeProc(tmp)
            fp.add(10, 1, "bash", ["-bash"], started_at=100)
            fp.add(11, 10, "claude", ["claude"], started_at=9990)
            fp.add(12, 11, "a b)c", ["x"], started_at=50)   # hostile comm with ")"
            t = ProcTable(Path(tmp))
            self.assertEqual(t.children(10), [11])
            self.assertEqual(t.descendants(10), [11, 12])
            self.assertAlmostEqual(t.age(11), 10.0, places=1)
            self.assertEqual(t.get(12)["comm"], "a b)c")


class ParsePanesTest(unittest.TestCase):
    def test_parses_fields_and_skips_malformed(self):
        sep = "\x1f"
        good = sep.join(["12", "1700", "night\U0001f916shift", "@3", "2", "a b", "1", "lay",
                         "%7", "1", "99", "bash", "/home/user/it's"])
        rows = observe.parse_panes(good + "\nbroken line\n")
        self.assertEqual(len(rows), 1)
        r = rows[0]
        self.assertEqual((r["session"], r["window_index"], r["automatic_rename"], r["cwd"]),
                         ("night\U0001f916shift", 2, True, "/home/user/it's"))


class ClaudeJoinTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.fp = FakeProc(Path(self.tmp.name) / "proc")
        self.sessions = Path(self.tmp.name) / "sessions"
        self.sessions.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def _session_file(self, pid, start, **extra):
        data = {"pid": pid, "sessionId": UUID, "procStart": str(start), "name": "x", "status": "idle"}
        data.update(extra)
        (self.sessions / f"{pid}.json").write_text(json.dumps(data))

    def test_joins_by_pid_and_procstart(self):
        self.fp.add(10, 1, "bash", ["-bash"])
        start = self.fp.add(11, 10, "claude", ["claude", "--permission-mode", "auto"])
        self._session_file(11, start)
        block = observe.claude_for_pane(ProcTable(self.fp.root), 10, self.sessions)
        self.assertEqual(block, {"session_id": UUID, "name": "x", "status": "idle", "pid": 11})

    def test_procstart_mismatch_degrades_to_unknown(self):
        self.fp.add(10, 1, "bash", ["-bash"])
        start = self.fp.add(11, 10, "claude", ["claude"])
        self._session_file(11, start + 1)
        block = observe.claude_for_pane(ProcTable(self.fp.root), 10, self.sessions)
        self.assertEqual(block["session_id"], None)
        self.assertEqual(block["pid"], 11)

    def test_non_uuid_session_id_is_dropped(self):
        self.fp.add(10, 1, "bash", ["-bash"])
        start = self.fp.add(11, 10, "claude", ["claude"])
        self._session_file(11, start, sessionId="../../etc")
        block = observe.claude_for_pane(ProcTable(self.fp.root), 10, self.sessions)
        self.assertIsNone(block["session_id"])

    def test_no_claude(self):
        self.fp.add(10, 1, "bash", ["-bash"])
        self.assertIsNone(observe.claude_for_pane(ProcTable(self.fp.root), 10, self.sessions))


class ChildrenTest(unittest.TestCase):
    def test_filters_collapses_and_sees_through_claude_shells(self):
        with tempfile.TemporaryDirectory() as tmp:
            fp = FakeProc(tmp)
            fp.add(10, 1, "bash", ["-bash"])
            fp.add(11, 10, "claude", ["claude", "--resume", "x"])
            fp.add(12, 11, "npm exec", ["npm", "exec", "chrome-devtools-mcp@latest"])
            fp.add(13, 11, "bash", ["/usr/bin/bash", "-c", "source snap && eval 'bin/dev'"])
            fp.add(14, 13, "ruby", ["ruby", "bin/dev"])
            fp.add(15, 14, "ruby", ["puma", "worker"])          # collapsed under 14
            fp.add(16, 10, "wl-copy", ["wl-copy"])               # ignored
            fp.add(17, 11, "bash", ["/usr/bin/bash", "-c", "x"])
            fp.add(18, 17, "rg", ["rg", "foo"], started_at=9995)  # too young
            kids = observe.children_for_pane(ProcTable(Path(tmp)), 10)
            self.assertEqual([k["cmd"] for k in kids], ["claude", "ruby bin/dev"])

    def test_claude_sessions_are_labelled_and_plumbing_is_hidden(self):
        with tempfile.TemporaryDirectory() as tmp:
            fp = FakeProc(Path(tmp) / "proc")
            sessions = Path(tmp) / "sessions"
            sessions.mkdir()
            fp.add(10, 1, "bash", ["-bash"])
            main = fp.add(11, 10, "claude", ["claude", "--permission-mode", "auto"])
            fp.add(20, 11, "claude", ["claude", "daemon", "run", "--origin", "transient"])
            fp.add(21, 20, "claude", ["claude", "--bg-pty-host", "/tmp/x.sock", "120", "51", "--", "claude"])
            bg = fp.add(22, 21, "claude", ["claude", "--session-id", UUID, "--fork-session"])
            fp.add(23, 20, "claude", ["claude", "--bg-pty-host", "/tmp/y.sock", "200", "50"])
            fp.add(24, 23, "claude", ["claude", "--bg-spare", "/tmp/z.sock"])
            (sessions / "11.json").write_text(json.dumps(
                {"pid": 11, "procStart": str(main), "sessionId": UUID, "name": "main-21",
                 "status": "busy", "kind": "interactive"}))
            (sessions / "22.json").write_text(json.dumps(
                {"pid": 22, "procStart": str(bg), "sessionId": UUID, "name": "bgjob",
                 "status": "idle", "kind": "bg"}))
            kids = observe.children_for_pane(ProcTable(fp.root), 10, sessions)
            self.assertEqual(kids, [
                {"comm": "claude", "cmd": "claude", "session": {"name": "main-21", "status": "busy", "kind": "interactive"}},
                {"comm": "claude", "cmd": "claude", "session": {"name": "bgjob", "status": "idle", "kind": "bg"}},
            ])

    def test_child_label(self):
        self.assertEqual(observe.child_label({"cmd": "claude", "session": {"name": "bgjob", "status": "idle", "kind": "bg"}}),
                         "background bgjob \u00b7 idle")
        self.assertEqual(observe.child_label({"cmd": "claude", "session": {"name": "m-21", "status": "busy", "kind": "interactive"}}),
                         "claude m-21 \u00b7 busy")
        self.assertEqual(observe.child_label({"cmd": "claude", "session": {"name": None, "status": None, "kind": None}}), "claude")
        self.assertEqual(observe.child_label({"cmd": "ruby bin/dev"}), "ruby bin/dev")

    def test_short_cmd_never_keeps_credential_shaped_words(self):
        cred = "gh" + "p_" + "A" * 36
        info = {"comm": "curl", "argv": ["curl", "-H", cred, "https://example.test/x"]}
        self.assertEqual(observe.short_cmd(info), "curl")
        info = {"comm": "npm", "argv": ["/usr/bin/npm", "run", "dev", "extra"]}
        self.assertEqual(observe.short_cmd(info), "npm run dev")
        info = {"comm": "tool", "argv": ["tool", "sk" + "-abc"]}
        self.assertEqual(observe.short_cmd(info), "tool")


class GroupAndNightShiftTest(unittest.TestCase):
    def test_groups_panes_and_marks_night_shift(self):
        sep = "\x1f"
        lines = [
            sep.join(["1", "2", "s", "@1", "1", "⏸night-shift-build", "0", "L", "%1", "1", "0",
                      "bash", "/w/.claude/worktrees/x"]),
            sep.join(["1", "2", "s", "@2", "2", "plain", "0", "L", "%3", "2", "0", "bash", "/a"]),
            sep.join(["1", "2", "s", "@2", "2", "plain", "0", "L", "%2", "1", "0", "bash",
                      "/r/.claude/worktrees/issue-drain"]),
        ]
        wins = observe.group_windows(observe.parse_panes("\n".join(lines)), None, Path("/nonexistent"))
        self.assertEqual([w["window_id"] for w in wins], ["@1", "@2"])
        self.assertTrue(wins[0]["night_shift"])
        self.assertTrue(wins[1]["night_shift"])
        self.assertEqual([p["pane_id"] for p in wins[1]["panes"]], ["%2", "%3"])


class ClientsTest(unittest.TestCase):
    def test_lowest_focus_history_wins(self):
        with tempfile.TemporaryDirectory() as tmp:
            script = Path(tmp) / "clients"
            script.write_text("#!/bin/sh\ncat <<'EOF'\n"
                              '[{"session":"a","workspace":{"id":2,"name":"a"},"focusHistoryID":5},'
                              '{"session":"a","workspace":{"id":3,"name":"z"},"focusHistoryID":1}]\nEOF\n')
            script.chmod(0o755)
            self.assertEqual(observe.read_clients(str(script)), {"a": {"id": 3, "name": "z"}})

    def test_failure_raises(self):
        with self.assertRaises(observe.SourceError):
            observe.read_clients("/bin/false")


if __name__ == "__main__":
    unittest.main()
