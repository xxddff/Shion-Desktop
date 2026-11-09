"""The shion plugin's RPCs for the CI stand-in (fake_hermes.py), shaped like hermes-plugin/README.md.

Covers what Shion calls: info, sync.state, changes.since, todos.list/add/update/delete, today.get,
reports.list/get. Every call must name a profile (the plugin lives in the assistants' profiles);
unknown parameters are refused the way the plugin refuses them. Writes bump the revision and push
`plugin.shion.changed` to the socket with an empty session id, as the plugin's watcher does. A few
seconds after the first sync, 课程 adds a todo through "its tool", so the push path is exercised.
"""
import threading
import time
from datetime import datetime, timedelta, timezone

TOKYO = timezone(timedelta(hours=9))
lock = threading.Lock()
state = {"revision": 1, "pushed_assistant_todo": False}


def iso(dt):
    return dt.astimezone(TOKYO).replace(microsecond=0).isoformat()


def today():
    return datetime.now(TOKYO).date()


def at(day_offset, hour, minute=0):
    d = today() + timedelta(days=day_offset)
    return iso(datetime(d.year, d.month, d.day, hour, minute, tzinfo=TOKYO))


def todo(id, title, area, source, detail=None, do_at=None, due_at=None, proposed=False):
    now = iso(datetime.now(TOKYO))
    return {"id": id, "title": title, "area": area, "source": source, "source_detail": detail,
            "do_at": do_at, "due_at": due_at, "done": False, "nudges": 0, "proposed": proposed,
            "created_at": now, "updated_at": now, "completed_at": None}


todos = {
    "td_ci_report": todo("td_ci_report", "CI：交实验报告", "study", "shion", "来自 中村老师 的邮件",
                         do_at=at(0, 15), due_at=at(0, 18)),
    "td_ci_shop": todo("td_ci_shop", "CI：买牛奶", "life", "你自己加的", do_at=at(0, 19)),
    "td_ci_quiz": todo("td_ci_quiz", "CI：准备小测", "study", "study", "机器学习 第6回",
                       do_at=at(1, 10), proposed=True),
}
summary = {"date": str(today()), "text": "（CI）早上好。今天 15:00 前把实验报告交了，晚上记得买牛奶。",
           "author": "shion", "updated_at": at(0, 7)}
reports = {
    "life": {"id": f"{today() - timedelta(days=1)}-life", "date": str(today() - timedelta(days=1)), "kind": "life",
             "headline": "CI 日报：昨天睡得早", "author": "journal", "created_at": at(-1, 22, 30),
             "updated_at": at(-1, 22, 30),
             "blocks": [{"heading": "睡眠", "items": ["比前天早睡半小时"]},
                        {"heading": "屏幕时间", "items": ["4 小时 10 分"]}]},
}

KEYS = {
    "info": set(), "sync.state": set(), "changes.since": {"revision"},
    "todos.list": {"status", "area", "proposed", "date", "from", "to", "date_field", "include_undated", "limit"},
    "todos.get": {"id"},
    "todos.add": {"title", "area", "do_at", "due_at", "proposed", "source_detail", "id"},
    "todos.update": {"id", "title", "area", "do_at", "due_at", "done", "proposed", "nudges", "add_nudge",
                     "source_detail"},
    "todos.delete": {"id"},
    "today.get": {"date"},
    "reports.list": {"from", "to", "kind", "limit"},
    "reports.get": {"date", "kind"},
}


class ShionError(Exception):
    def __init__(self, code, detail):
        super().__init__(f"{code}: {detail}")
        self.code = code


def bump():
    state["revision"] += 1
    return state["revision"]


def handle(conn, log, method, params, rid):
    """Answers a `plugin.shion.*` call on `conn` (the stand-in's socket handler)."""
    name = method[len("plugin.shion."):]
    try:
        if not params.get("profile"):
            # without a profile the call lands in the connection's own profile, where the plugin is not
            return conn.send_json({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": f"no method {method}"}})
        args = {k: v for k, v in params.items() if k not in ("profile", "session_id")}
        if name not in KEYS:
            return conn.send_json({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": f"no method {method}"}})
        unknown = sorted(set(args) - KEYS[name])
        if unknown:
            raise ShionError("invalid_params", f"unknown parameter(s): {', '.join(unknown)}")
        with lock:
            result, changed = call(name, args)
        log(f"    plugin {name} {args if name.startswith('todos.') and name != 'todos.list' else ''}".rstrip())
        conn.send_json({"jsonrpc": "2.0", "id": rid, "result": result})
        if changed:
            push(conn, log, changed)
        if name == "sync.state" and not state["pushed_assistant_todo"]:
            state["pushed_assistant_todo"] = True
            threading.Timer(4.0, assistant_adds, args=(conn, log)).start()
    except ShionError as error:
        log(f"    plugin {name} refused: {error}")
        conn.send_json({"jsonrpc": "2.0", "id": rid, "error": {
            "code": 4001, "message": "plugin_rpc_failed",
            "data": {"reason": "plugin_rpc_failed", "field": method, "detail": f"ShionError: {error}"}}})


def call(name, args):
    """(result, changed topics) for one call; the caller holds the lock."""
    if name == "info":
        return {"plugin_version": "ci", "schema_version": 1, "profile": "shion", "timezone": "Asia/Tokyo",
                "today": str(today()), "revision": state["revision"]}, None
    if name == "sync.state":
        return {"revision": state["revision"], "today": str(today()), "timezone": "Asia/Tokyo",
                "topics": {"todos": state["revision"], "today": 1, "reports": 1}}, None
    if name == "changes.since":
        if type(args.get("revision")) is not int:
            raise ShionError("invalid_params", "revision must be an integer")
        newer = args["revision"] < state["revision"]
        return {"revision": state["revision"], "reset": False, "topics": ["todos"] if newer else []}, None
    if name == "todos.list":
        status = args.get("status", "open")
        rows = [t for t in todos.values() if status == "all" or t["done"] == (status == "done")]
        rows.sort(key=lambda t: (t["do_at"] is None, t["do_at"] or "", t["due_at"] or "", t["created_at"]))
        return {"todos": rows[:args.get("limit", 500)], "revision": state["revision"]}, None
    if name == "todos.add":
        for key in ("title", "area"):
            if not args.get(key):
                raise ShionError("invalid_params", f"{key} is required")
        id = args.get("id") or f"td_{int(time.time() * 1000):x}"
        todos[id] = todo(id, args["title"], args["area"], "你自己加的", args.get("source_detail"),
                         args.get("do_at"), args.get("due_at"), args.get("proposed", False))
        return {"todo": todos[id], "revision": bump()}, ["todos"]
    if name in ("todos.update", "todos.delete", "todos.get"):
        id = args.get("id")
        if id not in todos:
            raise ShionError("not_found", f"no todo {id!r}")
        if name == "todos.get":
            return {"todo": todos[id]}, None
        if name == "todos.delete":
            del todos[id]
            return {"deleted": id, "revision": bump()}, ["todos"]
        item = todos[id]
        for key in ("title", "area", "do_at", "due_at", "proposed", "nudges", "source_detail"):
            if key in args:
                item[key] = args[key]
        if "done" in args:
            item["done"] = bool(args["done"])
            item["completed_at"] = iso(datetime.now(TOKYO)) if item["done"] else None
        item["updated_at"] = iso(datetime.now(TOKYO))
        return {"todo": item, "revision": bump()}, ["todos"]
    if name == "today.get":
        return {"summary": summary if args.get("date", str(today())) == summary["date"] else None}, None
    if name == "reports.list":
        rows = [{k: v for k, v in r.items() if k != "blocks"} | {"block_count": len(r["blocks"])}
                for r in reports.values() if args.get("kind") in (None, r["kind"])]
        return {"reports": sorted(rows, key=lambda r: r["date"], reverse=True)}, None
    if name == "reports.get":
        report = reports.get(args.get("kind"))
        if not report or report["date"] != args.get("date"):
            raise ShionError("not_found", f"no {args.get('kind')} report on {args.get('date')}")
        return {"report": report}, None
    raise ShionError("invalid_params", f"unhandled {name}")


def push(conn, log, topics):
    log(f"  -> plugin.shion.changed {topics} (revision {state['revision']})")
    conn.send_json({"jsonrpc": "2.0", "method": "event", "params": {
        "type": "plugin.shion.changed", "session_id": "",
        "payload": {"revision": state["revision"], "topics": topics, "reset": False}}})


def assistant_adds(conn, log):
    """课程 writes a todo with its tool, as an assistant would between Shion's calls."""
    with lock:
        todos["td_ci_review"] = todo("td_ci_review", "CI：复习第 7 回", "study", "study", "机器学习 第7回",
                                     do_at=at(1, 20))
        bump()
    log("  课程 added a todo through the plugin")
    try:
        push(conn, log, ["todos"])
    except OSError:
        pass
