"""Rebuild what disappeared. Types resume lines; never presses Enter."""
import json
import os
import re
import subprocess
import time

from . import ledger as L
from . import observe, paths, state, typed
from .tmuxctl import Tmux, TmuxError

SHELL_WAIT = 5.0


def current_server(tmux):
    pid, start = tmux("display-message", "-p", "#{pid} #{start_time}").split()
    return int(pid), int(start)


def wait_for_shell(tmux, pane_id, timeout=SHELL_WAIT):
    deadline = time.monotonic() + timeout
    while True:
        try:
            cmd = tmux("display-message", "-p", "-t", pane_id, "#{pane_current_command}").strip()
        except TmuxError:
            cmd = ""
        if cmd in observe.SHELLS:
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.2)


def type_line(tmux, pane_id, line):
    if not tmux.dry_run and not wait_for_shell(tmux, pane_id):
        return False
    tmux("send-keys", "-t", pane_id, "-l", "--", line, mutate=True)
    return True


def lines_for(entry):
    out = []
    for pane in entry["panes"]:
        try:
            line = typed.resume_line(pane, entry.get("night_shift"), paths.claude_dir(), paths.proc_root())
            out.append((line, None))
        except typed.Refused as why:
            out.append((None, f"{entry['name']} {pane['pane_id']}: {why}"))
    return out


def create_window(tmux, entry):
    session = entry["session"]
    try:
        tmux("has-session", "-t", "=" + session)
    except TmuxError:
        raise typed.Refused(f"session {session} is not running; restore the workspace instead")
    taken = {int(x) for x in tmux("list-windows", "-t", "=" + session, "-F", "#{window_index}").split()}
    target = f"={session}:{entry['index']}" if entry["index"] not in taken else f"={session}:"
    out = tmux("new-window", "-d", "-P", "-F", "#{window_id} #{pane_id}", "-t", target,
               "-c", entry["panes"][0]["cwd"], mutate=True).split()
    if tmux.dry_run:
        out = ["@dry", "%dry0"]
    return out[0], [out[1]]


def finish_window(tmux, entry, window_id, pane_ids):
    for n, pane in enumerate(entry["panes"][1:], start=1):
        out = tmux("split-window", "-d", "-t", window_id, "-c", pane["cwd"], "-P", "-F", "#{pane_id}",
                   mutate=True).strip()
        pane_ids.append(out or f"%dry{n}")
    if len(entry["panes"]) > 1 and entry.get("layout"):
        try:
            tmux("select-layout", "-t", window_id, entry["layout"], mutate=True)
        except TmuxError:
            pass
    if not entry.get("automatic_rename"):
        tmux("rename-window", "-t", window_id, "--", entry["name"], mutate=True)
    notes = []
    for (line, note), pane_id in zip(lines_for(entry), pane_ids):
        if note:
            notes.append(note)
        elif line and not type_line(tmux, pane_id, line):
            notes.append(f"{entry['name']}: pane not ready; type it yourself: {line}")
    return notes


def _load_for_restore(d):
    led, problem = state.load_ledger(d, int(time.time()), repair=False)
    if problem:
        raise typed.Refused("ledger unreadable")
    return led


def restore_window(key, dry_run=False):
    d = state.ensure_state_dir()
    tmux = Tmux(dry_run)
    with state.locked(d):
        led = _load_for_restore(d)
        entry = led["windows"].get(key)
        if entry is None:
            raise typed.Refused("no such entry")
        if entry.get("restored_to"):
            raise typed.Refused("already restored")
        if not entry.get("panes"):
            raise typed.Refused("entry has no panes")
        rows, error = observe.observe_now()
        if error:
            raise typed.Refused("tmux query failed")
        boot = observe.boot8(paths.boot_id_file())
        if key in L.live_keys(boot, rows):
            raise typed.Refused("window is still open")
        window_id, pane_ids = create_window(tmux, entry)
        if not dry_run:
            pid, start = current_server(tmux)
            entry["restored_to"] = L.window_key(boot, pid, start, window_id)
            state.atomic_write_json(d / state.LEDGER, led)
    notes = finish_window(tmux, entry, window_id, pane_ids)
    if not dry_run:
        with state.locked(d):
            led = _load_for_restore(d)
            led["windows"].pop(key, None)
            state.atomic_write_json(d / state.LEDGER, led)
    return notes, tmux.log


def restore_pane(key, pane_id, dry_run=False):
    d = state.ensure_state_dir()
    tmux = Tmux(dry_run)
    led = _load_for_restore(d)
    entry = led["windows"].get(key)
    if entry is None:
        raise typed.Refused("no such entry")
    pane = next((p for p in entry["panes"] if p["pane_id"] == pane_id), None)
    if pane is None:
        raise typed.Refused("no such pane in that window")
    try:
        pid, start, window_id, command = tmux(
            "display-message", "-p", "-t", pane_id,
            "#{pid} #{start_time} #{window_id} #{pane_current_command}").split(maxsplit=3)
    except (TmuxError, ValueError):
        raise typed.Refused("pane is gone; restore the window instead")
    if L.window_key(observe.boot8(paths.boot_id_file()), pid, start, window_id) != key:
        raise typed.Refused("that pane id now belongs to another window")
    if command.strip() not in observe.SHELLS:
        raise typed.Refused("pane is busy (not at a shell prompt)")
    line = typed.resume_line(pane, entry.get("night_shift"), paths.claude_dir(), paths.proc_root())
    if line is None:
        raise typed.Refused("no Claude session recorded for this pane")
    if not dry_run and not state.claim(d, f"pane:{key}:{pane_id}"):
        raise typed.Refused("restore was just requested for this pane")
    if not type_line(tmux, pane_id, line):
        raise typed.Refused(f"pane not ready; type it yourself: {line}")
    return [], tmux.log


# --- workspace restore -------------------------------------------------------------
# The terminal (and any tmux server it starts) must be Hyprland's child, so it lands in
# wayland-wm@hyprland.desktop.service whoever ran the restore. Only an integer id and a
# 16-hex restore id pass through the Lua string; everything else rides in a 0600 record.
SAFE_PATH = re.compile(r"^[A-Za-z0-9._/-]+$")
RESTORE_ID = re.compile(r"^[0-9a-f]{16}$")


def hypr_workspaces():
    res = observe.run(["hyprctl", "workspaces", "-j"])
    if res.returncode != 0:
        raise typed.Refused("hyprctl workspaces failed")
    try:
        data = json.loads(res.stdout)
    except ValueError:
        raise typed.Refused("hyprctl workspaces: bad json")
    return [w for w in data if isinstance(w, dict) and isinstance(w.get("id"), int)]


def choose_workspace_id(name, recorded, workspaces):
    if any(w.get("name") == name for w in workspaces):
        raise typed.Refused(f"workspace '{name}' is already open")
    used = {w["id"] for w in workspaces}
    if isinstance(recorded, int) and 1 <= recorded <= 10 and recorded not in used:
        return recorded
    for i in range(1, 11):
        if i not in used:
            return i
    raise typed.Refused("no free workspace id between 1 and 10")


def spawn_dispatch(ws_id, self_path, restore_id):
    if not SAFE_PATH.match(str(self_path)):
        raise typed.Refused("ws-blackbox is installed at a path with unusual characters")
    if not RESTORE_ID.match(restore_id):
        raise ValueError("restore id must be 16 hex digits")
    return f'hl.dsp.exec_cmd("[workspace {int(ws_id)} silent] {self_path} _spawn {restore_id}")'


def spawn_argv(record):
    argv = ["xdg-terminal-exec", "--", "tmux", "new-session", "-A", "-s", record["name"]]
    if not record.get("attach_only"):
        argv += ["-c", record.get("cwd") or os.path.expanduser("~")]
        if record.get("window_name"):
            argv += ["-n", record["window_name"]]
    return argv + [";", "set-option", "detach-on-destroy", "on"]


def _lib_call(func, *args):
    return subprocess.run(["bash", "-c", f'source "$1" && shift && {func} "$@"', "_",
                           str(paths.identity_lib()), *map(str, args)],
                          capture_output=True, text=True, timeout=10)


def _wait(predicate, timeout):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if predicate():
            return True
        time.sleep(0.25)
    return False


def _has_session(tmux, name):
    try:
        tmux("has-session", "-t", "=" + name)
        return True
    except TmuxError:
        return False


def restore_workspace(name, dry_run=False):
    d = state.ensure_state_dir()
    now = int(time.time())
    tmux = Tmux(dry_run)
    if not name or typed.CONTROL_RE.search(name):
        raise typed.Refused("bad workspace name")
    led = _load_for_restore(d)
    rows, error = observe.observe_now()
    if error:
        raise typed.Refused("tmux query failed")
    boot = observe.boot8(paths.boot_id_file())
    live = L.live_keys(boot, rows)
    ghosts = sorted((k for k in L.ghost_keys(led, live)
                     if (led["windows"][k].get("workspace") or {}).get("name") == name),
                    key=lambda k: led["windows"][k]["index"])
    session_live = any(r["session"] == name for r in rows or [])
    if not ghosts and not session_live:
        raise typed.Refused(f"nothing recorded for '{name}'")
    ws_id = choose_workspace_id(name, (led["workspaces"].get(name) or {}).get("id"), hypr_workspaces())
    reject = _lib_call("wsid_reject_name", name, ws_id)
    if reject.returncode == 0:
        raise typed.Refused(reject.stdout.strip() or "name refused")
    first = None if session_live else led["windows"][ghosts[0]]
    record = {"name": name, "attach_only": session_live,
              "cwd": first["panes"][0]["cwd"] if first and first.get("panes") else None,
              "window_name": first["name"] if first and not first.get("automatic_rename") else None}
    restore_id = os.urandom(8).hex()
    dispatch = spawn_dispatch(ws_id, paths.self_path(), restore_id)
    if dry_run:
        return [], [["hyprctl", "dispatch", dispatch]]
    if not state.claim(d, f"workspace:{name}"):
        raise typed.Refused(f"restore was just requested for '{name}'")
    for old in d.glob("spawn-*.json"):
        if now - old.stat().st_mtime > 3600:
            old.unlink(missing_ok=True)
    state.atomic_write_json(d / f"spawn-{restore_id}.json", record)
    res = observe.run(["hyprctl", "dispatch", dispatch])
    if res.returncode != 0 or res.stdout.strip() != "ok":
        raise typed.Refused("Hyprland refused to launch the terminal")
    if not _wait(lambda: _has_session(tmux, name), 10):
        raise typed.Refused("the terminal did not bring up the session within 10 s")
    _wait(lambda: any(w["id"] == ws_id for w in hypr_workspaces()), 5)
    notes = []
    _lib_call("wsid_rename_workspace", ws_id, name)
    if not any(w["id"] == ws_id and w.get("name") == name for w in hypr_workspaces()):
        notes.append(f"workspace {ws_id} could not be renamed to '{name}'")
    if session_live:
        return notes, tmux.log
    window_id, index, pane_id = tmux("list-windows", "-t", "=" + name, "-F",
                                     "#{window_id} #{window_index} #{pane_id}").split()[:3]
    taken = {int(x) for x in tmux("list-windows", "-t", "=" + name, "-F", "#{window_index}").split()}
    if int(index) != first["index"] and first["index"] not in taken:
        tmux("move-window", "-s", window_id, "-t", f"={name}:{first['index']}", mutate=True)
    with state.locked(d):
        led = _load_for_restore(d)
        pid, start = current_server(tmux)
        if ghosts[0] in led["windows"]:
            led["windows"][ghosts[0]]["restored_to"] = L.window_key(boot, pid, start, window_id)
            state.atomic_write_json(d / state.LEDGER, led)
    notes += finish_window(tmux, first, window_id, [pane_id])
    with state.locked(d):
        led = _load_for_restore(d)
        led["windows"].pop(ghosts[0], None)
        state.atomic_write_json(d / state.LEDGER, led)
    for key in ghosts[1:]:
        try:
            more, _ = restore_window(key)
            notes += more
        except typed.Refused as why:
            notes.append(f"{key}: {why}")
    return notes, tmux.log
