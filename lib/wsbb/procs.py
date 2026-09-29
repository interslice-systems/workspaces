"""A snapshot of /proc: the ppid tree, argv, and process age."""
import os
from pathlib import Path


class ProcTable:
    def __init__(self, root):
        self.root = Path(root)
        self.clk = os.sysconf("SC_CLK_TCK")
        self.uptime = float((self.root / "uptime").read_text().split()[0])
        self.procs = {}
        self.kids = {}
        for entry in self.root.iterdir():
            if not entry.name.isdigit():
                continue
            info = self._read(entry)
            if info is None:
                continue
            pid = int(entry.name)
            self.procs[pid] = info
            self.kids.setdefault(info["ppid"], []).append(pid)
        for pids in self.kids.values():
            pids.sort()

    @staticmethod
    def _read(entry):
        try:
            stat = (entry / "stat").read_text()
            raw = (entry / "cmdline").read_bytes()
        except OSError:
            return None
        lpar, rpar = stat.find("("), stat.rfind(")")
        if lpar < 0 or rpar < lpar:
            return None
        rest = stat[rpar + 2:].split()
        try:
            ppid, start = int(rest[1]), int(rest[19])   # fields 4 and 22
        except (IndexError, ValueError):
            return None
        argv = [a.decode("utf-8", "replace") for a in raw.split(b"\0") if a]
        return {"comm": stat[lpar + 1:rpar], "ppid": ppid, "start": start, "argv": argv}

    def get(self, pid):
        return self.procs.get(pid)

    def children(self, pid):
        return list(self.kids.get(pid, []))

    def descendants(self, pid):
        out, queue = [], self.children(pid)
        while queue:
            p = queue.pop(0)
            out.append(p)
            queue.extend(self.children(p))
        return out

    def age(self, pid):
        info = self.procs.get(pid)
        return None if info is None else self.uptime - info["start"] / self.clk
