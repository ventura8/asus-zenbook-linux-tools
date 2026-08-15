"""Shared helpers for display-mode shell unit tests."""

import os
import pwd
import shlex
from pathlib import Path

from tests.unit.shell.shell_test_utils import bin_script, write_fake_executable

SCRIPT = bin_script("asus-display-mode.sh")


def _current_username() -> str:
    """Return the current process username (USER may be unset in Docker)."""
    for key in ("USER", "LOGNAME"):
        value = os.environ.get(key)
        if value:
            return value
    return pwd.getpwuid(os.getuid()).pw_name


def _is_ydotool_p_tap_line(line: str) -> bool:
    """Return True for a P tap line that is not part of a Super-down open."""
    if not line.endswith("25:1 25:0"):
        return False
    return "125:1" not in line


def _ydotool_open_and_tap_lines(lines):
    """Split ydotool log lines into Super-down opens and later P taps."""
    opens = [line for line in lines if "125:1" in line]
    taps = [line for line in lines if _is_ydotool_p_tap_line(line)]
    return opens, taps


def _guaranteed_unused_pid() -> int:
    """Return a PID unlikely to refer to a live process for watchdog stubs."""
    try:
        return int(Path("/proc/sys/kernel/pid_max").read_text(encoding="utf-8").strip()) + 1
    except (OSError, ValueError):
        pass
    try:
        return max(int(name) for name in os.listdir("/proc") if name.isdigit()) + 1000
    except (OSError, ValueError):
        return 999999999


def _display_mode_env(run_root: str, mock_bin: str | None = None, **overrides: str) -> dict:
    """Build a local display-mode test environment."""
    env = {key: value for key, value in os.environ.items() if not key.startswith("ASUS_DISPLAY_MODE_")}
    if mock_bin is not None:
        env["PATH"] = f"{mock_bin}:{env.get('PATH', '')}"
    env["ASUS_DISPLAY_MODE_STATE_PREFIX"] = os.path.join(run_root, "disp")
    env["ASUS_DISPLAY_MODE_FORCE_LOCAL"] = "1"
    env["NOTIF_ID_ROOT"] = os.path.join(run_root, "notif")
    env.update(overrides)
    return env


def _sticky_osd_env(run_root: str, mock_bin: str | None = None, **overrides: str) -> dict:
    """Env that keeps sticky OSD markers alive across presses under suite load."""
    defaults = {
        # IDLE_SECS=1 races the idle watchdog under suite load / Docker matrix.
        "ASUS_DISPLAY_MODE_IDLE_SECS": "30",
        "ASUS_DISPLAY_MODE_DUP_MS": "1",
    }
    defaults.update(overrides)
    return _display_mode_env(run_root, mock_bin, **defaults)


def _write_ydotool_logger(mock_bin: str, log_path: str, body_extra: str = "") -> None:
    """Install a ydotool stub that appends argv to log_path then exits 0."""
    write_fake_executable(
        os.path.join(mock_bin, "ydotool"),
        f'#!/bin/bash\necho "$@" >> {shlex.quote(log_path)}\n{body_extra}exit 0\n',
    )


def _flock_serialize_fixture(run_root: str) -> tuple[dict, str, str, str]:
    """Build env/log/prefix/driver for concurrent display-mode flock coverage."""
    mock_bin = os.path.join(run_root, "mock-bin")
    os.makedirs(mock_bin, exist_ok=True)
    log_path = os.path.join(run_root, "ydotool.log")
    fifo_path = os.path.join(run_root, "sync.fifo")
    os.mkfifo(fifo_path)
    fifo_q = shlex.quote(fifo_path)
    _write_ydotool_logger(
        mock_bin,
        log_path,
        body_extra=(
            'if echo "$@" | grep -q "125:1"; then '
            f"read -r -t 2 _ < {fifo_q} || true; sleep 0.3; fi\n"
        ),
    )
    env = _sticky_osd_env(run_root, mock_bin)
    prefix = os.path.join(run_root, "disp")
    script_q = shlex.quote(SCRIPT)
    log_q = shlex.quote(log_path)
    driver = (
        f"exec 3<>{fifo_q}; "
        f"bash {script_q} & pid1=$!; "
        "end=$((SECONDS+20)); "
        "seen_open=0; "
        "while [ $SECONDS -lt $end ]; do "
        f"[ -f {log_q} ] && grep -q '125:1' {log_q} && seen_open=1 && break; "
        "sleep 0.05; done; "
        'if [ "$seen_open" -ne 1 ]; then '
        'echo "display-mode flock test: never saw 125:1 before pid2" >&2; '
        'kill "$pid1" 2>/dev/null || true; wait "$pid1" 2>/dev/null || true; '
        "exit 1; fi; "
        f"bash {script_q} & pid2=$!; "
        "printf '\\n' >&3; "
        'wait "$pid1"; status1=$?; wait "$pid2"; status2=$?; '
        "exec 3>&-; "
        "exit $(( status1 != 0 ? status1 : status2 ))"
    )
    return env, log_path, prefix, driver
