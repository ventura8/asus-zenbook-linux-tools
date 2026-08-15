"""E2E test helper utility for running subprocess checks."""

from __future__ import annotations

import hashlib
import os
import re
import shlex
import subprocess
import sys
import threading
import unittest
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path

from tests.shared.process_tee import (
    POST_KILL_JOIN_SECS as _POST_KILL_JOIN_SECS,
)
from tests.shared.process_tee import (
    TeeSinks,
    TeeStreamTarget,
)
from tests.shared.process_tee import (
    join_tee_threads as _join_tee_threads,
)
from tests.shared.process_tee import (
    kill_process_group as _kill_process_group,
)
from tests.shared.process_tee import (
    tee_stream as _tee_stream,
)

DEFAULT_E2E_TIMEOUT_SECONDS = 20
MAX_E2E_TIMEOUT_SECONDS = 30
MAX_REAL_E2E_TIMEOUT_SECONDS = 300

PROJECT_ROOT = str(Path(__file__).resolve().parents[2])
STATE_DIR = Path("/var/lib/asus-zenbook-linux-tools")
E2E_OWNED_SENTINEL = STATE_DIR / "e2e-test-owned"
INSTALL_MARKERS = (
    Path("/usr/local/bin/asus-hotkey-daemon.py"),
    Path("/usr/local/bin/asus-touchpad-share.py"),
    Path("/etc/systemd/system/asus-hotkey-daemon.service"),
    Path("/etc/systemd/system/asus-touchpad-share.service"),
    Path("/etc/systemd/system/asus-sound-fix.service"),
    Path("/lib/systemd/system-sleep/asus-sound-fix"),
)


def _e2e_log_root(env: Mapping[str, str] | None = None) -> Path:
    """Return the directory used for persistent E2E command logs."""
    default = Path(PROJECT_ROOT) / "reports" / "distro-logs"
    override = None
    if env is not None:
        override = env.get("E2E_LOG_DIR")
    if not override:
        override = os.environ.get("E2E_LOG_DIR")
    if not override:
        return default
    candidate = Path(override)
    try:
        resolved = candidate.resolve()
    except OSError:
        return default
    # Allow TemporaryDirectory and other absolute log roots outside reports/.
    # Accept paths that do not exist yet; creation is handled by the runner.
    return resolved


def _timeout_from_environment() -> int:
    """Parse timeout budget from E2E_TEST_TIMEOUT and validate integer format."""
    raw_timeout = os.environ.get("E2E_TEST_TIMEOUT", str(DEFAULT_E2E_TIMEOUT_SECONDS))
    try:
        return int(raw_timeout)
    except ValueError as exc:
        raise AssertionError(f"Invalid timeout budget: {raw_timeout}s") from exc


def _is_real_system_e2e() -> bool:
    """Return True when real-system E2E tests are explicitly enabled."""
    return os.environ.get("E2E_REAL_ALLOW_SYSTEM_CHANGES") == "1"


def _max_timeout_seconds(*, allow_real: bool = False) -> int:
    """Return the timeout ceiling for the active E2E mode (mock vs real-system)."""
    if allow_real and _is_real_system_e2e():
        return MAX_REAL_E2E_TIMEOUT_SECONDS
    return MAX_E2E_TIMEOUT_SECONDS


def e2e_test_timeout_seconds(
    default: int = DEFAULT_E2E_TIMEOUT_SECONDS,
    *,
    allow_real: bool = False,
) -> int:
    """Return validated E2E_TEST_TIMEOUT, using *default* when the env var is unset."""
    if "E2E_TEST_TIMEOUT" not in os.environ:
        timeout = default
    else:
        timeout = _timeout_from_environment()
    _validate_timeout_budget(timeout, allow_real=allow_real)
    return timeout


def _validate_timeout_budget(timeout: int, *, allow_real: bool = False) -> None:
    """Enforce timeout budget bounds used by E2E tests."""
    if timeout <= 0:
        raise AssertionError(f"Invalid timeout budget: {timeout}s")
    max_allowed = _max_timeout_seconds(allow_real=allow_real)
    if timeout > max_allowed:
        raise AssertionError(f"Timeout budget {timeout}s exceeds max allowed {max_allowed}s for this E2E mode")
    if timeout < DEFAULT_E2E_TIMEOUT_SECONDS:
        raise AssertionError(f"Timeout budget {timeout}s is below minimum {DEFAULT_E2E_TIMEOUT_SECONDS}s")


def _render_command(cmd: Sequence[str]) -> str:
    """Return a shell-safe string representation of an argv sequence for error messages."""
    return shlex.join(str(part) for part in cmd)


def _sanitize_log_stem(stem: str) -> str:
    """Return a filesystem-safe log stem, or a default token when empty."""
    safe = re.sub(r"[^a-zA-Z0-9._-]+", "-", stem).strip("-._")
    return safe if safe else "e2e"


def _bash_c_log_candidate(script_token: str) -> str:
    """Derive a log candidate stem from a bash -c script token."""
    script_token = script_token.strip()
    if not script_token:
        return "bash-c"
    parts = script_token.split()
    if not parts:
        return "bash-c"
    return Path(parts[0]).stem or "bash-c"


def _is_interpreter_dash_c(cmd: Sequence[str], interpreters: set[str]) -> bool:
    """Return True when *cmd* is ``interpreter -c <script>`` for one of *interpreters*."""
    long_enough = len(cmd) >= 3
    return long_enough and cmd[0] in interpreters and cmd[1] == "-c"


def _bash_script_path_candidate(cmd: Sequence[str]) -> str | None:
    """Return a stem for ``bash script.sh …``, or None when not that form."""
    if len(cmd) < 2:
        return None
    if cmd[0] not in {"bash", "/bin/bash"}:
        return None
    return Path(str(cmd[1])).stem


def _command_log_candidate(cmd: Sequence[str]) -> str:
    """Derive a log candidate stem from an argv sequence."""
    if _is_interpreter_dash_c(cmd, {"python3", "python", "/usr/bin/python3"}):
        return "python-c"
    if _is_interpreter_dash_c(cmd, {"bash", "/bin/bash"}):
        return _bash_c_log_candidate(str(cmd[2]))
    bash_script = _bash_script_path_candidate(cmd)
    if bash_script is not None:
        return bash_script
    if not cmd:
        return "e2e"
    return Path(str(cmd[0])).name


def _stable_log_basename(cmd: Sequence[str], log_name: str | None) -> str:
    """Derive a stable log file basename for an E2E command."""
    if log_name:
        return _sanitize_log_stem(log_name.removesuffix(".log"))
    candidate = _command_log_candidate(cmd)
    safe = re.sub(r"[^a-zA-Z0-9._-]+", "-", candidate)
    digest = hashlib.sha1(
        shlex.join(str(part) for part in cmd).encode("utf-8"),
        usedforsecurity=False,
    ).hexdigest()[:10]
    return f"e2e-{safe}-{digest}"


@dataclass
class _LoggedTeeSession:
    """Tee workers and capture buffers for one logged subprocess run."""

    sinks: TeeSinks
    write_lock: threading.Lock
    stdout_chunks: list[str]
    stderr_chunks: list[str]
    out_thread: threading.Thread | None = None
    err_thread: threading.Thread | None = None


def _new_logged_tee_session() -> _LoggedTeeSession:
    """Allocate stop/close events and capture buffers for a logged run."""
    return _LoggedTeeSession(
        sinks=TeeSinks(
            stop_out=threading.Event(),
            stop_err=threading.Event(),
            closed_out=threading.Event(),
            closed_err=threading.Event(),
            log_closed=threading.Event(),
        ),
        write_lock=threading.Lock(),
        stdout_chunks=[],
        stderr_chunks=[],
    )


def _start_tee_threads(
    proc: subprocess.Popen[str],
    log_file,
    session: _LoggedTeeSession,
) -> None:
    """Start stdout/stderr tee workers for *proc* into *session*."""
    out_thread = threading.Thread(
        target=_tee_stream,
        args=(
            proc.stdout,
            TeeStreamTarget(
                session.stdout_chunks,
                sys.stdout,
                log_file,
                session.write_lock,
                session.sinks.stop_out,
                session.sinks.closed_out,
                session.sinks.log_closed,
            ),
        ),
        daemon=True,
    )
    err_thread = threading.Thread(
        target=_tee_stream,
        args=(
            proc.stderr,
            TeeStreamTarget(
                session.stderr_chunks,
                sys.stderr,
                log_file,
                session.write_lock,
                session.sinks.stop_err,
                session.sinks.closed_err,
                session.sinks.log_closed,
            ),
        ),
        daemon=True,
    )
    out_thread.start()
    err_thread.start()
    session.out_thread = out_thread
    session.err_thread = err_thread


def _stop_tee_sinks(session: _LoggedTeeSession) -> None:
    """Signal tee workers to stop live/log writes."""
    session.sinks.stop_out.set()
    session.sinks.stop_err.set()
    with session.write_lock:
        session.sinks.log_closed.set()


def _wait_tee_closed(session: _LoggedTeeSession) -> None:
    """Wait briefly for tee pipes to close after stop/kill."""
    session.sinks.closed_out.wait(timeout=_POST_KILL_JOIN_SECS)
    session.sinks.closed_err.wait(timeout=_POST_KILL_JOIN_SECS)


def _join_session_tee_threads(session: _LoggedTeeSession) -> None:
    """Join tee threads from *session* with captured stdout/stderr chunks."""
    assert session.out_thread is not None
    assert session.err_thread is not None
    _join_tee_threads(
        session.out_thread,
        session.err_thread,
        stdout_chunks=session.stdout_chunks,
        stderr_chunks=session.stderr_chunks,
    )


def _handle_logged_timeout(proc: subprocess.Popen[str], session: _LoggedTeeSession) -> None:
    """Kill the process group and join tee workers after a timeout."""
    _stop_tee_sinks(session)
    _kill_process_group(proc)
    try:
        proc.wait(timeout=_POST_KILL_JOIN_SECS)
    except subprocess.TimeoutExpired:
        pass
    _wait_tee_closed(session)
    _join_session_tee_threads(session)


def _finalize_logged_success(
    proc: subprocess.Popen[str],
    session: _LoggedTeeSession,
    _cmd: Sequence[str],
) -> None:
    """Join tee workers after a normal exit; kill if a tee thread is stuck."""
    assert session.out_thread is not None
    assert session.err_thread is not None
    session.out_thread.join(timeout=_POST_KILL_JOIN_SECS)
    session.err_thread.join(timeout=_POST_KILL_JOIN_SECS)
    stuck = session.out_thread.is_alive() or session.err_thread.is_alive()
    _stop_tee_sinks(session)
    _wait_tee_closed(session)
    if stuck:
        _kill_process_group(proc)
    _join_session_tee_threads(session)


def _run_logged_subprocess(
    cmd: Sequence[str],
    env: dict[str, str] | None,
    timeout: int,
    log_path: Path,
) -> subprocess.CompletedProcess[str]:
    """Run *cmd* with live output, tee to *log_path*, and capture text."""
    log_path.parent.mkdir(parents=True, exist_ok=True)
    session = _new_logged_tee_session()

    returncode = None
    with open(log_path, "a", encoding="utf-8") as log_file:
        log_file.write(f"# {_render_command(cmd)}\n")
        log_file.flush()
        with subprocess.Popen(
            list(cmd),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
            start_new_session=True,
        ) as proc:
            _start_tee_threads(proc, log_file, session)
            try:
                returncode = proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                _handle_logged_timeout(proc, session)
                raise
            _finalize_logged_success(proc, session, cmd)
            assert returncode is not None

    return subprocess.CompletedProcess(
        args=list(cmd),
        returncode=returncode,
        stdout="".join(session.stdout_chunks),
        stderr="".join(session.stderr_chunks),
    )


def run_e2e_command(
    cmd: Sequence[str],
    env: Mapping[str, str] | None = None,
    timeout: int | None = None,
    *,
    allow_real: bool = False,
    log_name: str | None = None,
) -> subprocess.CompletedProcess[str]:
    """Execute a subprocess with live output, log tee, and captured stdout/stderr."""
    if isinstance(cmd, str):
        raise TypeError("run_e2e_command requires a sequence of argv tokens, not a shell string")
    if timeout is None:
        timeout = e2e_test_timeout_seconds(allow_real=allow_real)

    _validate_timeout_budget(timeout, allow_real=allow_real)

    env_dict = None if env is None else dict(env)
    log_dir = _e2e_log_root(env_dict)
    log_path = log_dir / f"{_stable_log_basename(cmd, log_name)}.log"

    try:
        return _run_logged_subprocess(cmd, env_dict, timeout, log_path)
    except subprocess.TimeoutExpired as exc:
        cmd_str = _render_command(cmd)
        raise AssertionError(f"Command exceeded {timeout}s timeout budget and is treated as a failed test: {cmd_str}") from exc


def assert_root_check(test_case: unittest.TestCase, script_path: str) -> None:
    """Assert that script_path exits 1 with the standard root-error message.

    Exercises the real root-check path via ASUS_TEST_MODE + EFFECTIVE_UID_OVERRIDE so the
    owned installer/uninstaller logic runs without privilege demotion helpers.
    """
    env = os.environ.copy()
    env["ASUS_TEST_MODE"] = "1"
    env["EFFECTIVE_UID_OVERRIDE"] = "1000"
    env.pop("SKIP_ROOT_CHECK", None)
    proc = run_e2e_command(["bash", script_path], env=env)
    test_case.assertEqual(proc.returncode, 1, f"{script_path} must exit 1 when not root")
    test_case.assertIn("Please run as root (use sudo).", proc.stderr)


def require_real_system_mode(test_case: unittest.TestCase) -> None:
    """Skip real-system tests unless explicitly enabled by environment."""
    if not _is_real_system_e2e():
        test_case.skipTest("Set E2E_REAL_ALLOW_SYSTEM_CHANGES=1 to run real-system E2E tests")


def _host_dirty_paths() -> list[str]:
    """Return install marker / unowned state paths that indicate a dirty host."""
    present = [str(path) for path in INSTALL_MARKERS if path.exists()]
    if STATE_DIR.exists() and not E2E_OWNED_SENTINEL.exists():
        present.append(str(STATE_DIR))
    return present


def assert_host_clean(test_case: unittest.TestCase) -> None:
    """Fail when prior install markers or state remain on the host."""
    present = _host_dirty_paths()
    if present:
        test_case.fail("Host is not clean before real E2E; remove leftovers or run uninstall: " + ", ".join(present))


def restore_host_if_dirty(uninstall_script: str, timeout: int) -> None:
    """Best-effort uninstall when markers or unowned state remain after a failed real E2E test."""
    if not _host_dirty_paths():
        return
    env = os.environ.copy()
    env["SKIP_PKG_REMOVE"] = "1"
    result = run_e2e_command(
        ["bash", uninstall_script],
        env=env,
        timeout=timeout,
        allow_real=True,
        log_name="real-e2e-failed-install-cleanup",
    )
    if result.returncode:
        raise RuntimeError(f"E2E host cleanup uninstall failed with return code {result.returncode}")
