"""Turns store revisions into push events.

Writes come from several processes (the gateway, and kanban workers that run as separate
``hermes -p <profile> chat -q`` subprocesses), and an event can only reach the Mac from the gateway
process that holds its ``/api/ws`` connection. So instead of emitting at each write, one thread in the
gateway polls the store's revision and emits whenever it moved, whoever wrote it.
"""

from __future__ import annotations

import logging
import threading
import time
from typing import Callable

logger = logging.getLogger(__name__)

THREAD_NAME = "shion-change-watcher"


class ChangeWatcher:
    def __init__(self, store, emit: Callable[[dict], None], *, interval: float = 1.0,
                 purge_every: float = 3600.0):
        self.store = store
        self.emit = emit
        self.interval = interval
        self.purge_every = purge_every
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._lock = threading.Lock()

    def start(self) -> bool:
        """Start once per process: several profiles each load their own copy of the plugin, and one
        watcher already broadcasts to every connected client."""
        with self._lock:
            if self._thread is not None and self._thread.is_alive():
                return False
            if any(t.name == THREAD_NAME and t.is_alive() for t in threading.enumerate()):
                return False
            self._stop.clear()
            self._thread = threading.Thread(target=self._run, name=THREAD_NAME, daemon=True)
            self._thread.start()
            return True

    def stop(self) -> None:
        self._stop.set()
        thread = self._thread
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout=5)

    def _run(self) -> None:
        last = self._safe(self.store.revision, default=0)
        next_purge = time.monotonic()
        while not self._stop.wait(self.interval):
            if time.monotonic() >= next_purge:
                self._safe(self.store.purge_usage)
                next_purge = time.monotonic() + self.purge_every
            last = self.tick(last)

    def tick(self, last: int) -> int:
        """Emit one event if the revision moved past ``last``; returns the revision now seen."""
        try:
            info = self.store.changes_since(last)
        except Exception:
            logger.warning("shion: reading the store revision failed", exc_info=True)
            return last
        if info["revision"] == last:
            return last
        try:
            self.emit({"revision": info["revision"], "topics": info["topics"], "reset": info["reset"]})
        except Exception:
            logger.warning("shion: change event could not be sent", exc_info=True)
        return info["revision"]

    @staticmethod
    def _safe(fn, default=None):
        try:
            return fn()
        except Exception:
            logger.warning("shion: background step failed", exc_info=True)
            return default
