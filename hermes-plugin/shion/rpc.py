"""Plugin RPC methods for the Shion app: ``plugin.shion.<name>`` over ``/api/ws``.

Each handler takes the call's params (Hermes leaves ``profile`` and ``session_id`` in them; both are
routing, not data) and returns a JSON object. A ``ShionError`` becomes the call's error.
"""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

from . import timeutil
from .errors import ShionError
from .store import SCHEMA_VERSION, USER_SOURCE

if TYPE_CHECKING:
    from .plugin import ShionPlugin

PLUGIN_VERSION = "0.2.0"
_ROUTING = {"profile", "session_id"}


def _take(params: Any, allowed: set[str], required: set[str] = frozenset()) -> dict:
    if params is None:
        params = {}
    if not isinstance(params, dict):
        raise ShionError("invalid_params", "params must be an object")
    clean = {k: v for k, v in params.items() if k not in _ROUTING}
    unknown = sorted(set(clean) - allowed)
    if unknown:
        raise ShionError("invalid_params", f"unknown params: {', '.join(unknown)}")
    missing = sorted(k for k in required if k not in clean)
    if missing:
        raise ShionError("invalid_params", f"missing params: {', '.join(missing)}")
    return clean


def methods(plugin: "ShionPlugin") -> dict:
    store = plugin.store

    def info(params):
        _take(params, set())
        settings = store.settings()
        return {"plugin_version": PLUGIN_VERSION, "schema_version": SCHEMA_VERSION, "profile": plugin.profile(),
                "timezone": settings["timezone"], "today": store.today(), "revision": store.revision(),
                "tz_database": timeutil.tz_database()}

    def sync_state(params):
        _take(params, set())
        plugin.ensure_watcher()
        return {"revision": store.revision(), "topics": store.topic_revisions(), "today": store.today(),
                "timezone": store.settings()["timezone"]}

    def changes_since(params):
        p = _take(params, {"revision"}, {"revision"})
        rev = p["revision"]
        if isinstance(rev, bool) or not isinstance(rev, int) or rev < 0:
            raise ShionError("invalid_params", "revision must be a non-negative integer")
        plugin.ensure_watcher()
        return store.changes_since(rev)

    def settings_get(params):
        _take(params, set())
        return {"settings": store.settings()}

    def settings_update(params):
        p = _take(params, {"timezone", "usage_retention_days", "focus_retention_days", "chief_profile"})
        settings, revision = store.update_settings(p)
        return {"settings": settings, "revision": revision}

    def todos_list(params):
        p = _take(params, {"status", "area", "proposed", "from", "to", "date", "date_field", "include_undated",
                           "limit"})
        todos = store.list_todos(status=p.get("status", "open"), area=p.get("area"), proposed=p.get("proposed"),
                                 start=p.get("from"), end=p.get("to"), date=p.get("date"),
                                 field=p.get("date_field", "either"), include_undated=p.get("include_undated"),
                                 limit=p.get("limit", 500))
        return {"todos": todos, "revision": store.revision()}

    def todos_get(params):
        p = _take(params, {"id"}, {"id"})
        return {"todo": store.get_todo(p["id"])}

    def todos_add(params):
        p = _take(params, {"id", "title", "area", "do_at", "due_at", "proposed", "source_detail"},
                  {"title", "area"})
        todo, revision = store.add_todo(title=p["title"], area=p["area"], source=USER_SOURCE,
                                        do_at=p.get("do_at"), due_at=p.get("due_at"),
                                        proposed=p.get("proposed", False), source_detail=p.get("source_detail"),
                                        todo_id=p.get("id"))
        return {"todo": todo, "revision": revision}

    def todos_update(params):
        p = _take(params, {"id", "title", "area", "do_at", "due_at", "done", "proposed", "nudges", "add_nudge",
                           "source_detail"}, {"id"})
        todo_id = p.pop("id")
        todo, revision = store.update_todo(todo_id, p)
        return {"todo": todo, "revision": revision}

    def todos_delete(params):
        p = _take(params, {"id"}, {"id"})
        revision = store.delete_todo(p["id"])
        return {"deleted": p["id"], "revision": revision}

    def today_get(params):
        p = _take(params, {"date"})
        return {"summary": store.get_today(p.get("date"))}

    def reports_list(params):
        p = _take(params, {"from", "to", "kind", "limit"})
        return {"reports": store.list_reports(start=p.get("from"), end=p.get("to"), kind=p.get("kind"),
                                              limit=p.get("limit", 200))}

    def reports_get(params):
        p = _take(params, {"date", "kind"}, {"date", "kind"})
        return {"report": store.get_report(day=p["date"], kind=p["kind"])}

    def usage_upload(params):
        p = _take(params, {"segments", "device"}, {"segments"})
        result, revision = store.upload_usage(p["segments"], device=p.get("device", "mac"))
        return {**result, "revision": revision}

    def usage_day(params):
        p = _take(params, {"date"})
        return store.usage_day(p.get("date"))

    def usage_categories_list(params):
        _take(params, set())
        return {"categories": store.app_categories()}

    def usage_categories_set(params):
        p = _take(params, {"bundle_id", "category"}, {"bundle_id", "category"})
        revision = store.set_app_category(p["bundle_id"], p["category"], set_by=USER_SOURCE)
        return {"bundle_id": p["bundle_id"], "category": p["category"], "revision": revision}

    def focus_report(params, session_id=None):
        p = _take(params, {"plan", "off_minutes", "activity", "on_track"},
                  {"plan", "off_minutes", "activity", "on_track"})
        return plugin.focus_report(p, session_id=session_id)

    def focus_latest(params):
        _take(params, set())
        return {"latest": store.latest_focus()}

    def reviews_list(params):
        _take(params, set())
        return plugin.reviews.list()

    def reviews_detail(params):
        p = _take(params, {"id"}, {"id"})
        return {"review": plugin.reviews.detail(p["id"])}

    def reviews_bind(params):
        p = _take(params, {"id", "review_session"}, {"id", "review_session"})
        return plugin.reviews.bind(p["id"], p["review_session"])

    def reviews_decide(params):
        p = _take(params, {"id", "decision", "entries"}, {"id", "decision", "entries"})
        return plugin.reviews.decide(p["id"], p["decision"], p["entries"])

    return {
        "info": info,
        "sync.state": sync_state,
        "changes.since": changes_since,
        "settings.get": settings_get,
        "settings.update": settings_update,
        "todos.list": todos_list,
        "todos.get": todos_get,
        "todos.add": todos_add,
        "todos.update": todos_update,
        "todos.delete": todos_delete,
        "today.get": today_get,
        "reports.list": reports_list,
        "reports.get": reports_get,
        "usage.upload": usage_upload,
        "usage.day": usage_day,
        "usage.categories.list": usage_categories_list,
        "usage.categories.set": usage_categories_set,
        "focus.report": focus_report,
        "focus.latest": focus_latest,
        "reviews.list": reviews_list,
        "reviews.detail": reviews_detail,
        "reviews.bind": reviews_bind,
        "reviews.decide": reviews_decide,
    }
