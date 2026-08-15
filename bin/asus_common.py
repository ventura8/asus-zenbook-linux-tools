"""Shared helpers for ASUS ZenBook Python daemons."""

import os

import evdev


def _evdev_event_sort_key(entry):
    """Sort eventN by numeric suffix so event2 precedes event10."""
    if entry.startswith("event") and entry[5:].isdigit():
        return (0, int(entry[5:]))
    return (1, entry)


def _evdev_event_paths_in_dir(root_dir):
    """Return event* device paths under a directory when present."""
    paths = []
    try:
        entries = sorted(os.listdir(root_dir), key=_evdev_event_sort_key)
    except OSError:
        return []
    for entry in entries:
        if not entry.startswith("event"):
            continue
        candidate = os.path.join(root_dir, entry)
        if os.path.exists(candidate):
            paths.append(candidate)
    return paths


def _list_evdev_device_paths():
    """Return evdev device paths, optionally restricted to ASUS_EVDEV_DEVICE_ROOT."""
    override = os.environ.get("ASUS_EVDEV_DEVICE_ROOT")
    if override is None:
        return evdev.list_devices()
    if not override or not os.path.isdir(override):
        return []
    return _evdev_event_paths_in_dir(override)


def list_evdev_device_paths():
    """Public wrapper for evdev path enumeration (tests and peer modules)."""
    return _list_evdev_device_paths()


def close_input_device(device):
    """Close an evdev device safely when present."""
    if device is None:
        return
    try:
        device.close()
    except OSError:
        return


def find_input_device_path(device_name):
    """Locate a matching evdev input device path by name."""
    return next(_iter_matching_input_device_paths(device_name), None)


def find_all_input_device_paths(device_name):
    """Return every evdev path whose name contains *device_name* (case-insensitive)."""
    return list(_iter_matching_input_device_paths(device_name))


def _iter_matching_input_device_paths(device_name):
    """Yield evdev paths whose name contains *device_name* (case-insensitive)."""
    target_name = device_name.lower()
    for path in _list_evdev_device_paths():
        dev = None
        try:
            dev = evdev.InputDevice(path)
            device_label = getattr(dev, "name", "")
            if target_name in device_label.lower():
                yield path
        except (OSError, ValueError):
            continue
        finally:
            close_input_device(dev)


def is_executable_file(path):
    """Return True when the path is a regular file with execute permission."""
    return os.path.isfile(path) and os.access(path, os.X_OK)
