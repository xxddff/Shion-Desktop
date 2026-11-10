#!/usr/bin/env python3
"""Checks that the stand-in (fake_shion.py) takes and refuses what the shion plugin does.

Runs the plugin itself (hermes-plugin/shion, without Hermes, as its own tests do) and the
stand-in on the same usage.upload, usage.day, focus.report and settings calls, and compares their
answers: both take it, or both refuse it with the same message. A day's usage has to come back
the same, number for number: apps in several kinds, one app's overlapping stretches, a second
device, a stretch across Tokyo's midnight. A focus report also has to wake the same
way (or say the same reason it did not), and the settings have to come back the same. The plugin
runs in two profiles over one store, as on a server: 詩音's and 通勤's, so a report in the profile
that is not `chief_profile` is `wrong_profile` on both sides. Run it after changing either; no CI
step runs it.

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

    def __init__(self, profile_name="shion"):
        self.profile_name = profile_name
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


def summary(method, result):
    """What has to be the same in an answer, beyond taking the call."""
    if method == "focus.report":
        return f"ok woke={result.get('woke')} reason={result.get('reason')}"
    if method.startswith("settings."):
        return "ok " + json.dumps(result.get("settings"), sort_keys=True)
    if method == "usage.day":
        return "ok " + json.dumps(result, sort_keys=True, ensure_ascii=False, default=str)
    return "ok"


def plugin_answer(ctx, method, params):
    try:
        return summary(method, ctx.rpc[method](dict(params, profile=ctx.profile_name), session_id=None))
    except ShionError as error:
        return f"refused: {error}"


def stand_in_answer(method, params, profile):
    conn = Conn()
    fake_shion.handle(conn, lambda *_: None, "plugin.shion." + method, dict(params, profile=profile), 1)
    reply = next(frame for frame in conn.sent if frame.get("id") == 1)
    if "result" in reply:
        return summary(method, reply["result"])
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

    # a day of the plugin's (its time zone is Tokyo's): today, yesterday, and a stretch across midnight
    tokyo_now = now.astimezone(fake_shion.TOKYO)
    today = tokyo_now.date().isoformat()
    yesterday = (tokyo_now - timedelta(days=1)).date().isoformat()
    midnight = tokyo_now.replace(hour=0, minute=0, second=0)

    def app(bundle, name, start, end, **changes):
        return segment(bundle_id=bundle, app_name=name, start=start, end=end, **changes)

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
        # apps of several kinds; LINE over Safari; Safari again over itself (once); Notion on an iPad too
        ("usage.upload", {"segments": [app("notion.id", "Notion", at(-90), at(-60)),
                                       app("com.apple.Safari", "Safari", at(-60), at(-45)),
                                       app("jp.naver.line.mac", "LINE", at(-50), at(-41)),
                                       app("com.example.unknown", "Some App", at(-41), at(-40))]}),
        ("usage.upload", {"segments": [app("com.apple.Safari", "Safari", at(-55), at(-50))]}),
        ("usage.upload", {"segments": [app("notion.id", "Notion", at(-80), at(-70))], "device": "ipad"}),
        ("usage.upload", {"segments": [app("com.spotify.client", "Spotify",
                                           (midnight - timedelta(minutes=20)).isoformat(),
                                           min(midnight + timedelta(minutes=20), tokyo_now).isoformat())]}),
        ("usage.day", {}),
        ("usage.day", {"date": today}),
        ("usage.day", {"date": f" {today} "}),
        ("usage.day", {"date": yesterday}),
        ("usage.day", {"date": None}),
        ("usage.day", {"date": "2026-02-30"}),
        ("usage.day", {"date": "2026/11/09"}),
        ("usage.day", {"date": "2026-11-09T09:00"}),
        ("usage.day", {"date": 20261109}),
        ("usage.day", {"day": today}),
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
        # who the plugin wakes: chief_profile, one setting for every profile
        ("settings.get", {}),
        ("settings.get", {"chief_profile": "commute"}),
        ("settings.update", {}),
        ("settings.update", {"chief": "commute"}),
        ("settings.update", {"chief_profile": "Commute"}),
        ("settings.update", {"chief_profile": "-commute"}),
        ("settings.update", {"chief_profile": ""}),
        ("settings.update", {"chief_profile": 5}),
        ("settings.update", {"chief_profile": "c" * 65}),
        ("settings.update", {"timezone": "Mars/Olympus"}),
        ("settings.update", {"timezone": "  "}),
        ("settings.update", {"usage_retention_days": 0}),
        ("settings.update", {"focus_retention_days": 91}),
        ("settings.update", {"focus_retention_days": True}),
        ("settings.update", {"usage_retention_days": 60, "timezone": " Asia/Tokyo "}),
        ("focus.report", focus, "commute"),
        ("settings.update", {"chief_profile": "commute"}),
        ("focus.report", focus),
        ("focus.report", focus, "commute"),
        ("focus.report", dict(focus, off_minutes=1441), "commute"),
        ("settings.get", {}, "commute"),
        ("settings.update", {"chief_profile": "shion"}, "commute"),
        ("focus.report", focus),
        ("focus.report", focus, "commute"),
    ]
    with tempfile.TemporaryDirectory() as folder:
        store = Store(Path(folder) / "shion.db")
        plugins = {}
        for profile in ("shion", "commute"):
            ctx = Ctx(profile)
            ShionPlugin(ctx, hermes=Hermes, store=store).register()
            plugins[profile] = ctx
            # each Bot Chat has had a turn: the plugin's hook has its routing key, as the stand-in assumes
            store.remember_session_key(profile=profile, session_id=f"sess-{profile}", session_key=f"key-{profile}",
                                       platform="local")
        mismatches = 0
        for case in cases:
            method, params, profile = case if len(case) == 3 else (*case, "shion")
            real = plugin_answer(plugins[profile], method, params)
            fake = stand_in_answer(method, params, profile)
            same = real == fake
            mismatches += not same
            shown = json.dumps(params, ensure_ascii=False)
            where = "" if profile == "shion" else f" in {profile}"
            print(f"{'same' if same else 'DIFF'}  {method}{where} {shown[:80]}{'…' if len(shown) > 80 else ''}  → {real[:60]}")
            if not same:
                print(f"      plugin:   {real}\n      stand-in: {fake}")
    print(f"{len(cases) - mismatches} of {len(cases)} the same")
    return 1 if mismatches else 0


if __name__ == "__main__":
    os.environ.setdefault("SHION_DATA_DIR", tempfile.gettempdir())
    sys.exit(main())
