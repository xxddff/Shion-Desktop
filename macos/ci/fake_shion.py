"""The shion plugin's RPCs for the CI stand-in (fake_hermes.py), shaped like hermes-plugin/README.md.

Covers what Shion calls: info, sync.state, changes.since, todos.list/add/update/delete, today.get,
reports.list/get, and what the Mac sends of its own data: usage.upload, usage.day, focus.report,
focus.latest. Every call must name a profile (the plugin lives in the assistants' profiles);
unknown or missing parameters are refused the way the plugin refuses them, and usage.upload's
segments and focus.report's values are checked as hermes-plugin/shion/store.py checks them
(check_fake_shion.py runs both on the same inputs). A `session_id` is checked first, as Hermes
does before any plugin method (gateway/session_plugin_rpc.py): it must be a string naming a
session of that profile. Writes bump the revision and push `plugin.shion.changed` to the socket
with an empty session id, as the plugin's watcher does. A few seconds after the first sync, 课程
adds a todo through "its tool", so the push path is exercised.

Two assistants answer what the Mac sends, as they would on a real server: a focus report puts
the plugin's line in 詩音's Bot Chat (`inject_message`) and she replies there (the line itself is
stored, as Hermes stores it, and Shion must not show it); an upload makes 回顾 write today's life
report with the screen time it adds up from the segments.
"""
import sys
import threading
import time
from datetime import date, datetime, timedelta, timezone

TOKYO = timezone(timedelta(hours=9))
lock = threading.Lock()
state = {"revision": 1, "pushed_assistant_todo": False}
usage = {}  # (device, bundle_id, start as stored: UTC to the second) -> segment
focus_log = []  # focus.report's records, oldest first
ACTIVITIES = ("study", "work", "life", "fun", "social", "other")
ACTIVITY_LABELS = {"study": "学习", "work": "工作", "life": "生活", "fun": "娱乐", "social": "社交", "other": "别的事"}
CHIEF = "shion"  # the plugin's chief_profile


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
    "usage.upload": {"segments", "device"},
    "usage.day": {"date"},
    "focus.report": {"plan", "off_minutes", "activity", "on_track"},
    "focus.latest": set(),
}
# as rpc.py's _take: these must be there
REQUIRED = {
    "changes.since": {"revision"},
    "usage.upload": {"segments"},
    "focus.report": {"plan", "off_minutes", "activity", "on_track"},
}


class ShionError(Exception):
    def __init__(self, code, detail):
        super().__init__(f"{code}: {detail}")
        self.code = code


def bump():
    state["revision"] += 1
    return state["revision"]


def hermes_of(conn):
    """fake_hermes.py's globals (it runs as __main__): the profiles' Bot Chats and their transcripts.
    None when the caller is not the stand-in's socket (check_fake_shion.py)."""
    module = sys.modules.get(type(conn).__module__)
    return module if all(hasattr(module, name) for name in ("sessions", "transcripts", "lock")) else None


def refuse(conn, rid, reason, **data):
    conn.send_json({"jsonrpc": "2.0", "id": rid, "error": {"code": 4001, "message": reason, "data": {"reason": reason, **data}}})


def handle(conn, log, method, params, rid):
    """Answers a `plugin.shion.*` call on `conn` (the stand-in's socket handler)."""
    name = method[len("plugin.shion."):]
    try:
        if not params.get("profile"):
            # without a profile the call lands in the connection's own profile, where the plugin is not
            return conn.send_json({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": f"no method {method}"}})
        if name not in KEYS:
            return conn.send_json({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": f"no method {method}"}})
        # Hermes checks a session_id before the plugin sees the call: a string, naming a session of
        # that profile (not_found otherwise)
        session_id = params.get("session_id")
        if session_id is not None and not isinstance(session_id, str):
            log(f"    plugin {name} refused: session_id is not a string")
            return refuse(conn, rid, "invalid_params", field="session_id")
        if session_id:
            hermes = hermes_of(conn)
            known = getattr(hermes, "sessions", {}).get(params["profile"]) if hermes else None
            if session_id != known:
                log(f"    plugin {name} refused: {session_id!r} is not a session of {params['profile']}")
                return refuse(conn, rid, "not_found")
        args = {k: v for k, v in params.items() if k not in ("profile", "session_id")}
        unknown = sorted(set(args) - KEYS[name])
        if unknown:
            raise ShionError("invalid_params", f"unknown params: {', '.join(unknown)}")
        missing = sorted(REQUIRED.get(name, set()) - set(args))
        if missing:
            raise ShionError("invalid_params", f"missing params: {', '.join(missing)}")
        with lock:
            result, changed = call(name, args, params["profile"])
        if name == "usage.upload":
            apps = sorted({seg["app_name"] for seg in args["segments"]})
            log(f"    plugin usage.upload {len(args['segments'])} segments ({', '.join(apps)}): {result}")
        elif name == "focus.report":
            log(f"    plugin focus.report {args} session_id={session_id!r}: woke={result['woke']}")
        else:
            log(f"    plugin {name} {args if name.startswith('todos.') and name != 'todos.list' else ''}".rstrip())
        conn.send_json({"jsonrpc": "2.0", "id": rid, "result": result})
        if changed:
            push(conn, log, changed)
        if name == "sync.state" and not state["pushed_assistant_todo"]:
            state["pushed_assistant_todo"] = True
            threading.Timer(4.0, assistant_adds, args=(conn, log)).start()
        if name == "focus.report" and result["woke"]:
            threading.Timer(1.0, chief_answers, args=(conn, log, result["latest"])).start()
        if name == "usage.upload" and (result["added"] or result["updated"]):
            threading.Timer(1.0, journal_writes, args=(conn, log)).start()
    except ShionError as error:
        log(f"    plugin {name} refused: {error}")
        conn.send_json({"jsonrpc": "2.0", "id": rid, "error": {
            "code": 4001, "message": "plugin_rpc_failed",
            "data": {"reason": "plugin_rpc_failed", "field": method, "detail": f"ShionError: {error}"}}})


# -- the plugin's checks (hermes-plugin/shion/store.py and timeutil.py) ----------------------------

def text(value, field, *, max_len):
    if not isinstance(value, str):
        raise ShionError("invalid_params", f"{field} must be a string")
    value = value.strip()
    if not value:
        raise ShionError("invalid_params", f"{field} must not be empty")
    if len(value) > max_len:
        raise ShionError("invalid_params", f"{field} is longer than {max_len} characters")
    return value


def choice(value, field, choices):
    if value not in choices:
        raise ShionError("invalid_params", f"{field} must be one of {', '.join(choices)}")
    return value


def boolean(value, field):
    if not isinstance(value, bool):
        raise ShionError("invalid_params", f"{field} must be true or false")
    return value


def integer(value, field, *, lo, hi):
    if isinstance(value, bool) or not isinstance(value, int) or not lo <= value <= hi:
        raise ShionError("invalid_params", f"{field} must be an integer from {lo} to {hi}")
    return value


def instant(value, field):
    """ISO 8601 date-time; an offset (or Z) is honoured, a value without one is Tokyo time."""
    if not isinstance(value, str) or not value.strip():
        raise ShionError("invalid_params", f"{field} must be an ISO 8601 date-time string")
    value = value.strip()
    if len(value) == 10 and value[4] == "-" and value[7] == "-":
        raise ShionError("invalid_params", f"{field} needs a time as well as a date (e.g. {value}T09:00)")
    try:
        moment = datetime.fromisoformat(value)
    except ValueError as exc:
        raise ShionError("invalid_params", f"{field} is not an ISO 8601 date-time: {value!r}") from exc
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=TOKYO)
    return moment.astimezone(timezone.utc).replace(microsecond=0)


def union_seconds(spans):
    total, cur_start, cur_end = 0, None, None
    for start, end in sorted(spans):
        if cur_end is None or start > cur_end:
            if cur_end is not None:
                total += (cur_end - cur_start).total_seconds()
            cur_start, cur_end = start, end
        else:
            cur_end = max(cur_end, end)
    if cur_end is not None:
        total += (cur_end - cur_start).total_seconds()
    return int(total)


def upload_usage(args):
    device = text(args.get("device", "mac"), "device", max_len=64)
    segments = args["segments"]
    if not isinstance(segments, list):
        raise ShionError("invalid_params", "segments must be a list")
    if len(segments) > 5000:
        raise ShionError("invalid_params", "at most 5000 segments per upload")
    now = datetime.now(timezone.utc)
    clean = []
    for i, seg in enumerate(segments):
        if not isinstance(seg, dict) or set(seg) - {"bundle_id", "app_name", "start", "end"}:
            raise ShionError("invalid_params", f"segments[{i}] must be {{bundle_id, app_name, start, end}}")
        bundle = text(seg.get("bundle_id"), f"segments[{i}].bundle_id", max_len=255)
        name = text(seg.get("app_name"), f"segments[{i}].app_name", max_len=255)
        start = instant(seg.get("start"), f"segments[{i}].start")
        end = instant(seg.get("end"), f"segments[{i}].end")
        if end <= start:
            raise ShionError("invalid_params", f"segments[{i}] ends before it starts")
        if end - start > timedelta(hours=24):
            raise ShionError("invalid_params", f"segments[{i}] is longer than 24 hours")
        if end > now + timedelta(minutes=5):
            raise ShionError("invalid_params", f"segments[{i}] ends in the future")
        clean.append((device, bundle, start, end, name))
    counts = {"added": 0, "updated": 0, "unchanged": 0, "expired": 0}
    cutoff = now - timedelta(days=30)
    for device_, bundle, start, end, name in clean:
        if end < cutoff:
            counts["expired"] += 1
            continue
        key = (device_, bundle, start)
        old = usage.get(key)
        if old is None:
            counts["added"] += 1
        elif (old["end"], old["app_name"]) == (end, name):
            counts["unchanged"] += 1
            continue
        else:
            counts["updated"] += 1
        usage[key] = {"bundle_id": bundle, "app_name": name, "start": start, "end": end}
    changed = counts["added"] or counts["updated"]
    return {"received": len(clean), **counts, "revision": bump() if changed else state["revision"]}, \
        (["usage"] if changed else None)


def usage_day(day):
    lo = datetime(day.year, day.month, day.day, tzinfo=TOKYO).astimezone(timezone.utc)
    hi = lo + timedelta(days=1)
    per_app, names, everything = {}, {}, []
    for (device, bundle, _), seg in usage.items():
        start, end = max(seg["start"], lo), min(seg["end"], hi)
        if start < end:
            per_app.setdefault(bundle, []).append((start, end))
            everything.append((start, end))
            names[bundle] = seg["app_name"]
    by_app = sorted(({"bundle_id": b, "app_name": names[b], "category": None, "seconds": union_seconds(spans)}
                     for b, spans in per_app.items()), key=lambda item: (-item["seconds"], item["app_name"]))
    by_category = {c: 0 for c in (*ACTIVITIES, "uncategorized")}
    by_category["uncategorized"] = sum(item["seconds"] for item in by_app)
    return {"date": day.isoformat(), "timezone": "Asia/Tokyo", "total_seconds": union_seconds(everything),
            "by_app": by_app, "by_category": by_category}


def report_focus(args, profile):
    plan = text(args["plan"], "plan", max_len=200)
    off_minutes = integer(args["off_minutes"], "off_minutes", lo=0, hi=24 * 60)
    activity = choice(args["activity"], "activity", ACTIVITIES)
    on_track = boolean(args["on_track"], "on_track")
    record = {"at": iso(datetime.now(TOKYO)), "plan": plan, "off_minutes": off_minutes, "activity": activity,
              "on_track": on_track, "woke": False}
    result = {"recorded": True, "woke": False}
    if profile != CHIEF:
        result["reason"] = "wrong_profile"
    else:
        # 詩音's Bot Chat on the stand-in has had turns, so the plugin knows its routing key, and it
        # is live while Shion is connected: inject_message takes the line
        record["woke"] = result["woke"] = True
    focus_log.append(record)
    return {**result, "latest": dict(record), "revision": bump()}, ["focus"]


def focus_message(report):
    if report["on_track"]:
        return f"［专注检查］已经回到「{report['plan']}」上了。"
    return f"［专注检查］「{report['plan']}」：已经偏离 {report['off_minutes']} 分钟，现在在做{ACTIVITY_LABELS[report['activity']]}。"


def call(name, args, profile):
    """(result, changed topics) for one call; the caller holds the lock."""
    if name == "usage.upload":
        return upload_usage(args)
    if name == "usage.day":
        day = date.fromisoformat(args["date"]) if "date" in args else today()
        return usage_day(day), None
    if name == "focus.report":
        return report_focus(args, profile)
    if name == "focus.latest":
        if not focus_log:
            return {"latest": None}, None
        latest = dict(focus_log[-1])
        latest["age_minutes"] = int((datetime.now(TOKYO) - datetime.fromisoformat(latest["at"])).total_seconds() // 60)
        return {"latest": latest}, None
    if name == "info":
        return {"plugin_version": "ci", "schema_version": 1, "profile": "shion", "timezone": "Asia/Tokyo",
                "today": str(today()), "revision": state["revision"]}, None
    if name == "sync.state":
        return {"revision": state["revision"], "today": str(today()), "timezone": "Asia/Tokyo",
                "topics": {"todos": state["revision"], "today": 1, "reports": 1, "usage": 1, "focus": 1}}, None
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


def chief_answers(conn, log, report):
    """The plugin's inject_message: its line goes into 詩音's Bot Chat as a turn of yours (stored, as
    Hermes stores it), and she answers it there. Shion shows her answer, never the line."""
    hermes = hermes_of(conn)
    line = focus_message(report)
    if report["on_track"]:
        reply = f"（CI）回来了就好，「{report['plan']}」接着做。"
    else:
        reply = f"（CI）「{report['plan']}」已经过了 {report['off_minutes']} 分钟，先回来做十五分钟吧？"
    session_id = getattr(hermes, "sessions", {}).get(CHIEF, "sess-shion") if hermes else "sess-shion"
    if hermes is not None:
        with hermes.lock:
            rows = hermes.transcripts.setdefault(session_id, [])
            rows.append({"row_id": len(rows) + 1000, "row_kind": "message", "role": "user", "text": line,
                         "timestamp": time.time()})
            rows.append({"row_id": len(rows) + 1000, "row_kind": "message", "role": "assistant", "text": reply,
                         "timestamp": time.time()})
    log(f"  -> 詩音 woken on {session_id}: {line} / {reply}")
    try:
        conn.event("message.start", session_id, {})
        conn.event("message.delta", session_id, {"text": reply})
        conn.event("message.complete", session_id, {"text": reply, "status": "complete"})
    except OSError:
        pass


def minutes_text(seconds):
    minutes = seconds // 60
    if minutes < 60:
        return f"{minutes} 分钟"
    return f"{minutes // 60} 小时 {minutes % 60} 分钟" if minutes % 60 else f"{minutes // 60} 小时"


def journal_writes(conn, log):
    """回顾 adds up the screen time from what the Mac uploaded (all of it: the runner's day and Tokyo's
    may differ) and writes today's life report with it, replacing the older one."""
    with lock:
        per_app, names = {}, {}
        for (_, bundle, _), seg in usage.items():
            per_app.setdefault(bundle, []).append((seg["start"], seg["end"]))
            names[bundle] = seg["app_name"]
        apps = sorted(((names[b], union_seconds(spans)) for b, spans in per_app.items()), key=lambda a: (-a[1], a[0]))
        total = union_seconds([span for spans in per_app.values() for span in spans])
        day = str(today())
        reports["life"] = {
            "id": f"{day}-life", "date": day, "kind": "life", "headline": f"（CI）屏幕时间 {minutes_text(total)}",
            "author": "journal", "created_at": iso(datetime.now(TOKYO)), "updated_at": iso(datetime.now(TOKYO)),
            "blocks": [{"heading": "屏幕时间", "items": [f"{name} {minutes_text(seconds)}" for name, seconds in apps]}],
        }
        bump()
    log(f"  回顾 wrote today's screen time: {[f'{n} {s // 60}m' for n, s in apps]}")
    try:
        push(conn, log, ["reports"])
    except OSError:
        pass
