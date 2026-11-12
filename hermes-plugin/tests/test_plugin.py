import json
import time

import pytest

from conftest import FakeCtx
from shion import tools
from shion.errors import ShionError
from shion.plugin import ShionPlugin
from shion.store import USER_SOURCE, Store
from shion.watcher import ChangeWatcher


@pytest.fixture
def make(tmp_path, clock, hermes):
    """One plugin copy per profile, all on the same store file, as on a gateway serving several profiles."""
    path = tmp_path / "shion.db"
    made = []

    def build(profile="shion", inject_result=True):
        ctx = FakeCtx(profile, inject_result)
        plugin = ShionPlugin(ctx, hermes=hermes, store=Store(path, clock=clock), watch_interval=0.05)
        plugin.register()
        made.append(plugin)
        return ctx, plugin
    yield build
    for plugin in made:
        plugin.watcher.stop()


def tool(ctx, name, **args):
    return json.loads(ctx.tools[name](args, task_id="t", session_id="s"))


def test_registers_every_method_tool_and_the_hook(make):
    ctx, _ = make()
    assert set(ctx.rpc) == {
        "info", "sync.state", "changes.since", "settings.get", "settings.update", "todos.list", "todos.get",
        "todos.add", "todos.update", "todos.delete", "today.get", "reports.list", "reports.get", "usage.upload",
        "usage.day", "usage.categories.list", "usage.categories.set", "focus.report", "focus.latest",
        "reviews.list", "reviews.detail", "reviews.bind", "reviews.decide"}
    assert set(ctx.tools) == set(tools.SCHEMAS)
    assert set(ctx.hooks) == {"pre_llm_call", "post_tool_call"}
    assert len(ctx.unload) == 1


def test_manifest_lists_the_registered_tools(make):
    # `hermes plugins validate` fails when provides_tools and the registered tools differ.
    from pathlib import Path
    lines = (Path(__file__).resolve().parents[1] / "shion" / "plugin.yaml").read_text().splitlines()
    start = lines.index("provides_tools:") + 1
    declared = []
    for line in lines[start:]:
        if not line.startswith("  - "):
            break
        declared.append(line[4:].strip())
    ctx, _ = make()
    assert sorted(declared) == sorted(ctx.tools)


def test_rpc_ignores_routing_params_and_refuses_unknown_ones(make):
    ctx, _ = make()
    added = ctx.call("todos.add", {"profile": "shion", "session_id": "s1", "title": "交房租", "area": "life",
                                   "do_at": "2026-11-09T20:00+09:00"}, session_id="s1")
    assert added["todo"]["source"] == USER_SOURCE and added["revision"] == 1
    with pytest.raises(ShionError) as info:
        ctx.call("todos.add", {"title": "x", "area": "life", "colour": "red"})
    assert str(info.value) == "invalid_params: unknown params: colour"
    with pytest.raises(ShionError) as info:
        ctx.call("todos.update", {"title": "x"})
    assert info.value.code == "invalid_params"


def test_todos_over_rpc(make):
    ctx, _ = make()
    todo = ctx.call("todos.add", {"title": "复习", "area": "study", "do_at": "2026-11-10T20:00",
                                  "proposed": True, "id": "mac-1"})["todo"]
    assert ctx.call("todos.list", {"proposed": True})["todos"] == [todo]
    confirmed = ctx.call("todos.update", {"id": "mac-1", "proposed": False})["todo"]
    assert confirmed["proposed"] is False
    assert ctx.call("todos.get", {"id": "mac-1"})["todo"] == confirmed
    assert ctx.call("todos.delete", {"id": "mac-1"}) == {"deleted": "mac-1", "revision": 3}
    assert ctx.call("todos.list")["todos"] == []


def test_an_assistant_adds_a_todo_and_the_app_sees_who(make):
    course, _ = make("course")
    app, _ = make("shion")
    out = tool(course, "shion_todo_add", title="数据结构 作业4", area="study", do_at="2026-11-11T19:00",
               due_at="2026-11-13T23:59", proposed=True, source_detail="数据结构与算法 第7回")
    assert out["todo"]["source"] == "course"
    listed = app.call("todos.list")["todos"]
    assert [(t["title"], t["source"], t["source_detail"], t["proposed"]) for t in listed] == [
        ("数据结构 作业4", "course", "数据结构与算法 第7回", True)]
    nudged = tool(course, "shion_todo_update", id=listed[0]["id"], add_nudge=True, due_at="")
    assert nudged["todo"]["nudges"] == 1 and nudged["todo"]["due_at"] is None


def test_tools_answer_errors_instead_of_raising(make):
    ctx, _ = make("mail")
    assert tool(ctx, "shion_todo_add", title="x", area="fun")["error"] == "invalid_params"
    assert tool(ctx, "shion_todo_update", id="nope", done=True)["error"] == "not_found"
    assert tool(ctx, "shion_todo_list", colour="red")["error"] == "invalid_params"


def test_today_and_reports_flow(make):
    chief, _ = make("shion")
    journal, _ = make("journal")
    app, _ = make("shion")
    tool(chief, "shion_today_write", text="早上好。10:45 有小测。")
    assert app.call("today.get")["summary"]["author"] == "shion"
    assert app.call("today.get", {"date": "2026-11-08"})["summary"] is None
    blocks = [{"heading": "睡眠", "items": ["比前天早睡半小时"]}]
    tool(journal, "shion_report_write", kind="life", headline="早睡了", blocks=blocks)
    listed = app.call("reports.list", {"from": "2026-11-01"})["reports"]
    assert [(r["kind"], r["author"], r["headline"]) for r in listed] == [("life", "journal", "早睡了")]
    report = app.call("reports.get", {"date": "2026-11-09", "kind": "life"})["report"]
    assert report["blocks"] == blocks
    assert tool(journal, "shion_report_read", date="2026-11-09", kind="life")["report"]["blocks"] == blocks


def test_usage_flow(make):
    app, _ = make("shion")
    journal, _ = make("journal")
    segments = [{"bundle_id": "com.apple.Safari", "app_name": "Safari", "start": "2026-11-09T09:00+09:00",
                 "end": "2026-11-09T09:30+09:00"}]
    assert app.call("usage.upload", {"segments": segments})["added"] == 1
    assert app.call("usage.upload", {"segments": segments})["unchanged"] == 1
    day = tool(journal, "shion_usage_day")
    assert day["total_seconds"] == 1800 and day["by_category"]["uncategorized"] == 1800
    tool(journal, "shion_usage_set_category", bundle_id="com.apple.Safari", category="study")
    assert app.call("usage.day")["by_category"]["study"] == 1800
    tool(journal, "shion_usage_set_category", bundle_id="com.apple.Safari", category="default")
    assert "com.apple.Safari" not in app.call("usage.categories.list")["categories"]


# -- focus check ------------------------------------------------------------------------------

FOCUS = {"plan": "机器学习 课前小测", "off_minutes": 7, "activity": "fun", "on_track": False}


def test_focus_report_wakes_the_chief_in_her_bot_chat(make, hermes):
    chief, plugin = make("shion")
    hermes.env = {"HERMES_SESSION_KEY": "agent:shion:local:dm:bot-chat", "HERMES_SESSION_PLATFORM": "local"}
    chief.hooks["pre_llm_call"](session_id="sess-bot", user_message="hi", platform="local")
    out = chief.call("focus.report", {"profile": "shion", "session_id": "sess-bot", **FOCUS}, session_id="sess-bot")
    assert out["recorded"] and out["woke"] and out["latest"]["woke"]
    assert chief.injected == [{"content": "［专注检查］「机器学习 课前小测」：已经偏离 7 分钟，现在在做娱乐。",
                               "role": "user", "session_key": "agent:shion:local:dm:bot-chat"}]
    back = chief.call("focus.report", {**FOCUS, "off_minutes": 9, "on_track": True}, session_id="sess-bot")
    assert back["woke"] and chief.injected[-1]["content"] == "［专注检查］已经回到「机器学习 课前小测」上了。"
    status = tool(chief, "shion_focus_status", recent=5)
    assert status["latest"]["on_track"] is True and len(status["recent"]) == 1


def test_focus_report_falls_back_to_the_latest_local_session(make, hermes):
    chief, _ = make("shion")
    hermes.env = {"HERMES_SESSION_KEY": "key-1", "HERMES_SESSION_PLATFORM": "local"}
    chief.hooks["pre_llm_call"](session_id="old-id")
    # Compression gave the conversation a new id the plugin has not seen yet.
    assert chief.call("focus.report", FOCUS, session_id="new-id")["woke"] is True
    assert chief.injected[-1]["session_key"] == "key-1"


def test_focus_report_without_a_known_session_records_but_does_not_wake(make):
    chief, _ = make("shion")
    out = chief.call("focus.report", FOCUS, session_id="sess")
    assert (out["recorded"], out["woke"], out["reason"]) == (True, False, "no_session_key")
    assert chief.injected == []


def test_focus_report_on_another_profile_does_not_wake(make, hermes):
    default, _ = make("default")
    hermes.env = {"HERMES_SESSION_KEY": "k", "HERMES_SESSION_PLATFORM": "local"}
    default.hooks["pre_llm_call"](session_id="s")
    out = default.call("focus.report", FOCUS)
    assert (out["woke"], out["reason"]) == (False, "wrong_profile")


def test_focus_report_when_injection_is_refused(make, hermes):
    chief, _ = make("shion", inject_result=False)  # e.g. allow_gateway_injection is off
    hermes.env = {"HERMES_SESSION_KEY": "k", "HERMES_SESSION_PLATFORM": "local"}
    chief.hooks["pre_llm_call"](session_id="s")
    out = chief.call("focus.report", FOCUS, session_id="s")
    assert (out["woke"], out["reason"], out["latest"]["woke"]) == (False, "inject_refused", False)
    assert chief.call("focus.latest")["latest"]["plan"] == FOCUS["plan"]


def test_focus_report_validates(make):
    chief, _ = make("shion")
    with pytest.raises(ShionError):
        chief.call("focus.report", {**FOCUS, "window_title": "YouTube - cats"})
    with pytest.raises(ShionError):
        chief.call("focus.report", {"plan": "x"})


def test_hook_ignores_turns_without_a_key(make, hermes):
    chief, plugin = make("shion")
    hermes.env = {}
    assert chief.hooks["pre_llm_call"](session_id="s") is None
    assert plugin.store.session_key_for(profile="shion", session_id="s") is None


# -- push events ------------------------------------------------------------------------------

def test_watcher_tick_emits_once_per_revision(store):
    events = []
    watcher = ChangeWatcher(store, events.append)
    assert watcher.tick(0) == 0 and events == []
    store.add_todo(title="x", area="life", source="mail")
    store.write_today(text="t", author="shion")
    assert watcher.tick(0) == 2
    assert events == [{"revision": 2, "topics": ["todos", "today"], "reset": False}]
    assert watcher.tick(2) == 2 and len(events) == 1


def test_sync_state_starts_one_watcher_that_pushes_writes_from_any_profile(make, hermes):
    app, app_plugin = make("shion")
    mail, mail_plugin = make("mail")
    state = app.call("sync.state")
    assert state["revision"] == 0 and state["today"] == "2026-11-09" and state["timezone"] == "Asia/Tokyo"
    assert app_plugin.watcher._thread is not None
    mail.call("sync.state")  # a second profile's copy finds the watcher running and starts none
    assert mail_plugin.watcher._thread is None
    tool(mail, "shion_todo_add", title="回复 HR", area="work")
    deadline = time.monotonic() + 5
    while not hermes.events and time.monotonic() < deadline:
        time.sleep(0.02)
    assert hermes.events == [("shion", "changed", {"revision": 1, "topics": ["todos"], "reset": False})]
    assert app.call("changes.since", {"revision": 0})["topics"] == ["todos"]
    assert app.call("sync.state")["topics"]["todos"] == 1


def test_info_and_settings(make):
    app, _ = make("shion")
    info = app.call("info")
    assert info["profile"] == "shion" and info["today"] == "2026-11-09" and info["schema_version"] == 1
    out = app.call("settings.update", {"timezone": "UTC", "usage_retention_days": 10})
    assert out["settings"]["timezone"] == "UTC" and app.call("settings.get")["settings"]["usage_retention_days"] == 10
    with pytest.raises(ShionError):
        app.call("changes.since", {"revision": -1})


def test_register_entry_point_uses_shion_data_dir(tmp_path, monkeypatch):
    import shion
    monkeypatch.setenv("SHION_DATA_DIR", str(tmp_path / "data"))
    ctx = FakeCtx("study")
    shion.register(ctx)
    try:
        assert (tmp_path / "data" / "shion.db").exists()
        assert json.loads(ctx.tools["shion_todo_add"]({"title": "x", "area": "study"}))["todo"]["source"] == "study"
    finally:
        for stop in ctx.unload:
            stop()
