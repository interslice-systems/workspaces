import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))
from wsbb import typed  # noqa: E402

UUID = "12345678-1234-4234-8234-123456789abc"


class ResumeLineTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.claude = base / "claude"
        (self.claude / "sessions").mkdir(parents=True)
        (self.claude / "projects" / "-home-user-p").mkdir(parents=True)
        (self.claude / "projects" / "-home-user-p" / f"{UUID}.jsonl").write_text("{}\n")
        self.proc = base / "proc"
        self.proc.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def pane(self, cwd="/home/user/p", sid=UUID):
        return {"pane_id": "%1", "cwd": cwd, "claude": {"session_id": sid, "pid": 5}}

    def test_quoted_cwd_and_no_permission_flag(self):
        line = typed.resume_line(self.pane(cwd="/home/user/it's a dir"), False, self.claude, self.proc)
        self.assertEqual(line, "cd '/home/user/it'\"'\"'s a dir' && claude --resume " + UUID)
        self.assertNotIn("--permission-mode", line)

    def test_night_shift_is_a_comment(self):
        self.assertEqual(typed.resume_line(self.pane(), True, self.claude, self.proc),
                         f"# night-shift: claude --resume {UUID}")

    def test_non_claude_pane_types_nothing(self):
        self.assertIsNone(typed.resume_line({"pane_id": "%1", "cwd": "/x", "claude": None},
                                            False, self.claude, self.proc))

    def test_refusals(self):
        with self.assertRaisesRegex(typed.Refused, "session id"):
            typed.resume_line(self.pane(sid="not-a-uuid"), False, self.claude, self.proc)
        with self.assertRaisesRegex(typed.Refused, "unsafe"):
            typed.resume_line(self.pane(cwd="/home/user/a\nb"), False, self.claude, self.proc)
        with self.assertRaisesRegex(typed.Refused, "unsafe"):
            typed.resume_line(self.pane(cwd="/home/user/\x1b[31m"), False, self.claude, self.proc)
        other = "87654321-4321-4321-8321-cba987654321"
        with self.assertRaisesRegex(typed.Refused, "transcript expired"):
            typed.resume_line(self.pane(sid=other), False, self.claude, self.proc)

    def test_live_session_is_refused(self):
        (self.proc / "77").mkdir()
        (self.proc / "77" / "stat").write_text("77 (claude) S 1 " + " ".join(["0"] * 17) + " 4242 0\n")
        (self.claude / "sessions" / "77.json").write_text(
            json.dumps({"pid": 77, "sessionId": UUID, "procStart": "4242"}))
        with self.assertRaisesRegex(typed.Refused, "still running"):
            typed.resume_line(self.pane(), False, self.claude, self.proc)


if __name__ == "__main__":
    unittest.main()
