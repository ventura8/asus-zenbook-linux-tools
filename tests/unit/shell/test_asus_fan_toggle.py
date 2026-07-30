"""Unit tests for bin/asus-fan-toggle.sh."""

import os
import shlex
import tempfile
import unittest
from pathlib import Path

from tests.unit.shell.shell_test_utils import (
    bin_script,
    create_writable_node,
    read_node_content,
    run_shell_script,
    write_fake_executable,
)

SCRIPT = bin_script("asus-fan-toggle.sh")


def _fan_env(tmpdir: str, **extra: str) -> dict[str, str]:
    """Build env with SYS_PLATFORM_ROOT=tmpdir so ASUS_FAN_NODE passes containment."""
    env = dict(os.environ)
    env["SYS_PLATFORM_ROOT"] = tmpdir
    env["ASUS_FAN_USE_PPD"] = "0"
    env.update(extra)
    return env


def _install_fake_powerprofilesctl(bin_dir, state_file, set_mode="ok"):
    """Install a PATH stub that reads/writes a power-profile state file."""
    state_q = shlex.quote(state_file)
    fail_branch = "echo fail >&2; exit 1" if set_mode == "fail" else f'printf "%s\\n" "$2" > {state_q}'
    write_fake_executable(
        os.path.join(bin_dir, "powerprofilesctl"),
        "\n".join(
            [
                "#!/bin/sh",
                'case "$1" in',
                "  get)",
                f"    if [ ! -f {state_q} ]; then",
                '      echo "missing powerprofilesctl state file" >&2',
                "      exit 1",
                "    fi",
                f'    tr -d "[:space:]" < {state_q}',
                "    ;;",
                "  set)",
                f"    {fail_branch}",
                "    ;;",
                "  *)",
                "    exit 1",
                "    ;;",
                "esac",
                "",
            ]
        ),
    )


class TestAsusFanToggle(unittest.TestCase):
    """Unit tests for bin/asus-fan-toggle.sh."""

    def test_no_node_reports_error(self):
        """Script exits non-zero and reports an error for a missing node path."""
        with tempfile.TemporaryDirectory() as tmpdir:
            missing_node = os.path.join(tmpdir, "does-not-exist-fan-node")
            proc = run_shell_script(
                SCRIPT,
                env=_fan_env(tmpdir, ASUS_FAN_NODE=missing_node),
            )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Error: Fan control node is not writable", proc.stderr)

    def test_mode_0_advances_to_1(self):
        """Fan mode 0 (Normal) advances to 1 (Performance)."""
        with tempfile.TemporaryDirectory() as tmpdir:
            node = create_writable_node(tmpdir, "throttle_thermal_policy", "0\n")
            proc = run_shell_script(SCRIPT, env=_fan_env(tmpdir, ASUS_FAN_NODE=node))
            self.assertEqual(proc.returncode, 0)
            self.assertEqual(read_node_content(node), "1")

    def test_mode_1_advances_to_2(self):
        """Fan mode 1 (Performance) advances to 2 (Quiet/Silent)."""
        with tempfile.TemporaryDirectory() as tmpdir:
            node = create_writable_node(tmpdir, "throttle_thermal_policy", "1\n")
            proc = run_shell_script(SCRIPT, env=_fan_env(tmpdir, ASUS_FAN_NODE=node))
            self.assertEqual(proc.returncode, 0)
            self.assertEqual(read_node_content(node), "2")

    def test_mode_2_wraps_to_0(self):
        """Fan mode 2 (Quiet/Silent) wraps back to 0 (Normal)."""
        with tempfile.TemporaryDirectory() as tmpdir:
            node = create_writable_node(tmpdir, "throttle_thermal_policy", "2\n")
            proc = run_shell_script(SCRIPT, env=_fan_env(tmpdir, ASUS_FAN_NODE=node))
            self.assertEqual(proc.returncode, 0)
            self.assertEqual(read_node_content(node), "0")

    def test_out_of_range_mode_clamps_then_advances(self):
        """Out-of-range fan mode values clamp to 2 then advance to 0."""
        with tempfile.TemporaryDirectory() as tmpdir:
            node = create_writable_node(tmpdir, "throttle_thermal_policy", "7\n")
            proc = run_shell_script(SCRIPT, env=_fan_env(tmpdir, ASUS_FAN_NODE=node))
            self.assertEqual(proc.returncode, 0)
            self.assertEqual(read_node_content(node), "0")

    def test_whitespace_in_node_normalized(self):
        """Fan mode read from node with extra whitespace is normalized correctly."""
        with tempfile.TemporaryDirectory() as tmpdir:
            node = create_writable_node(tmpdir, "throttle_thermal_policy", " 0 \n")
            proc = run_shell_script(SCRIPT, env=_fan_env(tmpdir, ASUS_FAN_NODE=node))
            self.assertEqual(proc.returncode, 0)
            self.assertEqual(read_node_content(node), "1")

    def test_ppd_cycle_uses_powerprofilesctl(self):
        """When PPD is forced, cycle follows powerprofilesctl and keeps sysfs unused."""
        with tempfile.TemporaryDirectory() as tmpdir:
            node = create_writable_node(tmpdir, "throttle_thermal_policy", "0\n")
            state = Path(tmpdir) / "ppd"
            state.write_text("balanced\n", encoding="utf-8")
            bin_dir = Path(tmpdir) / "bin"
            bin_dir.mkdir()
            _install_fake_powerprofilesctl(str(bin_dir), str(state))
            env = _fan_env(
                tmpdir,
                PATH=f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}",
                ASUS_FAN_NODE=node,
                ASUS_FAN_USE_PPD="1",
            )
            proc = run_shell_script(SCRIPT, env=env)
            self.assertEqual(proc.returncode, 0)
            self.assertEqual(state.read_text(encoding="utf-8").strip(), "performance")
            self.assertEqual(read_node_content(node), "0")

    def test_ppd_forced_without_sysfs_node(self):
        """ASUS_FAN_USE_PPD=1 must cycle via PPD when sysfs node path is absent."""
        with tempfile.TemporaryDirectory() as tmpdir:
            state = Path(tmpdir) / "ppd"
            state.write_text("balanced\n", encoding="utf-8")
            bin_dir = Path(tmpdir) / "bin"
            bin_dir.mkdir()
            _install_fake_powerprofilesctl(str(bin_dir), str(state))
            env = _fan_env(
                tmpdir,
                PATH=f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}",
                ASUS_FAN_NODE=f"{tmpdir}/missing-throttle-node",
                ASUS_FAN_USE_PPD="1",
            )
            proc = run_shell_script(SCRIPT, env=env)
            self.assertEqual(proc.returncode, 0)
            self.assertEqual(state.read_text(encoding="utf-8").strip(), "performance")

    def test_ppd_set_failure_falls_back_to_sysfs(self):
        """Failed powerprofilesctl set falls back to writing the fan sysfs node."""
        with tempfile.TemporaryDirectory() as tmpdir:
            node = create_writable_node(tmpdir, "throttle_thermal_policy", "1\n")
            state = Path(tmpdir) / "ppd"
            state.write_text("performance\n", encoding="utf-8")
            bin_dir = Path(tmpdir) / "bin"
            bin_dir.mkdir()
            _install_fake_powerprofilesctl(str(bin_dir), str(state), set_mode="fail")
            env = _fan_env(
                tmpdir,
                PATH=f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}",
                ASUS_FAN_NODE=node,
                ASUS_FAN_USE_PPD="1",
            )
            proc = run_shell_script(SCRIPT, env=env)
            self.assertEqual(proc.returncode, 0)
            self.assertEqual(read_node_content(node), "2")
            self.assertEqual(state.read_text(encoding="utf-8").strip(), "performance")

    def test_ppd_power_saver_wraps_to_balanced_sysfs_unchanged(self):
        """PPD power-saver cycles to balanced without writing the sysfs node."""
        with tempfile.TemporaryDirectory() as tmpdir:
            node = create_writable_node(tmpdir, "throttle_thermal_policy", "2\n")
            state = Path(tmpdir) / "ppd"
            state.write_text("power-saver\n", encoding="utf-8")
            bin_dir = Path(tmpdir) / "bin"
            bin_dir.mkdir()
            _install_fake_powerprofilesctl(str(bin_dir), str(state))
            env = _fan_env(
                tmpdir,
                PATH=f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}",
                ASUS_FAN_NODE=node,
                ASUS_FAN_USE_PPD="1",
            )
            proc = run_shell_script(SCRIPT, env=env)
            self.assertEqual(proc.returncode, 0)
            self.assertEqual(state.read_text(encoding="utf-8").strip(), "balanced")
            self.assertEqual(read_node_content(node), "2")

    def test_invalid_asus_fan_use_ppd_rejects_non_binary(self):
        """Invalid ASUS_FAN_USE_PPD values fail closed before toggling."""
        with tempfile.TemporaryDirectory() as tmpdir:
            env = {key: value for key, value in os.environ.items() if not key.startswith("ASUS_")}
            env["SYS_PLATFORM_ROOT"] = tmpdir
            env["ASUS_FAN_USE_PPD"] = "2"
            proc = run_shell_script(SCRIPT, env=env)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("Invalid ASUS_FAN_USE_PPD", proc.stderr)

    def test_asus_fan_use_ppd_0_forces_sysfs_even_with_ppd(self):
        """ASUS_FAN_USE_PPD=0 disables powerprofilesctl regardless of ASUS_FAN_NODE."""
        with tempfile.TemporaryDirectory() as tmpdir:
            mock_bin = os.path.join(tmpdir, "bin")
            os.makedirs(mock_bin)
            state = Path(tmpdir) / "ppd"
            state.write_text("performance\n", encoding="utf-8")
            _install_fake_powerprofilesctl(mock_bin, str(state))
            node = create_writable_node(tmpdir, "throttle_thermal_policy", "0\n")
            env = _fan_env(
                tmpdir,
                PATH=f"{mock_bin}:{os.environ.get('PATH', '')}",
                ASUS_FAN_NODE=node,
                ASUS_FAN_USE_PPD="0",
            )
            proc = run_shell_script(SCRIPT, env=env)
            self.assertEqual(proc.returncode, 0)
            self.assertEqual(read_node_content(node), "1")
            self.assertEqual(state.read_text(encoding="utf-8").strip(), "performance")


if __name__ == "__main__":
    unittest.main()
