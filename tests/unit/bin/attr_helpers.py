"""Helpers for accessing module attributes by name in unit tests."""


def call_attr(obj, name: str, *args, **kwargs):
    """Call ``getattr(obj, name)(*args, **kwargs)`` without protected-access lint."""
    return getattr(obj, name)(*args, **kwargs)


def get_attr(obj, name: str):
    """Return ``getattr(obj, name)`` without protected-access lint."""
    return getattr(obj, name)
