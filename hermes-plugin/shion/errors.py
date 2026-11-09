"""The one error type the plugin raises on purpose.

Hermes answers a plugin RPC that raised with error 4001, reason ``plugin_rpc_failed`` and
``error.data.detail = "<ExceptionType>: <str(exc)>"``, so a client reads ``ShionError: <code>: <message>``.
"""

from __future__ import annotations

CODES = ("invalid_params", "not_found", "conflict", "wrong_profile")


class ShionError(Exception):
    def __init__(self, code: str, message: str):
        assert code in CODES, code
        self.code = code
        self.message = message
        super().__init__(f"{code}: {message}")

    def as_dict(self) -> dict:
        return {"error": self.code, "message": self.message}
