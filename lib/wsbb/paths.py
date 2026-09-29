"""Every location ws-blackbox touches. Each one is overridable by env so tests stay hermetic."""
import os
from pathlib import Path


def _env_path(name, default):
    value = os.environ.get(name)
    return Path(value) if value else Path(default)


def state_dir_path():
    return _env_path("WS_BLACKBOX_STATE", Path.home() / ".local/state/ws-blackbox")


def proc_root():
    return _env_path("WS_BLACKBOX_PROC", "/proc")


def claude_dir():
    return _env_path("WS_BLACKBOX_CLAUDE_DIR", Path.home() / ".claude")


def clients_cmd():
    return str(_env_path("WS_BLACKBOX_CLIENTS", Path.home() / ".local/bin/tmux-local-clients"))


def boot_id_file():
    return _env_path("WS_BLACKBOX_BOOT_ID", "/proc/sys/kernel/random/boot_id")


def identity_lib():
    return _env_path("WS_BLACKBOX_IDENTITY_LIB", Path.home() / ".local/lib/workspace-identity-lib")


def self_path():
    return _env_path("WS_BLACKBOX_SELF", Path.home() / ".local/bin/ws-blackbox")
