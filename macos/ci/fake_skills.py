"""Skills an assistant taught itself, for the CI stand-in (fake_hermes.py): what ComposeTests needs.

Shaped like Hermes main (2026-11-12) and the shion plugin's `reviews.*` (hermes-plugin/README.md,
技能审核):

- 「学一个技能（CI）」: the turn has nothing to say and answers `[SILENT]` (stored as it is: silence
  is the client's to keep off the screen, gateway/response_filters.py); the review after it says
  what it kept (`review.summary {text}`, gateway/run_turn_runner.py) and a skill card is filed for
  that profile, new. 「再改一下技能（CI）」 files a second card, a change to the same skill, and
  answers in words.
- `plugin.shion.reviews.list`, `.detail`, `.bind`, `.decide`, in the profiles that have the plugin
  (fake_profiles.py). `bind` keeps the first session; `decide` wants the card's own `entries`.
- `session.create` with `request_id` `shion-review-<card id>`: a session of its own. Asserted: no
  title (Hermes would look a titled session up first), no tools (`toolsets: []`, so the talk can
  change no skill and sets off no review of its own), `ignore_rules`.
- a prompt in that session is answered with an opinion on the skill.
"""
import datetime
import threading
import time

import fake_profiles
import fake_words

LEARN = "学一个技能（CI）"
CHANGE = "再改一下技能（CI）"
SUMMARY = "💾 学会了技能 ci-notes；记下了：你喜欢简短的回答（CI）"
OPINION = "审核意见（CI）：这个技能写得清楚，只在整理课堂录音时用得上，建议批准。"
SKILL = "# ci-notes\n整理课堂录音：先转文字，再按小节列要点。\n"

cards = {}  # card id -> the card, as reviews.list gives it
talks = {}  # request id -> the review session it made
lock = threading.Lock()


def now():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def handles_prompt(params):
    return params.get("text") in (LEARN, CHANGE) or str(params.get("session_id", "")).startswith("review-")


def refuse(conn, rid, code, words):
    conn.send_json({"jsonrpc": "2.0", "id": rid, "error": {"code": 4001, "message": "plugin_rpc_failed", "data": {
        "reason": "plugin_rpc_failed", "detail": f"ShionError: {code}: {words}"}}})
    return True


def rpc(conn, log, transcripts, method, params, rid):
    """True when the call was one of these, and answered."""
    def reply(result):
        conn.send_json({"jsonrpc": "2.0", "id": rid, "result": result})
        return True

    if method.startswith("plugin.shion.reviews."):
        profile = params.get("profile")
        if not profile or not fake_profiles.has_plugin(profile, "shion"):
            return False  # no such method there, as for the rest of the plugin
        name = method.rsplit(".", 1)[-1]
        with lock:
            if name == "list":
                mine = [card for card in cards.values() if card["profile"] == profile]
                return reply({"reviews": list(reversed(mine)), "available": True})
            card = cards.get(params.get("id"))
            if card is None or card["profile"] != profile:
                return refuse(conn, rid, "not_found", f"no skill review {params.get('id')!r}")
            if name == "detail":
                before = None if card["kind"] == "created" else SKILL
                after = SKILL if card["kind"] == "created" else SKILL + "遇到听不清的地方标出来（CI）。\n"
                diff = "--- 变更前/ci-notes/SKILL.md\n+++ 变更后/ci-notes/SKILL.md\n@@\n+遇到听不清的地方标出来（CI）。"
                return reply({"review": {**card, "available": True,
                                         "files": [{"path": "ci-notes/SKILL.md", "before": before, "after": after, "diff": diff}],
                                         "document": {"path": "ci-notes/SKILL.md", "text": after}}})
            if name == "bind":
                if card["review_session"] not in (None, params.get("review_session")):
                    return refuse(conn, rid, "conflict", "这张卡已经有审核会话了")
                card["review_session"] = params.get("review_session")
                return reply({"review": card})
            if name == "decide":
                if params.get("entries") != card["entries"]:
                    return refuse(conn, rid, "conflict", "这个技能又有了新的变更，请重新看一遍")
                if card["status"] not in ("pending", params.get("decision")):
                    return refuse(conn, rid, "conflict", "这张卡已经处理过了")
                card["status"] = params.get("decision")
                card["decided_at"] = now()
                log(f"    skill review {card['id']}: {card['status']}")
                return reply({"review": card, "revision": 1})
        return False

    if method == "session.create" and str(params.get("request_id", "")).startswith("shion-review-"):
        assert "title" not in params, "a review session is made by its request id alone"
        assert params.get("toolsets") == [], "a review session has no tools"
        assert params.get("ignore_rules") is True and params.get("hidden") is True
        with lock:
            session_id = talks.setdefault(params["request_id"], "review-" + params["request_id"][len("shion-review-"):])
        log(f"    a review session of its own: {session_id}")
        conn.subscribed.add(session_id)
        return reply(conn.snapshot(session_id, {}))

    if method != "prompt.submit" or not handles_prompt(params):
        return False
    session_id, text = params.get("session_id"), params.get("text", "")
    reply({"status": "queued", "admission_id": f"adm-{rid}"})
    if session_id.startswith("review-"):
        say(conn, transcripts, session_id, text, OPINION)
        return True
    changed = text == CHANGE
    with lock:
        ident = "sr_ci2" if changed else "sr_ci1"
        cards[ident] = {"id": ident, "profile": params.get("profile"), "skill": "ci-notes", "session": session_id,
                        "kind": "updated" if changed else "created", "entries": ["0000000000c2" if changed else "0000000000c1"],
                        "status": "pending", "review_session": None, "at": now(), "decided_at": None}
    say(conn, transcripts, session_id, text, "改好了（CI）。" if changed else "[SILENT]")
    conn.event("review.summary", session_id, {"text": SUMMARY})
    return True


def say(conn, transcripts, session_id, prompt, answer):
    rows = transcripts.setdefault(session_id, [])
    for role, words in (("user", fake_words.sent(prompt)), ("assistant", answer)):
        rows.append({"row_id": len(rows) + 9000, "row_kind": "message", "role": role, "text": words, "timestamp": time.time()})
    conn.event("message.start", session_id, {})
    conn.event("message.delta", session_id, {"text": answer[:4]})
    conn.event("message.delta", session_id, {"text": answer[4:]})
    conn.event("message.complete", session_id, {"text": answer, "status": "complete"})
    conn.event("session.info", session_id, {"running": False})
