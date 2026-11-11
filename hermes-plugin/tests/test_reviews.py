import hashlib
import json
from datetime import datetime, timezone, timedelta

import pytest

from shion.errors import ShionError
from shion.reviews import Ledger, Reviews
from shion.plugin import ShionPlugin
from conftest import FakeCtx, FakeHermes


class FixtureLedger(Ledger):
    def __init__(self, home):
        super().__init__(home, "shion")
        self.calls = []
        self.failure = False

    def command(self, *args):
        self.calls.append(args)
        if self.failure: raise ShionError("rollback_failed", "failed")
        if args[0] == "rollback":
            entry = next(e for e in self.entries() if e["id"] == args[1])
            before = {r["path"]: r["sha256"] for r in entry["before"]}
            for row in entry["after"]:
                if row["path"] not in before: self.file(row["path"]).unlink(missing_ok=True)
            for path, digest in before.items(): self.file(path).write_bytes(self.blob(digest))
        elif args[0] == "archive":
            src = self.home / "skills" / args[1]
            dest = self.home / "skills" / ".archive" / args[1]
            dest.parent.mkdir(parents=True, exist_ok=True)
            src.rename(dest)

    def add(self, ident, *, before=None, after="new", action="edit", session="chat", actor="curator", at=None):
        file = self.home / "skills/test-skill/SKILL.md"
        file.parent.mkdir(parents=True, exist_ok=True)
        def manifest(text):
            if text is None: return []
            digest = hashlib.sha256(text.encode()).hexdigest()
            path = self.home / ".curator_backups/blobs" / digest
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
            return [{"path": str(file), "sha256": digest}]
        row = dict(id=ident, skill="test-skill", actor=actor, action=action,
                   before=manifest(before), after=manifest(after), evidence={"session_id": session},
                   ts=at or (datetime.now(timezone.utc) + timedelta(seconds=1)).isoformat())
        with (self.home / "skills/.curator_ledger.jsonl").open("a") as out: out.write(json.dumps(row) + "\n")
        if after is None: file.unlink(missing_ok=True)
        else: file.write_text(after)
        return row


@pytest.fixture
def system(tmp_path, store):
    ledger = FixtureLedger(tmp_path / "profile")
    return Reviews(store, "shion", lambda: ledger), ledger


def test_written_first_approve_is_idempotent(system):
    reviews, ledger = system
    ledger.add("000000000001", action="create")
    row = reviews.list()[0]
    assert ledger.file("test-skill/SKILL.md").read_text() == "new"
    assert row["status"] == "pending"
    assert reviews.decide(row["id"], "approved", row["entries"])["status"] == "approved"
    assert reviews.decide(row["id"], "approved", row["entries"])["status"] == "approved"
    assert not ledger.calls
    with pytest.raises(ShionError, match="conflict"): reviews.decide(row["id"], "rejected", row["entries"])


def test_reject_new_skill_archives(system):
    reviews, ledger = system
    ledger.add("000000000001", action="create")
    row = reviews.list()[0]
    reviews.decide(row["id"], "rejected", row["entries"])
    assert ledger.calls == [("archive", "test-skill")]
    assert (ledger.home / "skills/.archive/test-skill/SKILL.md").read_text() == "new"


def test_group_turn_restore_reverse_order_context_limit_and_binding(system):
    reviews, ledger = system
    reviews.context("chat", [{"role": "user", "content": str(i)} for i in range(60)] +
                    [{"role": "tool", "content": "not context"}], turn="turn-1")
    ledger.add("000000000001", before="original", after="second")
    ledger.add("000000000002", before="second", after="third")
    row, = reviews.list()
    assert len(row["entries"]) == 2
    detail = reviews.detail(row["id"])
    assert len(detail["context"]) == 50 and detail["context"][0]["content"] == "10"
    assert detail["before"][0]["text"] == "original" and detail["after"][0]["text"] == "third"
    reviews.bind(row["id"], "separate-chat")
    assert reviews.get(row["id"])["review_session"] == "separate-chat"
    with pytest.raises(ShionError, match="conflict"): reviews.bind(row["id"], "another")
    reviews.decide(row["id"], "rejected", row["entries"])
    assert ledger.file("test-skill/SKILL.md").read_text() == "original"
    assert ledger.calls == [("rollback", "000000000002", "--yes"), ("rollback", "000000000001", "--yes")]


def test_expired_ledger_or_blob_never_mutates(system):
    reviews, ledger = system
    entry = ledger.add("000000000001", before="original")
    row = reviews.list()[0]
    (ledger.home / ".curator_backups/blobs" / entry["before"][0]["sha256"]).unlink()
    with pytest.raises(ShionError, match="version_unavailable"): reviews.decide(row["id"], "rejected", row["entries"])
    assert not ledger.calls
    (ledger.home / "skills/.curator_ledger.jsonl").write_text("")
    assert reviews.list()[0]["status"] == "pending"
    with pytest.raises(ShionError, match="version_unavailable"): reviews.detail(row["id"])


def test_conflicts_in_current_file_and_later_ledger(system):
    reviews, ledger = system
    ledger.add("000000000001", before="original")
    row = reviews.list()[0]
    ledger.file("test-skill/SKILL.md").write_text("manual change")
    with pytest.raises(ShionError, match="conflict"): reviews.decide(row["id"], "rejected", row["entries"])
    ledger.add("000000000002", before="manual change", after="new", actor="agent")
    with pytest.raises(ShionError, match="conflict"): reviews.decide(row["id"], "rejected", row["entries"])
    assert not ledger.calls


def test_historical_entries_do_not_take_current_context_or_cross_profiles(system, store):
    reviews, ledger = system
    reviews.context("chat", [{"role": "user", "content": "today"}], turn="today")
    ledger.add("000000000001", action="create", at="2000-01-01T00:00:00+00:00")
    row = reviews.list()[0]
    assert reviews.detail(row["id"])["context"] == []
    with pytest.raises(ShionError, match="not_found"): Reviews(store, "other", lambda: ledger).get(row["id"])
    with pytest.raises(ShionError, match="invalid_ledger"): ledger.file("../outside")


def test_failed_rollback_has_explicit_status(system):
    reviews, ledger = system
    ledger.add("000000000001", before="original")
    row = reviews.list()[0]
    ledger.failure = True
    with pytest.raises(ShionError, match="rollback_failed"): reviews.decide(row["id"], "rejected", row["entries"])
    assert reviews.get(row["id"])["status"] == "rollback_failed"


def test_memory_events_durable_deduped_and_never_injected(store, tmp_path):
    ctx, hermes = FakeCtx(), FakeHermes()
    hermes.profile_home = lambda: tmp_path
    plugin = ShionPlugin(ctx, hermes=hermes, store=store)
    plugin.register()
    kw = dict(tool_name="memory", status="ok", session_id="chat", tool_call_id="call-1",
              args={"target": "user", "operations": [{"action": "add", "content": "prefers concise replies"}]},
              result=json.dumps({"success": True}))
    plugin.on_post_tool_call(**kw)
    plugin.on_post_tool_call(**kw)
    notices = ctx.call("notices.list", {"source_session": "chat"})["notices"]
    assert len(notices) == 1 and notices[0]["kind"] == "memory" and not ctx.injected
    plugin.on_post_tool_call(**{**kw, "tool_call_id": "failed", "result": '{"success": false}'})
    assert len(ctx.call("notices.list", {"source_session": "chat"})["notices"]) == 1
    event = {"id": "epoch:5", "source_session": "chat", "text": "learned", "at": "2026-11-11T12:00:00Z"}
    first = ctx.call("notices.record", event)
    assert ctx.call("notices.record", event) == first
    assert len(ctx.call("notices.list", {"source_session": "chat"})["notices"]) == 2
    assert not ctx.call("notices.list", {"source_session": "other"})["notices"]
