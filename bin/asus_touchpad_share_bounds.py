"""Share corner bounds learning and persistence for the touchpad Share gesture."""

import json
import logging
import os
from dataclasses import dataclass, replace
from math import ceil

from evdev import ecodes

MAX_TAP_DURATION_S = 0.7
SEED_X_FRACTION = 0.08
SEED_Y_FRACTION = 0.08
MIN_CORNER_FRACTION = 0.03
LEARN_PERCENTILE = 0.85
MIN_SAMPLES_TO_LEARN = 8
MAX_SAMPLES = 32
STATE_VERSION = 1
_logger = logging.getLogger(__name__)
_persist_warned_paths: set[str] = set()


def get_abs_axis(device, mt_code, abs_code):
    """Safely fetch max bounds without KeyError/OSError crashes."""
    try:
        info = device.absinfo(mt_code)
        if info:
            return info
    except (KeyError, OSError):
        pass
    try:
        info = device.absinfo(abs_code)
        if info:
            return info
    except (KeyError, OSError):
        pass
    return None


def _get_axis_range(abs_axis, default_min, default_max):
    """Extract (min, max) bounds from an AbsInfo object or return defaults."""
    if not abs_axis:
        return default_min, default_max
    return getattr(abs_axis, "min", default_min), getattr(abs_axis, "max", default_max)


def _pick_check(primary, fallback):
    """Return primary if set, else fallback."""
    if primary != -1:
        return primary
    return fallback


def _gesture_end(curr, start):
    """Return the ending coordinate for a gesture axis."""
    return _pick_check(curr, start)


@dataclass(frozen=True)
class ShareBounds:
    """Active Share corner bounds plus learned samples."""

    ranges: tuple = (0, 4000, 0, 3000)
    bounds: tuple = (320.0, 240.0)
    x_fraction: float = SEED_X_FRACTION
    y_fraction: float = SEED_Y_FRACTION
    samples: tuple = ()
    state_path: str = ""


def _bounds_path():
    """Return the persisted Share-bounds state path."""
    return os.environ.get(
        "ASUS_TOUCHPAD_SHARE_BOUNDS_PATH",
        "/var/lib/asus-zenbook-linux-tools/touchpad-share-bounds.json",
    )


def _state_dir(path):
    """Return the parent directory for a state path."""
    return os.path.dirname(path) or "."


def _gesture_coords_valid(start_x, start_y, end_x, end_y):
    """Return True when all gesture coordinates are initialized."""
    return min(start_x, start_y, end_x, end_y) >= 0


def _coords_inside_corner(start_x, start_y, end_x, end_y, corner_bounds):
    """Return True when start and end stay inside the Share corner."""
    corner_x_max, corner_y_max = corner_bounds
    if start_x > corner_x_max or end_x > corner_x_max:
        return False
    return start_y <= corner_y_max and end_y <= corner_y_max


def is_corner_gesture(coords, bounds):
    """Check if a tap started and ended inside the Share corner bounds."""
    start_x, start_y, curr_x, curr_y, duration = coords
    if duration >= MAX_TAP_DURATION_S:
        return False
    end_x = _gesture_end(curr_x, start_x)
    end_y = _gesture_end(curr_y, start_y)
    if not _gesture_coords_valid(start_x, start_y, end_x, end_y):
        return False
    return _coords_inside_corner(start_x, start_y, end_x, end_y, bounds)


def _normalize_fraction(value, min_val, max_val):
    """Return a normalized fraction or None for degenerate ranges."""
    if max_val <= min_val:
        return None
    return (value - min_val) / (max_val - min_val)


def _clamp_fraction(value, min_fraction, max_fraction):
    """Clamp a fraction into a safe learned Share-bounds range."""
    return max(min_fraction, min(max_fraction, value))


def _percentile(sorted_values, percentile):
    """Return a high-percentile sample from a sorted list."""
    if not sorted_values:
        return None
    if len(sorted_values) == 1:
        return sorted_values[0]
    index = ceil(percentile * (len(sorted_values) - 1))
    return sorted_values[index]


def _valid_fraction(value):
    """Return True when value is a usable normalized fraction."""
    return isinstance(value, (int, float)) and 0.0 <= float(value) <= 1.0


def _parse_sample(sample):
    """Return a valid normalized sample tuple or None."""
    if not isinstance(sample, dict):
        return None
    x_fraction = sample.get("x_fraction")
    y_fraction = sample.get("y_fraction")
    if not _valid_fraction(x_fraction) or not _valid_fraction(y_fraction):
        return None
    return (x_fraction, y_fraction)


def _read_bounds_state(path):
    """Read a saved Share-bounds JSON file or return None."""
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError, TypeError):
        return None


def _parse_learned_fraction(data, key, seed_fraction):
    """Return one clamped learned fraction from persisted state."""
    value = data.get(key, seed_fraction)
    if not _valid_fraction(value):
        value = seed_fraction
    return _clamp_fraction(float(value), MIN_CORNER_FRACTION, seed_fraction)


def _load_sample_history(data):
    """Return validated recent Share tap samples from persisted state."""
    persisted_samples = data.get("samples", ())
    if not isinstance(persisted_samples, list):
        return ()
    samples = []
    for sample in persisted_samples:
        parsed = _parse_sample(sample)
        if parsed is not None:
            samples.append(parsed)
    return tuple(samples[-MAX_SAMPLES:])


def _load_learned_bounds(path):
    """Load learned fractions and sample history from disk."""
    data = _read_bounds_state(path)
    if not isinstance(data, dict):
        return SEED_X_FRACTION, SEED_Y_FRACTION, ()
    learned_x = _parse_learned_fraction(data, "learned_x_fraction", SEED_X_FRACTION)
    learned_y = _parse_learned_fraction(data, "learned_y_fraction", SEED_Y_FRACTION)
    return learned_x, learned_y, _load_sample_history(data)


def _save_learned_bounds(share_bounds):
    """Persist learned Share-bounds state atomically."""
    if not share_bounds.state_path:
        return
    path = share_bounds.state_path
    try:
        os.makedirs(_state_dir(path), exist_ok=True)
        tmp_path = f"{path}.tmp"
        payload = {
            "version": STATE_VERSION,
            "seed_x_fraction": SEED_X_FRACTION,
            "seed_y_fraction": SEED_Y_FRACTION,
            "learned_x_fraction": share_bounds.x_fraction,
            "learned_y_fraction": share_bounds.y_fraction,
            "learn_percentile": LEARN_PERCENTILE,
            "samples": [
                {"x_fraction": x_fraction, "y_fraction": y_fraction}
                for x_fraction, y_fraction in share_bounds.samples
            ],
        }
        with open(tmp_path, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, sort_keys=True)
        os.replace(tmp_path, path)
    except OSError as exc:
        if path not in _persist_warned_paths:
            _persist_warned_paths.add(path)
            _logger.warning("Failed to persist Share bounds (%s): %s", path, exc)


def _bounds_from_fractions(ranges, x_fraction, y_fraction):
    """Convert normalized fractions into absolute Share corner bounds."""
    min_x, max_x, min_y, max_y = ranges
    corner_x = min_x + x_fraction * (max_x - min_x)
    corner_y = min_y + y_fraction * (max_y - min_y)
    return (corner_x, corner_y)


def _axis_ranges(dev):
    """Return touchpad axis ranges for Share-bound calculations."""
    abs_x = get_abs_axis(dev, ecodes.ABS_MT_POSITION_X, ecodes.ABS_X)
    abs_y = get_abs_axis(dev, ecodes.ABS_MT_POSITION_Y, ecodes.ABS_Y)
    min_x, max_x = _get_axis_range(abs_x, 0, 4000)
    min_y, max_y = _get_axis_range(abs_y, 0, 3000)
    return (min_x, max_x, min_y, max_y)


def _tap_sample_from_coords(coords, ranges):
    """Return one normalized sample from a successful Share gesture."""
    start_x, start_y, curr_x, curr_y, _duration = coords
    min_x, max_x, min_y, max_y = ranges
    end_x = _gesture_end(curr_x, start_x)
    end_y = _gesture_end(curr_y, start_y)
    x_fraction = _normalize_fraction(max(start_x, end_x), min_x, max_x)
    y_fraction = _normalize_fraction(max(start_y, end_y), min_y, max_y)
    if x_fraction is None or y_fraction is None:
        return None
    return (
        _clamp_fraction(x_fraction, MIN_CORNER_FRACTION, SEED_X_FRACTION),
        _clamp_fraction(y_fraction, MIN_CORNER_FRACTION, SEED_Y_FRACTION),
    )


def _percentile_fractions(samples):
    """Return percentile-based learned X/Y fractions from samples."""
    sorted_x = sorted(sample[0] for sample in samples)
    sorted_y = sorted(sample[1] for sample in samples)
    return _percentile(sorted_x, LEARN_PERCENTILE), _percentile(sorted_y, LEARN_PERCENTILE)


def _recompute_learned_fractions(samples):
    """Return learned fractions or None until enough valid samples exist."""
    if len(samples) < MIN_SAMPLES_TO_LEARN:
        return None
    learned_x, learned_y = _percentile_fractions(samples)
    if learned_x is None or learned_y is None:
        return None
    return (
        _clamp_fraction(learned_x, MIN_CORNER_FRACTION, SEED_X_FRACTION),
        _clamp_fraction(learned_y, MIN_CORNER_FRACTION, SEED_Y_FRACTION),
    )


def record_successful_tap(share_bounds, coords):
    """Update learned Share bounds from one accepted tap."""
    sample = _tap_sample_from_coords(coords, share_bounds.ranges)
    if sample is None:
        return share_bounds
    samples = (*share_bounds.samples, sample)[-MAX_SAMPLES:]
    learned = _recompute_learned_fractions(samples)
    x_fraction = share_bounds.x_fraction
    y_fraction = share_bounds.y_fraction
    if learned is not None:
        x_fraction, y_fraction = learned
    updated = replace(
        share_bounds,
        samples=samples,
        x_fraction=x_fraction,
        y_fraction=y_fraction,
        bounds=_bounds_from_fractions(share_bounds.ranges, x_fraction, y_fraction),
    )
    if x_fraction != share_bounds.x_fraction or y_fraction != share_bounds.y_fraction:
        _save_learned_bounds(updated)
    return updated


def compute_bounds(dev):
    """Return startup Share bounds for the touchpad."""
    ranges = _axis_ranges(dev)
    state_path = _bounds_path()
    x_fraction, y_fraction, samples = _load_learned_bounds(state_path)
    return ShareBounds(
        ranges=ranges,
        bounds=_bounds_from_fractions(ranges, x_fraction, y_fraction),
        x_fraction=x_fraction,
        y_fraction=y_fraction,
        samples=samples,
        state_path=state_path,
    )
