"""After-the-fact reviews. Skill bytes remain owned by Hermes' ledger, never copied here.

The adapter reads Hermes' documented on-disk ledger and invokes its public curator CLI.
No dependency on private Hermes Python modules. All queries are scoped to the serving profile.
"""
from __future__ import annotations
import hashlib
import json
import os
import re
import subprocess
import threading
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
from pathlib import Path

from .errors import ShionError

_ID = re.compile(r"^[a-f0-9]{12}$")
_HASH = re.compile(r"^[a-f0-9]{64}$")
_MUTATIONS = {"create", "edit", "patch", "write_file", "remove_file"}


class Ledger:
    def __init__(self, home: Path, profile: str):
        self.home, self.profile = Path(home), profile

    def entries(self):
        path = self.home / "skills" / ".curator_ledger.jsonl"
        if not path.exists():
            return []
        rows = []
        for line in path.read_text(encoding="utf-8-sig").splitlines():
            try:
                row = json.loads(line)
                if isinstance(row, dict) and _ID.fullmatch(str(row.get("id", ""))):
                    rows.append(row)
            except ValueError:
                continue  # an interrupted last append is not a completed mutation
        return rows

    def file(self, relative):
        root = (self.home / "skills").resolve()
        path = (root / relative).resolve()
        if not path.is_relative_to(root) or path == root:
            raise ShionError("invalid_ledger", "技能账本路径不在技能目录内")
        return path

    def blob(self, digest):
        if not isinstance(digest, str) or not _HASH.fullmatch(digest):
            raise ShionError("invalid_ledger", "无效的技能版本")
        path = self.home / ".curator_backups" / "blobs" / digest
        if not path.is_file():
            raise ShionError("version_unavailable", "账本备份已不可用，无法查看或撤销")
        data = path.read_bytes()
        if hashlib.sha256(data).hexdigest() != digest:
            raise ShionError("invalid_ledger", "技能备份校验失败")
        return data

    @contextmanager
    def mutation_lock(self, skill):
        # Same per-skill advisory lock as Hermes skill_manage. Its curator CLI does not
        # acquire this lock; hold it across validation and the public CLI invocation.
        digest = hashlib.sha256(Path(skill).name.encode("utf-8", "surrogatepass")).hexdigest()
        path = self.home / "skills" / ".locks" / (digest + ".lock")
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)

    def command(self, *args):
        try:
            result = subprocess.run(["hermes", "-p", self.profile, "curator", *args],
                                    capture_output=True, text=True, timeout=60, check=False,
                                    env={**os.environ, "HERMES_HOME": str(self.home)})
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise ShionError("rollback_failed", "Hermes 撤销命令未完成，请刷新后检查") from exc
        if result.returncode:
            raise ShionError("rollback_failed", "Hermes 拒绝撤销，请检查服务器的 curator 日志")


class Reviews:
    def __init__(self, store, profile, ledger):
        self.store, self.profile, self.ledger = store, profile, ledger
        self.lock = threading.RLock()

    def context(self, session, history, user="", answer="", turn=""):
        if not session:
            return
        rows = []
        for item in history or []:
            if not isinstance(item, dict) or item.get("role") not in ("user", "assistant"):
                continue
            content = item.get("content", "")
            if isinstance(content, list):
                content = "\n".join(str(p.get("text", "")) for p in content if isinstance(p, dict))
            if isinstance(content, str) and content:
                rows.append({"role": item["role"], "content": content})
        for role, content in (("user", user), ("assistant", answer)):
            if isinstance(content, str) and content and not any(x == {"role": role, "content": content} for x in rows[-2:]):
                rows.append({"role": role, "content": content})
        value = json.dumps({"turn": turn, "at": datetime.now(timezone.utc).isoformat(), "messages": rows[-50:]}, ensure_ascii=False)
        self.store._write([], lambda c: (c.execute("INSERT OR REPLACE INTO review_context VALUES (?, ?, ?)",
                                                  (self.profile, session, value)).rowcount, False))

    def sync(self):
        with self.lock:
            entries = self.ledger().entries()
            contexts = self.store._read(lambda c: {r[0]: json.loads(r[1]) for r in c.execute(
                "SELECT session, body FROM review_context WHERE profile = ?", (self.profile,))})
            def write(c):
                changed = False
                for entry in entries:
                    if entry.get("actor") != "curator" or entry.get("action") not in _MUTATIONS:
                        continue
                    if c.execute("SELECT 1 FROM review_entries WHERE profile=? AND entry_id=?", (self.profile, entry["id"])).fetchone():
                        continue
                    session = (entry.get("evidence") or {}).get("session_id", "")
                    ctx = contexts.get(session)
                    # Historical mutations must never inherit today's unrelated conversation.
                    try:
                        timely = ctx and datetime.fromisoformat(entry.get("ts", "")) >= datetime.fromisoformat(ctx.get("at", ""))
                    except (ValueError, TypeError):
                        timely = False
                    if not timely or not ctx.get("turn"):
                        ctx = {"turn": entry["id"], "messages": []}
                    key = hashlib.sha256(f'{self.profile}|{session}|{ctx["turn"]}|{entry["skill"]}'.encode()).hexdigest()[:24]
                    existing = c.execute("SELECT body FROM skill_reviews WHERE profile=? AND id=?", (self.profile, key)).fetchone()
                    if existing and (json.loads(existing[0]).get("review_session") or json.loads(existing[0])["status"] != "pending"):
                        # Once reviewed (or opened for review), that card's version is frozen.
                        key = hashlib.sha256((key + "|" + entry["id"]).encode()).hexdigest()[:24]
                        existing = None
                    body = json.loads(existing[0]) if existing else {
                        "id": key, "profile": self.profile, "session": session, "skill": entry["skill"],
                        "at": entry.get("ts", ""), "status": "pending", "entries": [],
                        "context": ctx["messages"], "review_session": None}
                    body["entries"].append(entry["id"])
                    body["status"] = "pending"  # a newly written version needs a new decision
                    c.execute("INSERT OR REPLACE INTO skill_reviews VALUES (?, ?, ?)", (self.profile, key, json.dumps(body, ensure_ascii=False)))
                    c.execute("INSERT INTO review_entries VALUES (?, ?, ?)", (self.profile, entry["id"], key))
                    changed = True
                return None, changed
            self.store._write(["reviews"], write)

    def list(self):
        self.sync()
        rows = self.store._read(lambda c: [json.loads(r[0]) for r in c.execute(
            "SELECT body FROM skill_reviews WHERE profile=? ORDER BY rowid DESC", (self.profile,))])
        return [{k: v for k, v in r.items() if k != "context"} for r in rows]

    def get(self, ident):
        row = self.store._read(lambda c: c.execute("SELECT body FROM skill_reviews WHERE profile=? AND id=?",
                                                  (self.profile, ident)).fetchone())
        if row is None:
            raise ShionError("not_found", "找不到这条技能审核记录")
        return json.loads(row[0])

    def save(self, row):
        self.store._write(["reviews"], lambda c: (c.execute("UPDATE skill_reviews SET body=? WHERE profile=? AND id=?",
            (json.dumps(row, ensure_ascii=False), self.profile, row["id"])).rowcount, True))

    def versions(self, row):
        ledger = self.ledger()
        by_id = {e["id"]: e for e in ledger.entries()}
        if any(i not in by_id for i in row["entries"]):
            raise ShionError("version_unavailable", "账本记录已被清理，无法查看或撤销")
        entries = [by_id[i] for i in row["entries"]]
        before, after = {}, {}
        for e in entries:
            b = {i["path"]: i["sha256"] for i in e["before"]}
            a = {i["path"]: i["sha256"] for i in e["after"]}
            for path in b.keys() | a.keys():
                ledger.file(path)
                if path not in before: before[path] = b.get(path)
                after[path] = a.get(path)
        # Fetch every required backup before an action can modify a single file.
        for digest in {i["sha256"] for e in entries for i in e["before"] + e["after"]}:
            if digest: ledger.blob(digest)
        return ledger, entries, before, after

    def detail(self, ident):
        row = self.get(ident)
        ledger, entries, before, after = self.versions(row)
        def texts(manifest):
            return [{"path": path, "text": ledger.blob(digest).decode("utf-8", errors="replace") if digest else None}
                    for path, digest in sorted(manifest.items())]
        # Delta entries need not contain SKILL.md when only a support file changed.
        # Supply the current skill document separately, clearly named, without archiving it.
        document = None
        for path in after.keys() | before.keys():
            file = ledger.file(path)
            for parent in file.parents:
                if parent == (ledger.home / "skills").resolve(): break
                candidate = parent / "SKILL.md"
                if candidate.is_file():
                    checked = ledger.file(str(candidate))
                    document = {"path": str(checked), "text": checked.read_text(encoding="utf-8", errors="replace")}
                    break
            if document: break
        return {**row, "before": texts(before), "after": texts(after), "current_skill": document}

    def decide(self, ident, decision, expected):
        row = self.get(ident)
        with self.lock, self.ledger().mutation_lock(row["skill"]):
            return self._decide(ident, decision, expected)

    def _decide(self, ident, decision, expected):
        if decision not in ("approved", "rejected"):
            raise ShionError("invalid_params", "无效的审核操作")
        with self.lock:
            self.sync()
            row = self.get(ident)
            if row["entries"] != expected:
                raise ShionError("conflict", "技能又有了新变更，请重新查看")
            if row["status"] == decision: return row
            if row["status"] != "pending":
                raise ShionError("conflict", "这条审核已处理，请刷新")
            ledger, entries, before, after = self.versions(row)
            all_entries = ledger.entries()
            last = max(i for i, entry in enumerate(all_entries) if entry["id"] in row["entries"])
            if any(e.get("skill") == row["skill"] for e in all_entries[last + 1:]):
                raise ShionError("conflict", "技能已有后续账本变更，请重新审核")
            for path, digest in after.items():
                file = ledger.file(path)
                current = hashlib.sha256(file.read_bytes()).hexdigest() if file.is_file() else None
                if current != digest:
                    raise ShionError("conflict", "技能已被后续修改，不能覆盖；请重新审核")
            if decision == "rejected":
                creating = entries[0]["action"] == "create"
                if creating:
                    # An unrecorded file added since creation is also a later modification.
                    roots = [ledger.file(p).parent for p in after if Path(p).name == "SKILL.md"]
                    known = {ledger.file(p) for p, digest in after.items() if digest}
                    if not roots or any(f.is_file() and f.resolve() not in known for root in roots for f in root.rglob("*")):
                        raise ShionError("conflict", "技能目录有未记录的新文件，不能整包归档")
                completed = []
                try:
                    if creating:
                        ledger.command("archive", row["skill"])
                    else:
                        for entry in reversed(entries):
                            ledger.command("rollback", entry["id"], "--yes")
                            completed.append(entry["id"])
                except ShionError:
                    row["status"] = "rollback_failed"
                    row["rolled_back"] = completed
                    self.save(row)
                    raise
            row["status"] = decision
            self.save(row)
            return row

    def notice(self, ident, session, text, at, kind="review.summary"):
        if not all(isinstance(x, str) and x for x in (ident, session, text, at, kind)) or len(text) > 64000:
            raise ShionError("invalid_params", "invalid notice")
        return self.store._write(["reviews"], lambda c: (None, c.execute(
            "INSERT OR IGNORE INTO review_notices VALUES (?, ?, ?, ?, ?, ?)",
            (self.profile, ident, session, text, at, kind)).rowcount > 0))[1]

    def bind(self, ident, session):
        if not isinstance(session, str) or not session.strip() or len(session) > 256:
            raise ShionError("invalid_params", "invalid review session")
        with self.lock:
            row = self.get(ident)
            if row["review_session"] and row["review_session"] != session:
                raise ShionError("conflict", "此技能已有审核会话，请刷新")
            row["review_session"] = session
            self.save(row)
            return row
