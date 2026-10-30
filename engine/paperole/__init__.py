"""Paperole engine."""

__version__ = "0.1.0"  # pyproject.toml's version; backup.json's made_by "engine"


class EngineError(Exception):
    """An expected failure, with a message the advisor can read."""
