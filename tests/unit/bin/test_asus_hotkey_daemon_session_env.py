"""Session bus-root, loginctl, cache, and systemctl-env paths for the hotkey daemon."""

import importlib
import os
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

from tests.unit.bin.attr_helpers import call_attr, get_attr

_BIN_DIR = Path(__file__).resolve().parents[3] / "bin"
if str(_BIN_DIR) not in sys.path:
    sys.path.insert(0, str(_BIN_DIR))

session = importlib.import_module("asus_hotkey_daemon_session")
hotkey_state = importlib.import_module("asus_hotkey_daemon_state")


class TestAsusHotkeyDaemonSessionEnv(unittest.TestCase):
    """Bus-root precedence, loginctl parse, cache, and systemctl-env helpers."""

    def tearDown(self):
        """Clear systemctl env skip cache between tests."""
        call_attr(session, "reset_systemctl_env_cache")

    def test_resolve_session_bus_root_precedence(self):
        """BUS_ROOT wins; otherwise fall through to /run/user."""
        with patch.dict(os.environ, {"BUS_ROOT": "/tmp/bus-root"}, clear=False):
            self.assertEqual(call_attr(session, "_resolve_session_bus_root"), "/tmp/bus-root")
        with patch.dict(
            os.environ,
            {"BUS_ROOT": "", "DBUS_BUS_ROOT": "/tmp/dbus-root"},
            clear=False,
        ):
            self.assertEqual(call_attr(session, "_resolve_session_bus_root"), "/tmp/dbus-root")
        with patch.dict(
            os.environ,
            {"BUS_ROOT": "", "DBUS_BUS_ROOT": "", "RUN_USER_ROOT": ""},
            clear=False,
        ):
            self.assertEqual(call_attr(session, "_resolve_session_bus_root"), "/run/user")

    def test_parse_loginctl_skips_malformed_lines(self):
        """Lines without '=' are ignored during property parsing."""
        values = call_attr(session, "_parse_loginctl_property_lines", "Type=wayland\nbogus\nState=active\n")
        self.assertEqual(values, {"Type": "wayland", "State": "active"})

    def test_loginctl_properties_empty_session(self):
        """Empty session id short-circuits without subprocess."""
        self.assertIsNone(call_attr(session, "_loginctl_show_session_properties", "", ["Type"]))

    @patch(
        "asus_hotkey_daemon_session.subprocess.run",
        side_effect=subprocess.TimeoutExpired(cmd="loginctl", timeout=1),
    )
    def test_run_loginctl_timeout(self, _run):
        """loginctl timeout returns None from the runner."""
        self.assertIsNone(call_attr(session, "_run_loginctl_show_session", "1", ["Type"]))

    def test_is_active_gui_session_false_when_missing(self):
        """Missing show-session properties mean not an active GUI session."""
        with patch.object(session, "_loginctl_show_session_properties", return_value=None):
            self.assertFalse(call_attr(session, "_is_active_gui_session", "1"))

    def test_parse_uid_username_rejects(self):
        """root / non-digit / system UIDs are rejected."""
        self.assertIsNone(call_attr(session, "_parse_uid_username", "root", "0"))
        self.assertIsNone(call_attr(session, "_parse_uid_username", "alice", "nope"))
        self.assertIsNone(call_attr(session, "_parse_uid_username", "alice", "42"))
        self.assertEqual(call_attr(session, "_parse_uid_username", "alice", "1000"), (1000, "alice"))

    def test_user_from_gui_session_none(self):
        """Missing Name/User properties yield None."""
        with patch.object(session, "_loginctl_show_session_properties", return_value=None):
            self.assertIsNone(call_attr(session, "_user_from_gui_session", "1"))

    def test_trim_proc_environ_raw(self):
        """Truncated environ blobs keep only complete NUL-terminated entries."""
        max_bytes = get_attr(session, "_PROC_ENVIRON_MAX_BYTES")
        short = b"A=1\0B=2\0"
        self.assertEqual(call_attr(session, "_trim_proc_environ_raw", short), short)
        prefix = b"K=v\0K2=v2\0"
        blob = prefix + (b"x" * (max_bytes - len(prefix)))
        self.assertEqual(len(blob), max_bytes)
        trimmed = call_attr(session, "_trim_proc_environ_raw", blob)
        self.assertEqual(trimmed, b"K=v\0K2=v2")
        no_nul = b"x" * max_bytes
        self.assertEqual(call_attr(session, "_trim_proc_environ_raw", no_nul), no_nul)

    def test_cached_desktop_user_valid_paths(self):
        """Expired cache, inactive session, and revalidation paths."""
        hotkey_state.clear_desktop_user_cache()
        self.addCleanup(hotkey_state.clear_desktop_user_cache)
        expires_past = 0.0
        hotkey_state.set_desktop_user_cache(
            1500,
            "bob",
            "99",
            expires_past,
            {"session_env": {"DISPLAY": ":1"}, "validated_until": 0.0},
        )
        cached = hotkey_state.get_desktop_user_cache()
        with patch("asus_hotkey_daemon_session.time.monotonic", return_value=10.0):
            self.assertIsNone(call_attr(session, "_cached_desktop_user_valid", cached))
        hotkey_state.set_desktop_user_cache(
            1500,
            "bob",
            "99",
            1e18,
            {"session_env": {"DISPLAY": ":1"}, "validated_until": 0.0},
        )
        cached = hotkey_state.get_desktop_user_cache()
        with (
            patch("asus_hotkey_daemon_session.time.monotonic", return_value=1.0),
            patch.object(session, "_is_active_gui_session", return_value=False),
        ):
            self.assertIsNone(call_attr(session, "_cached_desktop_user_valid", cached))
        with (
            patch("asus_hotkey_daemon_session.time.monotonic", return_value=1.0),
            patch.object(session, "_is_active_gui_session", return_value=True),
        ):
            self.assertEqual(call_attr(session, "_cached_desktop_user_valid", cached), (1500, "bob"))

    def test_resolve_desktop_user_cache_hit(self):
        """Valid cache short-circuits detect."""
        self.addCleanup(hotkey_state.clear_desktop_user_cache)
        hotkey_state.set_desktop_user_cache(
            1500,
            "bob",
            "99",
            1e18,
            {"session_env": {"DISPLAY": ":1"}, "validated_until": 1e18},
        )
        with patch.object(session, "_detect_desktop_user") as detect:
            self.assertEqual(call_attr(session, "_resolve_desktop_user"), (1500, "bob"))
            detect.assert_not_called()

    def test_prime_desktop_user_cache_skips_non_root(self):
        """Priming is a no-op when not running as root."""
        with (
            patch("asus_hotkey_daemon_session.os.geteuid", return_value=1000),
            patch.object(session, "_resolve_desktop_user") as resolve,
        ):
            call_attr(session, "prime_desktop_user_cache")
            resolve.assert_not_called()

    def test_systemctl_env_timeout_secs(self):
        """Invalid env falls back to 1.0; deadline clamps the base timeout."""
        with patch.dict(os.environ, {"ASUS_SYSTEMCTL_ENV_TIMEOUT_SECS": "nope"}, clear=False):
            self.assertEqual(call_attr(session, "_systemctl_env_timeout_secs"), 1.0)
        with (
            patch.dict(os.environ, {"ASUS_SYSTEMCTL_ENV_TIMEOUT_SECS": "2"}, clear=False),
            patch("asus_hotkey_daemon_session.time.monotonic", return_value=0.0),
        ):
            self.assertEqual(call_attr(session, "_systemctl_env_timeout_secs", 0.2), 0.2)

    def test_systemctl_env_skip_and_blob_cache(self):
        """Skip window, expired blob, and username mismatch force refetch."""
        state = get_attr(session, "_SYSTEMCTL_ENV_STATE")
        state.clear()
        state.update(
            {
                "user": None,
                "blob": None,
                "blob_valid": False,
                "blob_expires": None,
                "skip_until": None,
            }
        )
        self.assertFalse(call_attr(session, "_systemctl_env_skip_blocks_fetch", state))
        state["skip_until"] = 1e18
        with patch("asus_hotkey_daemon_session.time.monotonic", return_value=1.0):
            self.assertTrue(call_attr(session, "_systemctl_env_skip_blocks_fetch", state))
        state["skip_until"] = 0.5
        with patch("asus_hotkey_daemon_session.time.monotonic", return_value=1.0):
            self.assertFalse(call_attr(session, "_systemctl_env_skip_blocks_fetch", state))
            self.assertIsNone(state["skip_until"])
        need, blob = call_attr(session, "_systemctl_env_blob_from_cache", state, "alice")
        self.assertTrue(need)
        self.assertIsNone(blob)
        state.update({"user": "alice", "blob": "DISPLAY=:0\n", "blob_valid": True, "blob_expires": 0.1})
        with patch("asus_hotkey_daemon_session.time.monotonic", return_value=1.0):
            need, blob = call_attr(session, "_systemctl_env_blob_from_cache", state, "alice")
            self.assertTrue(need)
            self.assertIsNone(blob)
        state.update({"user": "alice", "blob": "DISPLAY=:0\n", "blob_valid": True, "blob_expires": 1e18})
        need, blob = call_attr(session, "_systemctl_env_blob_from_cache", state, "alice")
        self.assertFalse(need)
        self.assertEqual(blob, "DISPLAY=:0\n")

    @patch("asus_hotkey_daemon_session.subprocess.run", side_effect=OSError("no runuser"))
    def test_invoke_systemctl_oserror_marks_skip(self, _run):
        """runuser OSError marks skip and returns None."""
        self.assertIsNone(call_attr(session, "_invoke_systemctl_show_environment", "alice", 1000))

    @patch("asus_hotkey_daemon_session.subprocess.run")
    def test_invoke_systemctl_nonzero_marks_skip(self, mock_run):
        """Nonzero systemctl exit marks skip."""
        mock_run.return_value = MagicMock(returncode=1, stdout="")
        self.assertIsNone(call_attr(session, "_invoke_systemctl_show_environment", "alice", 1000))

    def test_merge_systemctl_environ_empty_username(self):
        """Empty username leaves the env dict unchanged."""
        env = {"DISPLAY": ":0"}
        self.assertEqual(call_attr(session, "_merge_systemctl_environ", env, "", 1000), env)


if __name__ == "__main__":
    unittest.main()
