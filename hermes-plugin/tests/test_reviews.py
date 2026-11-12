"""Skill reviews against a ledger that behaves as Hermes's does (tools/skill_ledger.py): entries with
the files a change replaced and wrote, content by digest, a rollback that restores one entry and
writes itself down, and an archive that moves the skill away."""

import hashlib
import json
from datetime import datetime, timedelta, timezone

import pytest

from conftest import FakeCtx
from shion.errors import ShionError
from shion.plugin import ShionPlugin
from shion.reviews import Reviews


class FakeLedger:
    def __init__(self, home):
        self.home = home
        self.rows = []
        self.blobs = {}
        self.calls = []
        self.refuse = None
        self.clock = datetime(2026, 11, 12, 3, 0, tzinfo=timezone.utc)

    # what Reviews reads and calls

    def skills_dir(self):
        return self.home / "skills"

    def entries(self):
        return list(self.rows)

    def blob(self, digest):
        return self.blobs.get(digest)

    def rollback(self, entry_id):
        self.calls.append(("rollback", entry_id))
        if self.refuse == entry_id:
            return False, "missing blob; rollback aborted, nothing was changed"
        entry = next(e for e in self.rows if e["id"] == entry_id)
        kept = {i["path"] for i in entry["before"]}
        self._append("pre-rollback", entry["skill"], actor="user", evidence={"rollback_target": entry_id})
        for item in entry["before"]:
            (self.home / item["path"]).write_bytes(self.blobs[item["sha256"]])
        for item in entry["after"]:
            if item["path"] not in kept:
                (self.home / item["path"]).unlink()
        self._append("rollback", entry["skill"], actor="user", evidence={"rollback_target": entry_id})
        return True, "rolled back"

    def archive(self, skill):
        self.calls.append(("archive", skill))
        if self.refuse == skill:
            return False, f"skill '{skill}' is hub-installed; never archive"
        target = self.skills_dir() / ".archive" / skill
        target.parent.mkdir(parents=True, exist_ok=True)
        (self.skills_dir() / skill).rename(target)
        self._append("archive", skill, actor="user")
        return True, "archived"

    # what the test does to it

    def write(self, skill, text, *, file="SKILL.md", actor="curator", session="s1", action=None, after=0):
        """A change as skill_manage records it: only the file it touched, absolute paths."""
        self.clock += timedelta(seconds=after)
        path = self.skills_dir() / skill / file
        before = [self._item(path)] if path.exists() else []
        if text is None:
            path.unlink()
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        return self._append(action or ("edit" if before else "create"), skill, actor=actor, before=before,
                            after=[] if text is None else [self._item(path)], evidence={"session_id": session})

    def _item(self, path):
        data = path.read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        self.blobs[digest] = data
        return {"path": str(path), "sha256": digest}

    def _append(self, action, skill, *, actor, before=(), after=(), evidence=None):
        self.clock += timedelta(seconds=1)
        entry = {"id": f"{len(self.rows) + 1:012x}", "ts": self.clock.isoformat(), "actor": actor, "action": action,
                 "skill": skill, "evidence": evidence or {}, "before": list(before), "after": list(after)}
        self.rows.append(entry)
        return entry["id"]

    def text(self, skill, file="SKILL.md"):
        path = self.skills_dir() / skill / file
        return path.read_text(encoding="utf-8") if path.exists() else None


@pytest.fixture
def ledger(tmp_path):
    return FakeLedger(tmp_path / "home")


@pytest.fixture
def reviews(store, ledger):
    return Reviews(store, "shion", ledger)


def code(call):
    with pytest.raises(ShionError) as caught:
        call()
    return caught.value.code


def cards(reviews):
    return reviews.list()["reviews"]


def test_one_pass_is_one_card_and_only_the_background_review_is_carded(reviews, ledger, store):
    ledger.write("notes", "v1")
    ledger.write("notes", "ref", file="references/a.md")
    ledger.write("other", "x", actor="agent")           # you asked for this one in the chat
    ledger.write("mail", "m1", session="s2")
    found = cards(reviews)
    assert [(c["skill"], c["kind"], c["status"], len(c["entries"])) for c in found] == [
        ("mail", "created", "pending", 1), ("notes", "created", "pending", 2)]
    assert found[1]["session"] == "s1" and found[1]["at"] == "2026-11-12T12:00:01+09:00"
    assert store.changes_since(0)["topics"] == ["reviews"]
    # reading again files nothing new, so nothing is pushed again
    revision = store.revision()
    assert cards(reviews) == found and store.revision() == revision
    # a later pass on the same skill is its own card
    ledger.write("notes", "v2", after=3600)
    assert [(c["skill"], c["kind"]) for c in cards(reviews)][0] == ("notes", "updated")
    assert len(cards(reviews)) == 3


def test_detail_shows_each_file_before_after_and_as_a_diff(reviews, ledger):
    ledger.write("notes", "line one\nline two\n", actor="agent")
    ledger.write("notes", "line one\nline 2\n")
    ledger.write("notes", "extra", file="references/a.md")
    card, = cards(reviews)
    detail = reviews.detail(card["id"])
    assert detail["available"] and [f["path"] for f in detail["files"]] == ["notes/SKILL.md", "notes/references/a.md"]
    skill, extra = detail["files"]
    assert (skill["before"], skill["after"]) == ("line one\nline two\n", "line one\nline 2\n")
    assert "-line two" in skill["diff"] and "+line 2" in skill["diff"]
    assert (extra["before"], extra["after"]) == (None, "extra")
    assert detail["document"] == {"path": "notes/SKILL.md", "text": "line one\nline 2\n"}
    # the ledger trimmed, or its content collected: what is left is still shown, and says so
    ledger.blobs.pop(hashlib.sha256(b"line one\nline two\n").hexdigest())
    detail = reviews.detail(card["id"])
    assert not detail["available"] and detail["files"][0]["before"] is None and detail["document"]["text"]
    ledger.rows.clear()
    detail = reviews.detail(card["id"])
    assert not detail["available"] and detail["files"] == []
    assert code(lambda: reviews.detail("sr_nope")) == "not_found"


def test_approving_writes_the_decision_down_and_touches_nothing(reviews, ledger):
    ledger.write("notes", "v1")
    card, = cards(reviews)
    done = reviews.decide(card["id"], "approved", card["entries"])["review"]
    assert done["status"] == "approved" and done["decided_at"]
    assert reviews.decide(card["id"], "approved", card["entries"])["review"] == done     # asked twice
    assert code(lambda: reviews.decide(card["id"], "rejected", card["entries"])) == "conflict"
    assert ledger.calls == [] and ledger.text("notes") == "v1"
    assert code(lambda: reviews.decide(card["id"], "maybe", card["entries"])) == "invalid_params"
    assert code(lambda: reviews.decide(card["id"], "approved", "all")) == "invalid_params"


def test_rejecting_a_new_skill_archives_it(reviews, ledger):
    ledger.write("notes", "v1")
    ledger.write("notes", "ref", file="references/a.md")
    card, = cards(reviews)
    assert reviews.decide(card["id"], "rejected", card["entries"])["review"]["status"] == "rejected"
    assert ledger.calls == [("archive", "notes")]
    assert ledger.text("notes") is None and (ledger.skills_dir() / ".archive/notes/SKILL.md").exists()
    # the archive is your change, not another card
    assert len(cards(reviews)) == 1


def test_rejecting_an_edit_restores_what_was_there_newest_change_first(reviews, ledger):
    ledger.write("notes", "mine", actor="user")
    first = ledger.write("notes", "review 1")
    second = ledger.write("notes", "review 2")
    added = ledger.write("notes", "ref", file="references/a.md")
    card, = cards(reviews)
    assert card["kind"] == "updated"
    reviews.decide(card["id"], "rejected", card["entries"])
    assert ledger.calls == [("rollback", added), ("rollback", second), ("rollback", first)]
    assert ledger.text("notes") == "mine" and ledger.text("notes", "references/a.md") is None
    assert [c["status"] for c in cards(reviews)] == ["rejected"]


def test_a_card_that_gained_a_change_since_you_looked_is_refused(reviews, ledger):
    ledger.write("notes", "mine", actor="user")
    ledger.write("notes", "review 1")
    card, = cards(reviews)
    ledger.write("notes", "review 2")
    assert code(lambda: reviews.decide(card["id"], "approved", card["entries"])) == "conflict"
    assert cards(reviews)[0]["status"] == "pending" and len(cards(reviews)[0]["entries"]) == 2


def test_rejecting_never_writes_over_what_came_after(reviews, ledger):
    ledger.write("notes", "mine", actor="user")
    ledger.write("notes", "review 1")
    card, = cards(reviews)
    # edited by hand since, outside the ledger
    (ledger.skills_dir() / "notes/SKILL.md").write_text("by hand")
    assert code(lambda: reviews.decide(card["id"], "rejected", card["entries"])) == "conflict"
    # or changed again through Hermes, by anyone
    ledger.write("notes", "yours again", actor="user")
    assert code(lambda: reviews.decide(card["id"], "rejected", card["entries"])) == "conflict"
    assert ledger.calls == [] and ledger.text("notes") == "yours again"
    # the decision itself can still be written down
    assert reviews.decide(card["id"], "approved", card["entries"])["review"]["status"] == "approved"


def test_an_older_card_and_a_newer_one(reviews, ledger):
    ledger.write("notes", "mine", actor="user")
    ledger.write("notes", "review 1")
    ledger.write("notes", "review 2", after=3600)
    newer, older = cards(reviews)
    assert code(lambda: reviews.decide(older["id"], "rejected", older["entries"])) == "conflict"
    reviews.decide(newer["id"], "rejected", newer["entries"])
    assert ledger.text("notes") == "review 1"
    # with the newer one taken back, the older can be too: the rollback's own entries are not "later changes"
    reviews.decide(older["id"], "rejected", older["entries"])
    assert ledger.text("notes") == "mine"


def test_a_change_that_cannot_be_taken_back_leaves_the_card_waiting(reviews, ledger):
    ledger.write("notes", "mine", actor="user")
    first = ledger.write("notes", "review 1")
    second = ledger.write("notes", "review 2")
    card, = cards(reviews)
    ledger.refuse = second
    assert code(lambda: reviews.decide(card["id"], "rejected", card["entries"])) == "undo_failed"
    assert cards(reviews)[0]["status"] == "pending" and ledger.text("notes") == "review 2"
    # half way: what was taken back stays so, and 拒绝 again goes on from there
    ledger.refuse = first
    assert code(lambda: reviews.decide(card["id"], "rejected", card["entries"])) == "undo_failed"
    assert ledger.text("notes") == "review 1" and cards(reviews)[0]["status"] == "pending"
    ledger.refuse = None
    ledger.calls.clear()
    assert reviews.decide(card["id"], "rejected", card["entries"])["review"]["status"] == "rejected"
    assert ledger.calls == [("rollback", first)] and ledger.text("notes") == "mine"
    # Hermes refusing to archive a new skill is the same: nothing changed, the card waits
    ledger.write("hub", "h1", after=3600)
    new = cards(reviews)[0]
    ledger.refuse = "hub"
    assert code(lambda: reviews.decide(new["id"], "rejected", new["entries"])) == "undo_failed"
    assert cards(reviews)[0]["status"] == "pending"


def test_a_ledger_trimmed_past_the_change_cannot_be_rejected_but_can_be_approved(reviews, ledger):
    ledger.write("notes", "mine", actor="user")
    ledger.write("notes", "review 1")
    card, = cards(reviews)
    ledger.rows.clear()
    assert code(lambda: reviews.decide(card["id"], "rejected", card["entries"])) == "unavailable"
    assert reviews.decide(card["id"], "approved", card["entries"])["review"]["status"] == "approved"


def test_the_review_session_is_remembered_once_and_closes_the_card_to_new_changes(reviews, ledger):
    ledger.write("notes", "v1")
    card, = cards(reviews)
    assert reviews.bind(card["id"], "sess-1")["review"]["review_session"] == "sess-1"
    assert reviews.bind(card["id"], "sess-1")["review"]["review_session"] == "sess-1"
    assert code(lambda: reviews.bind(card["id"], "sess-2")) == "conflict"
    assert code(lambda: reviews.bind(card["id"], " ")) == "invalid_params"
    ledger.write("notes", "v2")      # seconds later, but the card is being discussed already
    assert [len(c["entries"]) for c in cards(reviews)] == [1, 1]


def test_profiles_do_not_see_each_others_cards(reviews, ledger, store):
    ledger.write("notes", "v1")
    card, = cards(reviews)
    other = Reviews(store, "study", FakeLedger(ledger.home / "other"))
    assert cards(other) == [] and code(lambda: other.detail(card["id"])) == "not_found"


def test_without_a_ledger_there_are_no_reviews(store):
    class NoLedger:
        def entries(self):
            raise ImportError("No module named 'tools.skill_ledger'")
    reviews = Reviews(store, "shion", NoLedger())
    assert reviews.list() == {"reviews": [], "available": False}


def test_over_rpc_and_filed_as_soon_as_a_skill_is_written(store, ledger, hermes):
    ctx = FakeCtx()
    plugin = ShionPlugin(ctx, hermes=hermes, store=store, ledger=ledger)
    plugin.register()
    ledger.write("notes", "mine", actor="user")
    ledger.write("notes", "review 1")
    ctx.hooks["post_tool_call"](tool_name="terminal", status="ok")
    assert store.revision() == 0
    ctx.hooks["post_tool_call"](tool_name="skill_manage", status="ok", session_id="s1")
    assert store.changes_since(0)["topics"] == ["reviews"]
    card, = ctx.call("reviews.list", {"profile": "shion"})["reviews"]
    assert ctx.call("reviews.detail", {"id": card["id"]})["review"]["files"][0]["after"] == "review 1"
    assert ctx.call("reviews.bind", {"id": card["id"], "review_session": "sess-1"})["review"]["review_session"] == "sess-1"
    reply = ctx.call("reviews.decide", {"id": card["id"], "decision": "rejected", "entries": card["entries"]})
    assert reply["review"]["status"] == "rejected" and reply["revision"] == store.revision()
    assert ledger.text("notes") == "mine"
    with pytest.raises(ShionError, match="invalid_params"):
        ctx.call("reviews.decide", {"id": card["id"], "decision": "rejected"})
    assert json.dumps(reply)     # plain JSON all the way
