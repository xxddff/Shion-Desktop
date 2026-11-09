"""Wires the store to Hermes: RPC methods, tools, the session-key hook, the focus wake-up and push events.

Everything Hermes-specific comes in through ``ctx`` or the ``hermes`` adapter, so tests can run the
plugin without Hermes installed.
"""

from __future__ import annotations

import logging
import os
from pathlib import Path
from typing import Any, Callable, Optional

from . import rpc, tools
from .errors import ShionError
from .store import Store
from .watcher import ChangeWatcher

logger = logging.getLogger(__name__)

DB_FILENAME = "shion.db"
ACTIVITY_LABELS = {"study": "学习", "work": "工作", "life": "生活", "fun": "娱乐", "social": "社交", "other": "别的事"}


class HermesAdapter:
    """The few Hermes functions the plugin calls outside ``ctx``; all are on Hermes' public plugin API
    (``hermes_cli/data/plugin_api.json``). Imported lazily so the module loads without Hermes."""

    @staticmethod
    def data_dir() -> Path:
        override = os.environ.get("SHION_DATA_DIR", "").strip()
        if override:
            return Path(override).expanduser()
        # The shared root, not the profile's home: every profile reads and writes one store, the way
        # the kanban board is shared (hermes_cli/kanban_db.py: kanban_home).
        from hermes_constants import get_default_hermes_root
        return get_default_hermes_root() / "plugin-data" / "shion"

    @staticmethod
    def broadcast(plugin_id: str, event: str, payload: dict) -> None:
        from hermes_cli.plugin_events import broadcast_plugin_event
        broadcast_plugin_event(plugin_id, event, payload)

    @staticmethod
    def session_env(name: str) -> str:
        from gateway.session_context import get_session_env
        return get_session_env(name, "")


def focus_message(plan: str, off_minutes: int, activity: str, on_track: bool) -> str:
    if on_track:
        return f"［专注检查］已经回到「{plan}」上了。"
    return f"［专注检查］「{plan}」：已经偏离 {off_minutes} 分钟，现在在做{ACTIVITY_LABELS[activity]}。"


class ShionPlugin:
    def __init__(self, ctx, *, hermes: Any = HermesAdapter, store: Optional[Store] = None,
                 watch_interval: float = 1.0):
        self.ctx = ctx
        self.hermes = hermes
        self.store = store or Store(hermes.data_dir() / DB_FILENAME)
        self.watcher = ChangeWatcher(self.store, self._emit_change, interval=watch_interval)
        self._seen_keys: dict[str, str] = {}

    # -- identity ----------------------------------------------------------------------------

    def profile(self) -> str:
        try:
            name = self.ctx.profile_name
        except Exception:
            name = None
        return name or "default"

    # -- registration ------------------------------------------------------------------------

    def register(self) -> None:
        for name, handler in rpc.methods(self).items():
            self.ctx.register_rpc(name, _rpc_entry(name, handler))
        handlers = tools.handlers(self)
        for name, schema in tools.SCHEMAS.items():
            self.ctx.register_tool(name=name, toolset=tools.TOOLSET, schema=schema, handler=handlers[name])
        self.ctx.register_hook("pre_llm_call", self.on_pre_llm_call)
        self.ctx.on_unload(self.watcher.stop)

    # -- push events -------------------------------------------------------------------------

    def ensure_watcher(self) -> None:
        """Started by the first RPC call: only the gateway process serves RPC, and only it can reach the Mac."""
        self.watcher.start()

    def _emit_change(self, payload: dict) -> None:
        self.hermes.broadcast(self.ctx.plugin_id, "changed", payload)

    # -- session keys ------------------------------------------------------------------------

    def on_pre_llm_call(self, session_id: str = "", platform: str = "", **kwargs) -> None:
        """Remember each session's routing key: ``inject_message`` needs it, and the RPC that asks to wake
        the chief only knows the session id. Never changes the turn."""
        try:
            key = self.hermes.session_env("HERMES_SESSION_KEY")
            if not key or not session_id or self._seen_keys.get(session_id) == key:
                return None
            surface = self.hermes.session_env("HERMES_SESSION_PLATFORM") or platform or ""
            self.store.remember_session_key(profile=self.profile(), session_id=session_id, session_key=key,
                                            platform=surface)
            self._seen_keys[session_id] = key
        except Exception:
            logger.debug("shion: could not record the session key", exc_info=True)
        return None

    # -- focus check -------------------------------------------------------------------------

    def focus_report(self, p: dict, *, session_id: Optional[str]) -> dict:
        report, report_id, revision = self.store.add_focus(
            plan=p["plan"], off_minutes=p["off_minutes"], activity=p["activity"], on_track=p["on_track"])
        chief = self.store.settings()["chief_profile"]
        result = {"recorded": True, "latest": report, "revision": revision, "woke": False}
        if self.profile() != chief:
            result["reason"] = "wrong_profile"
            return result
        key = self.store.session_key_for(profile=chief, session_id=session_id)
        if key is None:
            result["reason"] = "no_session_key"
            return result
        text = focus_message(report["plan"], report["off_minutes"], report["activity"], report["on_track"])
        try:
            woke = bool(self.ctx.inject_message(text, role="user", session_key=key))
        except Exception:
            logger.warning("shion: inject_message failed", exc_info=True)
            woke = False
        if woke:
            self.store.mark_focus_woke(report_id)
            result["latest"] = {**report, "woke": True}
        else:
            result["reason"] = "inject_refused"
        result["woke"] = woke
        return result


def _rpc_entry(name: str, handler: Callable) -> Callable:
    """Hermes calls ``handler(params, *, session_id, **kwargs)``; ours take params (and session_id when
    they need it)."""
    wants_session = name == "focus.report"

    def entry(params, *, session_id=None, **kwargs):
        if wants_session:
            return handler(params, session_id=session_id)
        return handler(params)
    entry.__name__ = f"shion_rpc_{name.replace('.', '_')}"
    return entry


__all__ = ["ShionPlugin", "ShionError", "HermesAdapter", "focus_message"]
