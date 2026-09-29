"""Why things died, from journald. Only pid, comm, signal, unit and time ever leave this module."""
import json
import re

from . import observe

PATTERNS = [
    ("earlyoom", re.compile(r'sending (SIG[A-Z]+) to process (\d+) uid \d+ "([^"]{1,32})"'),
     lambda m: {"signal": m[1], "pid": int(m[2]), "comm": m[3]}),
    ("kernel-oom", re.compile(r"Out of memory: Killed process (\d+) \(([^)]{1,32})\)"),
     lambda m: {"pid": int(m[1]), "comm": m[2]}),
    ("coredump", re.compile(r"Process (\d+) \(([^)]{1,32})\) of user \d+ (?:dumped core|terminated abnormally)"),
     lambda m: {"pid": int(m[1]), "comm": m[2]}),
    ("oomd", re.compile(r"Killed (\S{1,200}\.(?:scope|service)) due to"),
     lambda m: {"unit": m[1].rsplit("/", 1)[-1]}),
    ("scope-stop", re.compile(r"Stopped (tmux-spawn-[0-9a-f-]{1,64}\.scope)"),
     lambda m: {"unit": m[1]}),
    ("reboot", re.compile(r"System is (rebooting|powering down)"), lambda m: {}),
]

QUERIES = [
    ["-u", "earlyoom"],
    ["-u", "systemd-oomd"],
    ["-k", "--grep", "Out of memory"],
    ["-t", "systemd-coredump"],
    ["-t", "systemd-logind", "--grep", "System is"],
    ["--user", "--grep", "Stopped tmux-spawn"],
]


def classify(message, ts):
    for kind, pattern, pick in PATTERNS:
        m = pattern.search(message)
        if m:
            return {"kind": kind, "time": ts, **pick(m)}
    return None


def causes(since, runner=observe.run):
    events = []
    for query in QUERIES:
        argv = ["journalctl", "--no-pager", "-q", "-o", "json", "--since", f"@{int(since)}",
                "--output-fields=MESSAGE,__REALTIME_TIMESTAMP", *query]
        try:
            res = runner(argv, timeout=10.0)
        except observe.SourceError:
            continue
        for line in res.stdout.splitlines():
            try:
                obj = json.loads(line)
                msg = obj["MESSAGE"]
                ts = int(obj["__REALTIME_TIMESTAMP"]) // 1_000_000
            except (ValueError, KeyError, TypeError):
                continue
            if isinstance(msg, str):
                ev = classify(msg, ts)
                if ev and ev not in events:
                    events.append(ev)
    return sorted(events, key=lambda e: e["time"])


def unclean_previous_boot(runner=observe.run):
    try:
        res = runner(["journalctl", "--no-pager", "-q", "-b", "0", "-t", "systemd-journald", "-o", "cat"],
                     timeout=10.0)
    except observe.SourceError:
        return False
    return "uncleanly" in res.stdout
