import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BIN = REPO / "bin" / "ws-blackbox"


class CliSkeletonTest(unittest.TestCase):
    def test_help_lists_subcommands(self):
        res = subprocess.run([sys.executable, str(BIN), "--help"], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, res.stderr)
        for word in ("tick", "status", "what", "dismiss", "restore"):
            self.assertIn(word, res.stdout)

    def test_state_dir_override(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "state"
            sys.path.insert(0, str(REPO / "lib"))
            from wsbb import paths
            old = os.environ.get("WS_BLACKBOX_STATE")
            os.environ["WS_BLACKBOX_STATE"] = str(target)
            try:
                self.assertEqual(paths.state_dir_path(), target)
            finally:
                if old is None:
                    del os.environ["WS_BLACKBOX_STATE"]
                else:
                    os.environ["WS_BLACKBOX_STATE"] = old


if __name__ == "__main__":
    unittest.main()
