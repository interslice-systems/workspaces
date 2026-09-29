import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))
from wsbb import journal  # noqa: E402


class ClassifyTest(unittest.TestCase):
    def test_earlyoom_keeps_only_signal_pid_comm(self):
        cred = "gh" + "p_" + "B" * 36
        msg = (f'sending SIGTERM to process 4242 uid 1000 "claude": oom_score 900, '
               f'VmRSS 2000 MiB, cmdline "curl -H {cred}"')
        ev = journal.classify(msg, 50)
        self.assertEqual(ev, {"kind": "earlyoom", "time": 50, "signal": "SIGTERM",
                              "pid": 4242, "comm": "claude"})
        self.assertNotIn(cred, repr(ev))

    def test_kernel_oom_coredump_oomd_scope_reboot(self):
        self.assertEqual(journal.classify("Out of memory: Killed process 77 (node) total-vm:1kB", 1),
                         {"kind": "kernel-oom", "time": 1, "pid": 77, "comm": "node"})
        self.assertEqual(journal.classify("Process 88 (kitty) of user 1000 dumped core.", 2)["pid"], 88)
        self.assertEqual(journal.classify("Killed /user.slice/app.slice/x.scope due to memory pressure", 3)["kind"],
                         "oomd")
        self.assertEqual(journal.classify("Stopped tmux-spawn-0a1b-2c.scope - tmux child pane 9.", 4)["kind"],
                         "scope-stop")
        self.assertEqual(journal.classify("System is rebooting.", 5)["kind"], "reboot")
        self.assertIsNone(journal.classify("nothing to see", 6))


class CausesTest(unittest.TestCase):
    def test_parses_json_lines_from_runner(self):
        class Res:
            returncode = 0
            stdout = ('{"MESSAGE":"sending SIGKILL to process 5 uid 1000 \\"claude\\": x",'
                      '"__REALTIME_TIMESTAMP":"7000000"}\n{"MESSAGE":[1,2]}\nnot json\n')
            stderr = ""
        evs = journal.causes(0, runner=lambda argv, timeout=10.0: Res())
        self.assertIn({"kind": "earlyoom", "time": 7, "signal": "SIGKILL", "pid": 5, "comm": "claude"}, evs)


if __name__ == "__main__":
    unittest.main()
