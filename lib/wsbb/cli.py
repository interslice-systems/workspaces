"""ws-blackbox: record tmux windows and their Claude sessions; restore what disappeared."""
import argparse
import sys
import time

from . import ledger as ledger_mod
from . import observe, paths, state
from .procs import ProcTable


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
