"""The Hermes kanban plugin (/api/plugins/kanban), for the board test on CI (BoardTests).

Shaped like plugins/kanban/dashboard/plugin_api.py and hermes_cli/kanban_workflow.py: the same
routes, the same JSON, the same refusals (400 for running, 409 for a move the workflow does not
allow or a card whose parents are open), and the /events socket that takes its credential from
?token= and sends {"events": [...], "cursor": N}. fake_hermes.py hands it every request under the
prefix; it checks the bearer itself.

Two boards: 「学习（CI）」, the current one, and 「副业（CI）」. With the stand-in's limits (4 at
once, from 2 GB of memory; 1 per assistant) the cards on the first board show each kind of wait:
课程 already has one running, so its ready card waits on it; its todo card waits on a parent;
詩音's ready card waits only for the dispatcher (her running card is on the other board, and the
per-assistant limit counts each board apart).

POST /dispatch is answered but logged as a mistake: Shion must not call it.
Stdlib only.
"""
import base64
import hashlib
import json
import secrets
import threading
import time
import urllib.parse

PREFIX = "/api/plugins/kanban"
PROFILES = ["shion", "study"]

COLUMNS = [("triage", "Triage", True), ("todo", "Todo", True), ("scheduled", "Scheduled", False),
           ("ready", "Ready", True), ("running", "Running", False), ("blocked", "Blocked", True),
           ("review", "Review", False), ("done", "Done", True)]
MANUAL = {
    "triage": ["todo", "ready"],
    "todo": ["triage", "scheduled", "ready"],
    "scheduled": ["triage", "todo", "ready"],
    "ready": ["triage", "todo", "scheduled", "blocked", "review", "done"],
    "running": ["triage", "todo", "scheduled", "ready", "blocked", "review", "done"],
    "blocked": ["triage", "todo", "scheduled", "ready", "done"],
    "review": ["triage", "todo", "ready", "done"],
    "done": ["triage", "todo", "ready"],
    "archived": ["triage", "todo", "ready"],
}

lock = threading.Lock()
boards = {}  # slug -> {"name", "tasks": {id: task}, "links": [(parent, child)], "comments", "events", "runs"}
CURRENT = "study"
_log = print
_valid = lambda token: False  # noqa: E731


def setup(log, valid_access):
    global _log, _valid
    _log, _valid = log, valid_access


def _task(tid, title, assignee, status, ago_min, body=None, started_min=None, done_min=None, summary=None,
          block_kind=None):
    now = int(time.time())
    return {"id": tid, "title": title, "body": body, "assignee": assignee, "status": status, "priority": 0,
            "created_by": "shion" if assignee != "shion" else "dashboard", "created_at": now - ago_min * 60,
            "started_at": now - started_min * 60 if started_min is not None else None,
            "completed_at": now - done_min * 60 if done_min is not None else None,
            "result": None, "block_kind": block_kind, "latest_summary": summary,
            "current_run_started_at": now - started_min * 60 if started_min is not None and status == "running"
            else None}


def seed():
    now = int(time.time())
    study = {"name": "学习（CI）", "tasks": {}, "links": [], "comments": [], "events": [], "runs": []}
    side = {"name": "副业（CI）", "tasks": {}, "links": [], "comments": [], "events": [], "runs": []}
    for t in [
        _task("t_rec8", "整理第8回录音（CI）", "study", "running", 30, body="把录音转写读一遍，列出要做的事。", started_min=6),
        _task("t_dl8", "下载第8回课件（CI）", "study", "ready", 25, body="从 Moodle 下载，存进 Notion。"),
        _task("t_cards8", "做第8回复习卡片（CI）", "study", "todo", 24),
        _task("t_week", "把这周的日程排进日历（CI）", "shion", "ready", 20),
        _task("t_grades", "下载成绩单（CI）", "study", "blocked", 90, body="登录学校门户，下载上学期成绩单。",
              block_kind="needs_input"),
        _task("t_fact", "核实「电费上涨 30%」（CI）", "shion", "done", 200, started_min=190, done_min=170,
              summary="公告里写的是 3%，不是 30%。"),
    ]:
        study["tasks"][t["id"]] = t
    study["links"].append(("t_dl8", "t_cards8"))
    study["comments"].append({"id": 1, "task_id": "t_grades", "author": "study",
                              "body": "门户要两步验证码，发到你的手机了。", "created_at": now - 80 * 60})
    study["runs"] += [
        {"id": 1, "task_id": "t_rec8", "profile": "study", "status": "running", "started_at": now - 360,
         "ended_at": None, "outcome": None, "summary": None, "error": None},
        {"id": 2, "task_id": "t_grades", "profile": "study", "status": "blocked", "started_at": now - 88 * 60,
         "ended_at": now - 80 * 60, "outcome": "blocked", "summary": "要两步验证码", "error": None},
        {"id": 3, "task_id": "t_fact", "profile": "shion", "status": "done", "started_at": now - 190 * 60,
         "ended_at": now - 170 * 60, "outcome": "completed", "summary": "公告里写的是 3%，不是 30%。", "error": None},
    ]
    side["tasks"]["t_invoice"] = _task("t_invoice", "整理副业发票（CI）", "shion", "running", 15, started_min=3)
    boards["study"], boards["side"] = study, side
    event(study, "t_grades", "blocked", {"reason": "门户要两步验证码，等你把验证码发过来", "kind": "needs_input"},
          at=now - 80 * 60)


def event(board, task_id, kind, payload=None, at=None):
    """Appends to the board's task_events; ids are global so a cursor means one thing."""
    all_events = [e for b in boards.values() for e in b["events"]]
    row = {"id": max([e["id"] for e in all_events], default=0) + 1, "task_id": task_id, "run_id": None,
           "kind": kind, "payload": payload, "created_at": at or int(time.time())}
    board["events"].append(row)
    return row


def counts(board):
    out = {}
    for t in board["tasks"].values():
        out[t["status"]] = out.get(t["status"], 0) + 1
    return out


def parents_open(board, tid):
    return [board["tasks"][p] for p, c in board["links"]
            if c == tid and p in board["tasks"] and board["tasks"][p]["status"] not in ("done", "archived")]


def recompute_ready(board):
    for t in board["tasks"].values():
        if t["status"] == "todo" and any(c == t["id"] for _, c in board["links"]) and not parents_open(board, t["id"]):
            t["status"] = "ready"
            event(board, t["id"], "promoted", {"status": "ready"})


def task_dict(board, t):
    d = dict(t)
    d["link_counts"] = {"parents": sum(1 for _, c in board["links"] if c == t["id"]),
                        "children": sum(1 for p, _ in board["links"] if p == t["id"])}
    d["comment_count"] = sum(1 for c in board["comments"] if c["task_id"] == t["id"])
    kids = [board["tasks"][c] for p, c in board["links"] if p == t["id"] and c in board["tasks"]]
    d["progress"] = {"done": sum(k["status"] == "done" for k in kids), "total": len(kids)} if kids else None
    return d


seed()


def route(handler, method, url, query, body):
    """One request under PREFIX; returns after answering."""
    path = url.path[len(PREFIX):] or "/"
    if method == "GET" and path == "/events":
        return events_socket(handler, query)
    bearer = handler.headers.get("Authorization", "").removeprefix("Bearer ").strip()
    if not _valid(bearer):
        return handler.answer(401, {"detail": "Unauthorized"})
    slug = query.get("board") or CURRENT
    with lock:
        board = boards.get(slug)
        if board is None and path != "/boards" and path != "/workflow":
            return handler.answer(404, {"detail": f"board {slug!r} does not exist"})
        status, reply = handle(method, path, board, slug, body)
    if status == 200 and method != "GET":
        _log(f"    kanban {method} {path} on {slug}: {json.dumps(body, ensure_ascii=False)[:120]}")
    return handler.answer(status, reply)


def handle(method, path, board, slug, body):
    if method == "GET" and path == "/workflow":
        return 200, {"columns": [{"key": k, "label": label, "icon": "?", "drag_target": drag}
                                 for k, label, drag in COLUMNS], "manual": MANUAL, "archived": "archived"}
    if method == "GET" and path == "/boards":
        rows = []
        for s, b in boards.items():
            c = counts(b)
            rows.append({"slug": s, "name": b["name"], "description": "", "icon": "", "color": "",
                         "archived": False, "is_current": s == CURRENT, "counts": c,
                         "total": sum(n for k, n in c.items() if k != "archived")})
        return 200, {"boards": rows, "current": CURRENT}
    if method == "GET" and path == "/board":
        columns = {k: [] for k, _, _ in COLUMNS}
        for t in board["tasks"].values():
            if t["status"] in columns:
                columns[t["status"]].append(task_dict(board, t))
        columns["done"].sort(key=lambda d: -(d["completed_at"] or 0))
        latest = max([e["id"] for b in boards.values() for e in b["events"]], default=0)
        return 200, {"columns": [{"name": k, "tasks": v} for k, v in columns.items()], "tenants": [],
                     "assignees": sorted(set(PROFILES) | {t["assignee"] for t in board["tasks"].values()
                                                          if t["assignee"]}),
                     "latest_event_id": latest, "now": int(time.time())}
    if method == "GET" and path == "/assignees":
        names = sorted(set(PROFILES) | {t["assignee"] for t in board["tasks"].values() if t["assignee"]})
        rows = []
        for name in names:
            c = {}
            for t in board["tasks"].values():
                if t["assignee"] == name and t["status"] != "archived":
                    c[t["status"]] = c.get(t["status"], 0) + 1
            rows.append({"name": name, "on_disk": name in PROFILES, "counts": c})
        return 200, {"assignees": rows}
    if method == "POST" and path == "/dispatch":
        _log("    !!! POST /dispatch: Shion must not call it (it ignores the in-progress limits)")
        return 200, {"spawned": []}
    if method == "POST" and path == "/tasks":
        title = (body.get("title") or "").strip()
        if not title:
            return 400, {"detail": "title is required"}
        tid = "t_" + secrets.token_hex(4)
        parents = [p for p in body.get("parents") or [] if p in board["tasks"]]
        t = _task(tid, title, body.get("assignee"), "ready", 0, body=body.get("body"))
        t["created_by"] = "dashboard"
        board["tasks"][tid] = t
        for p in parents:
            board["links"].append((p, tid))
        if parents_open(board, tid) or not t["assignee"]:
            t["status"] = "todo"
        event(board, tid, "created", {"assignee": t["assignee"], "status": t["status"]})
        return 200, {"task": task_dict(board, t)}
    if path.startswith("/tasks/"):
        rest = path[len("/tasks/"):].split("/")
        tid = urllib.parse.unquote(rest[0])
        t = board["tasks"].get(tid)
        if t is None:
            return 404, {"detail": f"task {tid} not found"}
        if method == "GET" and len(rest) == 1:
            links = {"parents": [p for p, c in board["links"] if c == tid],
                     "children": [c for p, c in board["links"] if p == tid]}
            linked = [board["tasks"][i] for i in links["parents"] + links["children"] if i in board["tasks"]]
            return 200, {
                "task": task_dict(board, t),
                "comments": [c for c in board["comments"] if c["task_id"] == tid],
                "events": [e for e in board["events"] if e["task_id"] == tid],
                "attachments": [], "links": links,
                "link_tasks": [{"id": x["id"], "title": x["title"], "status": x["status"]} for x in linked],
                "child_results": [], "runs": [r for r in board["runs"] if r["task_id"] == tid]}
        if method == "POST" and rest[1:] == ["comments"]:
            text = (body.get("body") or "").strip()
            if not text:
                return 400, {"detail": "body is required"}
            board["comments"].append({"id": len(board["comments"]) + 1, "task_id": tid,
                                      "author": body.get("author") or "dashboard", "body": text,
                                      "created_at": int(time.time())})
            event(board, tid, "commented", {"author": body.get("author") or "dashboard"})
            return 200, {"ok": True}
        if method == "PATCH" and len(rest) == 1:
            return patch(board, t, body)
    return 404, {"detail": "Not Found"}


def patch(board, t, body):
    unknown = sorted(set(body) - {"status", "assignee", "priority", "title", "body", "result", "block_reason",
                                  "summary", "metadata"})
    if unknown:
        return 422, {"detail": f"unexpected fields {unknown}"}
    if "assignee" in body:
        t["assignee"] = body["assignee"] or None
    if "title" in body and body["title"] is not None:
        t["title"] = body["title"].strip()
    if "body" in body and body["body"] is not None:
        t["body"] = body["body"]
    status = body.get("status")
    if status is not None:
        src = t["status"]
        if status == "running":
            return 400, {"detail": "Cannot set status to 'running' directly; use the dispatcher/claim path"}
        if status not in MANUAL and status != "archived":
            return 400, {"detail": f"unknown status: {status}"}
        if status != "archived" and status not in MANUAL.get(src, []):
            return 409, {"detail": f"status transition to {status!r} not valid from current state"}
        blockers = parents_open(board, t["id"])
        if status in ("ready", "done", "review") and blockers:
            names = ", ".join(f"{p['title']!r} ({p['id']}, status={p['status']})" for p in blockers)
            return 409, {"detail": f"Cannot move to {status!r}: blocked by parent(s) not done — {names}"}
        now = int(time.time())
        t["status"] = status
        if status == "done":
            t["completed_at"] = now
            for run in board["runs"]:
                if run["task_id"] == t["id"] and run["ended_at"] is None:
                    run.update(ended_at=now, outcome="completed", status="done")
        if status == "blocked":
            t["block_kind"] = "needs_input"
            event(board, t["id"], "blocked", {"reason": body.get("block_reason"), "kind": "needs_input"})
        else:
            event(board, t["id"], "status", {"status": status, "requested_status": status})
        if status == "done":
            recompute_ready(board)
    return 200, {"task": task_dict(board, t)}


# ---- /events --------------------------------------------------------------------------------

def events_socket(handler, query):
    if handler.headers.get("Upgrade", "").lower() != "websocket":
        return handler.answer(400, {"detail": "expected a WebSocket upgrade"})
    slug = query.get("board") or CURRENT
    token_ok = _valid(query.get("token", ""))
    _log(f"  kanban events: board={slug} since={query.get('since')} token={'ok' if token_ok else 'REFUSED'}"
         f" bearer-header={'yes' if handler.headers.get('Authorization') else 'no'}")
    accept = base64.b64encode(hashlib.sha1(
        (handler.headers["Sec-WebSocket-Key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
    handler.send_response(101, "Switching Protocols")
    handler.send_header("Upgrade", "websocket")
    handler.send_header("Connection", "Upgrade")
    handler.send_header("Sec-WebSocket-Accept", accept)
    handler.end_headers()
    handler.wfile.flush()
    handler.close_connection = True
    write = threading.Lock()
    if not token_ok or slug not in boards:
        # as Hermes: the canonical WS gate refuses with 1008
        handler.send_frame(8, (1008).to_bytes(2, "big") + b"policy violation")
        return
    try:
        cursor = int(query.get("since", ""))
    except ValueError:
        cursor = None
    with lock:
        if cursor is None:
            cursor = max([e["id"] for b in boards.values() for e in b["events"]], default=0)
    closed = threading.Event()

    def reader():
        try:
            while not closed.is_set():
                opcode, data = handler.frame()
                if opcode == 8:
                    with write:
                        handler.send_frame(8, data[:2])
                    break
                if opcode == 9:
                    with write:
                        handler.send_frame(10, data)
        except (ConnectionError, OSError, ValueError):
            pass
        closed.set()

    threading.Thread(target=reader, daemon=True).start()
    try:
        while not closed.wait(0.3):
            with lock:
                fresh = [e for e in boards[slug]["events"] if e["id"] > cursor][:200]
            if fresh:
                cursor = fresh[-1]["id"]
                with write:
                    handler.send_frame(1, json.dumps({"events": fresh, "cursor": cursor},
                                                     ensure_ascii=False).encode())
                _log(f"  kanban events: sent {len(fresh)} on {slug}, cursor {cursor}")
    except (ConnectionError, OSError):
        pass
    closed.set()
    _log("  kanban events: closed")
