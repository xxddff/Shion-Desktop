"""Skills an assistant taught itself, looked at after the fact.

Hermes's background review writes a skill first, and Hermes keeps every change to a skill in its own
ledger (``tools/skill_ledger.py``): each file before and after, who changed it, in which session.
Nothing of that is copied here. This module keeps only what the ledger does not: which changes
belong on one card, what you decided about them, and the session you talked them over in. A skill's
content is read from the ledger, and taking a change back is the ledger's own rollback (or, for a
skill that was new, Hermes's archive), so a rejected change can still be restored with
``hermes curator``.

Everything here is per profile: each profile has its own skills and its own ledger.
"""

from __future__ import annotations

import difflib
import hashlib
import json
import logging
import threading
from datetime import datetime
from pathlib import Path
from typing import Any, Optional

from .errors import ShionError
from .timeutil import to_storage, to_wire

logger = logging.getLogger(__name__)

#: The ledger's actor for what the background review (and the curator) changed on its own.
REVIEWED_ACTOR = "curator"
#: What a rollback writes down about itself: not a change to review, nor one that came "after".
_BOOKKEEPING = ("pre-rollback", "rollback")
_REMOVALS = ("delete", "archive", "purge")
#: One review pass makes its changes within seconds; later ones are another card.
_PASS_SECONDS = 300
#: A file's text is cut here on the way to the Mac: a card is read, not downloaded.
_TEXT_LIMIT = 100_000

STATUSES = ("pending", "approved", "rejected")


class Reviews:
    def __init__(self, store, profile: str, ledger):
        self.store = store
        self.profile = profile
        self.ledger = ledger
        self._deciding = threading.Lock()

    # -- cards -------------------------------------------------------------------------------

    def sync(self) -> bool:
        """Files the ledger's new changes on cards. False when Hermes has no ledger to read."""
        try:
            mine = [e for e in self._ledger_entries() if _reviewed(e)]
        except ShionError:
            return False

        def write(conn):
            filed = {row["entry_id"] for row in conn.execute(
                "SELECT entry_id FROM review_entries WHERE profile = ?", (self.profile,))}
            changed = False
            for entry in mine:
                if entry["id"] in filed:
                    continue
                card = self._open_card(conn, entry)
                if card is None:
                    card = {"id": "sr_" + entry["id"], "profile": self.profile, "skill": entry["skill"],
                            "session": _session(entry), "at": _stamp(entry), "kind": _kind(entry),
                            "entries": [], "status": "pending", "review_session": None, "decided_at": None,
                            "undone": []}
                card["entries"].append(entry["id"])
                card["updated_at"] = _stamp(entry)
                if entry.get("action") in _REMOVALS:
                    card["kind"] = "removed"
                conn.execute("INSERT OR REPLACE INTO skill_reviews VALUES (?, ?, ?, ?)",
                             (self.profile, card["id"], card["skill"], json.dumps(card, ensure_ascii=False)))
                conn.execute("INSERT INTO review_entries VALUES (?, ?, ?)", (self.profile, entry["id"], card["id"]))
                changed = True
            return None, changed
        self.store._write(["reviews"], write)
        return True

    def _ledger_entries(self) -> list[dict]:
        """The profile's ledger, oldest first. A Hermes without one (too old, or the ledger turned
        off and never written) has no skill reviews."""
        try:
            return list(self.ledger.entries())
        except Exception as exc:
            logger.debug("shion: no skill ledger to read", exc_info=True)
            raise ShionError("unavailable", "这台 Hermes 没有可读的技能账本") from exc

    def _open_card(self, conn, entry: dict) -> Optional[dict]:
        """The card this change joins: the skill's newest, while nothing was decided or discussed on
        it yet and the change is part of the same pass."""
        row = conn.execute("SELECT body FROM skill_reviews WHERE profile = ? AND skill = ? ORDER BY rowid DESC LIMIT 1",
                           (self.profile, entry["skill"])).fetchone()
        if row is None:
            return None
        card = json.loads(row["body"])
        if card["status"] != "pending" or card["review_session"] or card["undone"] or card["session"] != _session(entry):
            return None
        apart = (_moment(_stamp(entry)) - _moment(card["updated_at"])).total_seconds()
        return card if 0 <= apart <= _PASS_SECONDS else None

    def list(self) -> dict:
        available = self.sync()
        rows = self.store._read(lambda c: c.execute(
            "SELECT body FROM skill_reviews WHERE profile = ? ORDER BY rowid DESC LIMIT 200", (self.profile,)).fetchall())
        return {"reviews": [self._out(json.loads(row["body"])) for row in rows], "available": available}

    def _card(self, review_id) -> dict:
        if not isinstance(review_id, str) or not review_id:
            raise ShionError("invalid_params", "id is required")
        row = self.store._read(lambda c: c.execute(
            "SELECT body FROM skill_reviews WHERE profile = ? AND id = ?", (self.profile, review_id)).fetchone())
        if row is None:
            raise ShionError("not_found", f"no skill review {review_id!r} in profile {self.profile!r}")
        return json.loads(row["body"])

    def _save(self, card: dict) -> int:
        def write(conn):
            conn.execute("UPDATE skill_reviews SET body = ? WHERE profile = ? AND id = ?",
                         (json.dumps(card, ensure_ascii=False), self.profile, card["id"]))
            return None, True
        return self.store._write(["reviews"], write)[1]

    def _out(self, card: dict) -> dict:
        tz = self.store.tz()
        return {**{k: card[k] for k in ("id", "profile", "skill", "session", "kind", "entries", "status",
                                        "review_session")},
                "at": to_wire(card["at"], tz), "decided_at": to_wire(card["decided_at"], tz)}

    # -- what changed ------------------------------------------------------------------------

    def detail(self, review_id) -> dict:
        """The card with each file it changed, before and after, as text and as a diff, and the skill
        as it is now. ``available`` is false once Hermes has trimmed the ledger past these changes:
        what is still there is given, and the skill's current text always is."""
        card = self._card(review_id)
        entries, complete = self._entries(card)
        root = self.ledger.skills_dir()
        before, after = _net(entries)
        files = []
        for path in sorted(before.keys() | after.keys()):
            old, new = self._text(before.get(path)), self._text(after.get(path))
            complete = complete and old is not False and new is not False
            name = _relative(path, root)
            files.append({"path": name, "before": None if old is False else old, "after": None if new is False else new,
                          "diff": _diff(name, old or "", new or "")})
        return {**self._out(card), "files": files, "available": complete,
                "document": self._document(card["skill"], list(before.keys() | after.keys()), root)}

    def _entries(self, card: dict) -> tuple[list[dict], bool]:
        by_id = {e.get("id"): e for e in self._ledger_entries()}
        found = [by_id[i] for i in card["entries"] if i in by_id]
        return found, len(found) == len(card["entries"])

    def _text(self, digest: Optional[str]):
        """A file's text; None where there was no file; False when the ledger no longer has it."""
        if not digest:
            return None
        data = self.ledger.blob(digest)
        if data is None:
            return False
        if b"\0" in data[:8192]:
            return f"（二进制文件，{len(data)} 字节）"
        text = data.decode("utf-8", errors="replace")
        return text if len(text) <= _TEXT_LIMIT else text[:_TEXT_LIMIT] + "\n…（后面的省略了）"

    def _document(self, skill: str, paths: list[str], root: Path) -> Optional[dict]:
        """The skill's SKILL.md as it is now, found from the files the card touched."""
        for path in paths:
            for folder in Path(path).parents:
                if folder == root or root not in folder.parents:
                    break
                candidate = folder / "SKILL.md"
                if candidate.is_file():
                    text = candidate.read_text(encoding="utf-8", errors="replace")
                    return {"path": _relative(str(candidate), root), "text": text[:_TEXT_LIMIT]}
        return None

    # -- the session it is talked over in ----------------------------------------------------

    def bind(self, review_id, session) -> dict:
        """Remembers the card's own session, once: opening the card again goes back to it."""
        if not isinstance(session, str) or not session.strip() or len(session) > 200:
            raise ShionError("invalid_params", "review_session must be a session id")
        card = self._card(review_id)
        if card["review_session"] not in (None, session):
            raise ShionError("conflict", "这张卡已经有审核会话了")
        if card["review_session"] is None:
            card["review_session"] = session
            self._save(card)
        return {"review": self._out(card)}

    # -- your decision -----------------------------------------------------------------------

    def decide(self, review_id, decision, entries) -> dict:
        """``approved`` writes the decision down and changes nothing else. ``rejected`` takes the
        card's changes back, newest first, and only while the skill is still as they left it.
        ``entries`` are the changes you looked at: a card that has gained one since is refused."""
        if decision not in ("approved", "rejected"):
            raise ShionError("invalid_params", "decision must be approved or rejected")
        if not isinstance(entries, list) or not all(isinstance(e, str) for e in entries):
            raise ShionError("invalid_params", "entries must be the card's entry ids")
        with self._deciding:
            self.sync()
            card = self._card(review_id)
            if card["entries"] != entries:
                raise ShionError("conflict", "这个技能又有了新的变更，请重新看一遍")
            if card["status"] == decision:
                return {"review": self._out(card), "revision": self.store.revision()}
            if card["status"] != "pending":
                raise ShionError("conflict", "这张卡已经处理过了")
            if decision == "rejected":
                self._take_back(card)
            card["status"] = decision
            card["decided_at"] = to_storage(self.store.now())
            revision = self._save(card)
            return {"review": self._out(card), "revision": revision}

    def _take_back(self, card: dict) -> None:
        found, complete = self._entries(card)
        if not complete:
            raise ShionError("unavailable", "Hermes 的技能账本里已经没有这次变更的记录，没法撤销")
        self._refuse_later_changes(card)
        left = [e for e in found if e["id"] not in card["undone"]]
        for path, digest in _net(left)[1].items():
            if _digest(path) != digest:
                raise ShionError("conflict", "这个技能在那之后被改过，撤销会盖掉后来的修改")
        if found[0].get("action") == "create" and not card["undone"]:
            # a skill that was new goes to Hermes's archive whole, where `hermes curator restore` finds it
            ok, message = self.ledger.archive(card["skill"])
            if not ok:
                raise ShionError("undo_failed", message)
            return
        for entry in reversed(left):
            ok, message = self.ledger.rollback(entry["id"])
            if not ok:
                # what was taken back stays so: the card says how far it got, and 拒绝 goes on from there
                self._save(card)
                raise ShionError("undo_failed", message)
            card["undone"].append(entry["id"])

    def _refuse_later_changes(self, card: dict) -> None:
        """A change made to the skill after the card's, by anyone, and still in effect: taking the
        card's back from under it is not this card's to do. (That the files are as the card left
        them is checked apart; this also covers files the card never touched.)"""
        entries = self._ledger_entries()
        last = max((i for i, e in enumerate(entries) if e.get("id") in card["entries"]), default=-1)
        taken_back = {(e.get("evidence") or {}).get("rollback_target") for e in entries if e.get("action") == "rollback"}
        for entry in entries[last + 1:]:
            if (entry.get("skill") == card["skill"] and entry.get("action") not in _BOOKKEEPING
                    and entry.get("id") not in taken_back):
                raise ShionError("conflict", "这个技能在那之后又有修改，撤销会盖掉它；请先看新的那张卡")


# -- the ledger's entries --------------------------------------------------------------------------

def _reviewed(entry: Any) -> bool:
    return (isinstance(entry, dict) and entry.get("actor") == REVIEWED_ACTOR and entry.get("action") not in _BOOKKEEPING
            and isinstance(entry.get("id"), str) and isinstance(entry.get("skill"), str) and bool(entry["skill"])
            and _stamp(entry) is not None)


def _session(entry: dict) -> str:
    return str((entry.get("evidence") or {}).get("session_id") or "")


def _stamp(entry: dict) -> Optional[str]:
    """The entry's time as the store keeps instants."""
    try:
        return to_storage(datetime.fromisoformat(str(entry.get("ts"))))
    except ValueError:
        return None


def _moment(stored: str) -> datetime:
    return datetime.strptime(stored, "%Y-%m-%dT%H:%M:%SZ")


def _kind(entry: dict) -> str:
    action = entry.get("action")
    return "created" if action == "create" else "removed" if action in _REMOVALS else "updated"


def _net(entries: list[dict]) -> tuple[dict, dict]:
    """Each touched file's digest before the first of ``entries`` and after the last (None: no file).
    An entry lists only the files it changed."""
    before: dict[str, Optional[str]] = {}
    after: dict[str, Optional[str]] = {}
    for entry in entries:
        old = {str(i.get("path")): i.get("sha256") for i in entry.get("before") or [] if i.get("path")}
        new = {str(i.get("path")): i.get("sha256") for i in entry.get("after") or [] if i.get("path")}
        for path in old.keys() | new.keys():
            before.setdefault(path, old.get(path))
            after[path] = new.get(path)
    return before, after


def _digest(path: str) -> Optional[str]:
    file = Path(path)
    return hashlib.sha256(file.read_bytes()).hexdigest() if file.is_file() else None


def _relative(path: str, root: Path) -> str:
    try:
        return Path(path).relative_to(root).as_posix()
    except ValueError:
        return Path(path).name


def _diff(name: str, old: str, new: str) -> str:
    lines = difflib.unified_diff(old.splitlines(), new.splitlines(), "变更前/" + name, "变更后/" + name, lineterm="", n=3)
    return "\n".join(lines)[:_TEXT_LIMIT]


class HermesLedger:
    """Hermes's skill ledger, and the two ways Hermes takes a change back, for the profile this
    process serves (``tools/skill_ledger.py`` and ``tools/skill_usage.py``, read at Hermes
    ``611bf53``, 2026-11-12). The ledger is not on Hermes's public plugin API list, so it is
    imported only when used: the plugin loads without it, and then there are no skill reviews."""

    def skills_dir(self) -> Path:
        from hermes_constants import get_hermes_home
        return get_hermes_home() / "skills"

    def entries(self) -> list[dict]:
        """Every change, oldest first."""
        from tools import skill_ledger
        return list(reversed(skill_ledger.list_entries()))

    def blob(self, digest: str) -> Optional[bytes]:
        from tools import skill_ledger
        return skill_ledger.read_blob(digest)

    def rollback(self, entry_id: str) -> tuple[bool, str]:
        """Restores what one change replaced. Hermes checks every file it needs first and writes
        down the state it is about to replace, so the rollback can itself be rolled back."""
        from tools import skill_ledger
        return self._as_user(lambda: skill_ledger.rollback_entry(entry_id))

    def archive(self, skill: str) -> tuple[bool, str]:
        """Moves a skill to ``skills/.archive``, from where ``hermes curator restore`` brings it back."""
        from tools import skill_usage
        return self._as_user(lambda: skill_usage.archive_skill(skill))

    @staticmethod
    def _as_user(act):
        # the ledger says who changed a skill: this change is yours, not the agent's
        from tools import skill_ledger
        token = skill_ledger.set_ledger_actor("user")
        try:
            return act()
        finally:
            skill_ledger.reset_ledger_actor(token)
