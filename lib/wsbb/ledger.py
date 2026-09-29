"""Pure ledger operations. The ledger is every window ever seen and not dismissed."""
import copy

LAST_SEEN_PERSIST = 600


def window_key(boot8, server_pid, server_start, window_id):
    return f"{boot8}:{server_pid}:{server_start}:{window_id}"


def live_keys(boot8, rows):
    return {window_key(boot8, r["server_pid"], r["server_start"], r["window_id"]) for r in rows or []}


def _without_seen(entry):
    e = copy.deepcopy(entry)
    e.pop("last_seen", None)
    for pane in e.get("panes", []):
        if isinstance(pane.get("claude"), dict):
            pane["claude"].pop("last_seen", None)
    return e


def merge_claude(old, new, now):
    if new is None:
        return old
    if new.get("session_id") is None and old and old.get("pid") == new.get("pid"):
        return old
    merged = dict(new)
    if merged.get("session_id") is None and old and old.get("session_id"):
        # A new claude whose presence file can't be joined (yet, or ever) keeps the known
        # identity; only a DIFFERENT valid session id replaces it.
        merged["session_id"] = old["session_id"]
        merged["name"] = merged.get("name") or old.get("name")
    merged["last_seen"] = now
    return merged


def upsert(ledger, obs, now):
    changed = False
    clients = obs.get("clients")
    for w in obs["windows"]:
        key = window_key(obs["boot8"], w["server_pid"], w["server_start"], w["window_id"])
        old = ledger["windows"].get(key)
        old_panes = {p["pane_id"]: p for p in (old or {}).get("panes", [])}
        workspace = clients.get(w["session"]) if clients else None
        if workspace is None and old:
            workspace = old.get("workspace")
        candidate = {
            "server": {"boot_id": obs["boot8"], "pid": w["server_pid"], "start": w["server_start"]},
            "window_id": w["window_id"], "workspace": workspace, "session": w["session"],
            "index": w["index"], "name": w["name"], "automatic_rename": w["automatic_rename"],
            "layout": w["layout"], "night_shift": w["night_shift"],
            "first_seen": old["first_seen"] if old else now, "last_seen": now,
            "restored_to": old.get("restored_to") if old else None,
            "panes": [{
                "pane_id": p["pane_id"], "index": p["index"], "cwd": p["cwd"], "pid": p["pid"],
                "claude": merge_claude(old_panes.get(p["pane_id"], {}).get("claude"), p["claude"], now),
                "children": p["children"],
            } for p in w["panes"]],
        }
        if (old is not None and _without_seen(candidate) == _without_seen(old)
                and now - old.get("last_seen", 0) < LAST_SEEN_PERSIST):
            continue
        ledger["windows"][key] = candidate
        changed = True
        if workspace and workspace.get("name"):
            prev = ledger["workspaces"].get(workspace["name"])
            if (prev is None or prev.get("id") != workspace["id"]
                    or now - prev.get("last_seen", 0) >= LAST_SEEN_PERSIST):
                ledger["workspaces"][workspace["name"]] = {"id": workspace["id"], "last_seen": now}
    return changed


def ghost_keys(ledger, live):
    return sorted(k for k, e in ledger["windows"].items()
                  if k not in live and not e.get("restored_to"))


def dismiss_workspace(ledger, name, live):
    removed = 0
    for key in list(ledger["windows"]):
        e = ledger["windows"][key]
        if (e.get("workspace") or {}).get("name") == name and key not in live:
            del ledger["windows"][key]
            removed += 1
    if not any((e.get("workspace") or {}).get("name") == name for e in ledger["windows"].values()):
        ledger["workspaces"].pop(name, None)
    return removed
