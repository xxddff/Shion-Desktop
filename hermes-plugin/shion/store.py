"""The shared SQLite store.

One file serves every profile and every process: the gateway (assistant turns, plugin RPC from the
Mac) and the kanban workers it spawns as ``hermes -p <profile> chat -q`` subprocesses. So every call
opens its own connection, writes take ``BEGIN IMMEDIATE``, and the file runs in WAL mode.

Every write bumps one ``revision`` and records which topics it touched; the change watcher turns
that into a push event, and ``changes_since`` lets a client that missed events catch up.

Nothing here imports Hermes.
"""

from __future__ import annotations

import json
import re
import secrets
import sqlite3
import threading
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Iterable, Optional

from .errors import ShionError
from .timeutil import (
    day_bounds, from_storage, local_date, parse_bound, parse_date, parse_instant, to_storage, to_wire, zone,
)

SCHEMA_VERSION = 1

AREAS = ("study", "work", "life")
REPORT_KINDS = ("study", "work", "life", "news")
ACTIVITIES = ("study", "work", "life", "fun", "social", "other")
CATEGORIES = ACTIVITIES
UNCATEGORIZED = "uncategorized"
TOPICS = ("todos", "today", "reports", "usage", "focus", "settings")

#: ``source`` of a todo added from the Shion app rather than by an assistant.
USER_SOURCE = "你自己加的"

DEFAULT_SETTINGS = {
    "timezone": "Asia/Tokyo",
    "usage_retention_days": 30,
    "focus_retention_days": 7,
    "chief_profile": "shion",
}

_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
_PROFILE_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
_CHANGES_KEEP_DAYS = 7

# Built-in app categories, for apps whose bundle id says what they are for. Browsers and mail are left
# out on purpose: what you do in them depends on the page. ``set_app_category`` overrides any of these.
BUILTIN_CATEGORIES = {
    "com.apple.dt.Xcode": "work",
    "com.microsoft.VSCode": "work",
    "com.todesktop.230313mzl4w4u92": "work",  # Cursor
    "com.googlecode.iterm2": "work",
    "com.apple.Terminal": "work",
    "com.mitchellh.ghostty": "work",
    "com.tinyspeck.slackmacgap": "work",
    "com.microsoft.teams2": "work",
    "us.zoom.xos": "work",
    "com.microsoft.Word": "work",
    "com.microsoft.Excel": "work",
    "com.microsoft.Powerpoint": "work",
    "com.apple.iWork.Pages": "work",
    "com.apple.iWork.Numbers": "work",
    "com.apple.iWork.Keynote": "work",
    "com.figma.Desktop": "work",
    "notion.id": "study",
    "com.apple.iBooksX": "study",
    "net.ankiweb.dtop": "study",
    "com.apple.Preview": "study",
    "jp.naver.line.mac": "social",
    "com.tencent.xinWeChat": "social",
    "com.hnc.Discord": "social",
    "ru.keepcoder.Telegram": "social",
    "com.apple.MobileSMS": "social",
    "com.apple.FaceTime": "social",
    "com.spotify.client": "fun",
    "com.apple.Music": "fun",
    "com.apple.TV": "fun",
    "com.valvesoftware.steam": "fun",
    "com.apple.iCal": "life",
    "com.apple.reminders": "life",
    "com.apple.Maps": "life",
}

_SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS changes (
    revision INTEGER NOT NULL, topic TEXT NOT NULL, at TEXT NOT NULL, PRIMARY KEY (revision, topic));
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS todos (
    id TEXT PRIMARY KEY, title TEXT NOT NULL, area TEXT NOT NULL, source TEXT NOT NULL, source_detail TEXT,
    do_at TEXT, due_at TEXT, done INTEGER NOT NULL DEFAULT 0, nudges INTEGER NOT NULL DEFAULT 0,
    proposed INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, completed_at TEXT);
CREATE INDEX IF NOT EXISTS todos_do_at ON todos (do_at);
CREATE INDEX IF NOT EXISTS todos_due_at ON todos (due_at);
CREATE TABLE IF NOT EXISTS today (
    date TEXT PRIMARY KEY, text TEXT NOT NULL, author TEXT NOT NULL, updated_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS reports (
    date TEXT NOT NULL, kind TEXT NOT NULL, headline TEXT, blocks TEXT NOT NULL, author TEXT NOT NULL,
    created_at TEXT NOT NULL, updated_at TEXT NOT NULL, PRIMARY KEY (date, kind));
CREATE TABLE IF NOT EXISTS usage_segments (
    device TEXT NOT NULL, bundle_id TEXT NOT NULL, start TEXT NOT NULL, end TEXT NOT NULL,
    app_name TEXT NOT NULL, uploaded_at TEXT NOT NULL, PRIMARY KEY (device, bundle_id, start));
CREATE INDEX IF NOT EXISTS usage_end ON usage_segments (end);
CREATE TABLE IF NOT EXISTS app_categories (
    bundle_id TEXT PRIMARY KEY, category TEXT NOT NULL, set_by TEXT NOT NULL, updated_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS focus_reports (
    id INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT NOT NULL, plan TEXT NOT NULL, off_minutes INTEGER NOT NULL,
    activity TEXT NOT NULL, on_track INTEGER NOT NULL, woke INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS session_keys (
    profile TEXT NOT NULL, session_id TEXT NOT NULL, session_key TEXT NOT NULL, platform TEXT NOT NULL,
    seen_at TEXT NOT NULL, PRIMARY KEY (profile, session_id));
"""


def _text(value, field: str, *, max_len: int, required: bool = True, allow_empty: bool = False) -> Optional[str]:
    if value is None and not required:
        return None
    if not isinstance(value, str):
        raise ShionError("invalid_params", f"{field} must be a string")
    text = value.strip()
    if not text and not allow_empty:
        raise ShionError("invalid_params", f"{field} must not be empty")
    if len(text) > max_len:
        raise ShionError("invalid_params", f"{field} is longer than {max_len} characters")
    return text


def _choice(value, field: str, choices: Iterable[str]) -> str:
    choices = tuple(choices)
    if value not in choices:
        raise ShionError("invalid_params", f"{field} must be one of {', '.join(choices)}")
    return value


def _bool(value, field: str) -> bool:
    if not isinstance(value, bool):
        raise ShionError("invalid_params", f"{field} must be true or false")
    return value


def _int(value, field: str, *, lo: int, hi: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not lo <= value <= hi:
        raise ShionError("invalid_params", f"{field} must be an integer from {lo} to {hi}")
    return value


class Store:
    def __init__(self, path: Path, *, clock: Callable[[], datetime] | None = None):
        self.path = Path(path)
        self._clock = clock or (lambda: datetime.now(timezone.utc))
        self._init_lock = threading.Lock()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._init()

    # -- plumbing ----------------------------------------------------------------------------

    def now(self) -> datetime:
        return self._clock().astimezone(timezone.utc).replace(microsecond=0)

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.path, timeout=15, isolation_level=None)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA busy_timeout = 15000")
        return conn

    def _init(self) -> None:
        with self._init_lock:
            conn = self._connect()
            try:
                try:
                    conn.execute("PRAGMA journal_mode = WAL")
                except sqlite3.OperationalError:
                    pass  # a filesystem without WAL support keeps the default journal
                conn.execute("BEGIN IMMEDIATE")
                for statement in filter(None, (s.strip() for s in _SCHEMA.split(";"))):
                    conn.execute(statement)
                conn.execute("INSERT OR IGNORE INTO meta VALUES ('schema_version', ?)", (str(SCHEMA_VERSION),))
                conn.execute("INSERT OR IGNORE INTO meta VALUES ('revision', '0')")
                conn.execute("INSERT OR IGNORE INTO meta VALUES ('changes_floor', '0')")
                conn.execute("COMMIT")
            finally:
                conn.close()

    def _read(self, fn):
        conn = self._connect()
        try:
            return fn(conn)
        finally:
            conn.close()

    def _write(self, topics: Iterable[str], fn):
        """Run ``fn(conn)`` in one write transaction; when it reports a change, bump the revision.

        ``fn`` returns ``(result, changed)``. Returns ``(result, revision)``."""
        conn = self._connect()
        try:
            conn.execute("BEGIN IMMEDIATE")
            try:
                result, changed = fn(conn)
                revision = int(conn.execute("SELECT value FROM meta WHERE key = 'revision'").fetchone()[0])
                if changed:
                    revision += 1
                    now = to_storage(self.now())
                    conn.execute("UPDATE meta SET value = ? WHERE key = 'revision'", (str(revision),))
                    conn.executemany("INSERT OR IGNORE INTO changes VALUES (?, ?, ?)",
                                     [(revision, topic, now) for topic in topics])
                    self._trim_changes(conn)
                conn.execute("COMMIT")
            except BaseException:
                conn.execute("ROLLBACK")
                raise
            return result, revision
        finally:
            conn.close()

    def _trim_changes(self, conn) -> None:
        cutoff = to_storage(self.now() - timedelta(days=_CHANGES_KEEP_DAYS))
        row = conn.execute("SELECT MAX(revision) FROM changes WHERE at < ?", (cutoff,)).fetchone()
        if row[0] is not None:
            conn.execute("DELETE FROM changes WHERE revision <= ?", (row[0],))
            conn.execute("UPDATE meta SET value = ? WHERE key = 'changes_floor'", (str(row[0]),))

    # -- settings ----------------------------------------------------------------------------

    def settings(self) -> dict:
        def read(conn):
            stored = {row["key"]: json.loads(row["value"]) for row in conn.execute("SELECT * FROM settings")}
            return {**DEFAULT_SETTINGS, **{k: v for k, v in stored.items() if k in DEFAULT_SETTINGS}}
        return self._read(read)

    def tz(self):
        return zone(self.settings()["timezone"])

    def today(self) -> str:
        return local_date(self.now(), self.tz())

    def update_settings(self, changes: dict) -> tuple[dict, int]:
        clean = {}
        for key, value in changes.items():
            if key == "timezone":
                zone(_text(value, key, max_len=64))
                clean[key] = value.strip()
            elif key == "usage_retention_days":
                clean[key] = _int(value, key, lo=1, hi=365)
            elif key == "focus_retention_days":
                clean[key] = _int(value, key, lo=1, hi=90)
            elif key == "chief_profile":
                if not isinstance(value, str) or not _PROFILE_RE.match(value):
                    raise ShionError("invalid_params", "chief_profile must be a profile name")
                clean[key] = value
            else:
                raise ShionError("invalid_params", f"unknown setting {key!r}")
        if not clean:
            raise ShionError("invalid_params", "nothing to change")

        def write(conn):
            for key, value in clean.items():
                conn.execute("INSERT OR REPLACE INTO settings VALUES (?, ?)", (key, json.dumps(value)))
            return None, True
        _, revision = self._write(["settings"], write)
        return self.settings(), revision

    # -- revisions ---------------------------------------------------------------------------

    def revision(self) -> int:
        return self._read(lambda c: int(c.execute("SELECT value FROM meta WHERE key = 'revision'").fetchone()[0]))

    def changes_since(self, since: int) -> dict:
        """Topics changed after revision ``since``. ``reset`` when the log no longer reaches back that far
        (or ``since`` is ahead of this store: another data file): refetch everything."""
        def read(conn):
            revision = int(conn.execute("SELECT value FROM meta WHERE key = 'revision'").fetchone()[0])
            floor = int(conn.execute("SELECT value FROM meta WHERE key = 'changes_floor'").fetchone()[0])
            if since < floor or since > revision:
                return {"revision": revision, "reset": True, "topics": list(TOPICS)}
            rows = conn.execute("SELECT DISTINCT topic FROM changes WHERE revision > ?", (since,)).fetchall()
            found = {row["topic"] for row in rows}
            return {"revision": revision, "reset": False, "topics": [t for t in TOPICS if t in found]}
        return self._read(read)

    def topic_revisions(self) -> dict:
        def read(conn):
            rows = conn.execute("SELECT topic, MAX(revision) AS rev FROM changes GROUP BY topic").fetchall()
            return {row["topic"]: row["rev"] for row in rows}
        found = self._read(read)
        return {topic: found.get(topic, 0) for topic in TOPICS}

    # -- todos -------------------------------------------------------------------------------

    def _todo_out(self, row, tz) -> dict:
        return {
            "id": row["id"], "title": row["title"], "area": row["area"], "source": row["source"],
            "source_detail": row["source_detail"], "do_at": to_wire(row["do_at"], tz),
            "due_at": to_wire(row["due_at"], tz), "done": bool(row["done"]), "nudges": row["nudges"],
            "proposed": bool(row["proposed"]), "created_at": to_wire(row["created_at"], tz),
            "updated_at": to_wire(row["updated_at"], tz), "completed_at": to_wire(row["completed_at"], tz),
        }

    def get_todo(self, todo_id: str) -> dict:
        tz = self.tz()
        row = self._read(lambda c: c.execute("SELECT * FROM todos WHERE id = ?", (todo_id,)).fetchone())
        if row is None:
            raise ShionError("not_found", f"no todo {todo_id!r}")
        return self._todo_out(row, tz)

    def list_todos(self, *, status: str = "open", area=None, proposed: Optional[bool] = None,
                   start=None, end=None, date: Optional[str] = None, field: str = "either",
                   include_undated: Optional[bool] = None, limit: int = 500) -> list[dict]:
        tz = self.tz()
        _choice(status, "status", ("open", "done", "all"))
        _choice(field, "date_field", ("do_at", "due_at", "either"))
        limit = _int(limit, "limit", lo=1, hi=2000)
        where, args = [], []
        if status == "open":
            where.append("done = 0")
        elif status == "done":
            where.append("done = 1")
        if area is not None:
            areas = [area] if isinstance(area, str) else area
            if not isinstance(areas, list) or not areas:
                raise ShionError("invalid_params", "area must be a string or a non-empty list")
            for a in areas:
                _choice(a, "area", AREAS)
            where.append(f"area IN ({','.join('?' * len(areas))})")
            args += areas
        if proposed is not None:
            where.append("proposed = ?")
            args.append(int(_bool(proposed, "proposed")))
        if date is not None:
            if start is not None or end is not None:
                raise ShionError("invalid_params", "give date, or from/to, not both")
            lo, hi = day_bounds(parse_date(date, "date"), tz)
        else:
            lo = parse_bound(start, tz, "from", upper=False) if start is not None else None
            hi = parse_bound(end, tz, "to", upper=True) if end is not None else None
        if lo is not None or hi is not None:
            cols = {"do_at": ["do_at"], "due_at": ["due_at"], "either": ["do_at", "due_at"]}[field]
            parts = []
            for col in cols:
                cond, cargs = [f"{col} IS NOT NULL"], []
                if lo is not None:
                    cond.append(f"{col} >= ?")
                    cargs.append(to_storage(lo))
                if hi is not None:
                    cond.append(f"{col} < ?")
                    cargs.append(to_storage(hi))
                parts.append("(" + " AND ".join(cond) + ")")
                args += cargs
            if include_undated:
                parts.append("(" + " AND ".join(f"{col} IS NULL" for col in cols) + ")")
            where.append("(" + " OR ".join(parts) + ")")
        sql = "SELECT * FROM todos"
        if where:
            sql += " WHERE " + " AND ".join(where)
        sql += (" ORDER BY do_at IS NULL, do_at, due_at IS NULL, due_at, created_at, id LIMIT ?")
        args.append(limit)
        rows = self._read(lambda c: c.execute(sql, args).fetchall())
        return [self._todo_out(row, tz) for row in rows]

    def add_todo(self, *, title, area, source: str, do_at=None, due_at=None, proposed=False,
                 source_detail=None, todo_id=None) -> tuple[dict, int]:
        tz = self.tz()
        title = _text(title, "title", max_len=500)
        area = _choice(area, "area", AREAS)
        source = _text(source, "source", max_len=100)
        detail = _text(source_detail, "source_detail", max_len=200, required=False)
        proposed = _bool(proposed, "proposed")
        do = to_storage(parse_instant(do_at, tz, "do_at")) if do_at is not None else None
        due = to_storage(parse_instant(due_at, tz, "due_at")) if due_at is not None else None
        if todo_id is None:
            todo_id = "td_" + secrets.token_hex(6)
        elif not isinstance(todo_id, str) or not _ID_RE.match(todo_id):
            raise ShionError("invalid_params", "id must be 1-64 characters of A-Z a-z 0-9 _ -")
        now = to_storage(self.now())

        def write(conn):
            existing = conn.execute("SELECT * FROM todos WHERE id = ?", (todo_id,)).fetchone()
            if existing is not None:
                same = (existing["title"], existing["area"], existing["do_at"], existing["due_at"]) == (
                    title, area, do, due)
                if same:  # a retried add with the same id: answer with what is stored
                    return existing, False
                raise ShionError("conflict", f"todo {todo_id!r} already exists with other content")
            conn.execute(
                "INSERT INTO todos (id, title, area, source, source_detail, do_at, due_at, done, nudges, proposed,"
                " created_at, updated_at, completed_at) VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, ?, ?, ?, NULL)",
                (todo_id, title, area, source, detail, do, due, int(proposed), now, now))
            return conn.execute("SELECT * FROM todos WHERE id = ?", (todo_id,)).fetchone(), True
        row, revision = self._write(["todos"], write)
        return self._todo_out(row, tz), revision

    def update_todo(self, todo_id, changes: dict) -> tuple[dict, int]:
        tz = self.tz()
        if not isinstance(todo_id, str) or not todo_id:
            raise ShionError("invalid_params", "id is required")
        sets: dict[str, Any] = {}
        add_nudge = False
        for key, value in changes.items():
            if key == "title":
                sets["title"] = _text(value, key, max_len=500)
            elif key == "area":
                sets["area"] = _choice(value, key, AREAS)
            elif key in ("do_at", "due_at"):
                sets[key] = None if value is None else to_storage(parse_instant(value, tz, key))
            elif key == "done":
                sets["done"] = int(_bool(value, key))
            elif key == "proposed":
                sets["proposed"] = int(_bool(value, key))
            elif key == "nudges":
                sets["nudges"] = _int(value, key, lo=0, hi=10000)
            elif key == "add_nudge":
                add_nudge = _bool(value, key)
            elif key == "source_detail":
                sets["source_detail"] = _text(value, key, max_len=200, required=False, allow_empty=True) or None
            else:
                raise ShionError("invalid_params", f"cannot change {key!r}")
        if not sets and not add_nudge:
            raise ShionError("invalid_params", "nothing to change")
        if add_nudge and "nudges" in sets:
            raise ShionError("invalid_params", "give nudges or add_nudge, not both")
        now = to_storage(self.now())

        def write(conn):
            row = conn.execute("SELECT * FROM todos WHERE id = ?", (todo_id,)).fetchone()
            if row is None:
                raise ShionError("not_found", f"no todo {todo_id!r}")
            new = dict(sets)
            if add_nudge:
                new["nudges"] = row["nudges"] + 1
            if "done" in new:
                if new["done"] and not row["done"]:
                    new["completed_at"] = now
                elif not new["done"]:
                    new["completed_at"] = None
            changed = {k: v for k, v in new.items() if row[k] != v}
            if not changed:
                return row, False
            changed["updated_at"] = now
            conn.execute(f"UPDATE todos SET {', '.join(f'{k} = ?' for k in changed)} WHERE id = ?",
                         [*changed.values(), todo_id])
            return conn.execute("SELECT * FROM todos WHERE id = ?", (todo_id,)).fetchone(), True
        row, revision = self._write(["todos"], write)
        return self._todo_out(row, tz), revision

    def delete_todo(self, todo_id) -> int:
        if not isinstance(todo_id, str) or not todo_id:
            raise ShionError("invalid_params", "id is required")

        def write(conn):
            if conn.execute("DELETE FROM todos WHERE id = ?", (todo_id,)).rowcount == 0:
                raise ShionError("not_found", f"no todo {todo_id!r}")
            return None, True
        return self._write(["todos"], write)[1]

    # -- today's summary ---------------------------------------------------------------------

    def get_today(self, day: Optional[str] = None) -> Optional[dict]:
        tz = self.tz()
        day = parse_date(day, "date") if day is not None else local_date(self.now(), tz)
        row = self._read(lambda c: c.execute("SELECT * FROM today WHERE date = ?", (day,)).fetchone())
        if row is None:
            return None
        return {"date": row["date"], "text": row["text"], "author": row["author"],
                "updated_at": to_wire(row["updated_at"], tz)}

    def write_today(self, *, text, author: str, day: Optional[str] = None) -> tuple[dict, int]:
        tz = self.tz()
        text = _text(text, "text", max_len=4000)
        day = parse_date(day, "date") if day is not None else local_date(self.now(), tz)
        now = to_storage(self.now())

        def write(conn):
            conn.execute("INSERT OR REPLACE INTO today VALUES (?, ?, ?, ?)", (day, text, author, now))
            return None, True
        _, revision = self._write(["today"], write)
        return self.get_today(day), revision

    # -- reports -----------------------------------------------------------------------------

    @staticmethod
    def _blocks(value) -> list[dict]:
        if not isinstance(value, list) or not value:
            raise ShionError("invalid_params", "blocks must be a non-empty list of {heading, items}")
        if len(value) > 50:
            raise ShionError("invalid_params", "a report has at most 50 blocks")
        out = []
        for i, block in enumerate(value):
            if not isinstance(block, dict) or set(block) - {"heading", "items"}:
                raise ShionError("invalid_params", f"blocks[{i}] must be {{heading, items}}")
            heading = _text(block.get("heading"), f"blocks[{i}].heading", max_len=200, allow_empty=True)
            items = block.get("items")
            if not isinstance(items, list) or len(items) > 200:
                raise ShionError("invalid_params", f"blocks[{i}].items must be a list of at most 200 strings")
            out.append({"heading": heading,
                        "items": [_text(item, f"blocks[{i}].items[{j}]", max_len=2000) for j, item in enumerate(items)]})
        return out

    def _report_out(self, row, tz, *, with_blocks: bool) -> dict:
        blocks = json.loads(row["blocks"])
        out = {"id": f"{row['date']}-{row['kind']}", "date": row["date"], "kind": row["kind"],
               "headline": row["headline"], "author": row["author"],
               "created_at": to_wire(row["created_at"], tz), "updated_at": to_wire(row["updated_at"], tz)}
        if with_blocks:
            out["blocks"] = blocks
        else:
            out["block_count"] = len(blocks)
        return out

    def write_report(self, *, kind, blocks, author: str, day: Optional[str] = None,
                     headline=None) -> tuple[dict, int]:
        tz = self.tz()
        kind = _choice(kind, "kind", REPORT_KINDS)
        blocks = self._blocks(blocks)
        headline = _text(headline, "headline", max_len=300, required=False)
        day = parse_date(day, "date") if day is not None else local_date(self.now(), tz)
        now = to_storage(self.now())

        def write(conn):
            conn.execute(
                "INSERT INTO reports VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT (date, kind) DO UPDATE SET"
                " headline = excluded.headline, blocks = excluded.blocks, author = excluded.author,"
                " updated_at = excluded.updated_at",
                (day, kind, headline, json.dumps(blocks, ensure_ascii=False), author, now, now))
            return conn.execute("SELECT * FROM reports WHERE date = ? AND kind = ?", (day, kind)).fetchone(), True
        row, revision = self._write(["reports"], write)
        return self._report_out(row, tz, with_blocks=True), revision

    def get_report(self, *, day, kind) -> dict:
        tz = self.tz()
        day = parse_date(day, "date")
        kind = _choice(kind, "kind", REPORT_KINDS)
        row = self._read(lambda c: c.execute("SELECT * FROM reports WHERE date = ? AND kind = ?",
                                             (day, kind)).fetchone())
        if row is None:
            raise ShionError("not_found", f"no {kind} report for {day}")
        return self._report_out(row, tz, with_blocks=True)

    def list_reports(self, *, start=None, end=None, kind=None, limit: int = 200) -> list[dict]:
        tz = self.tz()
        where, args = [], []
        if start is not None:
            where.append("date >= ?")
            args.append(parse_date(start, "from"))
        if end is not None:
            where.append("date <= ?")
            args.append(parse_date(end, "to"))
        if kind is not None:
            where.append("kind = ?")
            args.append(_choice(kind, "kind", REPORT_KINDS))
        limit = _int(limit, "limit", lo=1, hi=1000)
        sql = "SELECT * FROM reports" + (" WHERE " + " AND ".join(where) if where else "")
        sql += " ORDER BY date DESC, kind LIMIT ?"
        rows = self._read(lambda c: c.execute(sql, [*args, limit]).fetchall())
        return [self._report_out(row, tz, with_blocks=False) for row in rows]

    # -- app usage ---------------------------------------------------------------------------

    def upload_usage(self, segments, *, device="mac") -> tuple[dict, int]:
        """Store foreground-app segments. A segment is keyed by (device, bundle_id, start): uploading it
        again replaces it (so a segment still running can be sent again with a later end)."""
        tz = self.tz()
        device = _text(device, "device", max_len=64)
        if not isinstance(segments, list):
            raise ShionError("invalid_params", "segments must be a list")
        if len(segments) > 5000:
            raise ShionError("invalid_params", "at most 5000 segments per upload")
        now = self.now()
        clean = []
        for i, seg in enumerate(segments):
            if not isinstance(seg, dict) or set(seg) - {"bundle_id", "app_name", "start", "end"}:
                raise ShionError("invalid_params", f"segments[{i}] must be {{bundle_id, app_name, start, end}}")
            bundle = _text(seg.get("bundle_id"), f"segments[{i}].bundle_id", max_len=255)
            name = _text(seg.get("app_name"), f"segments[{i}].app_name", max_len=255)
            start = parse_instant(seg.get("start"), tz, f"segments[{i}].start")
            end = parse_instant(seg.get("end"), tz, f"segments[{i}].end")
            if end <= start:
                raise ShionError("invalid_params", f"segments[{i}] ends before it starts")
            if end - start > timedelta(hours=24):
                raise ShionError("invalid_params", f"segments[{i}] is longer than 24 hours")
            if end > now + timedelta(minutes=5):
                raise ShionError("invalid_params", f"segments[{i}] ends in the future")
            clean.append((device, bundle, to_storage(start), to_storage(end), name))
        retention = self.settings()["usage_retention_days"]
        cutoff = to_storage(now - timedelta(days=retention))
        stamp = to_storage(now)

        def write(conn):
            counts = {"added": 0, "updated": 0, "unchanged": 0, "expired": 0}
            for device_, bundle, start, end, name in clean:
                if end < cutoff:
                    counts["expired"] += 1
                    continue
                row = conn.execute("SELECT end, app_name FROM usage_segments WHERE device = ? AND bundle_id = ?"
                                   " AND start = ?", (device_, bundle, start)).fetchone()
                if row is None:
                    counts["added"] += 1
                elif (row["end"], row["app_name"]) == (end, name):
                    counts["unchanged"] += 1
                    continue
                else:
                    counts["updated"] += 1
                conn.execute("INSERT OR REPLACE INTO usage_segments VALUES (?, ?, ?, ?, ?, ?)",
                             (device_, bundle, start, end, name, stamp))
            purged = conn.execute("DELETE FROM usage_segments WHERE end < ?", (cutoff,)).rowcount
            return counts, bool(counts["added"] or counts["updated"] or purged)
        counts, revision = self._write(["usage"], write)
        return {"received": len(clean), **counts}, revision

    def purge_usage(self) -> int:
        cutoff = to_storage(self.now() - timedelta(days=self.settings()["usage_retention_days"]))

        def write(conn):
            n = conn.execute("DELETE FROM usage_segments WHERE end < ?", (cutoff,)).rowcount
            return n, n > 0
        return self._write(["usage"], write)[0]

    def app_categories(self) -> dict:
        rows = self._read(lambda c: c.execute("SELECT * FROM app_categories").fetchall())
        return {**BUILTIN_CATEGORIES, **{row["bundle_id"]: row["category"] for row in rows}}

    def set_app_category(self, bundle_id, category, *, set_by: str) -> int:
        bundle_id = _text(bundle_id, "bundle_id", max_len=255)
        now = to_storage(self.now())

        def write(conn):
            if category is None:
                conn.execute("DELETE FROM app_categories WHERE bundle_id = ?", (bundle_id,))
            else:
                conn.execute("INSERT OR REPLACE INTO app_categories VALUES (?, ?, ?, ?)",
                             (bundle_id, _choice(category, "category", CATEGORIES), set_by, now))
            return None, True
        return self._write(["usage"], write)[1]

    def usage_day(self, day: Optional[str] = None) -> dict:
        """Seconds per app and per category for one local day. Overlapping segments of one app on one
        device are merged first, so a segment uploaded twice, or split differently, is counted once."""
        tz = self.tz()
        day = parse_date(day, "date") if day is not None else local_date(self.now(), tz)
        lo, hi = day_bounds(day, tz)
        rows = self._read(lambda c: c.execute(
            "SELECT * FROM usage_segments WHERE start < ? AND end > ? ORDER BY start",
            (to_storage(hi), to_storage(lo))).fetchall())
        categories = self.app_categories()
        per_app: dict[str, list] = {}
        names: dict[str, str] = {}
        all_spans: dict[str, list] = {}
        for row in rows:
            start = max(from_storage(row["start"]), lo)
            end = min(from_storage(row["end"]), hi)
            per_app.setdefault((row["device"], row["bundle_id"]), []).append((start, end))
            all_spans.setdefault(row["device"], []).append((start, end))
            names[row["bundle_id"]] = row["app_name"]
        app_seconds: dict[str, int] = {}
        for (device, bundle), spans in per_app.items():
            app_seconds[bundle] = app_seconds.get(bundle, 0) + _union_seconds(spans)
        by_app = sorted(
            ({"bundle_id": b, "app_name": names[b], "category": categories.get(b), "seconds": s}
             for b, s in app_seconds.items()),
            key=lambda item: (-item["seconds"], item["app_name"]))
        by_category = {c: 0 for c in (*CATEGORIES, UNCATEGORIZED)}
        for item in by_app:
            by_category[item["category"] or UNCATEGORIZED] += item["seconds"]
        total = sum(_union_seconds(spans) for spans in all_spans.values())
        return {"date": day, "timezone": str(tz), "total_seconds": total, "by_app": by_app,
                "by_category": by_category}

    # -- focus check -------------------------------------------------------------------------

    def _focus_out(self, row, tz) -> dict:
        return {"at": to_wire(row["at"], tz), "plan": row["plan"], "off_minutes": row["off_minutes"],
                "activity": row["activity"], "on_track": bool(row["on_track"]), "woke": bool(row["woke"])}

    def add_focus(self, *, plan, off_minutes, activity, on_track) -> tuple[dict, int, int]:
        tz = self.tz()
        plan = _text(plan, "plan", max_len=200)
        off_minutes = _int(off_minutes, "off_minutes", lo=0, hi=24 * 60)
        activity = _choice(activity, "activity", ACTIVITIES)
        on_track = _bool(on_track, "on_track")
        now = self.now()
        cutoff = to_storage(now - timedelta(days=self.settings()["focus_retention_days"]))

        def write(conn):
            cur = conn.execute("INSERT INTO focus_reports (at, plan, off_minutes, activity, on_track) VALUES"
                               " (?, ?, ?, ?, ?)", (to_storage(now), plan, off_minutes, activity, int(on_track)))
            conn.execute("DELETE FROM focus_reports WHERE at < ?", (cutoff,))
            row = conn.execute("SELECT * FROM focus_reports WHERE id = ?", (cur.lastrowid,)).fetchone()
            return (row, cur.lastrowid), True
        (row, rid), revision = self._write(["focus"], write)
        return self._focus_out(row, tz), rid, revision

    def mark_focus_woke(self, report_id: int) -> None:
        def write(conn):
            conn.execute("UPDATE focus_reports SET woke = 1 WHERE id = ?", (report_id,))
            return None, True
        self._write(["focus"], write)

    def latest_focus(self) -> Optional[dict]:
        tz = self.tz()
        row = self._read(lambda c: c.execute("SELECT * FROM focus_reports ORDER BY id DESC LIMIT 1").fetchone())
        if row is None:
            return None
        out = self._focus_out(row, tz)
        out["age_minutes"] = int((self.now() - from_storage(row["at"])).total_seconds() // 60)
        return out

    def recent_focus(self, limit: int = 20) -> list[dict]:
        tz = self.tz()
        rows = self._read(lambda c: c.execute("SELECT * FROM focus_reports ORDER BY id DESC LIMIT ?",
                                              (limit,)).fetchall())
        return [self._focus_out(row, tz) for row in rows]

    # -- session keys (where to wake the chief) ----------------------------------------------

    def remember_session_key(self, *, profile: str, session_id: str, session_key: str, platform: str) -> None:
        now = to_storage(self.now())
        conn = self._connect()
        try:  # bookkeeping, not data a client sees: no revision bump
            conn.execute("INSERT OR REPLACE INTO session_keys VALUES (?, ?, ?, ?, ?)",
                         (profile, session_id, session_key, platform, now))
        finally:
            conn.close()

    def session_key_for(self, *, profile: str, session_id: Optional[str]) -> Optional[str]:
        """The routing key last seen for ``session_id`` in ``profile``; without a match, the most recent
        local session's key in that profile (the Bot Chat's id changes when Hermes compresses it)."""
        def read(conn):
            if session_id:
                row = conn.execute("SELECT session_key FROM session_keys WHERE profile = ? AND session_id = ?",
                                   (profile, session_id)).fetchone()
                if row is not None:
                    return row["session_key"]
            row = conn.execute("SELECT session_key FROM session_keys WHERE profile = ? AND platform = 'local'"
                               " ORDER BY seen_at DESC LIMIT 1", (profile,)).fetchone()
            return row["session_key"] if row is not None else None
        return self._read(read)


def _union_seconds(spans: list) -> int:
    total, cur_start, cur_end = 0, None, None
    for start, end in sorted(spans):
        if cur_end is None or start > cur_end:
            if cur_end is not None:
                total += (cur_end - cur_start).total_seconds()
            cur_start, cur_end = start, end
        else:
            cur_end = max(cur_end, end)
    if cur_end is not None:
        total += (cur_end - cur_start).total_seconds()
    return int(total)
