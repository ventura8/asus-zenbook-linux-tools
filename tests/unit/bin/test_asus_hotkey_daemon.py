"""Unit tests matching bin/asus-hotkey-daemon.py."""

import importlib
import importlib.util
import itertools
import os
import runpy
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

from evdev import ecodes

from tests.unit.bin.attr_helpers import call_attr
from tests.unit.bin.hotkey_daemon_test_utils import (
    BIN_DIR,
    exec_module_from_spec,
    load_daemon,
    reset_hotkey_daemon_state,
    seed_usable_monitor_topology,
    window_swap_monitor_patches,
)

_exec_module_from_spec = exec_module_from_spec

daemon = load_daemon()
daemon_input = importlib.import_module("asus_hotkey_daemon_input")
daemon_at_proxy = importlib.import_module("asus_hotkey_daemon_at_proxy")
daemon_runtime = importlib.import_module("asus_hotkey_daemon_runtime")
hotkey_state = importlib.import_module("asus_hotkey_daemon_state")


def _usr_local_bin_path(path) -> bool:
    """Return True when path is under /usr/local/bin (helper scripts under test)."""
    return str(path).startswith("/usr/local/bin/")


def _usr_local_bin_isfile_side_effect(present: bool):
    """Mock isfile for /usr/local/bin helpers only; delegate other paths."""
    real_isfile = os.path.isfile

    def side_effect(path):
        if _usr_local_bin_path(path):
            return present
        return real_isfile(path)

    return side_effect


def _usr_local_bin_access_side_effect(allowed: bool):
    """Mock access for /usr/local/bin helpers only; delegate other paths."""
    real_access = os.access

    def side_effect(path, mode):
        if _usr_local_bin_path(path):
            return allowed
        return real_access(path, mode)

    return side_effect


class TestAsusHotkeyDaemon(unittest.TestCase):
    """Unit tests for bin/asus-hotkey-daemon.py functions."""

    def setUp(self):
        """Reset daemon state before each test."""
        reset_hotkey_daemon_state(daemon)

    @patch("os.path.isfile", side_effect=_usr_local_bin_isfile_side_effect(True))
    @patch("os.access", side_effect=_usr_local_bin_access_side_effect(True))
    @patch("asus_hotkey_daemon_runtime.threading.Thread")
    def test_run_script_if_exists_success(self, mock_thread_cls, _mock_access, _mock_isfile):
        """Test run_script_if_exists schedules existing script on a worker."""
        mock_thread = MagicMock()
        mock_thread_cls.return_value = mock_thread
        started = daemon.run_script_if_exists("/usr/local/bin/test.sh")
        self.assertEqual(started, "started")
        mock_thread_cls.assert_called_once()
        self.assertEqual(mock_thread_cls.call_args.kwargs.get("args"), ("/usr/local/bin/test.sh", None))
        mock_thread.start.assert_called_once_with()

    @patch("os.path.isfile", side_effect=_usr_local_bin_isfile_side_effect(True))
    @patch("os.access", side_effect=_usr_local_bin_access_side_effect(True))
    @patch("asus_hotkey_daemon_runtime.threading.Thread")
    @patch("asus_hotkey_daemon_runtime.time.monotonic")
    def test_run_script_if_exists_debounced(self, mock_time, mock_thread_cls, _mock_access, _mock_isfile):
        """Test run_script_if_exists debounces rapid repeated invocations."""
        mock_thread_cls.return_value = MagicMock()
        clock_values = itertools.chain([1.0, 1.1], itertools.repeat(1.1))
        mock_time.side_effect = lambda: next(clock_values)
        self.assertEqual(daemon.run_script_if_exists("/usr/local/bin/test.sh"), "started")
        self.assertEqual(daemon.run_script_if_exists("/usr/local/bin/test.sh"), "debounced")
        mock_thread_cls.assert_called_once()

    @patch("os.path.isfile", side_effect=_usr_local_bin_isfile_side_effect(True))
    @patch("os.access", side_effect=_usr_local_bin_access_side_effect(True))
    @patch("asus_hotkey_daemon_runtime.threading.Thread")
    @patch("asus_hotkey_daemon_runtime.time.monotonic")
    def test_display_mode_debounce_allows_fast_osd_cycling(self, mock_time, mock_thread_cls, _mock_access, _mock_isfile):
        """Display-mode debounce is short so sticky OSD cycles match Super+P."""
        mock_thread_cls.return_value = MagicMock()
        clock_values = itertools.chain([1.0, 1.06], itertools.repeat(1.06))
        mock_time.side_effect = lambda: next(clock_values)
        path = "/usr/local/bin/asus-display-mode.sh"
        self.assertEqual(daemon.run_script_if_exists(path), "started")
        self.assertEqual(daemon.run_script_if_exists(path), "started")
        self.assertEqual(mock_thread_cls.call_count, 2)

    @patch("os.path.isfile", side_effect=_usr_local_bin_isfile_side_effect(False))
    @patch("asus_hotkey_daemon_runtime.threading.Thread")
    def test_run_script_if_exists_not_found(self, mock_thread_cls, _mock_isfile):
        """Test run_script_if_exists skips non-existent script."""
        started = daemon.run_script_if_exists("/usr/local/bin/nonexistent.sh")
        self.assertEqual(started, "missing")
        mock_thread_cls.assert_not_called()

    @patch("subprocess.run", side_effect=subprocess.TimeoutExpired(cmd="x", timeout=5))
    def test_exec_script_timeout_logged(self, _mock_run):
        """Test _exec_script logs a warning on timeout."""
        with self.assertLogs("asus_hotkey_daemon_runtime", level="WARNING") as log_ctx:
            exec_script_name = "_exec_script"
            getattr(daemon_runtime, exec_script_name)("/usr/local/bin/slow.sh")
        self.assertTrue(any("timed out" in m and "slow.sh" in m for m in log_ctx.output))

    @patch("subprocess.run")
    def test_exec_script_nonzero_logged(self, mock_run):
        """Test _exec_script logs a warning on non-zero exit status."""
        mock_run.return_value = MagicMock(returncode=1)
        with self.assertLogs("asus_hotkey_daemon_runtime", level="WARNING") as log_ctx:
            exec_script_name = "_exec_script"
            getattr(daemon_runtime, exec_script_name)("/usr/local/bin/fail.sh")
        self.assertTrue(any("status 1" in m and "fail.sh" in m for m in log_ctx.output))

    @patch("asus_hotkey_daemon_runtime.threading.Thread")
    def test_start_script_worker_starts_daemon_thread(self, mock_thread_cls):
        """Test _start_script_worker starts a daemon thread targeting _exec_script."""
        mock_thread = MagicMock()
        mock_thread_cls.return_value = mock_thread
        start_script_worker_name = "_start_script_worker"
        exec_script_name = "_exec_script"
        getattr(daemon_runtime, start_script_worker_name)("/usr/local/bin/test.sh")
        mock_thread_cls.assert_called_once_with(
            target=getattr(daemon_runtime, exec_script_name),
            args=("/usr/local/bin/test.sh", None),
            daemon=True,
        )
        mock_thread.start.assert_called_once_with()

    @patch("asus_hotkey_daemon_input.perform_window_swap")
    def test_handle_key_press_window_swap(self, mock_swap):
        """Test handle_key_press calls perform_window_swap on scancode 0x9C."""
        mock_ui = MagicMock()
        daemon.handle_key_press(0x9C, 240, mock_ui, False)
        mock_swap.assert_called_once_with(mock_ui, 0)

    @patch("os.path.isfile", side_effect=_usr_local_bin_isfile_side_effect(True))
    @patch("os.access", side_effect=_usr_local_bin_access_side_effect(True))
    @patch("asus_hotkey_daemon_runtime.threading.Thread")
    def test_handle_key_press_control_center(self, mock_thread_cls, _mock_access, _mock_isfile):
        """Test handle_key_press triggers control center script on scancode 0x5C."""
        mock_thread_cls.return_value = MagicMock()
        mock_ui = MagicMock()
        with self.assertLogs("asus_hotkey_daemon_runtime", level="INFO") as log_ctx:
            daemon.handle_key_press(0x5C, 148, mock_ui, False)
        self.assertEqual(mock_thread_cls.call_args.kwargs.get("args"), ("/usr/local/bin/asus-control-center.sh", None))
        self.assertTrue(any("Dispatched helper script successfully" in m for m in log_ctx.output))

    @patch("os.path.isfile", side_effect=_usr_local_bin_isfile_side_effect(True))
    @patch("os.access", side_effect=_usr_local_bin_access_side_effect(True))
    @patch("asus_hotkey_daemon_runtime.threading.Thread")
    def test_handle_key_press_display_mode_toggle(self, mock_thread_cls, _mock_access, _mock_isfile):
        """Test handle_key_press triggers display mode via KEY_SWITCHVIDEOMODE (227)."""
        mock_thread_cls.return_value = MagicMock()
        mock_ui = MagicMock()
        with self.assertLogs("asus_hotkey_daemon_runtime", level="INFO") as log_ctx:
            daemon.handle_key_press(None, 227, mock_ui, False)
        self.assertEqual(mock_thread_cls.call_args.kwargs.get("args"), ("/usr/local/bin/asus-display-mode.sh", None))
        self.assertTrue(any("Dispatched helper script successfully" in m for m in log_ctx.output))

    def test_perform_window_swap_multi_directional(self):
        """Test perform_window_swap emits one directional key combination per step."""
        mock_ui = MagicMock()
        monitors = [
            {"x": 0, "y": 0, "width": 1920, "height": 1080, "primary": True},
            {"x": 0, "y": 1080, "width": 1920, "height": 540, "primary": False},
            {"x": 0, "y": 1620, "width": 1920, "height": 720, "primary": False},
        ]
        self.addCleanup(reset_hotkey_daemon_state, daemon)
        seed_usable_monitor_topology(monitors)
        with window_swap_monitor_patches(move_return=False):
            res = daemon.perform_window_swap(mock_ui, 0)
        self.assertEqual(res, 1)
        mock_ui.write.assert_any_call(ecodes.EV_KEY, ecodes.KEY_DOWN, 1)

    @patch("os.path.isfile", side_effect=_usr_local_bin_isfile_side_effect(True))
    @patch("os.access", side_effect=_usr_local_bin_access_side_effect(True))
    @patch("asus_hotkey_daemon_runtime.threading.Thread")
    def test_handle_key_press_screenpad(self, mock_thread_cls, _mock_access, _mock_isfile):
        """Test handle_key_press triggers screenpad script on scancode 0x6A."""
        mock_thread_cls.return_value = MagicMock()
        mock_ui = MagicMock()
        daemon.handle_key_press(0x6A, 0, mock_ui, False)
        self.assertEqual(mock_thread_cls.call_args.kwargs.get("args"), ("/usr/local/bin/asus-screenpad-toggle.sh", None))

    @patch("os.path.isfile", side_effect=_usr_local_bin_isfile_side_effect(True))
    @patch("os.access", side_effect=_usr_local_bin_access_side_effect(True))
    @patch("asus_hotkey_daemon_runtime.threading.Thread")
    def test_handle_key_press_fan(self, mock_thread_cls, _mock_access, _mock_isfile):
        """Test handle_key_press triggers fan script."""
        mock_thread_cls.return_value = MagicMock()
        mock_ui = MagicMock()
        daemon.handle_key_press(0x9D, 482, mock_ui, False)
        self.assertEqual(mock_thread_cls.call_args.kwargs.get("args"), ("/usr/local/bin/asus-fan-toggle.sh", None))

    @patch("os.path.isfile", side_effect=_usr_local_bin_isfile_side_effect(True))
    @patch("os.access", side_effect=_usr_local_bin_access_side_effect(True))
    @patch("asus_hotkey_daemon_runtime.threading.Thread")
    def test_handle_key_press_camera(self, mock_thread_cls, _mock_access, _mock_isfile):
        """Test handle_key_press triggers camera script."""
        mock_thread_cls.return_value = MagicMock()
        mock_ui = MagicMock()
        daemon.handle_key_press(0x85, 212, mock_ui, False)
        self.assertEqual(mock_thread_cls.call_args.kwargs.get("args"), ("/usr/local/bin/asus-camera-toggle.sh", None))

    @patch("os.path.isfile", side_effect=_usr_local_bin_isfile_side_effect(True))
    @patch("os.access", side_effect=_usr_local_bin_access_side_effect(True))
    @patch("asus_hotkey_daemon_runtime.threading.Thread")
    def test_handle_key_press_screenshot(self, mock_thread_cls, _mock_access, _mock_isfile):
        """Test handle_key_press triggers screenshot script."""
        mock_thread_cls.return_value = MagicMock()
        mock_ui = MagicMock()
        daemon.handle_key_press(0xBF, 634, mock_ui, False)
        self.assertEqual(mock_thread_cls.call_args.kwargs.get("args"), ("/usr/local/bin/asus-screenshot.sh", None))

    @patch("os.path.isfile", side_effect=_usr_local_bin_isfile_side_effect(True))
    @patch("os.access", side_effect=_usr_local_bin_access_side_effect(True))
    @patch("asus_hotkey_daemon_runtime.threading.Thread")
    def test_handle_key_press_uses_event_code_fallback(self, mock_thread_cls, _mock_access, _mock_isfile):
        """Test event-code map is used when scancode is unknown."""
        mock_thread_cls.return_value = MagicMock()
        mock_ui = MagicMock()
        daemon.handle_key_press(None, 156, mock_ui, False)
        self.assertEqual(mock_thread_cls.call_args.kwargs.get("args"), ("/usr/local/bin/asus-control-center.sh", None))

    @patch("evdev.list_devices")
    @patch("evdev.InputDevice")
    def test_find_device_path_success(self, mock_input_device, mock_list_devices):
        """Test find_device_path returns matching WMI hotkeys device path."""
        mock_list_devices.return_value = ["/dev/input/event0"]
        mock_dev = MagicMock()
        mock_dev.name = "Asus WMI hotkeys"
        mock_input_device.return_value = mock_dev
        path = daemon.find_device_path()
        self.assertEqual(path, "/dev/input/event0")

    @patch("evdev.list_devices", return_value=[])
    def test_find_device_path_none(self, _mock_list_devices):
        """Test find_device_path returns None when no matching device found."""
        path = daemon.find_device_path()
        self.assertIsNone(path)


class TestAsusHotkeyDaemonMainLifecycle(unittest.TestCase):
    """Main-loop and UInput startup coverage for the hotkey daemon."""

    def setUp(self):
        """Reset daemon state before each test."""
        reset_hotkey_daemon_state(daemon)

    @patch("asus_hotkey_daemon_input.open_video_bus_devices", return_value=[])
    @patch("asus_hotkey_daemon_input.open_modifier_watch_devices", return_value=[])
    @patch("asus_hotkey_daemon_input.UInput")
    @patch("asus_hotkey_daemon_input.find_input_device_path", side_effect=["/dev/input/event0", "/dev/input/event1"])
    @patch("evdev.InputDevice")
    @patch("select.select")
    def test_main_loop_event_handling(
        self,
        mock_select,
        mock_input_device,
        _mock_find,
        mock_uinput,
        _mock_mod,
        _mock_video,
    ):
        """Test main event loop processing with two input devices."""
        mock_dev1 = MagicMock()
        mock_dev1.fd = 10
        mock_dev1.name = "Asus WMI hotkeys"
        mock_dev1.path = "/dev/input/event0"
        mock_dev1.grab.side_effect = OSError("grab failed")
        mock_dev2 = MagicMock()
        mock_dev2.fd = 11
        mock_dev2.name = "AT Translated Set 2 keyboard"
        mock_dev2.path = "/dev/input/event1"
        mock_dev2.capabilities.return_value = {
            ecodes.EV_KEY: [ecodes.KEY_LEFTMETA, ecodes.KEY_P],
            ecodes.EV_MSC: [ecodes.MSC_SCAN],
        }

        event1 = MagicMock()
        event1.type = ecodes.EV_MSC
        event1.code = ecodes.MSC_SCAN
        event1.value = 0x9C

        event2 = MagicMock()
        event2.type = ecodes.EV_KEY
        event2.value = 1
        event2.code = 240

        mock_dev1.read.return_value = [event1, event2]
        mock_input_device.side_effect = [mock_dev1, mock_dev2]
        mock_kb_ui = MagicMock()
        mock_ui = MagicMock()
        mock_uinput.side_effect = [mock_kb_ui, mock_ui]
        mock_select.side_effect = [([10], [], []), KeyboardInterrupt()]

        with (
            patch("asus_hotkey_daemon_input.perform_window_swap") as mock_swap,
            self.assertLogs("asus_hotkey_daemon_input", level="INFO") as log_ctx,
        ):
            try:
                daemon.main()
            except KeyboardInterrupt:
                pass
            mock_swap.assert_called_once_with(mock_ui, 0)
        mock_ui.close.assert_called_once_with()
        mock_kb_ui.close.assert_called_once_with()
        mock_dev1.close.assert_called_once_with()
        mock_dev2.close.assert_called_once_with()
        joined = "\n".join(log_ctx.output)
        self.assertIn("Failed to grab exclusive access on Asus WMI hotkeys", joined)
        self.assertIn("Grabbed exclusive access on AT Translated Set 2 keyboard", joined)

    @patch("asus_hotkey_daemon_input.open_video_bus_devices", return_value=[])
    @patch("asus_hotkey_daemon_input.open_modifier_watch_devices", return_value=[])
    @patch("asus_hotkey_daemon_input.UInput", side_effect=OSError("permission denied"))
    @patch(
        "asus_hotkey_daemon_input.find_input_device_path",
        side_effect=["/dev/input/event0", None],
    )
    @patch("evdev.InputDevice")
    def test_main_uinput_init_failure_reports_actionable_error(
        self,
        mock_input_device,
        _mock_find,
        _mock_uinput,
        _mock_mod,
        _mock_video,
    ):
        """Test main reports actionable UInput init failure and always closes device."""
        mock_dev = MagicMock()
        mock_dev.name = "Asus WMI hotkeys"
        mock_dev.path = "/dev/input/event0"
        mock_input_device.return_value = mock_dev

        with (
            self.assertRaises(SystemExit) as err_ctx,
            self.assertLogs("asus_hotkey_daemon_input", level="INFO") as log_ctx,
        ):
            daemon.main()

        self.assertIn("uinput support is enabled", str(err_ctx.exception))
        self.assertIn("/dev/uinput", str(err_ctx.exception))
        mock_dev.close.assert_called_once_with()
        self.assertTrue(any("Grabbed exclusive access on Asus WMI hotkeys" in line for line in log_ctx.output))


class TestAsusHotkeyDaemonAtKeyboardFilter(unittest.TestCase):
    """AT keyboard Super+P filter and WMI forward-path coverage."""

    def setUp(self):
        """Reset daemon state before each test."""
        reset_hotkey_daemon_state(daemon)

    def test_firmware_super_p_is_swallowed_and_dispatches_display_script(self):
        """Firmware-fast Super+P must not be forwarded; it runs the display script."""
        daemon_at_proxy.reset_pending_meta()
        kb_ui = MagicMock()
        t0 = 1000.0

        def key_event(code, value):
            event = MagicMock()
            event.type = ecodes.EV_KEY
            event.code = code
            event.value = value
            return event

        with patch("asus_hotkey_daemon_at_proxy._dispatch_display_script") as mock_dispatch:
            daemon_at_proxy.handle_at_key_event(key_event(ecodes.KEY_LEFTMETA, 1), kb_ui, t0)
            daemon_at_proxy.handle_at_key_event(key_event(ecodes.KEY_P, 1), kb_ui, t0 + 0.01)
            daemon_at_proxy.handle_at_key_event(key_event(ecodes.KEY_P, 0), kb_ui, t0 + 0.02)
            daemon_at_proxy.handle_at_key_event(key_event(ecodes.KEY_LEFTMETA, 0), kb_ui, t0 + 0.03)
            mock_dispatch.assert_called_once_with()
        kb_ui.write.assert_not_called()

    def test_touchpad_toggle_scancode_is_forwarded_not_settings(self):
        """WMI 0x6B / KEY_TOUCHPAD_TOGGLE must not open Settings; forward via uinput."""
        self.assertNotIn(0x6B, hotkey_state.get_script_map())
        self.assertNotIn(66, hotkey_state.get_code_script_map())
        mock_ui = MagicMock()
        handle_wmi_name = "_handle_wmi_key_press"
        handle_wmi = getattr(daemon_input, handle_wmi_name)
        last, step = handle_wmi(0x6B, ecodes.KEY_TOUCHPAD_TOGGLE, mock_ui, 0)
        self.assertIsNone(last)
        self.assertEqual(step, 0)
        mock_ui.write.assert_any_call(ecodes.EV_KEY, ecodes.KEY_TOUCHPAD_TOGGLE, 1)
        mock_ui.write.assert_any_call(ecodes.EV_KEY, ecodes.KEY_TOUCHPAD_TOGGLE, 0)


class TestAsusHotkeyDaemonScriptDispatch(unittest.TestCase):
    """Dispatch logging coverage for resolved helper scripts."""

    def setUp(self):
        """Reset daemon state before each test."""
        reset_hotkey_daemon_state(daemon)

    @patch("os.path.isfile", side_effect=_usr_local_bin_isfile_side_effect(False))
    def test_handle_key_press_logs_dispatch_failure(self, _mock_isfile):
        """Test handle_key_press logs a warning when script dispatch fails."""
        mock_ui = MagicMock()
        with self.assertLogs("asus_hotkey_daemon_runtime", level="WARNING") as log_ctx:
            daemon.handle_key_press(None, 227, mock_ui, False)
        self.assertTrue(any("Failed to dispatch helper script" in m for m in log_ctx.output))


class TestAsusHotkeyDaemonLoader(unittest.TestCase):
    """Loader and hyphenated CLI entrypoint tests."""

    def _load_isolated_module(self, module_name: str, path: str):
        """Load a one-off module and remove it from sys.modules after the test."""
        module = _exec_module_from_spec(module_name, path)
        self.addCleanup(sys.modules.pop, module_name, None)
        return module

    def test_hyphenated_entrypoint_is_symlink_to_loader(self):
        """Test asus-hotkey-daemon.py is a symlink to the underscore loader module."""
        path = os.path.join(BIN_DIR, "asus-hotkey-daemon.py")
        target = os.path.join(BIN_DIR, "asus_hotkey_daemon.py")
        self.assertTrue(os.path.islink(path))
        self.assertEqual(os.path.realpath(path), os.path.realpath(target))

    def test_loader_requires_real_modules_without_tests_package(self):
        """Test loader imports without requiring the tests package."""
        path = os.path.join(BIN_DIR, "asus_hotkey_daemon.py")
        real_import = __import__

        def guarded_import(name, global_ns=None, local_ns=None, fromlist=(), level=0):
            if name.startswith("tests"):
                raise ModuleNotFoundError(f"No module named '{name}'")
            return real_import(name, global_ns, local_ns, fromlist, level)

        with patch("builtins.__import__", side_effect=guarded_import):
            module = self._load_isolated_module("asus_hotkey_daemon_runtime_test", path)

        self.assertTrue(callable(module.main))

    def test_loader_resolves_shared_imports_from_script_dir_or_repo_root(self):
        """Loader finds shared_imports beside the daemon (install) or at repo root (checkout)."""
        path = os.path.join(BIN_DIR, "asus_hotkey_daemon.py")
        module = self._load_isolated_module("asus_hotkey_daemon_shared_imports_path_test", path)
        resolved = os.path.realpath(module.SHARED_IMPORTS_PATH)
        install_copy = os.path.realpath(os.path.join(BIN_DIR, "shared_imports.py"))
        checkout_copy = os.path.realpath(os.path.join(os.path.dirname(BIN_DIR), "shared_imports.py"))
        self.assertIn(resolved, {install_copy, checkout_copy})
        self.assertTrue(os.path.isfile(resolved))

    def test_loader_prefers_shared_imports_beside_daemon(self):
        """When both layouts exist, prefer the copy next to the loader (installed layout)."""
        with tempfile.TemporaryDirectory() as tmp:
            script_dir = Path(tmp) / "bin"
            script_dir.mkdir()
            beside = script_dir / "shared_imports.py"
            beside.write_text("MARKER = 'beside'\n", encoding="utf-8")
            (Path(tmp) / "shared_imports.py").write_text("MARKER = 'root'\n", encoding="utf-8")
            with patch.object(daemon, "SCRIPT_DIR", str(script_dir)), patch.object(daemon, "REPO_ROOT", tmp):
                resolved = daemon.resolve_shared_imports_path()
            self.assertEqual(os.path.realpath(resolved), os.path.realpath(beside))

    def test_loader_skips_path_insert_when_already_present(self):
        """Test loader keeps sys.path unchanged when SCRIPT_DIR is already present."""
        path = os.path.join(BIN_DIR, "asus_hotkey_daemon.py")
        preserved = [entry for entry in sys.path if entry != BIN_DIR]
        test_path = [BIN_DIR, *preserved]
        with patch.object(sys, "path", test_path):
            before = list(sys.path)
            module = self._load_isolated_module("asus_hotkey_daemon_loader_path_test", path)
            self.assertEqual(list(sys.path), before)
        self.assertEqual(module.SCRIPT_DIR, BIN_DIR)

    def test_loader_appends_script_dir_and_repo_root_when_absent(self):
        """Loader appends SCRIPT_DIR and REPO_ROOT when they are missing from sys.path."""
        path = os.path.join(BIN_DIR, "asus_hotkey_daemon.py")
        repo_root = os.path.dirname(BIN_DIR)
        skip = {os.path.realpath(BIN_DIR), os.path.realpath(repo_root)}
        cleaned = [entry for entry in sys.path if os.path.realpath(entry) not in skip]
        with patch.object(sys, "path", cleaned):
            module = self._load_isolated_module("asus_hotkey_daemon_loader_path_append_test", path)
            self.assertIn(module.SCRIPT_DIR, sys.path)
            self.assertIn(module.REPO_ROOT, sys.path)

    def test_resolve_shared_imports_raises_when_missing(self):
        """resolve_shared_imports_path fails closed when neither layout exists."""
        with tempfile.TemporaryDirectory() as tmp:
            missing_bin = os.path.join(tmp, "bin")
            os.makedirs(missing_bin)
            with (
                patch.object(daemon, "SCRIPT_DIR", missing_bin),
                patch.object(daemon, "REPO_ROOT", tmp),
                self.assertRaises(ImportError),
            ):
                daemon.resolve_shared_imports_path()

    def test_loader_raises_import_error_when_spec_is_missing(self):
        """Test implementation loader raises ImportError when spec creation fails."""
        with patch("importlib.util.spec_from_file_location", return_value=None), self.assertRaises(ImportError):
            load_implementation_module_name = "_load_implementation_module"
            getattr(daemon, load_implementation_module_name)()

    def test_loader_raises_when_shared_imports_spec_missing(self):
        """Module load fails when shared_imports spec_from_file_location returns None."""
        path = os.path.join(BIN_DIR, "asus_hotkey_daemon.py")
        real_spec = importlib.util.spec_from_file_location

        def _spec_for_name(name, location, *args, **kwargs):
            if name == "shared_imports":
                return None
            return real_spec(name, location, *args, **kwargs)

        previous = sys.modules.pop("shared_imports", None)
        try:
            with (
                patch("importlib.util.spec_from_file_location", side_effect=_spec_for_name),
                self.assertRaises(ImportError),
            ):
                self._load_isolated_module("asus_hotkey_daemon_shared_spec_none", path)
        finally:
            if previous is not None:
                sys.modules["shared_imports"] = previous
            else:
                sys.modules.pop("shared_imports", None)

    def test_loader_entrypoints_run_real_impl_main(self):
        """Hyphenated symlink and underscore loader __main__ execute the real implementation."""
        cases = (
            ("hyphenated symlink", os.path.join(BIN_DIR, "asus-hotkey-daemon.py")),
            ("underscore loader", os.path.join(BIN_DIR, "asus_hotkey_daemon.py")),
        )
        for label, path in cases:
            with self.subTest(entrypoint=label):
                with (
                    tempfile.TemporaryDirectory() as evdev_root,
                    patch.dict(os.environ, {"ASUS_EVDEV_DEVICE_ROOT": evdev_root}, clear=False),
                    patch("evdev.list_devices", return_value=[]),
                    self.assertRaises(SystemExit) as ctx,
                ):
                    runpy.run_path(path, run_name="__main__")
                self.assertIn("Asus WMI hotkeys device not found", str(ctx.exception))

    def test_existing_shared_imports_oserror_returns_none(self):
        """samefile OSError treats the cached module as not reusable."""
        fake = type(sys)("shared_imports_fake")
        fake.__file__ = "/tmp/shared_imports_missing.py"
        previous = sys.modules.get("shared_imports")
        sys.modules["shared_imports"] = fake
        try:
            with patch("os.path.samefile", side_effect=OSError("gone")):
                self.assertIsNone(call_attr(daemon, "_existing_shared_imports_module"))
        finally:
            if previous is not None:
                sys.modules["shared_imports"] = previous
            else:
                sys.modules.pop("shared_imports", None)

    def test_load_shared_imports_restores_slot_on_exec_failure(self):
        """Failed exec_module restores the prior shared_imports sys.modules entry."""
        previous = object()
        fake_spec = MagicMock()
        fake_spec.loader = MagicMock()
        fake_spec.loader.exec_module.side_effect = RuntimeError("boom")
        with (
            patch.object(daemon, "_existing_shared_imports_module", return_value=None),
            patch("importlib.util.spec_from_file_location", return_value=fake_spec),
            patch("importlib.util.module_from_spec", return_value=MagicMock()),
            patch.dict(sys.modules, {"shared_imports": previous}, clear=False),
        ):
            with self.assertRaises(RuntimeError):
                call_attr(daemon, "_load_shared_imports")
            self.assertIs(sys.modules.get("shared_imports"), previous)

    def test_restore_shared_imports_slot_clears_when_previous_missing(self):
        """None previous clears a partially registered shared_imports module."""
        sys.modules["shared_imports"] = object()
        call_attr(daemon, "_restore_shared_imports_slot", None)
        self.assertNotIn("shared_imports", sys.modules)
