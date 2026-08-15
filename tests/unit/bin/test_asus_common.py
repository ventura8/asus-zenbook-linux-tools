"""Unit tests for bin/asus_common.py."""

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

import shared_imports

PROJECT_ROOT = Path(__file__).resolve().parents[3]
BIN_DIR = PROJECT_ROOT / "bin"


def _ensure_bin_on_path() -> None:
    """Ensure the repository bin/ directory is importable."""
    bin_dir = str(BIN_DIR)
    if bin_dir not in sys.path:
        sys.path.insert(0, bin_dir)


def _load_module_from_path(module_name: str, module_path: Path):
    """Load module_name from module_path and register it in sys.modules."""
    return shared_imports.load_module_from_path(module_name, str(module_path))


def _load_asus_common():
    """Load bin/asus_common.py and register it for importable patches."""
    module_path = BIN_DIR / "asus_common.py"
    _ensure_bin_on_path()
    existing = sys.modules.get("asus_common")
    if existing is not None and getattr(existing, "__file__", None) == str(module_path):
        return existing
    return _load_module_from_path("asus_common", module_path)


asus_common = _load_asus_common()


class TestAsusCommon(unittest.TestCase):
    """Coverage tests for shared ASUS Python helpers."""

    def test_find_input_device_path_uses_system_list_without_override(self):
        """Unset ASUS_EVDEV_DEVICE_ROOT falls back to evdev.list_devices()."""
        env = {key: value for key, value in os.environ.items() if key != "ASUS_EVDEV_DEVICE_ROOT"}
        device = MagicMock()
        device.name = "ASUS WMI hotkeys"
        with (
            patch.dict(os.environ, env, clear=True),
            patch.object(
                asus_common.evdev,
                "list_devices",
                return_value=["/dev/input/event9"],
            ) as listed,
            patch.object(asus_common.evdev, "InputDevice", return_value=device),
        ):
            self.assertEqual(
                asus_common.find_input_device_path("wmi hotkeys"),
                "/dev/input/event9",
            )
            listed.assert_called_once_with()

    def test_find_input_device_path_empty_or_missing_override(self):
        """Empty or non-directory override yields no matching device path."""
        with patch.dict(os.environ, {"ASUS_EVDEV_DEVICE_ROOT": ""}):
            self.assertIsNone(asus_common.find_input_device_path("wmi"))
        with tempfile.TemporaryDirectory() as tmp:
            missing_root = os.path.join(tmp, "asus-missing-evdev-root")
            with patch.dict(os.environ, {"ASUS_EVDEV_DEVICE_ROOT": missing_root}):
                self.assertIsNone(asus_common.find_input_device_path("wmi"))

    def test_find_input_device_path_reads_override_directory(self):
        """Directory override discovers event* nodes and ignores unrelated names."""
        good = MagicMock()
        good.name = "ASUS Touchpad"
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "event2").write_text("", encoding="utf-8")
            Path(tmp, "mouse0").write_text("", encoding="utf-8")
            with (
                patch.dict(os.environ, {"ASUS_EVDEV_DEVICE_ROOT": tmp}),
                patch.object(asus_common.evdev, "InputDevice", return_value=good),
            ):
                self.assertEqual(
                    asus_common.find_input_device_path("touchpad"),
                    os.path.join(tmp, "event2"),
                )

    def test_find_all_input_device_paths_returns_every_match(self):
        """find_all_input_device_paths keeps every matching Video Bus path."""
        first = MagicMock()
        first.name = "Video Bus"
        second = MagicMock()
        second.name = "Video Bus"
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "event0").write_text("", encoding="utf-8")
            Path(tmp, "event1").write_text("", encoding="utf-8")
            with (
                patch.dict(os.environ, {"ASUS_EVDEV_DEVICE_ROOT": tmp}),
                patch.object(
                    asus_common.evdev,
                    "InputDevice",
                    side_effect=[first, second],
                ),
            ):
                paths = asus_common.find_all_input_device_paths("Video Bus")
            self.assertEqual(
                paths,
                [os.path.join(tmp, "event0"), os.path.join(tmp, "event1")],
            )

    def test_find_input_device_path_match_and_errors(self):
        """find_input_device_path matches by name and skips failing devices."""
        good = MagicMock()
        good.name = "ASUS WMI hotkeys"
        bad = MagicMock()
        bad.name = "Other Device"
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "event0").write_text("", encoding="utf-8")
            Path(tmp, "event1").write_text("", encoding="utf-8")
            with (
                patch.dict(os.environ, {"ASUS_EVDEV_DEVICE_ROOT": tmp}),
                patch.object(
                    asus_common.evdev,
                    "InputDevice",
                    side_effect=[OSError("gone"), good],
                ),
            ):
                self.assertEqual(
                    asus_common.find_input_device_path("wmi hotkeys"),
                    os.path.join(tmp, "event1"),
                )
            with (
                patch.dict(os.environ, {"ASUS_EVDEV_DEVICE_ROOT": tmp}),
                patch.object(
                    asus_common.evdev,
                    "InputDevice",
                    side_effect=ValueError("invalid"),
                ),
            ):
                self.assertIsNone(asus_common.find_input_device_path("wmi hotkeys"))
            with (
                patch.dict(os.environ, {"ASUS_EVDEV_DEVICE_ROOT": tmp}),
                patch.object(asus_common.evdev, "InputDevice", return_value=bad),
            ):
                self.assertIsNone(asus_common.find_input_device_path("wmi hotkeys"))

    def test_is_executable_file(self):
        """is_executable_file requires both existence and execute permission."""
        with tempfile.TemporaryDirectory() as tmp:
            missing = os.path.join(tmp, "missing")
            plain = os.path.join(tmp, "plain")
            executable = os.path.join(tmp, "tool")
            Path(plain).write_text("", encoding="utf-8")
            Path(executable).write_text("", encoding="utf-8")
            os.chmod(executable, 0o755)
            self.assertFalse(asus_common.is_executable_file(missing))
            self.assertFalse(asus_common.is_executable_file(plain))
            self.assertTrue(asus_common.is_executable_file(executable))

    def test_load_asus_common_via_shared_imports_is_cached(self):
        """shared_imports.load_asus_common returns one module object across calls."""
        real_path = str(BIN_DIR / "asus_common.py")
        original = sys.modules.get("asus_common")
        sys.modules.pop("asus_common", None)
        try:
            loaded_first = shared_imports.load_asus_common()
            loaded_second = shared_imports.load_asus_common()
            self.assertIs(loaded_first, loaded_second)
            self.assertEqual(getattr(loaded_first, "__file__", None), real_path)
        finally:
            if original is None:
                sys.modules.pop("asus_common", None)
            else:
                sys.modules["asus_common"] = original


if __name__ == "__main__":
    unittest.main()
