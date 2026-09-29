"""Rebuild what disappeared. Types resume lines; never presses Enter."""
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
    if not type_line(tmux, pane_id, line):
        raise typed.Refused(f"pane not ready; type it yourself: {line}")
    return [], tmux.log
