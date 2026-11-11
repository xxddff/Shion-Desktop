"""Run151 contract fixture: written skills, durable notices and isolated review sessions.

Only invoked by RUN151-learning. Ordinary Bot Chats keep their existing scripts.
"""
import datetime
import time

reviews = {}
notices = {}
created = {}


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def rpc(conn, method, params, rid):
    def reply(value):
        conn.send_json({"jsonrpc": "2.0", "id": rid, "result": value})
        return True
    if method.startswith("plugin.shion.reviews."):
        name = method.rsplit(".", 1)[-1]
        profile = params.get("profile")
        if name == "list": return reply({"reviews": [r for r in reviews.values() if r["profile"] == profile]})
        row = reviews.get(params.get("id"))
        if not row or row["profile"] != profile: return False
        if name == "detail":
            return reply({**row, "context": [{"role": "user", "content": "来源消息 " + str(i)} for i in range(50)],
                          "before": [], "after": [{"path": "ci-skill/SKILL.md", "text": "# CI skill\nUse to check tests."}]})
        if name == "bind":
            row["review_session"] = params["review_session"]
            return reply(row)
        if name == "decide":
            if params.get("entries") != row["entries"]: return False
            row["status"] = params["decision"]
            return reply(row)
    if method.startswith("plugin.shion.notices."):
        key = (params.get("profile"), params.get("source_session"))
        if method.endswith(".record"):
            notices.setdefault(key, {}).setdefault(params["id"], params)
            return reply({"revision": 1})
        if method.endswith(".list"):
            return reply({"notices": list(notices.get(key, {}).values())})
    if method == "session.create" and str(params.get("request_id", "")).startswith("shion-review-"):
        # These are contract assertions, not a permissive fallback to Bot Chat.
        assert params.get("toolsets") == []
        assert params.get("ignore_rules") is True
        assert params.get("follow_profile_config") is False
        sid = created.setdefault(params["request_id"], "review-" + params["request_id"])
        module = __import__("__main__")
        module.transcripts.setdefault(sid, [])
        conn.subscribed.add(sid)
        return reply(conn.snapshot(sid, {}))
    if method == "prompt.submit" and str(params.get("session_id", "")).startswith("review-shion-review-"):
        reply({"accepted": True, "submission_id": params.get("submission_id")})
        answer(conn, params["session_id"], params["text"], "审核结论：技能描述清楚（CI）。")
        return True
    if method == "prompt.submit" and params.get("text") == "RUN151-learning":
        sid = params["session_id"]
        profile = params.get("profile")
        reviews["ci-review"] = {"id": "ci-review", "profile": profile, "session": sid, "skill": "ci-skill",
                                "at": now(), "status": "pending", "entries": ["000000000001"], "review_session": None}
        notices.setdefault((profile, sid), {})["ci-memory"] = {
            "id": "ci-memory", "source_session": sid, "kind": "memory", "text": "用户记忆已更新（CI）", "at": now()}
        reply({"accepted": True, "submission_id": params.get("submission_id")})
        answer(conn, sid, params["text"], "[SILENT]")
        conn.event("review.summary", sid, {"text": "已整理技能与记忆（CI）"})
        return True
    return False


def answer(conn, sid, prompt, text):
    module = __import__("__main__")
    with module.lock:
        rows = module.transcripts.setdefault(sid, [])
        for role, content in (("user", prompt), ("assistant", text)):
            rows.append({"row_id": len(rows) + 8000, "row_kind": "message", "role": role, "text": content, "timestamp": time.time()})
    conn.event("message.start", sid, {})
    conn.event("message.delta", sid, {"text": text[:3]})
    conn.event("message.delta", sid, {"text": text[3:]})
    conn.event("message.complete", sid, {"text": text, "status": "complete"})
    conn.event("session.info", sid, {"running": False})
