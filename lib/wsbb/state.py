"""State directory, atomic JSON writes, ledger load/repair, and the single-writer lock."""
import contextlib
import copy
import fcntl
import json
import os
import tempfile
import time
from pathlib import Path

from . import paths

LEDGER = "ledger.json"
HEARTBEAT = "heartbeat.json"
EMPTY_LEDGER = {"version": 1, "windows": {}, "workspaces": {}}


class LockTimeout(Exception):
    pass


def ensure_state_dir():
    d = paths.state_dir_path()
    d.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(d, 0o700)
    return d


def atomic_write_json(path, obj):
    path = Path(path)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix="." + path.name + ".")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(obj, fh, ensure_ascii=False, indent=1, sort_keys=True)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(tmp)
        raise
    dfd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)


def read_json(path, default):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError:
        return default


def _valid(data):
    return (isinstance(data, dict) and data.get("version") == 1
            and isinstance(data.get("windows"), dict)
            and isinstance(data.get("workspaces"), dict))


def load_ledger(directory, now, repair):
    path = Path(directory) / LEDGER
    try:
        data = read_json(path, None)
    except (ValueError, UnicodeDecodeError):
        data = False
    if data is None:
        return copy.deepcopy(EMPTY_LEDGER), None
    if not _valid(data):
        if repair:
            os.replace(path, path.with_name(f"{LEDGER}.corrupt-{int(now)}"))
        return copy.deepcopy(EMPTY_LEDGER), "ledger-corrupt"
    return data, None


@contextlib.contextmanager
def locked(directory, timeout=15.0):
    fd = os.open(Path(directory) / "lock", os.O_RDWR | os.O_CREAT, 0o600)
    try:
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise LockTimeout(f"state lock busy for {timeout:.1f}s")
                time.sleep(0.05)
        yield
    finally:
        os.close(fd)
