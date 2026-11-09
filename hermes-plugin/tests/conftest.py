import sys
from datetime import datetime, timezone
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from shion.store import Store  # noqa: E402


class Clock:
    """A settable clock (UTC)."""

    def __init__(self, moment: datetime):
        self.moment = moment

    def __call__(self) -> datetime:
        return self.moment

    def set(self, iso: str) -> None:
        self.moment = datetime.fromisoformat(iso).astimezone(timezone.utc)


@pytest.fixture
def clock():
    # 2026-11-09 10:52 in Tokyo, the moment the Mac app's snapshots use.
    return Clock(datetime(2026, 11, 9, 1, 52, tzinfo=timezone.utc))


@pytest.fixture
def store(tmp_path, clock):
    return Store(tmp_path / "shion.db", clock=clock)


class FakeCtx:
    """The slice of Hermes' PluginContext the plugin uses, recording what it is given."""

    plugin_id = "shion"

    def __init__(self, profile: str = "shion", inject_result: bool = True):
        self.profile_name = profile
        self.rpc = {}
        self.tools = {}
        self.hooks = {}
        self.unload = []
        self.injected = []
        self.inject_result = inject_result

    def register_rpc(self, name, handler):
        assert name not in self.rpc
        self.rpc[name] = handler

    def register_tool(self, name, toolset, schema, handler, **kwargs):
        assert schema["name"] == name and toolset == "shion"
        self.tools[name] = handler

    def register_hook(self, name, callback):
        self.hooks[name] = callback

    def on_unload(self, callback):
        self.unload.append(callback)

    def inject_message(self, content, role="user", *, session_key=None, origin=None):
        self.injected.append({"content": content, "role": role, "session_key": session_key})
        return self.inject_result

    def call(self, method, params=None, session_id=None):
        """Call as Hermes does: params keep ``session_id`` / ``profile``, and session_id comes as a keyword."""
        return self.rpc[method](dict(params or {}), session_id=session_id)


class FakeHermes:
    def __init__(self):
        self.events = []
        self.env = {}

    def broadcast(self, plugin_id, event, payload):
        self.events.append((plugin_id, event, payload))

    def session_env(self, name):
        return self.env.get(name, "")


@pytest.fixture
def hermes():
    return FakeHermes()
