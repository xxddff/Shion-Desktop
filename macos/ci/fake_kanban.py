"""The Hermes kanban plugin (/api/plugins/kanban), for the board tests on CI (BoardTests, WorkTests).

Shaped like plugins/kanban/dashboard/plugin_api.py, hermes_cli/kanban_db.py and
hermes_cli/kanban_workflow.py: the same routes, the same JSON (a card carries every Task field; its
latest_summary and current_run_started_at come from its runs, as Hermes derives them), the same
refusals (400 for running, 409 for a move the workflow does not allow or a card whose parents are
open), the same moves (PATCH ready on a blocked card unblocks it; done completes it and clears its
block kind), and the /events socket that takes its credential from ?token= and sends
{"events": [...], "cursor": N}. fake_hermes.py hands it every request under the prefix; it checks
the bearer itself.

Blocks go the way kanban_db.block_task routes them: a `blocked` event with the reason, the kind and
how many times in a row the card stopped for that kind; the same kind again after an unblock is
Hermes's loop breaker, which sends the card to triage with `block_loop_detected` instead. Hermes has
no route for one assistant's cards (list_tasks can filter by assignee, the dashboard route does
not): Shion reads every board's /board and keeps the runs whose profile is the assistant's.

Two boards: 「学习（CI）」, the current one, and 「副业（CI）」. With the stand-in's limits (4 at
once, from 2 GB of memory; 1 per assistant) the cards on the first board show each kind of wait:
课程 already has one running, so its ready card waits on it; its todo card waits on a parent;
詩音's ready card waits only for the dispatcher (her running card is on the other board, and the
per-assistant limit counts each board apart). Three cards are blocked: on a code only you get
(needs_input), on an account it does not have (capability), and on a flaky site (transient, 通勤's).
课程 ran cards on both boards today, and one yesterday.

What the dispatcher and the workers would do next is scripted (`on_ready`, `on_created`): the
first time 「下载成绩单」 is let go on, its worker stops on the same thing again (the loop breaker
sends it to triage); the second time it hands the card in for review, while 「整理第8回录音」 is
done and 詩音's 「把这周的日程排进日历」 stops on a question for you. A card made with 「（CI 通知）」
in its title runs and is done a few seconds later.

POST /dispatch is answered but logged as a mistake: Shion must not call it.
Stdlib only.
"""
import base64
import datetime
import hashlib
import json
import secrets
import threading
import time
import urllib.parse

PREFIX = "/api/plugins/kanban"
PROFILES = ["commute", "shion", "study"]

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
# hermes_cli/kanban_db.py
BLOCK_KINDS = {"dependency", "needs_input", "capability", "transient"}
BLOCK_RECURRENCE_LIMIT = 2

lock = threading.RLock()
# slug -> {"name", "tasks": {id: task}, "links": [(parent, child)], "comments", "events", "runs"}
boards = {}
CURRENT = "study"
resumed = {}  # task id -> how many times it was let go on to ready (the script's cue)
_log = print
_valid = lambda token: False  # noqa: E731


def setup(log, valid_access):
    global _log, _valid
    _log, _valid = log, valid_access


def now():
    return int(time.time())


def midnight():
    """The start of today on this machine: the runner's clock is the App's."""
    return int(datetime.datetime.now().replace(hour=0, minute=0, second=0, microsecond=0).timestamp())


def _task(tid, title, assignee, status, created, body=None):
    """Every field of kanban_db.Task, as the dashboard serialises it (asdict)."""
    return {"id": tid, "title": title, "body": body, "assignee": assignee, "status": status, "priority": 0,
            "created_by": "shion" if assignee != "shion" else "dashboard", "created_at": created,
            "started_at": None, "completed_at": None, "workspace_kind": "scratch", "workspace_path": None,
            "claim_lock": None, "claim_expires": None, "tenant": None, "branch_name": None, "project_id": None,
            "result": None, "idempotency_key": None, "consecutive_failures": 0, "worker_pid": None,
            "last_failure_error": None, "max_runtime_seconds": None, "last_heartbeat_at": None,
            "current_run_id": None, "workflow_template_id": None, "current_step_key": None, "skills": None,
            "model_override": None, "provider_override": None, "reasoning_effort": None, "max_retries": None,
            "goal_mode": False, "goal_max_turns": None, "session_id": None, "block_kind": None,
            "block_recurrences": 0, "completion_contract": None}


def _board(name):
    return {"name": name, "tasks": {}, "links": [], "comments": [], "events": [], "runs": []}


def add(board, task):
    board["tasks"][task["id"]] = task
    return task


def event(board, task_id, kind, payload=None, at=None, run_id=None):
    """Appends to the board's task_events; ids are global so a cursor means one thing."""
    all_events = [e for b in boards.values() for e in b["events"]]
    row = {"id": max([e["id"] for e in all_events], default=0) + 1, "task_id": task_id, "run_id": run_id,
           "kind": kind, "payload": payload, "created_at": at or now()}
    board["events"].append(row)
    return row


def comment(board, tid, author, body, at=None):
    """task_comments: numbered per board."""
    board["comments"].append({"id": len(board["comments"]) + 1, "task_id": tid, "author": author, "body": body,
                              "created_at": at or now()})
    event(board, tid, "commented", {"author": author, "len": len(body)}, at=at)


def first_line(text, limit=400):
    return (text or "").strip().splitlines()[0][:limit] if (text or "").strip() else None


# ---- what the dispatcher and the workers do (kanban_db) --------------------------------------

def _run(board, task, at, outcome=None):
    run = {"id": len(board["runs"]) + 1, "task_id": task["id"], "profile": task["assignee"], "step_key": None,
           "status": "running", "claim_lock": None, "claim_expires": None, "worker_pid": None,
           "max_runtime_seconds": None, "last_heartbeat_at": None, "started_at": at, "ended_at": None,
           "outcome": outcome, "summary": None, "metadata": None, "error": None}
    board["runs"].append(run)
    return run


def _end(board, task, outcome, at, summary=None, error=None, status=None):
    """_end_or_synthesize_run: closes the open run; with none open and a summary, a zero-length one."""
    run = next((r for r in board["runs"] if r["id"] == task["current_run_id"]), None)
    if run is None:
        if not summary:
            return None
        run = _run(board, task, at)
    run.update(status=status or outcome, outcome=outcome, ended_at=at, summary=summary, error=error)
    task.update(current_run_id=None, claim_lock=None, claim_expires=None, worker_pid=None)
    return run


def claim(board, task, at=None):
    """claim_task: ready -> running, with a new run under the assignee's profile."""
    at = at or now()
    task.update(status="running", started_at=task["started_at"] or at)
    run = _run(board, task, at)
    task["current_run_id"] = run["id"]
    event(board, task["id"], "claimed", {"run_id": run["id"]}, at=at, run_id=run["id"])


def crash(board, task, at, error):
    """The worker died: the run closes as crashed and the card goes back to ready for a retry."""
    run = _end(board, task, "crashed", at, error=error)
    task.update(status="ready", consecutive_failures=task["consecutive_failures"] + 1, last_failure_error=error)
    event(board, task["id"], "crashed", {"error": error, "failures": task["consecutive_failures"]}, at=at,
          run_id=run["id"] if run else None)


def block(board, task, kind, reason, at=None):
    """block_task and _route_block: blocked for a person, or triage when the same kind comes back."""
    at = at or now()
    if kind == "dependency":
        task.update(status="todo", block_kind=kind)
        run = _end(board, task, "blocked", at, summary=reason)
        event(board, task["id"], "dependency_wait", {"reason": reason, "kind": kind, "source_status": "ready"},
              at=at, run_id=run["id"] if run else None)
        return
    recurrences = task["block_recurrences"] + 1 if task["block_kind"] == kind else 1
    payload = {"reason": reason, "kind": kind, "recurrences": recurrences, "source_status": "ready"}
    status, kind_of_event = "blocked", "blocked"
    if recurrences >= BLOCK_RECURRENCE_LIMIT:
        payload["limit"] = BLOCK_RECURRENCE_LIMIT
        status, kind_of_event = "triage", "block_loop_detected"
    task.update(status=status, block_kind=kind, block_recurrences=recurrences)
    run = _end(board, task, "blocked", at, summary=reason, status="blocked")
    event(board, task["id"], kind_of_event, payload, at=at, run_id=run["id"] if run else None)


def unblock(board, task, at=None):
    """unblock_task: back to ready (todo while a parent is open); the block's kind and count stay."""
    landing = "todo" if parents_open(board, task["id"]) else "ready"
    task.update(status=landing, current_run_id=None, consecutive_failures=0, last_failure_error=None)
    event(board, task["id"], "unblocked", None if landing == "ready" else {"status": landing, "resume_status": "ready"},
          at=at)


def complete(board, task, at=None, summary=None, result=None):
    """complete_task: done, the run closed with the handoff; only this clears the block kind."""
    at = at or now()
    task.update(status="done", completed_at=at, result=result, block_kind=None, block_recurrences=0,
                consecutive_failures=0, last_failure_error=None)
    run = _end(board, task, "completed", at, summary=summary, status="done")
    event(board, task["id"], "completed", {"result_len": len(result or ""), "summary": first_line(summary)}, at=at,
          run_id=run["id"] if run else None)
    recompute_ready(board)


def archive(board, task, at=None):
    """archive_task: archived (terminal), the claim dropped; a run still open closes as reclaimed
    (_end_run: no run is made up when none is open)."""
    at = at or now()
    task.update(status="archived")
    run = None
    if task["current_run_id"]:
        run = _end(board, task, "reclaimed", at, summary="task archived with run still active", status="reclaimed")
    task.update(claim_lock=None, claim_expires=None, worker_pid=None)
    event(board, task["id"], "archived", None, at=at, run_id=run["id"] if run else None)
    recompute_ready(board)


def request_review(board, task, at=None, summary=None):
    """request_review: the implementer's run closes as review_requested; the card waits in review."""
    at = at or now()
    run = next((r for r in board["runs"] if r["id"] == task["current_run_id"]), None)
    implementer = run["profile"] if run else task["assignee"]
    task.update(status="review")
    run = _end(board, task, "review_requested", at, summary=summary, status="review")
    event(board, task["id"], "review_requested",
          {"summary": first_line(summary), "implementer": implementer, "reviewer": None}, at=at,
          run_id=run["id"] if run else None)


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


def seed():
    at = now()
    day = midnight()
    # cards that ran today stay inside today even on a run just after midnight: the minutes ago
    # shrink, in order, into the time since then
    scale = max(0.0, min(1.0, (at - day - 120) / (240 * 60)))

    def ago(minutes):
        return at - 1 - int(minutes * 60 * scale)

    yesterday = day - 3 * 3600
    study, side = _board("学习（CI）"), _board("副业（CI）")
    boards["study"], boards["side"] = study, side

    rec8 = add(study, _task("t_rec8", "整理第8回录音（CI）", "study", "ready", ago(30), body="把录音转写读一遍，列出要做的事。"))
    claim(study, rec8, ago(6))
    add(study, _task("t_dl8", "下载第8回课件（CI）", "study", "ready", ago(25), body="从 Moodle 下载，存进 Notion。"))
    add(study, _task("t_cards8", "做第8回复习卡片（CI）", "study", "todo", ago(24)))
    study["links"].append(("t_dl8", "t_cards8"))
    add(study, _task("t_week", "把这周的日程排进日历（CI）", "shion", "ready", ago(20)))
    # stopped on a code only you get; it crashed once before that
    grades = add(study, _task("t_grades", "下载成绩单（CI）", "study", "ready", ago(120), body="登录学校门户，下载上学期成绩单。"))
    claim(study, grades, ago(100))
    crash(study, grades, ago(97), "学校门户没有响应（CI）")
    claim(study, grades, ago(88))
    block(study, grades, "needs_input", "门户要两步验证码，等你把验证码发过来", ago(80))
    comment(study, "t_grades", "study", "门户要两步验证码，发到你的手机了。", ago(80))
    # a wall it cannot take down itself: an account it does not have
    moodle = add(study, _task("t_moodle", "登录 Moodle 下载第8回作业（CI）", "study", "ready", ago(70)))
    claim(study, moodle, ago(65))
    block(study, moodle, "capability", "Moodle 要学校的统一认证登录，我这里没有账号（CI）", ago(60))
    # a flaky site: a retry is all it needs
    weather = add(study, _task("t_weather", "查明早上学路上的天气（CI）", "commute", "ready", ago(50)))
    claim(study, weather, ago(46))
    block(study, weather, "transient", "天气网站超时了（CI）", ago(45))
    fact = add(study, _task("t_fact", "核实「电费上涨 30%」（CI）", "shion", "ready", ago(200)))
    claim(study, fact, ago(190))
    complete(study, fact, ago(170), summary="公告里写的是 3%，不是 30%。")
    # yesterday's: not in today's work log
    notes = add(study, _task("t_notes7", "整理第7回笔记（CI）", "study", "ready", yesterday - 3600))
    claim(study, notes, yesterday - 1800)
    complete(study, notes, yesterday, summary="笔记放进了 Notion（CI）。")
    # done today, then archived: the board page shows it no more, 课程's work log does
    quiz = add(study, _task("t_quiz", "核对第8回小测答案（CI）", "study", "ready", ago(150)))
    claim(study, quiz, ago(140))
    complete(study, quiz, ago(130), summary="小测 10 题都对过了，错的 2 题记进了笔记（CI）。")
    archive(study, quiz, ago(10))
    # archived as well, but it ran yesterday
    old = add(study, _task("t_hw6", "整理第6回作业（CI）", "study", "ready", yesterday - 7200))
    claim(study, old, yesterday - 6000)
    complete(study, old, yesterday - 5000, summary="第6回作业整理好了（CI）。")
    archive(study, old, yesterday - 4000)

    invoice = add(side, _task("t_invoice", "整理副业发票（CI）", "shion", "ready", ago(15)))
    claim(side, invoice, ago(3))
    receipt = add(side, _task("t_receipt", "整理副业收据（CI）", "study", "ready", ago(60)))
    claim(side, receipt, ago(55))
    complete(side, receipt, ago(40), summary="收据 12 张，记进了表格（CI）。")
    comment(side, "t_receipt", "study", "原件在「副业」文件夹里（CI）。", ago(40))
    bank = add(side, _task("t_bank", "导出银行流水（CI）", "shion", "ready", ago(35)))
    claim(side, bank, ago(33))
    block(side, bank, "needs_input", "银行要你在手机上点一下确认，点好了告诉我（CI）", ago(30))


def later(seconds, slug, tid, step):
    """A step the dispatcher or a worker takes `seconds` from now, on the card as it is then."""
    def run():
        with lock:
            board = boards[slug]
            task = board["tasks"].get(tid)
            if task is not None:
                step(board, task)
        _log(f"  kanban: {step.__name__} on {tid}")
    threading.Timer(seconds, run).start()


def claimed(board, task):
    if task["status"] == "ready":
        claim(board, task)


def asked_again(board, task):
    if task["status"] == "running":
        block(board, task, "needs_input", "验证码过期了，再发一个新的（CI）")


def handed_in(board, task):
    if task["status"] == "running":
        request_review(board, task, summary="成绩单下载好了，存在 Notion 的「成绩」页（CI）。")


def recorded(board, task):
    if task["status"] == "running":
        complete(board, task, summary="列出了 3 件要做的事（CI）。")


def asks_you(board, task):
    if task["status"] == "ready":
        claim(board, task)
    block(board, task, "needs_input", "周三晚上排作业4还是实验报告？你定一下（CI）")


def finished(board, task):
    if task["status"] == "running":
        complete(board, task, summary="做完了（CI）。")


def on_ready(slug, task):
    """A card a person let go on: the script's next steps for it."""
    resumed[task["id"]] = resumed.get(task["id"], 0) + 1
    if slug != "study" or task["id"] != "t_grades":
        return
    if resumed["t_grades"] == 1:
        later(1.5, slug, "t_grades", claimed)
        later(4.0, slug, "t_grades", asked_again)
    elif resumed["t_grades"] == 2:
        later(1.5, slug, "t_grades", claimed)
        later(8.0, slug, "t_grades", handed_in)
        later(8.0, slug, "t_rec8", recorded)
        later(8.5, slug, "t_week", asks_you)


def on_created(slug, task):
    if "（CI 通知）" in task["title"] and task["assignee"] and task["status"] == "ready":
        later(3.0, slug, task["id"], claimed)
        later(6.0, slug, task["id"], finished)


def assistant_creates(slug, title, assignee, creator, body=None):
    """A card an assistant makes with its kanban_create tool: ready for its assignee, made by its profile."""
    with lock:
        board = boards[slug]
        tid = "t_" + secrets.token_hex(4)
        t = add(board, _task(tid, title, assignee, "ready", now(), body=body))
        t["created_by"] = creator
        event(board, tid, "created", {"assignee": assignee, "status": "ready"})
    _log(f"  kanban: {creator} made {tid} for {assignee} on {slug}")
    return tid


WAKE_GUIDANCE = ("This is an automatic task-status notification, not a request to decompose the task again. "
                 "Inspect the current board before creating follow-up tasks; do not recreate tasks or graphs that "
                 "already exist.")


def wake(tid, title, assignee, board, status="completed", result=None):
    """What `hermes gateway` gives the session that subscribed to a card, as the text of the turn it
    wakes it with (gateway/kanban_watchers_notifier.py build_wake_text, the English of
    `gateway.kanban.wake.*`). Word for word as captured from Hermes 611bf53 on 2026-11-13, with a
    card completed and one blocked ("blocked; needs attention", which has no Result line). Hermes
    stores it as a user row of kind `internal_notification`; the turn's `message.start` says
    nothing of it, and no status line comes ahead of it: a Bot Chat learns of it from the row."""
    text = (f"[kanban] Task {tid} {status}.\nTitle: {title}\nAssignee: @{assignee}\nBoard: {board}\n\n"
            "Check the result or decide the next step.")
    if result:
        text += f"\nResult: {result}"
    return text + "\n\n" + WAKE_GUIDANCE


def worker_completes(slug, tid, summary):
    """The assignee's worker ran the card and finished it, handing off a summary."""
    with lock:
        board = boards[slug]
        t = board["tasks"][tid]
        if t["status"] == "ready":
            claim(board, t, now() - 2)
        complete(board, t, summary=summary)
    _log(f"  kanban: {tid} done on {slug}")


def task_dict(board, t):
    d = dict(t)
    runs = [r for r in board["runs"] if r["task_id"] == t["id"]]
    summaries = sorted((r for r in runs if r["summary"]), key=lambda r: (r["ended_at"] or r["started_at"], r["id"]))
    d["latest_summary"] = summaries[-1]["summary"] if summaries else None
    current = next((r for r in runs if r["id"] == t["current_run_id"]), None)
    d["current_run_started_at"] = current["started_at"] if current else None
    at = now()
    d["age"] = {"created_age_seconds": at - t["created_at"],
                "started_age_seconds": at - t["started_at"] if t["started_at"] else None,
                "time_to_complete_seconds": t["completed_at"] - t["started_at"]
                if t["completed_at"] and t["started_at"] else None}
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
        status, reply = handle(method, path, board, slug, body, query)
    if status == 200 and method != "GET":
        _log(f"    kanban {method} {path} on {slug}: {json.dumps(body, ensure_ascii=False)[:120]}")
    return handler.answer(status, reply)


def handle(method, path, board, slug, body, query=None):
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
        # Hermes: a bool query parameter; the archived cards come in a column of their own
        if str((query or {}).get("include_archived", "")).lower() in ("1", "true", "yes", "on"):
            columns["archived"] = []
        # list_tasks' order: priority, then the oldest first
        for t in sorted(board["tasks"].values(), key=lambda t: (-t["priority"], t["created_at"])):
            if t["status"] in columns:
                columns[t["status"]].append(task_dict(board, t))
        columns["done"].sort(key=lambda d: -(d["completed_at"] or 0))
        latest = max([e["id"] for b in boards.values() for e in b["events"]], default=0)
        return 200, {"columns": [{"name": k, "tasks": v} for k, v in columns.items()], "tenants": [],
                     "assignees": sorted(set(PROFILES) | {t["assignee"] for t in board["tasks"].values()
                                                          if t["assignee"]}),
                     "latest_event_id": latest, "now": now()}
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
        t = add(board, _task(tid, title, body.get("assignee"), "ready", now(), body=body.get("body")))
        t["created_by"] = "dashboard"
        for p in parents:
            board["links"].append((p, tid))
        if parents_open(board, tid) or not t["assignee"]:
            t["status"] = "todo"
        event(board, tid, "created", {"assignee": t["assignee"], "status": t["status"]})
        on_created(slug, t)
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
            runs = sorted((r for r in board["runs"] if r["task_id"] == tid), key=lambda r: (r["started_at"], r["id"]))
            return 200, {
                "task": task_dict(board, t),
                "comments": [c for c in board["comments"] if c["task_id"] == tid],
                "events": [e for e in board["events"] if e["task_id"] == tid],
                "attachments": [], "links": links,
                "link_tasks": [{"id": x["id"], "title": x["title"], "status": x["status"]} for x in linked],
                "child_results": [], "runs": runs}
        if method == "POST" and rest[1:] == ["comments"]:
            text = (body.get("body") or "").strip()
            if not text:
                return 400, {"detail": "body is required"}
            author = body.get("author") or "dashboard"
            _log(f"  kanban comment on {tid} by {author}")
            comment(board, tid, author, text)
            return 200, {"ok": True}
        if method == "PATCH" and len(rest) == 1:
            return patch(board, slug, t, body)
    return 404, {"detail": "Not Found"}


def patch(board, slug, t, body):
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
    if status is None:
        return 200, {"task": task_dict(board, t)}
    src = t["status"]
    if status == "running":
        return 400, {"detail": "Cannot set status to 'running' directly; use the dispatcher/claim path"}
    if status not in MANUAL and status != "archived":
        return 400, {"detail": f"unknown status: {status}"}
    if status != "archived" and status not in MANUAL.get(src, []):
        return 409, {"detail": f"status transition to {status!r} not valid from current state"}
    blockers = parents_open(board, t["id"])
    # an unblock with a parent open lands in todo rather than being refused
    unblocking = status == "ready" and src in ("blocked", "scheduled")
    if status in ("ready", "done", "review") and blockers and not unblocking:
        names = ", ".join(f"{p['title']!r} ({p['id']}, status={p['status']})" for p in blockers)
        return 409, {"detail": f"Cannot move to {status!r}: blocked by parent(s) not done — {names}"}
    if status == "archived":
        archive(board, t)
    elif status == "blocked":
        block(board, t, None, body.get("block_reason"))
    elif status == "done":
        complete(board, t, summary=body.get("summary"), result=body.get("result"))
    elif status == "review":
        request_review(board, t, summary=body.get("summary"))
    elif unblocking:
        unblock(board, t)
    else:
        # _set_status_direct: a move without a verb of its own; leaving running closes the run
        if src == "running":
            _end(board, t, "reclaimed", now(), summary=f"status changed to {status} (dashboard/direct)",
                 status="reclaimed")
        t["status"] = status
        event(board, t["id"], "status", {"status": status, "requested_status": status})
        if status == "ready":
            recompute_ready(board)
    if t["status"] == "ready" and src != "ready":
        on_ready(slug, t)
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
