"""Tools for the assistants (toolset ``shion``). Every profile's copy reads and writes the same store,
and ``source`` / ``author`` is the profile that called the tool."""

from __future__ import annotations

import json
import logging
from typing import TYPE_CHECKING, Callable

from .errors import ShionError
from .store import ACTIVITIES, AREAS, CATEGORIES, REPORT_KINDS

if TYPE_CHECKING:
    from .plugin import ShionPlugin

logger = logging.getLogger(__name__)

TOOLSET = "shion"

_DATETIME = ("A date (YYYY-MM-DD, no time) or ISO 8601 date-time, e.g. 2026-11-10T15:00 (no offset = the user's time zone, "
             "Asia/Tokyo unless changed) or with an offset such as +09:00")
_DATE = "Date as YYYY-MM-DD in the user's time zone; omit for today"

_TODO_FIELDS = {
    "title": {"type": "string", "description": "What to do, short, in the user's language"},
    "area": {"type": "string", "enum": list(AREAS), "description": "study, work or life"},
    "do_at": {"type": "string", "description": f"When to do it. {_DATETIME}. In an update, \"\" clears it"},
    "due_at": {"type": "string",
               "description": f"Deadline, separate from when to do it. {_DATETIME}. In an update, \"\" clears it"},
    "proposed": {"type": "boolean",
                 "description": "true when do_at/due_at are your suggestion and the user still has to confirm "
                                "them in Shion (they show up under 等你确认)"},
    "source_detail": {"type": "string",
                      "description": "Where it came from, shown under the todo, e.g. 来自 中村老师 的邮件 or "
                                     "数据结构与算法 第7回"},
}

SCHEMAS = {
    "shion_todo_list": {
        "name": "shion_todo_list",
        "description": "List the user's todos (the same list the Shion app shows). Filter by status, area and a "
                       "date range on do_at/due_at.",
        "parameters": {"type": "object", "properties": {
            "status": {"type": "string", "enum": ["open", "done", "all"], "description": "Default open"},
            "area": {"type": "string", "enum": list(AREAS)},
            "proposed": {"type": "boolean", "description": "Only todos whose dates await (true) or do not await "
                                                           "(false) the user's confirmation"},
            "date": {"type": "string", "description": "Only todos to do or due on this local day (YYYY-MM-DD)"},
            "from": {"type": "string", "description": "Range start: a date (start of that day) or date-time"},
            "to": {"type": "string", "description": "Range end: a date (whole day included) or date-time"},
            "date_field": {"type": "string", "enum": ["do_at", "due_at", "either"],
                           "description": "Which date the range applies to; default either"},
            "include_undated": {"type": "boolean", "description": "With a range, also return todos without dates"},
        }},
    },
    "shion_todo_add": {
        "name": "shion_todo_add",
        "description": "Add a todo for the user. It is marked as added by you (your profile). Keep do_at (when "
                       "to do it) and due_at (deadline) apart; set proposed=true if you picked the dates.",
        "parameters": {"type": "object", "properties": _TODO_FIELDS, "required": ["title", "area"]},
    },
    "shion_todo_update": {
        "name": "shion_todo_update",
        "description": "Change a todo: title, area, dates, done, confirm or re-propose dates, or count a nudge "
                       "(add_nudge=true each time you remind the user about it).",
        "parameters": {"type": "object", "properties": {
            "id": {"type": "string"},
            **_TODO_FIELDS,
            "done": {"type": "boolean"},
            "add_nudge": {"type": "boolean", "description": "true: you just reminded the user about this todo"},
        }, "required": ["id"]},
    },
    "shion_todo_delete": {
        "name": "shion_todo_delete",
        "description": "Delete a todo that should not exist (a duplicate, or one the user cancelled). To finish "
                       "a todo use shion_todo_update with done=true instead.",
        "parameters": {"type": "object", "properties": {"id": {"type": "string"}}, "required": ["id"]},
    },
    "shion_today_write": {
        "name": "shion_today_write",
        "description": "Write the short paragraph at the top of the user's Today page in Shion (the morning "
                       "brief, refreshed at 12:00, 18:00 and 21:00). Replaces that day's paragraph.",
        "parameters": {"type": "object", "properties": {
            "text": {"type": "string", "description": "A few sentences, in the user's language"},
            "date": {"type": "string", "description": _DATE},
        }, "required": ["text"]},
    },
    "shion_today_read": {
        "name": "shion_today_read",
        "description": "Read the Today paragraph for a day (who wrote it and when).",
        "parameters": {"type": "object", "properties": {"date": {"type": "string", "description": _DATE}}},
    },
    "shion_report_write": {
        "name": "shion_report_write",
        "description": "Write the daily report of one kind (study, work, life or news) shown on Shion's Reports "
                       "page. Replaces that day's report of that kind.",
        "parameters": {"type": "object", "properties": {
            "kind": {"type": "string", "enum": list(REPORT_KINDS)},
            "date": {"type": "string", "description": _DATE},
            "headline": {"type": "string", "description": "One line summing up the day"},
            "blocks": {"type": "array", "description": "Sections of the report", "items": {
                "type": "object", "properties": {
                    "heading": {"type": "string"},
                    "items": {"type": "array", "items": {"type": "string"}},
                }, "required": ["heading", "items"]}},
        }, "required": ["kind", "blocks"]},
    },
    "shion_report_read": {
        "name": "shion_report_read",
        "description": "Read a daily report, or list which reports exist in a date range.",
        "parameters": {"type": "object", "properties": {
            "kind": {"type": "string", "enum": list(REPORT_KINDS)},
            "date": {"type": "string", "description": "With kind: read that report"},
            "from": {"type": "string", "description": "List from this date (YYYY-MM-DD)"},
            "to": {"type": "string", "description": "List up to this date (YYYY-MM-DD)"},
        }},
    },
    "shion_usage_day": {
        "name": "shion_usage_day",
        "description": "How long the user spent in each app on their Mac on one day, and per category (study, "
                       "work, life, fun, social, other, uncategorized). Only app names and durations are known, "
                       "no window titles.",
        "parameters": {"type": "object", "properties": {"date": {"type": "string", "description": _DATE}}},
    },
    "shion_usage_set_category": {
        "name": "shion_usage_set_category",
        "description": "Set which category an app counts as in usage totals (by bundle id from shion_usage_day). "
                       "category default goes back to the built-in mapping (or uncategorized).",
        "parameters": {"type": "object", "properties": {
            "bundle_id": {"type": "string"},
            "category": {"type": "string", "enum": [*CATEGORIES, "default"]},
        }, "required": ["bundle_id", "category"]},
    },
    "shion_focus_status": {
        "name": "shion_focus_status",
        "description": "The Mac's latest focus check: the plan the user should be on now, how many minutes they "
                       "have been off it, what kind of thing they are doing instead (" + ", ".join(ACTIVITIES) +
                       "), and whether they are back on track. Empty when the Mac sent nothing (closed or "
                       "offline).",
        "parameters": {"type": "object", "properties": {
            "recent": {"type": "integer", "description": "Also return this many earlier reports (max 20)"},
        }},
    },
}


def _ok(payload) -> str:
    return json.dumps(payload, ensure_ascii=False)


def _wrap(fn: Callable[[dict], object]) -> Callable:
    def handler(args, **kwargs):
        try:
            return _ok(fn(args if isinstance(args, dict) else {}))
        except ShionError as exc:
            return _ok(exc.as_dict())
        except Exception as exc:  # a tool must answer, never raise into the turn
            logger.warning("shion tool failed", exc_info=True)
            return _ok({"error": "internal", "message": f"{type(exc).__name__}: {exc}"})
    return handler


def _only(args: dict, allowed: set[str]) -> dict:
    unknown = sorted(set(args) - allowed)
    if unknown:
        raise ShionError("invalid_params", f"unknown arguments: {', '.join(unknown)}")
    return args


def handlers(plugin: "ShionPlugin") -> dict:
    store = plugin.store

    def todo_list(a):
        a = _only(a, set(SCHEMAS["shion_todo_list"]["parameters"]["properties"]))
        todos = store.list_todos(status=a.get("status", "open"), area=a.get("area"), proposed=a.get("proposed"),
                                 start=a.get("from"), end=a.get("to"), date=a.get("date"),
                                 field=a.get("date_field", "either"), include_undated=a.get("include_undated"))
        return {"today": store.today(), "count": len(todos), "todos": todos}

    def todo_add(a):
        a = _only(a, set(_TODO_FIELDS))
        todo, _ = store.add_todo(title=a.get("title"), area=a.get("area"), source=plugin.profile(),
                                 do_at=a.get("do_at") or None, due_at=a.get("due_at") or None,
                                 proposed=a.get("proposed", False), source_detail=a.get("source_detail"))
        return {"todo": todo}

    def todo_update(a):
        a = dict(_only(a, set(SCHEMAS["shion_todo_update"]["parameters"]["properties"])))
        for key in ("do_at", "due_at"):
            if a.get(key) == "":
                a[key] = None
        todo, _ = store.update_todo(a.pop("id", None), a)
        return {"todo": todo}

    def todo_delete(a):
        a = _only(a, {"id"})
        store.delete_todo(a.get("id"))
        return {"deleted": a.get("id")}

    def today_write(a):
        a = _only(a, {"text", "date"})
        summary, _ = store.write_today(text=a.get("text"), author=plugin.profile(), day=a.get("date"))
        return {"summary": summary}

    def today_read(a):
        a = _only(a, {"date"})
        return {"summary": store.get_today(a.get("date"))}

    def report_write(a):
        a = _only(a, {"kind", "date", "headline", "blocks"})
        report, _ = store.write_report(kind=a.get("kind"), blocks=a.get("blocks"), author=plugin.profile(),
                                       day=a.get("date"), headline=a.get("headline"))
        return {"report": report}

    def report_read(a):
        a = _only(a, {"kind", "date", "from", "to"})
        if a.get("date") is not None:
            if a.get("kind") is None:
                return {"reports": store.list_reports(start=a["date"], end=a["date"])}
            return {"report": store.get_report(day=a["date"], kind=a["kind"])}
        return {"reports": store.list_reports(start=a.get("from"), end=a.get("to"), kind=a.get("kind"))}

    def usage_day(a):
        a = _only(a, {"date"})
        return store.usage_day(a.get("date"))

    def usage_set_category(a):
        a = _only(a, {"bundle_id", "category"})
        category = None if a.get("category") == "default" else a.get("category")
        store.set_app_category(a.get("bundle_id"), category, set_by=plugin.profile())
        return {"bundle_id": a.get("bundle_id"), "category": a.get("category")}

    def focus_status(a):
        a = _only(a, {"recent"})
        out = {"latest": store.latest_focus()}
        if a.get("recent"):
            n = a["recent"]
            if isinstance(n, bool) or not isinstance(n, int) or not 1 <= n <= 20:
                raise ShionError("invalid_params", "recent must be 1-20")
            out["recent"] = store.recent_focus(n + 1)[1:]
        return out

    table = {
        "shion_todo_list": todo_list, "shion_todo_add": todo_add, "shion_todo_update": todo_update,
        "shion_todo_delete": todo_delete, "shion_today_write": today_write, "shion_today_read": today_read,
        "shion_report_write": report_write, "shion_report_read": report_read, "shion_usage_day": usage_day,
        "shion_usage_set_category": usage_set_category, "shion_focus_status": focus_status,
    }
    return {name: _wrap(fn) for name, fn in table.items()}
