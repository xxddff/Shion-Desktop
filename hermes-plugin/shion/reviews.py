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

import contextlib
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
#: Nor is bringing a skill back from the archive: it puts back what was there, and whether the
#: files are still as a card left them is checked on the files themselves.
_NOT_A_CHANGE = _BOOKKEEPING + ("restore",)
_REMOVALS = ("delete", "archive", "purge")
#: One review pass makes its changes within seconds; later ones are another card.
_PASS_SECONDS = 300
#: A file's text is cut here on the way to the Mac: a card is read, not downloaded.
_TEXT_LIMIT = 100_000
#: Every card still waiting for you is listed, however old; of the decided ones, the newest.
_DECIDED_LISTED = 200
#: Where Hermes keeps the skills it archived, under the skills directory.
_ARCHIVE = ".archive/"

STATUSES = ("pending", "approved", "rejected")


class Reviews:
    def __init__(self, store, profile: str, ledger):
        self.store = store
        self.profile = profile
        self.ledger = ledger
        self._deciding = threading.Lock()

    # -- cards -------------------------------------------------------------------------------

    def sync(self) -> bool:
        """Files the ledger's new changes on cards. False when Hermes has no ledger to read.

        The ledger is read whole and in order, because what is between two changes decides whether
        they are one card: a change to the same skill by anyone else (you, the assistant in a chat,
        a rollback) closes the card before it, so a card never reaches across a change that is not
        its own."""
        try:
            entries = self._ledger_entries()
        except ShionError:
            return False
        by_id = {e.get("id"): e for e in entries if isinstance(e, dict)}

        def write(conn):
            filed = {row["entry_id"] for row in conn.execute(
                "SELECT entry_id FROM review_entries WHERE profile = ?", (self.profile,))}
            changed = False
            # the skills changed by someone else since their last change of the review's
            interrupted: set[str] = set()
            for entry in entries:
                if not _reviewed(entry):
                    if isinstance(entry, dict) and isinstance(entry.get("skill"), str):
                        interrupted.add(entry["skill"])
                    continue
                apart = entry["skill"] in interrupted
                interrupted.discard(entry["skill"])
                if entry["id"] in filed:
                    continue
                card = None if apart else self._open_card(conn, entry, by_id)
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

    def _open_card(self, conn, entry: dict, by_id: dict) -> Optional[dict]:
        """The card this change joins: the skill's newest, while nothing was decided or discussed on
        it yet and the change is part of the same pass. The second half of a removal (Hermes writes
        a background delete down twice: `_completes`) joins the card of the first whatever session
        it names, and gives the card that session."""
        row = conn.execute("SELECT body FROM skill_reviews WHERE profile = ? AND skill = ? ORDER BY rowid DESC LIMIT 1",
                           (self.profile, entry["skill"])).fetchone()
        if row is None:
            return None
        card = json.loads(row["body"])
        if card["status"] != "pending" or card["review_session"] or card["undone"]:
            return None
        apart = (_moment(_stamp(entry)) - _moment(card["updated_at"])).total_seconds()
        if not 0 <= apart <= _PASS_SECONDS:
            return None
        if _completes(entry, by_id.get(card["entries"][-1])):
            card["session"] = card["session"] or _session(entry)
            return card
        return card if card["session"] == _session(entry) else None

    def list(self) -> dict:
        """Every card still waiting for you, and the newest of the decided ones, newest first."""
        available = self.sync()
        rows = self.store._read(lambda c: c.execute(
            "SELECT body FROM skill_reviews WHERE profile = ? ORDER BY rowid DESC", (self.profile,)).fetchall())
        listed, decided = [], 0
        for card in (json.loads(row["body"]) for row in rows):
            if card["status"] != "pending":
                decided += 1
                if decided > _DECIDED_LISTED:
                    continue
            listed.append(self._out(card))
        return {"reviews": listed, "available": available}

    def _card(self, review_id) -> dict:
        if not isinstance(review_id, str) or not review_id:
            raise ShionError("invalid_params", "id is required")
        row = self.store._read(lambda c: c.execute(
            "SELECT body FROM skill_reviews WHERE profile = ? AND id = ?", (self.profile, review_id)).fetchone())
        if row is None:
            raise ShionError("not_found", f"no skill review {review_id!r} in profile {self.profile!r}")
        return json.loads(row["body"])

    def _change(self, review_id: str, change) -> tuple[dict, int]:
        """Changes a card as it is now: read, checked and written in one transaction, so what
        another call (or another process on the same store) wrote meanwhile is neither lost nor
        written over. ``change`` alters the card it is given, or raises to leave it as it is.
        Returns the card and the store's revision."""
        def write(conn):
            row = conn.execute("SELECT body FROM skill_reviews WHERE profile = ? AND id = ?",
                               (self.profile, review_id)).fetchone()
            if row is None:
                raise ShionError("not_found", f"no skill review {review_id!r} in profile {self.profile!r}")
            card = json.loads(row["body"])
            change(card)
            body = json.dumps(card, ensure_ascii=False)
            if body == row["body"]:
                return card, False
            conn.execute("UPDATE skill_reviews SET body = ? WHERE profile = ? AND id = ?", (body, self.profile, review_id))
            return card, True
        return self.store._write(["reviews"], write)

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
        before, after = _net(_steps(entries))
        files = []
        for path in sorted(before.keys() | after.keys()):
            name = _relative(path, root)
            if name.startswith(_ARCHIVE):
                # where Hermes put a skill it removed: the removal is the card, not this copy
                continue
            old, new = self._text(before.get(path)), self._text(after.get(path))
            complete = complete and old is not False and new is not False
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
        if not isinstance(review_id, str) or not review_id:
            raise ShionError("invalid_params", "id is required")

        def remember(card):
            if card["review_session"] not in (None, session):
                raise ShionError("conflict", "这张卡已经有审核会话了")
            card["review_session"] = session
        return {"review": self._out(self._change(review_id, remember)[0])}

    # -- your decision -----------------------------------------------------------------------

    def decide(self, review_id, decision, entries) -> dict:
        """``approved`` writes the decision down and changes nothing else. ``rejected`` takes the
        card's changes back, newest first, and only while the skill is still as they left it.
        ``entries`` are the changes you looked at: a card that has gained one since is refused."""
        if decision not in ("approved", "rejected"):
            raise ShionError("invalid_params", "decision must be approved or rejected")
        if not isinstance(entries, list) or not all(isinstance(e, str) for e in entries):
            raise ShionError("invalid_params", "entries must be the card's entry ids")

        def settle(card):
            """The decision, on the card as it is at that moment."""
            if card["entries"] != entries:
                raise ShionError("conflict", "这个技能又有了新的变更，请重新看一遍")
            if card["status"] == decision:
                return
            if card["status"] != "pending":
                raise ShionError("conflict", "这张卡已经处理过了")
            card["status"] = decision
            card["decided_at"] = to_storage(self.store.now())

        with self._deciding:
            if decision == "approved":
                self.sync()
                card, revision = self._change(review_id, settle)
                return {"review": self._out(card), "revision": revision}
            # Hermes's own lock on the skill, from before the ledger is read to after the decision
            # is written: nothing writes the skill between the checks and the taking back
            with self.ledger.lock(self._card(review_id)["skill"]):
                self.sync()
                card = self._card(review_id)
                if card["entries"] != entries:
                    raise ShionError("conflict", "这个技能又有了新的变更，请重新看一遍")
                if card["status"] != "rejected":
                    if card["status"] != "pending":
                        raise ShionError("conflict", "这张卡已经处理过了")
                    self._take_back(card)
                card, revision = self._change(review_id, settle)
                return {"review": self._out(card), "revision": revision}

    def _take_back(self, card: dict) -> None:
        """Undoes the card's changes, the newest first, each only from the state it left: a new
        skill goes to Hermes's archive whole, a skill Hermes archived comes back from it, anything
        else is the ledger's rollback of that one change. What was taken back is written on the
        card as it goes, so a refusal half way leaves the card saying how far it got."""
        found, complete = self._entries(card)
        if not complete:
            raise ShionError("unavailable", "Hermes 的技能账本里已经没有这次变更的记录，没法撤销")
        self._refuse_other_changes(card)
        steps = _steps(found)
        if not _in_a_row(steps):
            raise ShionError("conflict", "这张卡的几次变更之间，这个技能被改过；撤销会盖掉那次修改，所以没有撤销")
        left = [step for step in steps if step["id"] not in card["undone"]]
        for path, digest in _net(left)[1].items():
            if _digest(path) != digest:
                raise ShionError("conflict", "这个技能在那之后被改过，撤销会盖掉后来的修改")
        if found[0].get("action") == "create" and not card["undone"] and steps[-1].get("action") != "archive":
            # a skill that was new goes to Hermes's archive whole, where `hermes curator restore` finds it
            ok, message = self.ledger.archive(card["skill"])
            if not ok:
                raise ShionError("undo_failed", message)
            self._undone(card, card["entries"])
            return
        for step in reversed(left):
            # the files this one change wrote, as it wrote them: the changes after it are back already
            if any(_digest(path) != digest for path, digest in _net([step])[1].items()):
                raise ShionError("conflict", "撤销到一半时这个技能的文件和记录的对不上了，剩下的没有再动")
            if step.get("action") == "archive":
                if not self._restores(step):
                    raise ShionError("conflict", "归档里还有一份更早的同名技能，Hermes 会恢复那一份而不是这次归档的；"
                                                 "请用 hermes curator 处理")
                # as `hermes curator restore` does: the files, and Hermes's own record that it is active
                ok, message = self.ledger.restore(card["skill"])
            else:
                ok, message = self.ledger.rollback(step["id"])
            if not ok:
                raise ShionError("undo_failed", message)
            after = found[found.index(step) + 1:][:1]
            self._undone(card, [step["id"]] + [e["id"] for e in after if _completes(e, step)])

    def _restores(self, step: dict) -> bool:
        """Hermes's restore would bring back the copy this archive made. It takes the folder named
        after the skill first; a skill archived while an older copy of that name was still in the
        archive went into a folder of another name (Hermes adds the time), and is not the one."""
        root = self.ledger.skills_dir()
        homes = set()
        for path, digest in _files(step)[1].items():
            parts = Path(_relative(path, root)).parts
            if digest and len(parts) > 2 and parts[0] + "/" == _ARCHIVE:
                homes.add(parts[1])
        return homes <= {step["skill"]} or not (root / _ARCHIVE / step["skill"]).exists()

    def _undone(self, card: dict, entry_ids) -> None:
        """Writes down that these changes were taken back, on the card in the store and on ``card``."""
        def note(stored):
            stored["undone"] = stored["undone"] + [i for i in entry_ids if i not in stored["undone"]]
        card["undone"] = self._change(card["id"], note)[0]["undone"]

    def _refuse_other_changes(self, card: dict) -> None:
        """A change to the skill that is not this card's, made after the card's first, by anyone,
        and still in effect: between the card's changes or after them, taking the card's back would
        take that one with it. (That the files are as the card left them is checked apart; this also
        covers files the card never touched.) What was taken back since, by the ledger's rollback or
        on another card, is not in effect."""
        entries = self._ledger_entries()
        mine = [i for i, e in enumerate(entries) if e.get("id") in card["entries"]]
        if not mine:
            return
        taken_back = {(e.get("evidence") or {}).get("rollback_target") for e in entries if e.get("action") == "rollback"}
        rows = self.store._read(lambda c: c.execute(
            "SELECT body FROM skill_reviews WHERE profile = ? AND skill = ?", (self.profile, card["skill"])).fetchall())
        for row in rows:
            taken_back.update(json.loads(row["body"])["undone"])
        for index, entry in enumerate(entries[mine[0] + 1:], mine[0] + 1):
            if (entry.get("skill") != card["skill"] or entry.get("id") in card["entries"]
                    or entry.get("action") in _NOT_A_CHANGE or entry.get("id") in taken_back):
                continue
            if index > mine[-1]:
                raise ShionError("conflict", "这个技能在那之后又有修改，撤销会盖掉它；请先看新的那张卡")
            raise ShionError("conflict", "这张卡的几次变更之间，这个技能被改过；撤销会盖掉那次修改，所以没有撤销")


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


def _completes(entry: Any, earlier: Any) -> bool:
    """Hermes writes a background delete down twice: the archive that did it, without a session,
    then the delete itself, saying so (``archived``) and naming the session (tools/
    skill_manager_tool.py, ``_delete_skill`` and ``_record_success``). The second is the same
    change as the first."""
    return (isinstance(entry, dict) and isinstance(earlier, dict) and entry.get("action") == "delete"
            and (entry.get("evidence") or {}).get("archived") is True and earlier.get("action") == "archive"
            and entry.get("skill") == earlier.get("skill"))


def _steps(entries: list[dict]) -> list[dict]:
    """``entries`` as the changes they are: without the second half of a removal (`_completes`),
    which says nothing the first did not (its files are the archive's, read before the move)."""
    return [entry for index, entry in enumerate(entries)
            if not (index and _completes(entry, entries[index - 1]))]


def _files(entry: dict) -> tuple[dict, dict]:
    """The files a change touched: each one's digest before and after (absent: no such file)."""
    old = {str(i.get("path")): i.get("sha256") for i in entry.get("before") or [] if i.get("path")}
    new = {str(i.get("path")): i.get("sha256") for i in entry.get("after") or [] if i.get("path")}
    return old, new


def _in_a_row(steps: list[dict]) -> bool:
    """Each change starts from what the one before it left, file by file. Where it does not, the
    file was changed in between by something that is not on the card, whether or not the ledger
    has it (a file edited by hand is in no ledger)."""
    state: dict[str, Optional[str]] = {}
    for step in steps:
        old, new = _files(step)
        for path in old.keys() | new.keys():
            if path in state and state[path] != old.get(path):
                return False
            state[path] = new.get(path)
    return True


def _net(entries: list[dict]) -> tuple[dict, dict]:
    """Each touched file's digest before the first of ``entries`` and after the last (None: no file).
    An entry lists only the files it changed."""
    before: dict[str, Optional[str]] = {}
    after: dict[str, Optional[str]] = {}
    for entry in entries:
        old, new = _files(entry)
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

    def restore(self, skill: str) -> tuple[bool, str]:
        """Brings back a skill Hermes archived, as ``hermes curator restore`` does: its files out of
        ``skills/.archive``, and Hermes's own record that it is in use again. (Rolling the archive's
        entry back would write the files and leave Hermes believing the skill archived.) Hermes puts
        it at the top of the skills directory, also when it was in a category's folder before."""
        from tools import skill_usage
        return self._as_user(lambda: skill_usage.restore_skill(skill))

    def lock(self, skill: str):
        """The lock Hermes holds while it writes a skill (``skill_manage``): held here from the
        checks to the end of taking a change back, so no write lands in between. It is Hermes's
        own function, not on its plugin API: on a Hermes that no longer has it, changes are taken
        back without it, as the checks alone allow, and the log says so."""
        try:
            from tools.skill_manager_tool import _skill_mutation_lock
        except Exception:
            logger.warning("shion: this Hermes has no skill lock to take; taking a change back unlocked")
            return contextlib.nullcontext()
        return _skill_mutation_lock(skill)

    @staticmethod
    def _as_user(act):
        # the ledger says who changed a skill: this change is yours, not the agent's
        from tools import skill_ledger
        token = skill_ledger.set_ledger_actor("user")
        try:
            return act()
        finally:
            skill_ledger.reset_ledger_actor(token)
