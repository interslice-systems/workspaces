"""The one line restore may type into a pane, and every reason to refuse it."""
import json
import re
import shlex
from pathlib import Path

from .observe import UUID_RE

CONTROL_RE = re.compile(r"[\x00-\x1f\x7f-\x9f]")


class Refused(Exception):
    pass


def session_is_live(session_id, claude_dir, proc_root):
    for f in (Path(claude_dir) / "sessions").glob("*.json"):
        try:
            data = json.loads(f.read_text())
        except (OSError, ValueError):
            continue
        if not isinstance(data, dict) or data.get("sessionId") != session_id:
            continue
        pid = data.get("pid")
        if not isinstance(pid, int):
            continue
        try:
            text = (Path(proc_root) / str(pid) / "stat").read_text()
        except OSError:
            continue
        rest = text[text.rfind(")") + 2:].split()
        if len(rest) > 19 and rest[19] == str(data.get("procStart")):
            return pid
    return None


def transcript_exists(session_id, claude_dir):
    return any((Path(claude_dir) / "projects").glob(f"*/{session_id}.jsonl"))


def resume_line(pane, night_shift, claude_dir, proc_root):
    claude = pane.get("claude")
    if not claude:
        return None
    sid = claude.get("session_id")
    if not isinstance(sid, str) or not UUID_RE.match(sid):
        raise Refused("no recorded Claude session id")
    if CONTROL_RE.search(pane.get("cwd", "")):
        raise Refused("unsafe characters in the working directory")
    pid = session_is_live(sid, claude_dir, proc_root)
    if pid:
        raise Refused(f"session still running (pid {pid})")
    if not transcript_exists(sid, claude_dir):
        raise Refused("transcript expired")
    if night_shift:
        line = f"# night-shift: claude --resume {sid}"
    else:
        line = f"cd {shlex.quote(pane['cwd'])} && claude --resume {sid}"
    if CONTROL_RE.search(line):
        raise Refused("unsafe characters in line")
    return line
