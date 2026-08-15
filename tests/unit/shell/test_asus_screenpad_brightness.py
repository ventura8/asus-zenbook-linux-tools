"""Unit tests for bin/asus-screenpad-brightness.sh."""

import os
import shlex
import tempfile
import unittest
from pathlib import Path

from tests.unit.shell.shell_test_utils import (
    bin_script,
    bind_unix_socket,
    create_writable_node,
    read_node_content,
    run_shell_script,
    screenpad_env,
    write_fake_executable,
)

SCRIPT = bin_script("asus-screenpad-brightness.sh")


def _brightness_env(tmpdir: str, **extra: str) -> dict[str, str]:
    """Build env with writable NOTIF_ID_ROOT/STATE_DIR under tmpdir."""
    return screenpad_env(tmpdir, **extra)


def _node_with_max(tmpdir: str, value: str, max_value: str = "255") -> str:
    """Create brightness + sibling max_brightness under tmpdir."""
    node = create_writable_node(tmpdir, "brightness", value)
    max_path = os.path.join(os.path.dirname(node), "max_brightness")
    with open(max_path, "w", encoding="utf-8") as handle:
        handle.write(max_value if max_value.endswith("\n") else f"{max_value}\n")
    return node


class TestAsusScreenpadBrightness(unittest.TestCase):
    """Unit tests for bin/asus-screenpad-brightness.sh."""

    def test_usage_without_args(self):
        """Missing command prints usage and exits non-zero."""
        with tempfile.TemporaryDirectory() as tmpdir:
            proc = run_shell_script(SCRIPT, env=_brightness_env(tmpdir))
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Usage:", proc.stderr)

    def test_missing_node_errors(self):
        """Missing node path fails closed."""
        with tempfile.TemporaryDirectory() as tmpdir:
            missing = os.path.join(tmpdir, "missing-brightness")
            proc = run_shell_script(
                SCRIPT,
                args=["up"],
                env=_brightness_env(tmpdir, ASUS_SCREENPAD_NODE=missing),
            )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("not writable", proc.stderr)

    def test_up_steps_and_clamps_to_max(self):
        """up increases by ~10% and clamps to max_brightness."""
        with tempfile.TemporaryDirectory() as tmpdir:
            node = _node_with_max(tmpdir, "240\n", "255")
            proc = run_shell_script(
                SCRIPT,
                args=["up"],
                env=_brightness_env(tmpdir, ASUS_SCREENPAD_NODE=node),
            )
            self.assertEqual(proc.returncode, 0)
            self.assertEqual(read_node_content(node), "255")

    def test_down_floors_at_one(self):
        """down never writes 0; Off stays exclusive to the toggle helper."""
        with tempfile.TemporaryDirectory() as tmpdir:
            node = _node_with_max(tmpdir, "5\n", "255")
            proc = run_shell_script(
                SCRIPT,
                args=["down"],
                env=_brightness_env(tmpdir, ASUS_SCREENPAD_NODE=node),
            )
            self.assertEqual(proc.returncode, 0)
            self.assertEqual(read_node_content(node), "1")

    def test_set_percent_and_updates_restore_file(self):
        """set 40% writes clamped raw value and updates toggle restore state."""
        with tempfile.TemporaryDirectory() as tmpdir:
            node = _node_with_max(tmpdir, "10\n", "255")
            env = _brightness_env(tmpdir, ASUS_SCREENPAD_NODE=node)
            proc = run_shell_script(SCRIPT, args=["set", "40%"], env=env)
            self.assertEqual(proc.returncode, 0)
            self.assertEqual(read_node_content(node), "102")
            state_root = os.path.join(tmpdir, "state")
            found = []
            for root, _dirs, files in os.walk(state_root):
                if "screenpad_brightness" in files:
                    found.append(os.path.join(root, "screenpad_brightness"))
            self.assertEqual(len(found), 1)
            with open(found[0], encoding="utf-8") as handle:
                self.assertEqual(handle.read().strip(), "102")

    def test_get_prints_curr_max_percent(self):
        """get reports brightness, max, and percent."""
        with tempfile.TemporaryDirectory() as tmpdir:
            node = _node_with_max(tmpdir, "128\n", "255")
            proc = run_shell_script(
                SCRIPT,
                args=["get"],
                env=_brightness_env(tmpdir, ASUS_SCREENPAD_NODE=node),
            )
            self.assertEqual(proc.returncode, 0)
            self.assertIn("brightness=128", proc.stdout)
            self.assertIn("max=255", proc.stdout)
            self.assertIn("percent=50", proc.stdout)

    def test_set_raw_value(self):
        """set with a raw integer clamps into range and writes sysfs."""
        with tempfile.TemporaryDirectory() as tmpdir:
            node = _node_with_max(tmpdir, "10\n", "255")
            proc = run_shell_script(
                SCRIPT,
                args=["set", "200"],
                env=_brightness_env(tmpdir, ASUS_SCREENPAD_NODE=node),
            )
            self.assertEqual(proc.returncode, 0)
            self.assertEqual(read_node_content(node), "200")


class TestAsusScreenpadBrightnessFeedback(unittest.TestCase):
    """OSD preference and replace-in-place notify for ScreenPad brightness."""

    def _notify_env(self, tmpdir: str, gdbus_body: str) -> tuple[dict[str, str], Path, Path]:
        """Build PATH stubs so brightness feedback hits controlled gdbus."""
        mock_bin = Path(tmpdir) / "bin"
        runtime = Path(tmpdir) / "run" / "1000"
        mock_bin.mkdir()
        runtime.mkdir(parents=True)
        bind_unix_socket(runtime / "bus")
        gdbus_log = Path(tmpdir) / "gdbus.log"
        write_fake_executable(
            str(mock_bin / "gdbus"),
            f"""#!/bin/sh
printf '%s\\n' "$*" >> {shlex.quote(str(gdbus_log))}
{gdbus_body}
""",
        )
        write_fake_executable(
            str(mock_bin / "id"),
            '#!/bin/sh\nif [ "$1" = "-u" ]; then echo 1000; exit 0; fi\necho fakeuser\n',
        )
        write_fake_executable(
            str(mock_bin / "loginctl"),
            """#!/bin/sh
if [ "$1" = "list-sessions" ]; then echo c1 1000 seat0; exit 0; fi
if [ "$1" = "show-session" ]; then
  case "$*" in *Type*) echo x11 ;; *State*) echo active ;; *Name*) echo fakeuser ;; *Seat*) echo seat0 ;; esac
  exit 0
fi
""",
        )
        env = _brightness_env(tmpdir)
        env["PATH"] = f"{mock_bin}:{os.environ.get('PATH', '')}"
        env["RUN_USER_ROOT"] = str(Path(tmpdir) / "run")
        env.pop("BUS_ROOT", None)
        env.pop("DBUS_BUS_ROOT", None)
        env["ASUS_SCREENPAD_NODE"] = _node_with_max(tmpdir, "128\n", "255")
        return env, mock_bin, gdbus_log

    def test_gnome_osd_primes_extension_then_skips_notify(self):
        """ShowOsd miss triggers gnome-extensions enable; retry skips notify."""
        with tempfile.TemporaryDirectory() as tmpdir:
            armed = Path(tmpdir) / "osd_armed"
            env, mock_bin, gdbus_log = self._notify_env(
                tmpdir,
                f"""
case "$*" in
  *ShowOsd*)
    if [ -f {shlex.quote(str(armed))} ]; then echo '()'; exit 0; fi
    exit 1
    ;;
  *brightnessChanged*|*showProgress*|*Notifications.Notify*)
    echo NOTIFY
    exit 0
    ;;
  *) exit 1 ;;
esac
""",
            )
            write_fake_executable(
                str(mock_bin / "gnome-extensions"),
                f"""#!/bin/sh
touch {shlex.quote(str(armed))}
exit 0
""",
            )
            proc = run_shell_script(SCRIPT, args=["up"], env=env)
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            logged = gdbus_log.read_text(encoding="utf-8")
            self.assertIn("ShowOsd", logged)
            self.assertNotIn("Notifications.Notify", logged)
            self.assertTrue(armed.is_file())

    def test_plasma_osd_skips_notification(self):
        """When GNOME ShowOsd fails, Plasma brightnessChanged skips notify."""
        with tempfile.TemporaryDirectory() as tmpdir:
            env, _mock_bin, gdbus_log = self._notify_env(
                tmpdir,
                """
case "$*" in
  *ShowOsd*) exit 1 ;;
  *brightnessChanged*) echo '(true,)'; exit 0 ;;
  *Notifications.Notify*) echo 'NOTIFY'; exit 0 ;;
  *) exit 1 ;;
esac
""",
            )
            proc = run_shell_script(SCRIPT, args=["up"], env=env)
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            logged = gdbus_log.read_text(encoding="utf-8")
            self.assertIn("brightnessChanged", logged)
            self.assertNotIn("Notifications.Notify", logged)

    def test_lxqt_value_hint_notify_skips_generic_fallback(self):
        """LXQt uses Spec value-hint Notify when Shell/Plasma OSDs miss."""
        with tempfile.TemporaryDirectory() as tmpdir:
            env, _mock_bin, gdbus_log = self._notify_env(
                tmpdir,
                """
case "$*" in
  *ShowOsd*|*ShowOSD*|*brightnessChanged*|*showProgress*) exit 1 ;;
  *Notifications.Notify*)
    echo '(uint32 42,)'
    exit 0
    ;;
  *) exit 1 ;;
esac
""",
            )
            env["ASUS_DESKTOP_FAMILY"] = "lxqt"
            proc = run_shell_script(SCRIPT, args=["up"], env=env)
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            logged = gdbus_log.read_text(encoding="utf-8")
            self.assertIn("Notifications.Notify", logged)
            self.assertRegex(logged, r"'value':\s*<int32\s+\d+>")

    def test_cinnamon_show_osd_skips_notification(self):
        """Cinnamon ShowOSD runs after Plasma miss and skips notify."""
        with tempfile.TemporaryDirectory() as tmpdir:
            env, _mock_bin, gdbus_log = self._notify_env(
                tmpdir,
                """
case "$*" in
  *ShowOsd*|*brightnessChanged*|*showProgress*) exit 1 ;;
  *org.Cinnamon.ShowOSD*) echo '()'; exit 0 ;;
  *Notifications.Notify*) echo NOTIFY; exit 0 ;;
  *) exit 1 ;;
esac
""",
            )
            env["ASUS_DESKTOP_FAMILY"] = "cinnamon"
            proc = run_shell_script(SCRIPT, args=["up"], env=env)
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            logged = gdbus_log.read_text(encoding="utf-8")
            self.assertIn("org.Cinnamon.ShowOSD", logged)
            self.assertNotIn("Notifications.Notify", logged)

    def test_mate_value_hint_notify_skips_generic_fallback(self):
        """MATE uses Spec value-hint Notify when no public ShowOSD exists."""
        with tempfile.TemporaryDirectory() as tmpdir:
            env, _mock_bin, gdbus_log = self._notify_env(
                tmpdir,
                """
case "$*" in
  *ShowOsd*|*ShowOSD*|*brightnessChanged*|*showProgress*) exit 1 ;;
  *Notifications.Notify*)
    echo '(uint32 42,)'
    exit 0
    ;;
  *) exit 1 ;;
esac
""",
            )
            env["ASUS_DESKTOP_FAMILY"] = "mate"
            proc = run_shell_script(SCRIPT, args=["up"], env=env)
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            logged = gdbus_log.read_text(encoding="utf-8")
            self.assertIn("Notifications.Notify", logged)
            self.assertRegex(logged, r"'value':\s*<int32\s+\d+>")

    def test_notify_fallback_reuses_replace_id(self):
        """When all OSDs fail, successive notifies reuse the saved replace id."""
        with tempfile.TemporaryDirectory() as tmpdir:
            env, _mock_bin, gdbus_log = self._notify_env(
                tmpdir,
                """
case "$*" in
  *ShowOsd*|*ShowOSD*|*brightnessChanged*|*showProgress*) exit 1 ;;
  *Notifications.Notify*)
    echo '(uint32 9,)'
    exit 0
    ;;
  *) exit 1 ;;
esac
""",
            )
            env["ASUS_DESKTOP_FAMILY"] = "xfce"
            proc1 = run_shell_script(SCRIPT, args=["up"], env=env)
            proc2 = run_shell_script(SCRIPT, args=["up"], env=env)
            self.assertEqual(proc1.returncode, 0, msg=proc1.stderr)
            self.assertEqual(proc2.returncode, 0, msg=proc2.stderr)
            logged = gdbus_log.read_text(encoding="utf-8")
            notify_lines = [line for line in logged.splitlines() if "Notifications.Notify" in line]
            self.assertGreaterEqual(len(notify_lines), 2, msg=logged)
            self.assertRegex(notify_lines[0], r"ASUS ZenBook 0 ")
            self.assertRegex(notify_lines[1], r"ASUS ZenBook 9 ")


if __name__ == "__main__":
    unittest.main()
