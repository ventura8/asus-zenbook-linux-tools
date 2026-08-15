"""Unit tests for lib/asus-session.sh desktop/session helpers."""

import os
import shlex
import tempfile
import unittest
from pathlib import Path

from tests.unit.shell.shell_test_utils import PROJECT_ROOT, run_bash_c

SESSION_LIB = PROJECT_ROOT / "lib" / "asus-session.sh"


def _write_exact_id_stub(mock_bin: Path, *, uid: str = "1000", username: str = "testuser") -> None:
    """Install an id stub that matches exact argv[1] tokens (-u / -un)."""
    stub = mock_bin / "id"
    stub.write_text(
        f'#!/bin/sh\ncase "$1" in\n  -u) echo {uid} ;;\n  -un) echo {username} ;;\n  *) exit 1 ;;\nesac\n',
        encoding="utf-8",
    )
    stub.chmod(0o755)


def _source_and_run(body: str, env: dict | None = None, timeout: int = 5):
    """Source asus-session.sh and run a bash body."""
    script = f"set -euo pipefail; source {shlex.quote(str(SESSION_LIB))}; {body}"
    return run_bash_c(script, env=env, timeout=timeout)


class TestAsusSessionHelpers(unittest.TestCase):
    """Desktop-family and environ parsing helpers."""

    def test_desktop_family_prefers_xfce_over_ubuntu(self):
        """Xubuntu-style XFCE:ubuntu maps to xfce, not gnome."""
        proc = _source_and_run('asus_desktop_family_from_string "XFCE:ubuntu"')
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout.strip(), "xfce")

    def test_desktop_family_prefers_plasma_over_ubuntu(self):
        """Kubuntu-style strings map to kde."""
        proc = _source_and_run('asus_desktop_family_from_string "KDE:ubuntu"')
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout.strip(), "kde")

    def test_desktop_family_prefers_lxqt_over_ubuntu(self):
        """Lubuntu-style LXQt:ubuntu maps to lxqt, not gnome."""
        proc = _source_and_run('asus_desktop_family_from_string "LXQt:ubuntu"')
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout.strip(), "lxqt")

    def test_desktop_family_prefers_cinnamon_over_ubuntu(self):
        """Mint Cinnamon token maps to cinnamon before gnome/ubuntu."""
        proc = _source_and_run('asus_desktop_family_from_string "X-Cinnamon"')
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout.strip(), "cinnamon")

    def test_desktop_family_prefers_mate_over_ubuntu(self):
        """MATE token maps to mate before gnome/ubuntu."""
        proc = _source_and_run('asus_desktop_family_from_string "MATE"')
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout.strip(), "mate")

    def test_mint_bare_gnome_session_desktop_token(self):
        """Bare GNOME remaps via XDG_SESSION_DESKTOP cinnamon/mate tokens."""
        proc = _source_and_run(
            "_asus_lookup_env_key() { "
            'case "$1" in XDG_SESSION_DESKTOP) printf "cinnamon\\n" ;; '
            "*) return 1 ;; esac; }; "
            "_asus_mint_bare_gnome_family 1"
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertEqual(proc.stdout.strip(), "cinnamon")

    def test_mint_bare_gnome_schema_probe(self):
        """Schema probe classifies cinnamon when gsettings lists Cinnamon schemas."""
        with tempfile.TemporaryDirectory() as tmp:
            mock_bin = Path(tmp) / "bin"
            mock_bin.mkdir()
            (mock_bin / "gsettings").write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = list-schemas ]; then\n"
                "  echo org.cinnamon.desktop.keybindings\n"
                "  exit 0\n"
                "fi\n"
                "exit 1\n",
                encoding="utf-8",
            )
            (mock_bin / "gsettings").chmod(0o755)
            env = os.environ.copy()
            env["PATH"] = f"{mock_bin}:{env.get('PATH', '')}"
            proc = _source_and_run("_asus_probe_de_schema_family", env=env)
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            self.assertEqual(proc.stdout.strip(), "cinnamon")

    def test_mint_bare_gnome_true_gnome_stays_gnome(self):
        """True GNOME stays gnome when secondary Mint signals are absent."""
        proc = _source_and_run(
            "_asus_lookup_env_key() { return 1; }; "
            "_asus_probe_de_binary_family() { return 1; }; "
            "_asus_probe_de_schema_family() { return 1; }; "
            "asus_desktop_family_from_string ubuntu:GNOME; "
            "if _asus_mint_bare_gnome_family 1; then echo remapped; else echo stay; fi"
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        lines = [line for line in proc.stdout.strip().splitlines() if line]
        self.assertEqual(lines[0], "gnome")
        self.assertEqual(lines[-1], "stay")

    def test_desktop_family_override_env(self):
        """ASUS_DESKTOP_FAMILY overrides detection."""
        env = os.environ.copy()
        env["ASUS_DESKTOP_FAMILY"] = "kde"
        proc = _source_and_run("asus_desktop_family", env=env)
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout.strip(), "kde")

    def test_proc_environ_value_reads_key(self):
        """Leader environ file yields DISPLAY/WAYLAND values."""
        with tempfile.TemporaryDirectory() as tmp:
            pid_dir = Path(tmp) / "1"
            pid_dir.mkdir()
            environ_path = pid_dir / "environ"
            environ_path.write_bytes(b"DISPLAY=:1\0WAYLAND_DISPLAY=wayland-0\0")
            env = os.environ.copy()
            env["ASUS_PROC_ENVIRON_ROOT"] = tmp
            proc = _source_and_run(
                (
                    'printf "DISPLAY=%s\\n" "$(_asus_proc_environ_value 1 DISPLAY)"; '
                    'printf "WAYLAND=%s\\n" "$(_asus_proc_environ_value 1 WAYLAND_DISPLAY)"'
                ),
                env=env,
            )
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            self.assertIn("DISPLAY=:1", proc.stdout)
            self.assertIn("WAYLAND=wayland-0", proc.stdout)

    def test_systemctl_user_env_sets_xdg_runtime_dir(self):
        """systemctl --user lookup must pass XDG_RUNTIME_DIR for session env."""
        with tempfile.TemporaryDirectory() as tmp:
            mock_bin = Path(tmp) / "bin"
            mock_bin.mkdir()
            (Path(tmp) / "run" / "1000").mkdir(parents=True)
            (mock_bin / "systemctl").write_text(
                '#!/bin/sh\ncase "$XDG_RUNTIME_DIR" in\n  */1000) echo XDG_CURRENT_DESKTOP=ubuntu:GNOME ;;\n  *) exit 1 ;;\nesac\n',
                encoding="utf-8",
            )
            (mock_bin / "systemctl").chmod(0o755)
            _write_exact_id_stub(mock_bin)
            env = os.environ.copy()
            env["PATH"] = f"{mock_bin}:{env.get('PATH', '')}"
            env["RUN_USER_ROOT"] = str(Path(tmp) / "run")
            env.pop("BUS_ROOT", None)
            env.pop("DBUS_BUS_ROOT", None)
            proc = _source_and_run(
                "_asus_systemctl_user_env_value testuser XDG_CURRENT_DESKTOP; echo",
                env=env,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "ubuntu:GNOME")

    def test_systemctl_env_timeout_negative_caches_failures(self):
        """Timed-out systemctl --user must skip subsequent lookups in-process."""
        with tempfile.TemporaryDirectory() as tmp:
            mock_bin = Path(tmp) / "bin"
            mock_bin.mkdir()
            (Path(tmp) / "run" / "1000").mkdir(parents=True)
            counter = Path(tmp) / "calls"
            counter.write_text("0", encoding="utf-8")
            counter_q = shlex.quote(str(counter))
            (mock_bin / "systemctl").write_text(
                f"#!/bin/sh\nn=$(cat {counter_q}); echo $((n+1)) >{counter_q}\nsleep 2\nexit 0\n",
                encoding="utf-8",
            )
            (mock_bin / "systemctl").chmod(0o755)
            _write_exact_id_stub(mock_bin)
            env = os.environ.copy()
            env["PATH"] = f"{mock_bin}:{env.get('PATH', '')}"
            env["RUN_USER_ROOT"] = str(Path(tmp) / "run")
            env.pop("BUS_ROOT", None)
            env.pop("DBUS_BUS_ROOT", None)
            env["ASUS_SYSTEMCTL_ENV_TIMEOUT_SECS"] = "1"
            proc = _source_and_run(
                "_asus_systemctl_user_env_value testuser DISPLAY || true; "
                "_asus_systemctl_user_env_value testuser DISPLAY || true; "
                f"cat {counter_q}; echo",
                env=env,
                timeout=15,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "1")

    def test_systemctl_missing_key_double_lookup_in_subshells(self):
        """Missing-key lookups in subshells each fetch systemctl env (no shared blob)."""
        with tempfile.TemporaryDirectory() as tmp:
            mock_bin = Path(tmp) / "bin"
            mock_bin.mkdir()
            (Path(tmp) / "run" / "1000").mkdir(parents=True)
            counter = Path(tmp) / "calls"
            counter.write_text("0", encoding="utf-8")
            counter_q = shlex.quote(str(counter))
            (mock_bin / "systemctl").write_text(
                f"#!/bin/sh\nn=$(cat {counter_q}); echo $((n+1)) >{counter_q}\necho 'XDG_SESSION_TYPE=x11'\nexit 0\n",
                encoding="utf-8",
            )
            (mock_bin / "systemctl").chmod(0o755)
            _write_exact_id_stub(mock_bin)
            env = os.environ.copy()
            env["PATH"] = f"{mock_bin}:{env.get('PATH', '')}"
            env["RUN_USER_ROOT"] = str(Path(tmp) / "run")
            env.pop("BUS_ROOT", None)
            env.pop("DBUS_BUS_ROOT", None)
            proc = _source_and_run(
                "( _asus_systemctl_user_env_value testuser NO_SUCH_KEY || true ); "
                "( _asus_systemctl_user_env_value testuser NO_SUCH_KEY || true ); "
                f"cat {counter_q}; echo",
                env=env,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "2")

    def test_loginctl_transport_failure_finds_no_session(self):
        """Failed loginctl list-sessions must fail closed (no active session id)."""
        with tempfile.TemporaryDirectory() as tmp:
            mock_bin = Path(tmp) / "bin"
            mock_bin.mkdir()
            (mock_bin / "loginctl").write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
            (mock_bin / "loginctl").chmod(0o755)
            env = os.environ.copy()
            env["PATH"] = f"{mock_bin}:{env.get('PATH', '')}"
            proc = _source_and_run(
                "set +e; find_active_session_id; status=$?; set -e; printf '%s\\n' \"$status\"",
                env=env,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), "1")

    def test_user_runtime_dir_prefers_run_user_root(self):
        """Session runtime dir uses RUN_USER_ROOT over the default /run/user D-Bus root."""
        with tempfile.TemporaryDirectory() as tmp:
            mock_bin = Path(tmp) / "bin"
            mock_bin.mkdir()
            run_root = Path(tmp) / "custom-run"
            run_root.mkdir()
            _write_exact_id_stub(mock_bin, uid="4242")
            env = os.environ.copy()
            env["PATH"] = f"{mock_bin}:{env.get('PATH', '')}"
            env["RUN_USER_ROOT"] = str(run_root)
            env.pop("BUS_ROOT", None)
            env.pop("DBUS_BUS_ROOT", None)
            proc = _source_and_run("_asus_user_runtime_dir testuser; echo", env=env)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), str(run_root / "4242"))
            self.assertNotIn("/run/user", proc.stdout)


if __name__ == "__main__":
    unittest.main()
