"""Sources for one tick: tmux panes, local clients, boot id, and what runs in each pane."""
import json
import re
import subprocess
from pathlib import Path

SEP = "\x1f"
PANE_FORMAT = SEP.join([
    "#{pid}", "#{start_time}", "#{session_name}", "#{window_id}", "#{window_index}",
    "#{window_name}", "#{automatic-rename}", "#{window_layout}", "#{pane_id}", "#{pane_index}",
    "#{pane_pid}", "#{pane_current_command}", "#{pane_current_path}",
])
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
SHELLS = frozenset({"bash", "sh", "zsh", "fish", "dash"})
SAFE_WORD = re.compile(r"^[A-Za-z0-9._/:-]{1,24}$")
REDACT_PREFIXES = ("ghp_", "gho_", "ghs_", "ghu_", "github_pat_", "sk-", "xox")
IGNORED_COMMS = frozenset({"wl-copy", "wl-paste"})
MIN_CHILD_AGE = 60.0


class SourceError(Exception):
    pass


def run(argv, timeout=5.0):
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise SourceError(f"{Path(argv[0]).name}: {exc.__class__.__name__}") from exc


def no_server(stderr):
    return ("no server running on" in stderr
            or ("error connecting to" in stderr and "No such file or directory" in stderr))


def parse_panes(text):
    rows = []
    for line in text.splitlines():
        f = line.split(SEP)
        if len(f) != 13:
            continue
        try:
            rows.append({
                "server_pid": int(f[0]), "server_start": int(f[1]), "session": f[2],
                "window_id": f[3], "window_index": int(f[4]), "window_name": f[5],
                "automatic_rename": f[6] == "1", "layout": f[7], "pane_id": f[8],
                "pane_index": int(f[9]), "pane_pid": int(f[10]), "command": f[11], "cwd": f[12],
            })
        except ValueError:
            continue
    return rows


def read_tmux():
    res = run(["tmux", "-N", "list-panes", "-a", "-F", PANE_FORMAT])
    if res.returncode != 0:
        if no_server(res.stderr):
            return None
        raise SourceError("tmux list-panes failed")
    return parse_panes(res.stdout)


def read_clients(cmd):
    res = run([cmd])
    if res.returncode != 0:
        raise SourceError("tmux-local-clients failed")
    try:
        data = json.loads(res.stdout)
    except ValueError as exc:
        raise SourceError("tmux-local-clients: bad json") from exc
    if not isinstance(data, list):
        raise SourceError("tmux-local-clients: not a list")
    clients = [c for c in data if isinstance(c, dict)]
    clients.sort(key=lambda c: c.get("focusHistoryID")
                 if isinstance(c.get("focusHistoryID"), int) else 1 << 30)
    out = {}
    for c in clients:
        ws, session = c.get("workspace"), c.get("session")
        if not isinstance(session, str) or session in out or not isinstance(ws, dict):
            continue
        if isinstance(ws.get("id"), int) and not isinstance(ws.get("id"), bool):
            out[session] = {"id": ws["id"], "name": str(ws.get("name") or "")}
    return out


def boot8(path):
    return Path(path).read_text().strip().replace("-", "")[:8]


def observe_now():
    """(rows, error). rows None = no server running; error True = the tmux source failed."""
    try:
        return read_tmux(), False
    except SourceError:
        return None, True


def claude_for_pane(procs, pane_pid, sessions_dir):
    if procs is None:
        return None
    for pid in procs.descendants(pane_pid):
        info = procs.get(pid)
        if info is None or info["comm"] != "claude":
            continue
        block = {"session_id": None, "name": None, "status": None, "pid": pid}
        try:
            data = json.loads((Path(sessions_dir) / f"{pid}.json").read_text())
        except (OSError, ValueError):
            return block
        if not isinstance(data, dict) or str(data.get("procStart")) != str(info["start"]):
            return block
        sid = data.get("sessionId")
        if isinstance(sid, str) and UUID_RE.match(sid):
            block["session_id"] = sid
        for field in ("name", "status"):
            value = data.get(field)
            if isinstance(value, str):
                block[field] = value[:80]
        return block
    return None


def short_cmd(info):
    argv = info.get("argv") or []
    head = Path(argv[0]).name if argv else info["comm"]
    if not SAFE_WORD.match(head):
        head = info["comm"]
    words = [head]
    skip_value = False
    for word in argv[1:]:
        if len(words) == 3:
            break
        if word.startswith("-"):
            skip_value = "=" not in word   # `--flag value`: the value is not a positional word
            continue
        if skip_value:
            skip_value = False
            continue
        if not SAFE_WORD.match(word) or word.startswith(REDACT_PREFIXES) or "://" in word:
            break
        words.append(word)
    return " ".join(words)


def _ignored(info):
    return info["comm"] in IGNORED_COMMS or "mcp" in " ".join(info["argv"]).lower()


def children_for_pane(procs, pane_pid):
    if procs is None:
        return []
    out = []

    def visit(pid, under_claude):
        info = procs.get(pid)
        if info is None or _ignored(info):
            return
        if under_claude and info["comm"] in SHELLS and info["argv"][1:2] == ["-c"]:
            for kid in procs.children(pid):
                visit(kid, False)
            return
        age = procs.age(pid)
        if age is None or age < MIN_CHILD_AGE:
            return
        out.append({"comm": info["comm"], "cmd": short_cmd(info)})
        if info["comm"] == "claude":
            for kid in procs.children(pid):
                visit(kid, True)

    for kid in procs.children(pane_pid):
        visit(kid, False)
    return out


def night_shift(window_name, cwds):
    return "night-shift" in window_name or any("/.claude/worktrees/issue-drain" in c for c in cwds)


def group_windows(rows, procs, sessions_dir):
    windows = {}
    for r in rows:
        w = windows.setdefault(r["window_id"], {
            "window_id": r["window_id"], "session": r["session"], "index": r["window_index"],
            "name": r["window_name"], "automatic_rename": r["automatic_rename"],
            "layout": r["layout"], "server_pid": r["server_pid"],
            "server_start": r["server_start"], "panes": [],
        })
        if w["session"] != r["session"]:
            continue   # a linked window listed again under another session: first wins
        w["panes"].append({
            "pane_id": r["pane_id"], "index": r["pane_index"], "cwd": r["cwd"],
            "pid": r["pane_pid"], "command": r["command"],
            "claude": claude_for_pane(procs, r["pane_pid"], sessions_dir),
            "children": children_for_pane(procs, r["pane_pid"]),
        })
    for w in windows.values():
        w["panes"].sort(key=lambda p: p["index"])
        w["night_shift"] = night_shift(w["name"], [p["cwd"] for p in w["panes"]])
    return sorted(windows.values(), key=lambda w: (w["session"], w["index"]))
