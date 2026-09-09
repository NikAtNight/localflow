#!/usr/bin/env python3
"""Launch the installed local app and wait for its new model-load trace."""
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import time


class Readiness:
    def __init__(self):
        self.session = False
        self.trace = None

    def consume(self, line):
        if "timing_environment " in line:
            try:
                environment = json.loads(line.split("timing_environment ", 1)[1])
            except ValueError:
                return None
            self.session = isinstance(environment.get("pid"), str)
            self.trace = None
        if not self.session:
            return None
        if "model load failed:" in line:
            return (False, "Model preparation failed. Check the local app menu for details.")
        if "timing {" not in line:
            return None
        try:
            event = json.loads(line.split("timing ", 1)[1])
        except ValueError:
            return None
        if event.get("source") != "modelLoad":
            return None
        if event.get("name") == "modelLoadRequested":
            self.trace = event.get("traceID")
        if not self.trace or event.get("traceID") != self.trace:
            return None
        if event.get("name") == "modelLoadFinished":
            if event.get("status") in ("success", "warm"):
                seconds = event["sinceStartMs"] / 1000
                return (True, f"Speech recognition ready. Model load: {seconds:.2f}s.")
            if event.get("status") in ("failed", "cancelled"):
                return (False, "Model preparation failed or was cancelled. Check the local app menu.")
        return None


def main():
    path = Path.home() / "Library/Logs/LocalFlow-Local-diag.log"
    path.parent.mkdir(parents=True, exist_ok=True)
    offset = path.stat().st_size if path.exists() else 0
    inode = path.stat().st_ino if path.exists() else None
    pending = b""
    readiness = Readiness()
    watched_fd = None
    directory_fd = os.open(path.parent, os.O_RDONLY)
    queue = select.kqueue()
    queue.control([select.kevent(directory_fd, filter=select.KQ_FILTER_VNODE,
                                flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                                fflags=select.KQ_NOTE_WRITE)], 0, 0)
    started = time.monotonic()
    deadline = started + 330
    try:
        subprocess.run(["open", "/Applications/LocalFlow Local.app"], check=True)
        print("Preparing speech recognition for this Mac. Waiting for the app...", flush=True)
        while True:
            if path.exists():
                current = path.stat()
                if current.st_ino != inode or current.st_size < offset:
                    offset, pending = 0, b""
                    readiness = Readiness()
                if watched_fd is None or current.st_ino != inode:
                    if watched_fd is not None:
                        os.close(watched_fd)
                    watched_fd = os.open(path, os.O_RDONLY)
                    queue.control([select.kevent(watched_fd, filter=select.KQ_FILTER_VNODE,
                                                flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                                                fflags=select.KQ_NOTE_WRITE | select.KQ_NOTE_DELETE)], 0, 0)
                inode = current.st_ino
                with path.open("rb") as log:
                    log.seek(offset)
                    pending += log.read()
                    offset = log.tell()
                lines = pending.split(b"\n")
                pending = lines.pop()
                for line in lines:
                    result = readiness.consume(line.decode("utf-8", errors="replace"))
                    if result:
                        success, message = result
                        print(message, flush=True)
                        if success:
                            print("Microphone and Accessibility permissions are still required for dictation.")
                        return 0 if success else 1
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                print("Timed out waiting for model readiness. Check the local app menu and diagnostics.", file=sys.stderr)
                return 1
            if not queue.control(None, 2, min(5, remaining)):
                print(f"Preparing speech recognition... {int(time.monotonic() - started)}s elapsed", flush=True)
    finally:
        queue.close()
        os.close(directory_fd)
        if watched_fd is not None:
            os.close(watched_fd)


if __name__ == "__main__":
    sys.exit(main())
