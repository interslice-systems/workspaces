import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))
from wsbb.tmuxctl import Forbidden, Tmux  # noqa: E402


class GuardTest(unittest.TestCase):
    def test_forbidden_verbs_and_enter(self):
        t = Tmux(dry_run=True)
        for verb in ("rename-session", "switch-client", "kill-server", "kill-window", "kill-session",
                     "kill-pane", "new-session", "attach-session"):
            with self.assertRaises(Forbidden):
                t(verb, "-t", "x", mutate=True)
        with self.assertRaises(Forbidden):
            t("send-keys", "-t", "%1", "hello", mutate=True)          # no -l
        with self.assertRaises(Forbidden):
            t("send-keys", "-t", "%1", "-l", "--", "x", "Enter", mutate=True)

    def test_dry_run_logs_mutations_with_dash_n(self):
        t = Tmux(dry_run=True)
        self.assertEqual(t("new-window", "-d", mutate=True), "")
        self.assertEqual(t.log, [["tmux", "-N", "new-window", "-d"]])


if __name__ == "__main__":
    unittest.main()
