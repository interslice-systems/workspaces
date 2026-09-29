"""The only way ws-blackbox talks to tmux: always -N, never a forbidden verb, never Enter."""
import subprocess

FORBIDDEN = frozenset({"rename-session", "switch-client", "kill-server", "kill-session",
                       "kill-window", "kill-pane", "new-session", "attach-session"})
ENTER_KEYS = frozenset({"Enter", "C-m", "C-j", "KPEnter"})


class TmuxError(Exception):
    pass


class Forbidden(Exception):
    pass


class Tmux:
    def __init__(self, dry_run=False):
        self.dry_run = dry_run
        self.log = []

    def __call__(self, *args, mutate=False):
        verb = args[0]
        if verb in FORBIDDEN:
            raise Forbidden(verb)
        if verb == "send-keys" and ("-l" not in args or any(a in ENTER_KEYS for a in args)):
            raise Forbidden("send-keys must be literal and never press Enter")
        argv = ["tmux", "-N", *args]
        if mutate:
            self.log.append(argv)
            if self.dry_run:
                return ""
        try:
            res = subprocess.run(argv, capture_output=True, text=True, timeout=5)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise TmuxError(exc.__class__.__name__) from exc
        if res.returncode != 0:
            raise TmuxError(res.stderr.strip()[:200] or f"tmux {verb} failed")
        return res.stdout
