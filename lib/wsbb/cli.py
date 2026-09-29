"""ws-blackbox: record tmux windows and their Claude sessions; restore what disappeared."""
import argparse
import sys


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
