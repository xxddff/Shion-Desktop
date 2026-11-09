import sqlite3

import pytest

from shion.errors import ShionError
from shion.store import USER_SOURCE, Store


def codes(fn):
    with pytest.raises(ShionError) as info:
        fn()
    return info.value.code


# -- todos ------------------------------------------------------------------------------------

def test_todo_round_trip_in_the_users_time_zone(store):
    todo, rev = store.add_todo(title="机器学习 课前小测", area="study", source="course",
                               do_at="2026-11-09T10:45", due_at="2026-11-09T12:50+09:00")
    assert rev == 1
    assert todo["do_at"] == "2026-11-09T10:45:00+09:00"
    assert todo["due_at"] == "2026-11-09T12:50:00+09:00"
    assert todo["created_at"] == "2026-11-09T10:52:00+09:00"
    assert (todo["done"], todo["nudges"], todo["proposed"], todo["completed_at"]) == (False, 0, False, None)
    assert store.get_todo(todo["id"]) == todo


def test_utc_input_is_shown_with_the_local_offset(store):
    todo, _ = store.add_todo(title="x", area="life", source=USER_SOURCE, do_at="2026-11-09T06:00:00Z")
    assert todo["do_at"] == "2026-11-09T15:00:00+09:00"


def test_validation(store):
    assert codes(lambda: store.add_todo(title="", area="life", source="s")) == "invalid_params"
    assert codes(lambda: store.add_todo(title="x", area="fun", source="s")) == "invalid_params"
    assert codes(lambda: store.add_todo(title="x", area="life", source="s", do_at="2026-11-10")) == "invalid_params"
    assert codes(lambda: store.add_todo(title="x", area="life", source="s", do_at="soon")) == "invalid_params"
    assert codes(lambda: store.add_todo(title="x", area="life", source="s", proposed="yes")) == "invalid_params"
    assert codes(lambda: store.get_todo("nope")) == "not_found"
    assert store.revision() == 0


def test_add_with_a_client_id_is_idempotent(store):
    a, rev1 = store.add_todo(title="x", area="life", source=USER_SOURCE, todo_id="mac-1")
    b, rev2 = store.add_todo(title="x", area="life", source=USER_SOURCE, todo_id="mac-1")
    assert a == b and rev1 == rev2 == 1
    assert codes(lambda: store.add_todo(title="y", area="life", source=USER_SOURCE, todo_id="mac-1")) == "conflict"


def test_update_done_confirm_nudge_and_clear_dates(store, clock):
    todo, _ = store.add_todo(title="x", area="study", source="course", do_at="2026-11-10T20:00", proposed=True)
    clock.set("2026-11-09T12:00:00+09:00")
    t, _ = store.update_todo(todo["id"], {"proposed": False, "do_at": "2026-11-11T20:00"})
    assert (t["proposed"], t["do_at"], t["updated_at"]) == (False, "2026-11-11T20:00:00+09:00",
                                                            "2026-11-09T12:00:00+09:00")
    t, _ = store.update_todo(todo["id"], {"add_nudge": True})
    t, _ = store.update_todo(todo["id"], {"add_nudge": True})
    assert t["nudges"] == 2
    t, _ = store.update_todo(todo["id"], {"done": True})
    assert t["done"] and t["completed_at"] == "2026-11-09T12:00:00+09:00"
    t, _ = store.update_todo(todo["id"], {"done": False, "do_at": None})
    assert not t["done"] and t["completed_at"] is None and t["do_at"] is None
    assert codes(lambda: store.update_todo(todo["id"], {})) == "invalid_params"
    assert codes(lambda: store.update_todo(todo["id"], {"source": "me"})) == "invalid_params"
    assert codes(lambda: store.update_todo("missing", {"done": True})) == "not_found"


def test_an_update_that_changes_nothing_keeps_the_revision(store):
    todo, rev = store.add_todo(title="x", area="life", source=USER_SOURCE)
    _, rev2 = store.update_todo(todo["id"], {"title": "x"})
    assert rev2 == rev


def test_delete(store):
    todo, _ = store.add_todo(title="x", area="life", source=USER_SOURCE)
    store.delete_todo(todo["id"])
    assert codes(lambda: store.delete_todo(todo["id"])) == "not_found"


def _seed(store):
    ids = {}
    for key, kw in {
        "today_do": dict(area="study", do_at="2026-11-09T15:00"),
        "today_due": dict(area="work", do_at="2026-11-08T10:00", due_at="2026-11-09T18:00"),
        "tomorrow": dict(area="life", do_at="2026-11-10T09:00"),
        "undated": dict(area="life"),
        "proposed": dict(area="study", do_at="2026-11-11T19:00", proposed=True),
    }.items():
        ids[key] = store.add_todo(title=key, source="shion", **kw)[0]["id"]
    store.update_todo(store.add_todo(title="done", area="work", source="shion",
                                     do_at="2026-11-09T09:00")[0]["id"], {"done": True})
    return ids


def titles(todos):
    return [t["title"] for t in todos]


def test_list_filters(store):
    _seed(store)
    assert titles(store.list_todos()) == ["today_due", "today_do", "tomorrow", "proposed", "undated"]
    assert titles(store.list_todos(status="done")) == ["done"]
    assert len(store.list_todos(status="all")) == 6
    assert titles(store.list_todos(date="2026-11-09")) == ["today_due", "today_do"]
    assert titles(store.list_todos(date="2026-11-09", field="do_at")) == ["today_do"]
    assert titles(store.list_todos(date="2026-11-09", field="due_at")) == ["today_due"]
    assert titles(store.list_todos(date="2026-11-09", include_undated=True)) == ["today_due", "today_do", "undated"]
    assert titles(store.list_todos(start="2026-11-10", end="2026-11-11")) == ["tomorrow", "proposed"]
    assert titles(store.list_todos(start="2026-11-10T12:00")) == ["proposed"]
    assert titles(store.list_todos(area=["life"])) == ["tomorrow", "undated"]
    assert titles(store.list_todos(proposed=True)) == ["proposed"]
    assert codes(lambda: store.list_todos(date="2026-11-09", start="2026-11-09")) == "invalid_params"
    assert codes(lambda: store.list_todos(status="later")) == "invalid_params"


def test_a_day_is_the_users_local_day(store):
    # 23:30 in Tokyo on the 9th is 14:30 UTC: still the 9th for the user.
    store.add_todo(title="late", area="life", source="s", do_at="2026-11-09T23:30")
    store.add_todo(title="early", area="life", source="s", do_at="2026-11-10T00:30")
    assert titles(store.list_todos(date="2026-11-09")) == ["late"]
    store.update_settings({"timezone": "UTC"})
    assert titles(store.list_todos(date="2026-11-09")) == ["late", "early"]


# -- settings and revisions -------------------------------------------------------------------

def test_settings(store, clock):
    assert store.settings()["timezone"] == "Asia/Tokyo"
    assert store.today() == "2026-11-09"
    clock.set("2026-11-09T23:30:00+09:00")
    settings, _ = store.update_settings({"timezone": "Europe/London", "usage_retention_days": 14})
    assert settings["usage_retention_days"] == 14
    assert store.today() == "2026-11-09"  # 14:30 in London
    assert codes(lambda: store.update_settings({"timezone": "Mars/Base"})) == "invalid_params"
    assert codes(lambda: store.update_settings({"colour": "red"})) == "invalid_params"
    assert codes(lambda: store.update_settings({"usage_retention_days": 0})) == "invalid_params"


def test_changes_since_and_topic_revisions(store, clock):
    assert store.changes_since(0) == {"revision": 0, "reset": False, "topics": []}
    store.add_todo(title="x", area="life", source="s")
    store.write_today(text="早上好", author="shion")
    assert store.changes_since(0)["topics"] == ["todos", "today"]
    assert store.changes_since(1)["topics"] == ["today"]
    assert store.changes_since(2)["topics"] == []
    assert store.changes_since(99)["reset"] is True  # ahead of this store
    assert store.topic_revisions() == {"todos": 1, "today": 2, "reports": 0, "usage": 0, "focus": 0, "settings": 0}
    # A week later the log is trimmed: an old cursor must refetch everything.
    clock.set("2026-11-20T10:00:00+09:00")
    store.add_todo(title="y", area="life", source="s")
    assert store.changes_since(0)["reset"] is True
    assert store.changes_since(2) == {"revision": 3, "reset": False, "topics": ["todos"]}


def test_two_store_objects_share_one_file(tmp_path, clock):
    a = Store(tmp_path / "shared.db", clock=clock)
    b = Store(tmp_path / "shared.db", clock=clock)
    a.add_todo(title="from a", area="life", source="mail")
    assert titles(b.list_todos()) == ["from a"]
    assert b.revision() == 1
    mode = sqlite3.connect(tmp_path / "shared.db").execute("PRAGMA journal_mode").fetchone()[0]
    assert mode == "wal"


# -- today and reports ------------------------------------------------------------------------

def test_today_summary(store, clock):
    assert store.get_today() is None
    store.write_today(text="早上好。今天 10:45 有小测。", author="shion")
    clock.set("2026-11-09T12:00:00+09:00")
    s, _ = store.write_today(text="中午了。", author="shion")
    assert s == {"date": "2026-11-09", "text": "中午了。", "author": "shion", "updated_at": "2026-11-09T12:00:00+09:00"}
    store.write_today(text="明天", author="shion", day="2026-11-10")
    assert store.get_today("2026-11-10")["text"] == "明天"
    assert codes(lambda: store.write_today(text="", author="shion")) == "invalid_params"


BLOCKS = [{"heading": "睡眠", "items": ["比前天早睡半小时"]}, {"heading": "屏幕时间", "items": ["4 小时 10 分"]}]


def test_reports(store, clock):
    r, _ = store.write_report(kind="life", blocks=BLOCKS, author="journal", headline="早睡了", day="2026-11-08")
    assert r["id"] == "2026-11-08-life" and r["blocks"] == BLOCKS and r["author"] == "journal"
    store.write_report(kind="news", blocks=BLOCKS, author="news")
    clock.set("2026-11-09T22:30:00+09:00")
    again, _ = store.write_report(kind="life", blocks=BLOCKS[:1], author="journal", day="2026-11-08")
    assert again["created_at"] == r["created_at"] and again["updated_at"] == "2026-11-09T22:30:00+09:00"
    assert again["headline"] is None
    listed = store.list_reports()
    assert [(x["date"], x["kind"], x["block_count"]) for x in listed] == [("2026-11-09", "news", 2),
                                                                          ("2026-11-08", "life", 1)]
    assert "blocks" not in listed[0]
    assert [x["kind"] for x in store.list_reports(kind="news")] == ["news"]
    assert [x["kind"] for x in store.list_reports(start="2026-11-09")] == ["news"]
    assert store.get_report(day="2026-11-08", kind="life")["blocks"] == BLOCKS[:1]
    assert codes(lambda: store.get_report(day="2026-11-07", kind="life")) == "not_found"
    assert codes(lambda: store.write_report(kind="sports", blocks=BLOCKS, author="x")) == "invalid_params"
    assert codes(lambda: store.write_report(kind="life", blocks=[{"heading": "x"}], author="x")) == "invalid_params"
    assert codes(lambda: store.write_report(kind="life", blocks=[], author="x")) == "invalid_params"


# -- usage ------------------------------------------------------------------------------------

def seg(bundle, start, end, name=None):
    return {"bundle_id": bundle, "app_name": name or bundle.rsplit(".", 1)[-1], "start": start, "end": end}


def test_usage_upload_twice_counts_once(store):
    segments = [seg("com.apple.dt.Xcode", "2026-11-09T09:00+09:00", "2026-11-09T09:30+09:00"),
                seg("jp.naver.line.mac", "2026-11-09T09:30+09:00", "2026-11-09T09:40+09:00")]
    first, rev = store.upload_usage(segments)
    assert first == {"received": 2, "added": 2, "updated": 0, "unchanged": 0, "expired": 0}
    second, rev2 = store.upload_usage(segments)
    assert second["unchanged"] == 2 and rev2 == rev
    day = store.usage_day()
    assert day["total_seconds"] == 40 * 60
    assert [(a["bundle_id"], a["seconds"], a["category"]) for a in day["by_app"]] == [
        ("com.apple.dt.Xcode", 1800, "work"), ("jp.naver.line.mac", 600, "social")]
    assert day["by_category"]["work"] == 1800 and day["by_category"]["social"] == 600


def test_a_running_segment_can_grow_and_overlaps_are_merged(store):
    store.upload_usage([seg("com.apple.Safari", "2026-11-09T08:00+09:00", "2026-11-09T08:10+09:00")])
    result, _ = store.upload_usage([seg("com.apple.Safari", "2026-11-09T08:00+09:00", "2026-11-09T08:20+09:00")])
    assert result["updated"] == 1
    # The same time split differently (another start) is not counted twice.
    store.upload_usage([seg("com.apple.Safari", "2026-11-09T08:05+09:00", "2026-11-09T08:25+09:00")])
    day = store.usage_day()
    assert day["by_app"][0]["seconds"] == 25 * 60
    assert day["by_app"][0]["category"] is None and day["by_category"]["uncategorized"] == 25 * 60


def test_usage_splits_at_local_midnight(store, clock):
    clock.set("2026-11-10T08:00:00+09:00")
    store.upload_usage([seg("com.spotify.client", "2026-11-09T23:30+09:00", "2026-11-10T00:45+09:00")])
    assert store.usage_day("2026-11-09")["by_app"][0]["seconds"] == 30 * 60
    assert store.usage_day("2026-11-10")["by_app"][0]["seconds"] == 45 * 60
    assert store.usage_day("2026-11-10")["by_category"]["fun"] == 45 * 60


def test_usage_validation_and_retention(store, clock):
    bad = [seg("a.b", "2026-11-09T09:00+09:00", "2026-11-09T08:00+09:00")]
    assert codes(lambda: store.upload_usage(bad)) == "invalid_params"
    future = [seg("a.b", "2026-11-09T10:00+09:00", "2026-11-09T12:00+09:00")]
    assert codes(lambda: store.upload_usage(future)) == "invalid_params"
    extra = [{**seg("a.b", "2026-11-09T09:00+09:00", "2026-11-09T09:10+09:00"), "title": "secret"}]
    assert codes(lambda: store.upload_usage(extra)) == "invalid_params"
    old = [seg("a.b", "2026-10-01T09:00+09:00", "2026-10-01T09:10+09:00")]
    assert store.upload_usage(old)[0]["expired"] == 1
    store.upload_usage([seg("a.b", "2026-11-01T09:00+09:00", "2026-11-01T09:10+09:00")])
    clock.set("2026-12-05T09:00:00+09:00")
    assert store.purge_usage() == 1
    assert store.usage_day("2026-11-01")["total_seconds"] == 0


def test_app_categories(store):
    store.upload_usage([seg("com.apple.Safari", "2026-11-09T08:00+09:00", "2026-11-09T08:10+09:00")])
    store.set_app_category("com.apple.Safari", "study", set_by="journal")
    assert store.usage_day()["by_category"]["study"] == 600
    store.set_app_category("com.apple.dt.Xcode", "fun", set_by=USER_SOURCE)
    assert store.app_categories()["com.apple.dt.Xcode"] == "fun"
    store.set_app_category("com.apple.dt.Xcode", None, set_by=USER_SOURCE)
    assert store.app_categories()["com.apple.dt.Xcode"] == "work"
    assert codes(lambda: store.set_app_category("x", "games", set_by="x")) == "invalid_params"


# -- focus ------------------------------------------------------------------------------------

def test_focus_reports(store, clock):
    assert store.latest_focus() is None
    report, rid, _ = store.add_focus(plan="机器学习 课前小测", off_minutes=7, activity="fun", on_track=False)
    assert report == {"at": "2026-11-09T10:52:00+09:00", "plan": "机器学习 课前小测", "off_minutes": 7,
                      "activity": "fun", "on_track": False, "woke": False}
    store.mark_focus_woke(rid)
    clock.set("2026-11-09T11:00:00+09:00")
    latest = store.latest_focus()
    assert latest["woke"] and latest["age_minutes"] == 8
    assert codes(lambda: store.add_focus(plan="x", off_minutes=-1, activity="fun", on_track=False)) == "invalid_params"
    assert codes(lambda: store.add_focus(plan="x", off_minutes=1, activity="games", on_track=False)) == "invalid_params"
