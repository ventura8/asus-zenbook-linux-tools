"""Unit tests for bin/asus-screenpad-toggle.sh."""

import os
import tempfile
import unittest

from tests.unit.shell.shell_test_utils import (
    bin_script,
    create_writable_node,
    read_node_content,
    run_bash_c,
    run_shell_script,
    screenpad_env,
)

SCRIPT = bin_script("asus-screenpad-toggle.sh")


class TestAsusScreenpadToggle(unittest.TestCase):
    """Unit tests for bin/asus-screenpad-toggle.sh."""

    def test_no_node_reports_error(self):
        """Script exits non-zero and reports an error for a missing node path."""
        with tempfile.TemporaryDirectory() as tmpdir:
            missing_node = os.path.join(tmpdir, "does-not-exist-screenpad-node")
            proc = run_shell_script(
                SCRIPT,
                env=screenpad_env(tmpdir, ASUS_SCREENPAD_NODE=missing_node),
            )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Error: ScreenPad control node is not writable", proc.stderr)

    def test_brightness_positive_sets_zero(self):
        """When brightness > 0, toggle sets it to 0 (ScreenPad off)."""
        with tempfile.TemporaryDirectory() as tmpdir:
            node = create_writable_node(tmpdir, "brightness", "128\n")
            proc = run_shell_script(
                SCRIPT,
                env=screenpad_env(tmpdir, ASUS_SCREENPAD_NODE=node),
            )
            self.assertEqual(proc.returncode, 0)
            self.assertEqual(read_node_content(node), "0")

    def test_brightness_non_numeric_reads_as_zero(self):
        """Non-numeric brightness sysfs values are treated as off (0) before toggle."""
        with tempfile.TemporaryDirectory() as tmpdir:
            node = create_writable_node(tmpdir, "brightness", "not-a-number\n")
            proc = run_shell_script(
                SCRIPT,
                env=screenpad_env(tmpdir, ASUS_SCREENPAD_NODE=node),
            )
            self.assertEqual(proc.returncode, 0)
            self.assertEqual(read_node_content(node), "255")

    def test_brightness_zero_sets_max(self):
        """When brightness = 0, toggle sets it to 255 (ScreenPad full on)."""
        with tempfile.TemporaryDirectory() as tmpdir:
            node = create_writable_node(tmpdir, "brightness", "0\n")
            proc = run_shell_script(
                SCRIPT,
                env=screenpad_env(tmpdir, ASUS_SCREENPAD_NODE=node),
            )
            self.assertEqual(proc.returncode, 0)
            self.assertEqual(read_node_content(node), "255")

    def test_resolve_notification_icon_tints_to_app_name_color(self):
        """Icon file is tinted to ASUS_SCREENPAD_APP_NAME_COLOR (message-header)."""
        with tempfile.TemporaryDirectory() as tmpdir:
            script = (
                f'source "{SCRIPT}" >/dev/null\n'
                "_resolve_screenpad_notification_icon on\n"
                "_resolve_screenpad_notification_icon off\n"
            )
            proc = run_bash_c(
                script,
                env=screenpad_env(tmpdir),
                log_name="screenpad-icon-resolve",
            )
            self.assertEqual(proc.returncode, 0)
            lines = [line for line in proc.stdout.splitlines() if line.strip()]
            self.assertEqual(len(lines), 2)
            for path, state in zip(lines, ("on", "off"), strict=True):
                self.assertTrue(path.endswith(f"asus-screenpad-{state}.svg"), path)
                self.assertTrue(os.path.isfile(path), path)
                with open(path, encoding="utf-8") as handle:
                    body = handle.read()
                self.assertIn('stroke="#b2b2b4"', body)
                self.assertNotIn('stroke="gray"', body)


if __name__ == "__main__":
    unittest.main()
