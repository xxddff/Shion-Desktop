#!/usr/bin/env python3
"""Checks that the stand-in (fake_shion.py) takes and refuses what the shion plugin does.

Runs the plugin itself (hermes-plugin/shion, without Hermes, as its own tests do) and the
stand-in on the same usage.upload and focus.report calls, and compares their answers: both take
it, or both refuse it with the same message. Run it after changing either; no CI step runs it.

    python3 macos/ci/check_fake_shion.py
"""
import json
import os
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parents[1] / "hermes-plugin"))

import fake_shion  # noqa: E402
from shion.errors import ShionError  # noqa: E402
from shion.plugin import ShionPlugin  # noqa: E402
from shion.store import Store  # noqa: E402


class Ctx:
    """The slice of Hermes's PluginContext the plugin uses."""
    plugin_id = "shion"
    profile_name = "shion"

    def __init__(self):
        self.rpc = {}

    def register_rpc(self, name, handler):
        self.rpc[name] = handler

    def register_tool(self, **kwargs):
        pass

    def register_hook(self, name, callback):
        pass

    def on_unload(self, callback):
        pass

    def inject_message(self, content, role="user", *, session_key=None, origin=None):
        return True


class Hermes:
    @staticmethod
    def broadcast(plugin_id, event, payload):
        pass

    @staticmethod
    def session_env(name):
        return ""


class Conn:
    """Collects what the stand-in sends back."""

    def __init__(self):
        self.sent = []

    def send_json(self, value):
        self.sent.append(value)

    def event(self, *args):
        pass


def plugin_answer(ctx, method, params):
    try:
        ctx.rpc[method](dict(params, profile="shion"), session_id=None)
        return "ok"
    except ShionError as error:
        return f"refused: {error}"


def stand_in_answer(method, params):
    conn = Conn()
    fake_shion.handle(conn, lambda *_: None, "plugin.shion." + method, dict(params, profile="shion"), 1)
    reply = next(frame for frame in conn.sent if frame.get("id") == 1)
    if "result" in reply:
        return "ok"
    detail = reply["error"].get("data", {}).get("detail", reply["error"]["message"])
    return "refused: " + detail.removeprefix("ShionError: ")


def main():
    now = datetime.now(timezone.utc).replace(microsecond=0)

    def at(minutes):
        return (now + timedelta(minutes=minutes)).isoformat()

    def segment(**changes):
        seg = {"bundle_id": "com.apple.dt.Xcode", "app_name": "Xcode", "start": at(-40), "end": at(-10)}
        seg.update(changes)
        return {key: value for key, value in seg.items() if value is not None}

    focus = {"plan": "机器学习 课前小测", "off_minutes": 7, "activity": "fun", "on_track": False}
    cases = [
        ("usage.upload", {"segments": [segment()]}),
        ("usage.upload", {"segments": [segment(start=(now - timedelta(minutes=40)).astimezone(
            timezone(timedelta(hours=9))).isoformat())], "device": "mac"}),
        ("usage.upload", {"segments": [segment(start="2026-11-09T09:00:00")]}),
        ("usage.upload", {"segments": [segment(start=at(-40).replace("+00:00", "Z"))]}),
        ("usage.upload", {"segments": [segment(start=(now - timedelta(minutes=40, microseconds=-250000)).isoformat())]}),
        ("usage.upload", {"segments": []}),
        ("usage.upload", {"segments": [segment(title="AppStore.swift")]}),
        ("usage.upload", {"segments": [segment(app_name=None)]}),
        ("usage.upload", {"segments": [segment(bundle_id="  ")]}),
        ("usage.upload", {"segments": [segment(app_name="x" * 256)]}),
        ("usage.upload", {"segments": [segment(start="2026-11-09")]}),
        ("usage.upload", {"segments": [segment(start="yesterday")]}),
        ("usage.upload", {"segments": [segment(start=at(-10))]}),
        ("usage.upload", {"segments": [segment(start=at(-25 * 60))]}),
        ("usage.upload", {"segments": [segment(start=at(-5), end=at(10))]}),
        ("usage.upload", {"segments": [segment(), "Xcode"]}),
        ("usage.upload", {"segments": "Xcode"}),
        ("usage.upload", {"segments": [segment()] * 5001}),
        ("usage.upload", {"segments": [segment()], "device": "m" * 65}),
        ("usage.upload", {"segments": [segment()], "device": 1}),
        ("usage.upload", {"segments": [segment()], "window_titles": ["x"]}),
        ("usage.upload", {}),
        ("focus.report", focus),
        ("focus.report", dict(focus, on_track=True, off_minutes=0, activity="study")),
        ("focus.report", dict(focus, off_minutes=1440)),
        ("focus.report", dict(focus, off_minutes=1441)),
        ("focus.report", dict(focus, off_minutes=-1)),
        ("focus.report", dict(focus, off_minutes=True)),
        ("focus.report", dict(focus, off_minutes=7.0)),
        ("focus.report", dict(focus, activity="gaming")),
        ("focus.report", dict(focus, on_track="no")),
        ("focus.report", dict(focus, plan="  ")),
        ("focus.report", dict(focus, plan="长" * 200)),
        ("focus.report", dict(focus, plan="长" * 201)),
        ("focus.report", dict(focus, title="猫のおもしろ動画まとめ")),
        ("focus.report", {key: value for key, value in focus.items() if key != "plan"}),
    ]
    with tempfile.TemporaryDirectory() as folder:
        ctx = Ctx()
        ShionPlugin(ctx, hermes=Hermes, store=Store(Path(folder) / "shion.db")).register()
        mismatches = 0
        for method, params in cases:
            real = plugin_answer(ctx, method, params)
            fake = stand_in_answer(method, params)
            same = real == fake
            mismatches += not same
            shown = json.dumps(params, ensure_ascii=False)
            print(f"{'same' if same else 'DIFF'}  {method} {shown[:90]}{'…' if len(shown) > 90 else ''}")
            if not same:
                print(f"      plugin:   {real}\n      stand-in: {fake}")
    print(f"{len(cases) - mismatches} of {len(cases)} the same")
    return 1 if mismatches else 0


if __name__ == "__main__":
    os.environ.setdefault("SHION_DATA_DIR", tempfile.gettempdir())
    sys.exit(main())
