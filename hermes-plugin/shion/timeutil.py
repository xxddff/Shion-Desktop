"""Time handling: instants are stored in UTC, shown in the user's time zone, and "today" is that zone's date."""

from __future__ import annotations

import re
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from .errors import ShionError

_DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def zone(name: str) -> ZoneInfo:
    try:
        return ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError) as exc:
        raise ShionError("invalid_params", f"unknown time zone {name!r}") from exc


def to_storage(moment: datetime) -> str:
    """UTC, second precision, sortable as text."""
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def from_storage(text: str) -> datetime:
    return datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def to_wire(text: str | None, tz: ZoneInfo) -> str | None:
    """A stored instant as ISO 8601 with the user's offset, e.g. ``2026-11-09T10:45:00+09:00``."""
    if text is None:
        return None
    return from_storage(text).astimezone(tz).isoformat(timespec="seconds")


def parse_instant(value, tz: ZoneInfo, field: str) -> datetime:
    """ISO 8601 date-time; an offset (or ``Z``) is honoured, a value without one is taken in ``tz``."""
    if not isinstance(value, str) or not value.strip():
        raise ShionError("invalid_params", f"{field} must be an ISO 8601 date-time string")
    text = value.strip()
    if _DATE_RE.match(text):
        raise ShionError("invalid_params", f"{field} needs a time as well as a date (e.g. {text}T09:00)")
    try:
        moment = datetime.fromisoformat(text)
    except ValueError as exc:
        raise ShionError("invalid_params", f"{field} is not an ISO 8601 date-time: {value!r}") from exc
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=tz)
    return moment.astimezone(timezone.utc)


def parse_date(value, field: str) -> str:
    if not isinstance(value, str) or not _DATE_RE.match(value.strip()):
        raise ShionError("invalid_params", f"{field} must be a date as YYYY-MM-DD")
    text = value.strip()
    try:
        date.fromisoformat(text)
    except ValueError as exc:
        raise ShionError("invalid_params", f"{field} is not a real date: {value!r}") from exc
    return text


def day_bounds(day: str, tz: ZoneInfo) -> tuple[datetime, datetime]:
    """``[start, end)`` of the local day, in UTC (a DST day may be 23 or 25 hours long)."""
    d = date.fromisoformat(day)
    start = datetime(d.year, d.month, d.day, tzinfo=tz)
    nxt = d + timedelta(days=1)
    end = datetime(nxt.year, nxt.month, nxt.day, tzinfo=tz)
    return start.astimezone(timezone.utc), end.astimezone(timezone.utc)


def local_date(moment: datetime, tz: ZoneInfo) -> str:
    return moment.astimezone(tz).date().isoformat()


def parse_bound(value, tz: ZoneInfo, field: str, *, upper: bool) -> datetime:
    """A range bound: a date-time, or a date meaning the start of that day (``upper``: the start of the next)."""
    if isinstance(value, str) and _DATE_RE.match(value.strip()):
        start, end = day_bounds(parse_date(value, field), tz)
        return end if upper else start
    return parse_instant(value, tz, field)
