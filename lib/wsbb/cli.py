"""ws-blackbox: record tmux windows and their Claude sessions; restore what disappeared."""
import argparse
import os
import shlex
import sys
import time

from . import ledger as ledger_mod
from . import observe, paths, state
from .procs import ProcTable
from .tmuxctl import Forbidden, TmuxError


def _not_yet(args):
    print(f"ws-blackbox {args.command}: not implemented", file=sys.stderr)
    return 2


def build_parser():
    parser = argparse.ArgumentParser(prog="ws-blackbox", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("tick", help="record the current tmux state (run by the timer)")
    sub.add_parser("status", help="is recording active and healthy")
    sub.add_parser("what", help="what disappeared, why, and how to resume it")
    dismiss = sub.add_parser("dismiss", help="forget a gone window or workspace")
    dismiss.add_argument("key", nargs="?")
    dismiss.add_argument("--workspace")
    restore = sub.add_parser("restore", help="rebuild a gone window, pane, or workspace")
    restore.add_argument("key", nargs="?")
    restore.add_argument("--pane", nargs=2, metavar=("KEY", "PANE_ID"))
    restore.add_argument("--workspace")
    restore.add_argument("--dry-run", action="store_true")
    spawn = sub.add_parser("_spawn", help=argparse.SUPPRESS)
    spawn.add_argument("restore_id")
    return parser


HANDLERS = {}


def main(argv):
    args = build_parser().parse_args(argv)
    return HANDLERS.get(args.command, _not_yet)(args)


def cmd_tick(args):
    d = state.ensure_state_dir()
    now = int(time.time())
    partial = []
    try:
        with state.locked(d):
            led, problem = state.load_ledger(d, now, repair=True)
            if problem:
                partial.append(problem)
            rows, error = observe.observe_now()
            if error:
                partial.append("tmux")
            elif rows:
                try:
                    clients = observe.read_clients(paths.clients_cmd())
                except observe.SourceError:
                    clients = None
                    partial.append("clients")
                try:
                    procs = ProcTable(paths.proc_root())
                except OSError:
                    procs = None
                    partial.append("proc")
                sessions = paths.claude_dir() / "sessions"
                obs = {"boot8": observe.boot8(paths.boot_id_file()), "clients": clients,
                       "windows": observe.group_windows(rows, procs, sessions)}
                if ledger_mod.upsert(led, obs, now) or problem:
                    state.atomic_write_json(d / state.LEDGER, led)
            elif problem:
                state.atomic_write_json(d / state.LEDGER, led)
            try:
                prev = state.read_json(d / state.HEARTBEAT, {})
            except ValueError:
                prev = {}
            state.atomic_write_json(d / state.HEARTBEAT, {
                "last_attempt": now,
                "last_full": now if not partial else prev.get("last_full"),
                "partial_sources": partial,
            })
    except state.LockTimeout:
        return 0   # a restore holds the lock; the next minute records
    return 0


HANDLERS["tick"] = cmd_tick


def _ago(seconds):
    s = max(0, int(seconds))
    return f"{s}s" if s < 60 else (f"{s // 60}m" if s < 3600 else f"{s // 3600}h")


def _cgroup(pid):
    try:
        text = (paths.proc_root() / str(pid) / "cgroup").read_text().strip()
    except OSError:
        return "unknown"
    return text.rsplit("/user@", 1)[-1].split("/", 1)[-1] if "/user@" in text else text


def cmd_status(args):
    d = state.ensure_state_dir()
    now = int(time.time())
    try:
        hb = state.read_json(d / state.HEARTBEAT, None)
    except ValueError:
        hb = None
    led, problem = state.load_ledger(d, now, repair=False)
    try:
        timer = observe.run(["systemctl", "--user", "is-active", "ws-blackbox.timer"]).stdout.strip()
    except observe.SourceError:
        timer = ""
    print("ws-blackbox")
    print(f"  timer:       {timer or 'unknown'}")
    healthy = False
    if isinstance(hb, dict) and isinstance(hb.get("last_full"), int):
        age = now - hb["last_full"]
        healthy = age <= 300
        print(f"  last full:   {_ago(age)} ago" + ("" if healthy else "   STALE"))
    else:
        print("  last full:   never")
    if isinstance(hb, dict) and hb.get("partial_sources"):
        print(f"  last try:    partial ({', '.join(hb['partial_sources'])})")
    rows, error = observe.observe_now()
    live = ledger_mod.live_keys(observe.boot8(paths.boot_id_file()), rows) if not error else set()
    gone = len(ledger_mod.ghost_keys(led, live)) if not error else "?"
    print(f"  ledger:      {len(led['windows'])} windows ({gone} gone), "
          f"{len(led['workspaces'])} workspaces" + (" [corrupt]" if problem else ""))
    if rows:
        pid = rows[0]["server_pid"]
        print(f"  tmux server: pid {pid}, cgroup {_cgroup(pid)}")
    else:
        print("  tmux server: " + ("query failed" if error else "not running"))
    return 0 if healthy else 1


def _fmt_time(ts):
    return time.strftime("%Y-%m-%d %H:%M", time.localtime(ts))


def cmd_what(args):
    from . import journal, typed
    d = state.ensure_state_dir()
    now = int(time.time())
    led, _ = state.load_ledger(d, now, repair=False)
    rows, error = observe.observe_now()
    if error:
        print("tmux query failed; cannot tell what is live", file=sys.stderr)
        return 1
    boot = observe.boot8(paths.boot_id_file())
    live = ledger_mod.live_keys(boot, rows)
    commands = {r["pane_id"]: r["command"] for r in rows or []}
    ghosts = ledger_mod.ghost_keys(led, live)
    agent_gone = [k for k in sorted(live & set(led["windows"]))
                  if any(p.get("claude") and p["claude"].get("session_id")
                         and commands.get(p["pane_id"]) in observe.SHELLS
                         for p in led["windows"][k]["panes"])]
    if not ghosts and not agent_gone:
        print("nothing gone")
    since = min([led["windows"][k].get("last_seen", now) for k in ghosts + agent_gone] or [now])
    events = journal.causes(max(since - 60, now - 14 * 86400)) if (ghosts or agent_gone) else []
    by_ws = {}
    for k in ghosts + agent_gone:
        ws = (led["windows"][k].get("workspace") or {}).get("name") or "(no workspace)"
        by_ws.setdefault(ws, []).append(k)
    for ws in sorted(by_ws):
        print(ws)
        for k in sorted(by_ws[ws], key=lambda k: led["windows"][k]["index"]):
            e = led["windows"][k]
            state_word = "gone" if k in ghosts else "agent gone"
            print(f"  {e['index']}·{e['name']}  {state_word} · last seen ~{_fmt_time(e['last_seen'])}")
            pids = set()
            for p in e["panes"]:
                c = p.get("claude") or {}
                kids = " · ".join(ch["cmd"] for ch in p.get("children", []))
                label = f"claude \"{c.get('name')}\" ({c.get('status')})" if c else "no claude"
                print(f"     pane {p['pane_id']}  {label}" + (f"  ·  {kids}" if kids else ""))
                try:
                    line = typed.resume_line(p, e.get("night_shift"), paths.claude_dir(), paths.proc_root())
                    if line:
                        print(f"     resume: {line}")
                except typed.Refused as why:
                    print(f"     resume: refused ({why})")
                pids.update(x for x in (p.get("pid"), c.get("pid")) if x)
            for ev in events:
                if ev.get("pid") in pids or ev["kind"] in ("reboot", "oomd"):
                    detail = " ".join(str(ev[x]) for x in ("signal", "comm", "pid", "unit") if x in ev)
                    print(f"     cause: {ev['kind']} {detail} at {_fmt_time(ev['time'])}")
    if journal.unclean_previous_boot():
        print("previous boot ended uncleanly")
    return 0


HANDLERS["status"] = cmd_status
HANDLERS["what"] = cmd_what


def notify(summary, body):
    if os.environ.get("WS_BLACKBOX_NO_NOTIFY"):
        return
    try:
        observe.run(["notify-send", "-a", "ws-blackbox", summary, body])
    except observe.SourceError:
        pass


def cmd_dismiss(args):
    d = state.ensure_state_dir()
    with state.locked(d):
        led, problem = state.load_ledger(d, int(time.time()), repair=False)
        if problem:
            print("ledger unreadable", file=sys.stderr)
            return 1
        if args.workspace:
            rows, error = observe.observe_now()
            if error:
                print("tmux query failed", file=sys.stderr)
                return 1
            live = ledger_mod.live_keys(observe.boot8(paths.boot_id_file()), rows)
            n = ledger_mod.dismiss_workspace(led, args.workspace, live)
        elif args.key:
            n = 1 if led["windows"].pop(args.key, None) is not None else 0
        else:
            print("dismiss needs a key or --workspace", file=sys.stderr)
            return 2
        state.atomic_write_json(d / state.LEDGER, led)
    print(f"dismissed {n}")
    return 0


def cmd_restore(args):
    from . import restore, typed
    try:
        if args.workspace:
            notes, log = restore.restore_workspace(args.workspace, args.dry_run)
        elif args.pane:
            notes, log = restore.restore_pane(args.pane[0], args.pane[1], args.dry_run)
        elif args.key:
            notes, log = restore.restore_window(args.key, args.dry_run)
        else:
            print("restore needs a key, --pane or --workspace", file=sys.stderr)
            return 2
    except (typed.Refused, TmuxError, Forbidden, state.LockTimeout) as why:
        notify("Restore refused", str(why))
        print(f"refused: {why}", file=sys.stderr)
        return 1
    if args.dry_run:
        for argv in log:
            print(shlex.join(argv))
    for note in notes:
        notify("Restore", note)
        print(note)
    return 0


HANDLERS["dismiss"] = cmd_dismiss
HANDLERS["restore"] = cmd_restore
