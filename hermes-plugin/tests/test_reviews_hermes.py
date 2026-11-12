"""Skill reviews against Hermes itself. Hermes's own skill tool writes the skills, as its background
review does; its ledger is what the cards are read from; and a rejection calls its rollback and its
archive. What test_reviews.py gives a stand-in for is the real module here, so a Hermes whose ledger
the plugin no longer reads right fails here, not on your server.

Skipped where Hermes is not installed (the other tests need only pytest). ../test-with-hermes.sh
runs them in a container that holds Hermes at the commit the plugin was read against, and so does the
workflow's second job (.github/workflows/hermes-plugin.yml); there SHION_REQUIRE_HERMES is set, and a
Hermes that cannot be imported is a failure, not a skip. The home and the skills directory are set up
as Hermes's own ledger tests set theirs up (its tests/tools/test_skill_ledger.py)."""

import json
import os

import pytest

if os.environ.get("SHION_REQUIRE_HERMES"):
    import hermes_constants  # noqa: F401
    from agent import skill_utils
    from tools import skill_ledger, skill_manager_tool, skill_usage
else:
    pytest.importorskip("hermes_constants", reason="Hermes is not installed")
    skill_ledger = pytest.importorskip("tools.skill_ledger")
    skill_manager_tool = pytest.importorskip("tools.skill_manager_tool")
    skill_usage = pytest.importorskip("tools.skill_usage")
    skill_utils = pytest.importorskip("agent.skill_utils")

from tools.skill_manager_guards import mark_background_review_skill_read  # noqa: E402
from tools.skill_provenance import (  # noqa: E402
    BACKGROUND_REVIEW,
    reset_current_write_origin,
    set_current_write_origin,
)

from shion.errors import ShionError  # noqa: E402
from shion.reviews import HermesLedger, Reviews  # noqa: E402

SKILL = """---
name: ci-notes
description: Use when tidying lecture notes. Keeps each one short.
---

# Notes

Keep each note to three lines.
"""
OLD_LINE = "Keep each note to three lines."
NEW_LINE = "Keep each note to two lines."


@pytest.fixture
def skills(tmp_path, monkeypatch):
    """An empty Hermes home of its own; its skills directory."""
    home = tmp_path / "home"
    root = home / "skills"
    root.mkdir(parents=True)
    monkeypatch.setenv("HERMES_HOME", str(home))
    monkeypatch.setattr(skill_ledger, "get_hermes_home", lambda: home)
    monkeypatch.setattr(skill_usage, "get_hermes_home", lambda: home)
    monkeypatch.setattr(skill_manager_tool, "SKILLS_DIR", root)
    monkeypatch.setattr(skill_utils, "get_all_skills_dirs", lambda: [root])
    return root


@pytest.fixture
def reviews(store, skills):
    return Reviews(store, "shion", HermesLedger())


def manage(**call):
    """Hermes's skill tool, as an assistant calls it; the change must have gone through."""
    result = json.loads(skill_manager_tool.skill_manage(**call))
    assert result.get("success") is True and not result.get("staged"), result
    return result


def as_review(act):
    """What `act` does is the background review's doing, as Hermes marks its fork."""
    token = set_current_write_origin(BACKGROUND_REVIEW)
    try:
        return act()
    finally:
        reset_current_write_origin(token)


def learn(skills, session="sess-1"):
    """The review writes the skill. Its text as Hermes left it on disk."""
    as_review(lambda: manage(action="create", name="ci-notes", content=SKILL, session_id=session))
    return (skills / "ci-notes" / "SKILL.md").read_text(encoding="utf-8")


def revise(skills, session="sess-2"):
    """The review changes one line of it, having read it (Hermes's guard asks for that)."""
    document = skills / "ci-notes" / "SKILL.md"

    def patch():
        mark_background_review_skill_read(document)
        return manage(action="patch", name="ci-notes", old_string=OLD_LINE, new_string=NEW_LINE, session_id=session)

    as_review(patch)
    return document.read_text(encoding="utf-8")


def cards(reviews):
    found = reviews.list()
    assert found["available"] is True
    return found["reviews"]


def document(detail):
    [file] = [f for f in detail["files"] if f["path"] == "ci-notes/SKILL.md"]
    return file


def test_a_skill_the_review_wrote_is_a_card_with_its_text(reviews, skills):
    written = learn(skills)
    [card] = cards(reviews)
    assert (card["skill"], card["kind"], card["status"], card["session"]) == ("ci-notes", "created", "pending", "sess-1")
    detail = reviews.detail(card["id"])
    assert detail["available"] is True
    assert (document(detail)["before"], document(detail)["after"]) == (None, written)
    assert detail["document"] == {"path": "ci-notes/SKILL.md", "text": written}


def test_a_skill_you_asked_for_is_no_card(reviews, skills):
    manage(action="create", name="ci-notes", content=SKILL, session_id="sess-1")
    assert cards(reviews) == []


def test_approving_changes_nothing_in_hermes(reviews, skills):
    written = learn(skills)
    [card] = cards(reviews)
    ledger = skill_ledger.list_entries()
    assert reviews.decide(card["id"], "approved", card["entries"])["review"]["status"] == "approved"
    assert (skills / "ci-notes" / "SKILL.md").read_text(encoding="utf-8") == written
    assert skill_ledger.list_entries() == ledger


def test_rejecting_a_new_skill_archives_it_and_hermes_can_restore_it(reviews, skills):
    written = learn(skills)
    [card] = cards(reviews)
    assert reviews.decide(card["id"], "rejected", card["entries"])["review"]["status"] == "rejected"
    assert not (skills / "ci-notes").exists()
    # the archive is yours in the ledger, and nothing to review
    newest = skill_ledger.list_entries(skill="ci-notes")[0]
    assert (newest["action"], newest["actor"]) == ("archive", "user")
    assert [c["status"] for c in cards(reviews)] == ["rejected"]
    # where `hermes curator restore` finds it
    restored, message = skill_usage.restore_skill("ci-notes")
    assert restored, message
    assert (skills / "ci-notes" / "SKILL.md").read_text(encoding="utf-8") == written


def test_rejecting_a_change_restores_what_it_replaced(reviews, skills):
    written = learn(skills)
    [first] = cards(reviews)
    reviews.decide(first["id"], "approved", first["entries"])
    revised = revise(skills)
    second, _ = cards(reviews)
    assert (second["kind"], second["status"], second["session"]) == ("updated", "pending", "sess-2")
    assert second["id"] != first["id"]
    file = document(reviews.detail(second["id"]))
    assert (file["before"], file["after"]) == (written, revised)
    assert "-" + OLD_LINE in file["diff"] and "+" + NEW_LINE in file["diff"]

    reviews.decide(second["id"], "rejected", second["entries"])
    assert (skills / "ci-notes" / "SKILL.md").read_text(encoding="utf-8") == written
    # Hermes wrote the rollback down as yours, with what it replaced, so it can itself be undone
    since = skill_ledger.list_entries(skill="ci-notes")[:2]
    assert {e["action"] for e in since} == {"rollback", "pre-rollback"}
    assert {e["actor"] for e in since} == {"user"}
    assert [c["status"] for c in cards(reviews)] == ["rejected", "approved"]


def test_a_change_made_since_is_not_taken_back_with_it(reviews, skills):
    learn(skills)
    [card] = cards(reviews)
    # you had the assistant change it in the chat afterwards
    manage(action="patch", name="ci-notes", old_string=OLD_LINE, new_string=NEW_LINE, session_id="sess-9")
    yours = (skills / "ci-notes" / "SKILL.md").read_text(encoding="utf-8")
    with pytest.raises(ShionError) as refused:
        reviews.decide(card["id"], "rejected", card["entries"])
    assert refused.value.code == "conflict"
    assert (skills / "ci-notes" / "SKILL.md").read_text(encoding="utf-8") == yours
    assert [c["status"] for c in cards(reviews)] == ["pending"]
