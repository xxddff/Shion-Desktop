"""Time zones on a host without the IANA database (Hermes's Debian 13 image may not carry tzdata)."""

from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfoNotFoundError

import pytest

from shion import timeutil
from shion.errors import ShionError


@pytest.fixture
def no_tz_database(monkeypatch):
    def missing(key):
        raise ZoneInfoNotFoundError(f"No time zone found with key {key}")
    monkeypatch.setattr(timeutil, "ZoneInfo", missing)


def test_fixed_zone_without_database(no_tz_database):
    tz = timeutil.zone("Asia/Tokyo")
    assert tz.utcoffset(None) == timedelta(hours=9)
    assert str(tz) == "Asia/Tokyo"
    noon_utc = datetime(2026, 7, 1, 3, 0, tzinfo=timezone.utc)
    assert timeutil.local_date(noon_utc, tz) == "2026-07-01"
    assert not timeutil.tz_database()


def test_other_zone_without_database_says_why(no_tz_database):
    with pytest.raises(ShionError) as raised:
        timeutil.zone("Europe/Paris")
    assert "tzdata" in str(raised.value)


def test_zone_with_database_is_unchanged():
    if not timeutil.tz_database():
        pytest.skip("this host has no time zone database")
    assert timeutil.zone("Europe/Paris").utcoffset(datetime(2026, 7, 1)) == timedelta(hours=2)


def test_bad_name_is_refused():
    with pytest.raises(ShionError):
        timeutil.zone("../etc/passwd")
