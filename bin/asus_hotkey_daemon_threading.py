"""Patchable thread factory for the ASUS hotkey daemon."""

import threading


def _thread_factory(target, args=(), kwargs=None, daemon=False, name=None):
    """Create a Thread; tests patch monitor._thread_factory instead of threading.Thread."""
    thread_kwargs = {} if kwargs is None else kwargs
    return threading.Thread(target=target, args=args, kwargs=thread_kwargs, daemon=daemon, name=name)
