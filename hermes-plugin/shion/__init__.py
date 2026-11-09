"""Hermes plugin ``shion``: the data the Shion macOS app shows, shared by every assistant profile."""

from .plugin import ShionPlugin


def register(ctx):
    ShionPlugin(ctx).register()
