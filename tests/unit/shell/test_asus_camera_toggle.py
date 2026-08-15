"""Unit tests for bin/asus-camera-toggle.sh."""

import os
import pwd
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from tests.unit.shell.shell_test_utils import (
    PROJECT_ROOT,
    bin_script,
    create_writable_node,
    read_node_content,
    run_bash_c,
    run_shell_argv,
    run_shell_script,
)

SCRIPT = bin_script("asus-camera-toggle.sh")


def _camera_env(tmpdir: str, **extra: str) -> dict[str, str]:
    """Build env with writable NOTIF_ID_ROOT under tmpdir.

    Default SYS_PLATFORM_ROOT to tmpdir so ASUS_CAMERA_NODE paths under the
    fixture tree pass containment checks.
    """
    env = dict(os.environ)
    env["NOTIF_ID_ROOT"] = os.path.join(tmpdir, "notif")
    env["SYS_PLATFORM_ROOT"] = tmpdir
    env["ASUS_CAMERA_ICON_DIR"] = str(PROJECT_ROOT / "assets" / "icons")
    env["ASUS_CAMERA_APP_NAME_COLOR"] = "#b2b2b4"
    env.update(extra)
    return env


def _nobody_can_read_script(run_as: str, script_path: str) -> bool:
    """Return True when nobody can read *script_path* and traverse its parent."""
    parent = os.path.dirname(script_path)
    readable = subprocess.run(
        [run_as, "-u", "nobody", "--", "test", "-r", script_path],
        capture_output=True,
        check=False,
        timeout=15,
    )
    traversable = subprocess.run(
        [run_as, "-u", "nobody", "--", "test", "-x", parent],
        capture_output=True,
        check=False,
        timeout=15,
    )
    return readable.returncode == 0 and traversable.returncode == 0


def _nobody_camera_env(source: dict) -> dict[str, str]:
    """Build a minimal env for running camera-toggle as nobody."""
    clean_env = {
        "PATH": source.get("PATH") or os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": "/nonexistent",
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
    }
    for key in (
        "NOTIF_ID_ROOT",
        "ASUS_CAMERA_NODE",
        "ASUS_CAMERA_ICON_DIR",
        "ASUS_CAMERA_APP_NAME_COLOR",
        "ASUS_CAMERA_FORCE_KEYCAP",
        "ASUS_ICON_THEME_ROOT",
        "SYS_PLATFORM_ROOT",
    ):
        if key in source:
            clean_env[key] = source[key]
    return clean_env


def _run_script_as_nobody(script_path, env=None):
    """Run a shell script as nobody when the current user is root."""
    run_as = shutil.which("runuser")
    if not run_as:
        raise unittest.SkipTest("runuser is not available on this host")
    script_path = os.path.abspath(script_path)
    if not _nobody_can_read_script(run_as, script_path):
        raise unittest.SkipTest(f"Script is not readable/traversable by nobody: {script_path}")
    clean_env = _nobody_camera_env(env or {})
    cmd = [run_as, "-u", "nobody", "--", "bash", script_path]
    return run_shell_argv(cmd, env=clean_env, timeout=15)


class TestAsusCameraToggle(unittest.TestCase):
    """Unit tests for bin/asus-camera-toggle.sh."""

    def test_missing_node_reports_error(self):
        """Script exits non-zero and reports an error for a missing node path."""
        with tempfile.TemporaryDirectory() as tmpdir:
            missing_node = os.path.join(tmpdir, "does-not-exist-camera-node")
            proc = run_shell_script(
                SCRIPT,
                env=_camera_env(tmpdir, ASUS_CAMERA_NODE=missing_node),
            )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Error: Camera control node is not writable", proc.stderr)

    def test_readonly_node_reports_error(self):
        """Script exits non-zero when an existing camera node is not writable."""
        with tempfile.TemporaryDirectory() as tmpdir:
            os.chmod(tmpdir, 0o711)
            node = create_writable_node(tmpdir, "camera", "1\n")
            run_as_nobody = False
            if not os.geteuid():
                os.chmod(tmpdir, 0o755)
                try:
                    nobody = pwd.getpwnam("nobody")
                except KeyError:
                    self.skipTest("nobody account is not available on this host")
                try:
                    os.chown(node, nobody.pw_uid, nobody.pw_gid)
                    run_as_nobody = True
                except OSError as exc:
                    self.skipTest(f"Unable to chown camera node to nobody: {exc}")
            os.chmod(node, 0o444)
            env = _camera_env(tmpdir, ASUS_CAMERA_NODE=node)
            if run_as_nobody:
                proc = _run_script_as_nobody(SCRIPT, env=env)
            else:
                proc = run_shell_script(SCRIPT, env=env)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Error: Camera control node is not writable", proc.stderr)

    def test_camera_enabled_disables(self):
        """When node reads 1 (camera on), toggle writes 0 (disabled)."""
        with tempfile.TemporaryDirectory() as tmpdir:
            node = create_writable_node(tmpdir, "camera", "1\n")
            proc = run_shell_script(SCRIPT, env=_camera_env(tmpdir, ASUS_CAMERA_NODE=node))
            self.assertEqual(proc.returncode, 0)
            self.assertEqual(read_node_content(node), "0")

    def test_camera_disabled_enables(self):
        """When node reads 0 (camera off), toggle writes 1 (enabled)."""
        with tempfile.TemporaryDirectory() as tmpdir:
            node = create_writable_node(tmpdir, "camera", "0\n")
            proc = run_shell_script(SCRIPT, env=_camera_env(tmpdir, ASUS_CAMERA_NODE=node))
            self.assertEqual(proc.returncode, 0)
            self.assertEqual(read_node_content(node), "1")

    def test_default_discovery_via_sys_platform_root(self):
        """Without ASUS_CAMERA_NODE, discovery uses SYS_PLATFORM_ROOT asus-nb-wmi path."""
        with tempfile.TemporaryDirectory() as tmpdir:
            platform_root = Path(tmpdir) / "platform"
            node_dir = platform_root / "asus-nb-wmi"
            node_dir.mkdir(parents=True)
            node = node_dir / "camera"
            node.write_text("1\n", encoding="utf-8")
            env = _camera_env(tmpdir, SYS_PLATFORM_ROOT=str(platform_root))
            env.pop("ASUS_CAMERA_NODE", None)
            proc = run_shell_script(SCRIPT, env=env)
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            self.assertEqual(node.read_text(encoding="utf-8").strip(), "0")

    def test_resolve_icon_prefers_system_theme_when_present(self):
        """On/off resolve to camera-photo/disabled-symbolic when theme icons exist."""
        with tempfile.TemporaryDirectory() as tmpdir:
            icon_root = Path(tmpdir) / "icons"
            on_path = icon_root / "Adwaita/symbolic/devices/camera-photo-symbolic.svg"
            off_path = icon_root / "Adwaita/symbolic/status/camera-disabled-symbolic.svg"
            on_path.parent.mkdir(parents=True, exist_ok=True)
            off_path.parent.mkdir(parents=True, exist_ok=True)
            on_path.write_text("<svg/>\n", encoding="utf-8")
            off_path.write_text("<svg/>\n", encoding="utf-8")
            script = f'source "{SCRIPT}" >/dev/null\n_resolve_camera_notification_icon on\n_resolve_camera_notification_icon off\n'
            proc = run_bash_c(
                script,
                env=_camera_env(tmpdir, ASUS_ICON_THEME_ROOT=str(icon_root)),
                log_name="camera-icon-system",
            )
            self.assertEqual(proc.returncode, 0)
            lines = [line for line in proc.stdout.splitlines() if line.strip()]
            self.assertEqual(lines, ["camera-photo-symbolic", "camera-disabled-symbolic"])

    def test_resolve_icon_falls_back_without_theme_glyphs(self):
        """Missing theme glyphs under ASUS_ICON_THEME_ROOT fall back to keycap art."""
        with tempfile.TemporaryDirectory() as tmpdir:
            icon_root = Path(tmpdir) / "icons"
            icon_root.mkdir(parents=True, exist_ok=True)
            script = f'source "{SCRIPT}" >/dev/null\n_resolve_camera_notification_icon on\n_resolve_camera_notification_icon off\n'
            proc = run_bash_c(
                script,
                env=_camera_env(tmpdir, ASUS_ICON_THEME_ROOT=str(icon_root)),
                log_name="camera-icon-fallback",
            )
            self.assertEqual(proc.returncode, 0)
            lines = [line for line in proc.stdout.splitlines() if line.strip()]
            self.assertEqual(len(lines), 2)
            for path, state in zip(lines, ("on", "off"), strict=True):
                self.assertTrue(
                    path.endswith(f"asus-camera-{state}.svg") or path == "camera-web",
                    path,
                )

    def test_resolve_icon_force_keycap_tints_app_name_color(self):
        """ASUS_CAMERA_FORCE_KEYCAP tints UX582HS F10 templates to app-name color."""
        with tempfile.TemporaryDirectory() as tmpdir:
            script = f'source "{SCRIPT}" >/dev/null\n_resolve_camera_notification_icon on\n_resolve_camera_notification_icon off\n'
            proc = run_bash_c(
                script,
                env=_camera_env(
                    tmpdir,
                    ASUS_CAMERA_FORCE_KEYCAP="1",
                    ASUS_ICON_THEME_ROOT=str(Path(tmpdir) / "icons"),
                ),
                log_name="camera-icon-keycap",
            )
            self.assertEqual(proc.returncode, 0)
            lines = [line for line in proc.stdout.splitlines() if line.strip()]
            self.assertEqual(len(lines), 2)
            for path, state in zip(lines, ("on", "off"), strict=True):
                self.assertTrue(path.endswith(f"asus-camera-{state}.svg"), path)
                self.assertTrue(os.path.isfile(path), path)
                with open(path, encoding="utf-8") as handle:
                    body = handle.read()
                self.assertIn('stroke="#b2b2b4"', body)


if __name__ == "__main__":
    unittest.main()
