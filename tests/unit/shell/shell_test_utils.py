"""Shared helper utilities for shell script unit tests."""

import os
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

from tests.shared.process_tee import (
    POST_KILL_JOIN_SECS as _SHELL_LOG_JOIN_SECS,
)
from tests.shared.process_tee import (
    TeeSinks,
    TeeStreamTarget,
)
from tests.shared.process_tee import (
    kill_process_group as _kill_process_group,
)
from tests.shared.process_tee import (
    tee_stream as _tee_shell_stream,
)

PROJECT_ROOT = Path(__file__).resolve().parents[3]

_SHELL_UNIT_LOG_STATE: dict[str, object] = {"dir": None, "pruned": False}
# Only prune abandoned sibling log dirs older than this (avoid wiping concurrent runs).
_SHELL_UNIT_LOG_MAX_AGE_SECS = 3600


def _shell_unit_log_dir_is_stale(entry: Path, now: float) -> bool:
    """Return True when *entry* mtime is at least the prune age threshold."""
    try:
        mtime = entry.stat().st_mtime
    except OSError:
        return False
    return (now - mtime) >= _SHELL_UNIT_LOG_MAX_AGE_SECS


def _proc_starttime(pid: int) -> int | None:
    """Return /proc/<pid>/stat starttime, or None when the process is gone."""
    try:
        with open(f"/proc/{pid}/stat", encoding="utf-8") as handle:
            data = handle.read()
    except OSError:
        return None
    close = data.rfind(")")
    if close < 0:
        return None
    fields = data[close + 2 :].split()
    try:
        return int(fields[19])
    except (IndexError, ValueError):
        return None


def _pid_cmdline_text(pid: int) -> str | None:
    """Return decoded /proc/<pid>/cmdline text, or None on failure."""
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as cmdline_handle:
            return cmdline_handle.read().replace(b"\0", b" ").decode("utf-8", "replace")
    except OSError:
        return None


def _wait_pid_gone(pid: int) -> None:
    """Poll briefly until *pid* disappears from /proc."""
    for _ in range(10):
        if _proc_starttime(pid) is None:
            return
        time.sleep(0.01)


def _kill_pid_if_marker_matches(pid: int, starttime: str, process_marker: str) -> None:
    """SIGKILL *pid* when cmdline still matches *process_marker* at *starttime*."""
    cmdline = _pid_cmdline_text(pid)
    if cmdline is None:
        return
    if process_marker not in cmdline:
        return
    if _proc_starttime(pid) != starttime:
        return
    os.kill(pid, signal.SIGKILL)
    _wait_pid_gone(pid)


def terminate_pid_file(pid_file: str, process_marker: str = "sleep") -> None:
    """Best-effort, PID-reuse-safe SIGKILL for a recorded process."""
    try:
        with open(pid_file, encoding="utf-8") as handle:
            pid = int(handle.read().strip())
        starttime = _proc_starttime(pid)
        if starttime is None:
            return
        _kill_pid_if_marker_matches(pid, starttime, process_marker)
    except (OSError, ValueError):
        pass


def _resolved_shell_unit_log_keeps(keep: Path) -> set[Path]:
    """Return resolved paths that must not be pruned (session + optional override)."""
    keeps: set[Path] = set()
    try:
        keeps.add(keep.resolve())
    except OSError:
        keeps.add(keep)
    override = os.environ.get("SHELL_UNIT_LOG_DIR")
    if not override:
        return keeps
    override_path = Path(override)
    try:
        keeps.add(override_path.resolve())
    except OSError:
        keeps.add(override_path)
    return keeps


def _should_prune_shell_unit_log_dir(entry: Path, keep_set: set[Path], now: float) -> bool:
    """Return True when *entry* is a stale abandoned shell-unit log directory."""
    if not entry.is_dir():
        return False
    try:
        resolved = entry.resolve()
    except OSError:
        return False
    if resolved in keep_set:
        return False
    return _shell_unit_log_dir_is_stale(entry, now)


def _prune_stale_shell_unit_log_dirs(keep: Path) -> None:
    """Remove old abandoned shell-unit-logs-* dirs under the system temp dir.

    Keeps the current session directory and any SHELL_UNIT_LOG_DIR override.
    Only removes siblings older than ``_SHELL_UNIT_LOG_MAX_AGE_SECS``.
    """
    temp_root = Path(tempfile.gettempdir())
    keep_set = _resolved_shell_unit_log_keeps(keep)
    now = time.time()
    for entry in temp_root.glob("shell-unit-logs-*"):
        if _should_prune_shell_unit_log_dir(entry, keep_set, now):
            shutil.rmtree(entry, ignore_errors=True)


def _shell_log_root() -> Path:
    """Return the directory for persistent shell unit-test command logs.

    Default session logs use a process-local mkdtemp under the system temp dir and
    are retained intentionally (no atexit wipe) so failures remain inspectable.
    Override with SHELL_UNIT_LOG_DIR to choose a durable location.
    Abandoned sibling shell-unit-logs-* directories under the system temp dir older than
    ``_SHELL_UNIT_LOG_MAX_AGE_SECS`` are pruned once per process (current session and
    SHELL_UNIT_LOG_DIR override are kept).
    """
    override = os.environ.get("SHELL_UNIT_LOG_DIR")
    if override:
        path = Path(override)
        if not _SHELL_UNIT_LOG_STATE["pruned"]:
            _prune_stale_shell_unit_log_dirs(path)
            _SHELL_UNIT_LOG_STATE["pruned"] = True
        return path
    if _SHELL_UNIT_LOG_STATE["dir"] is None:
        _SHELL_UNIT_LOG_STATE["dir"] = Path(tempfile.mkdtemp(prefix="shell-unit-logs-"))
        _prune_stale_shell_unit_log_dirs(_SHELL_UNIT_LOG_STATE["dir"])
        _SHELL_UNIT_LOG_STATE["pruned"] = True
    return _SHELL_UNIT_LOG_STATE["dir"]


def screenpad_env(tmpdir: str, **extra: str) -> dict[str, str]:
    """Build env with writable NOTIF_ID_ROOT/STATE_DIR under tmpdir."""
    env = dict(os.environ)
    env["NOTIF_ID_ROOT"] = os.path.join(tmpdir, "notif")
    env["STATE_DIR"] = os.path.join(tmpdir, "state")
    env["ASUS_SCREENPAD_ICON_DIR"] = str(PROJECT_ROOT / "assets" / "icons")
    env["ASUS_SCREENPAD_APP_NAME_COLOR"] = "#b2b2b4"
    env.update(extra)
    return env


def _is_bash_dash_c(argv: list[str]) -> bool:
    """Return True when *argv* is ``bash -c <script>``."""
    return len(argv) >= 3 and argv[0] in {"bash", "/bin/bash"} and argv[1] == "-c"


def _bash_script_stem(argv: list[str]) -> str | None:
    """Return a stem for ``bash script.sh …``, or None when not that form."""
    if len(argv) < 2:
        return None
    if argv[0] not in {"bash", "/bin/bash"}:
        return None
    return Path(str(argv[1])).stem


def _shell_argv_log_candidate(argv: list[str]) -> str:
    """Derive a log candidate stem from a shell subprocess argv."""
    if _is_bash_dash_c(argv):
        snippet = str(argv[2]).strip()
        return Path(snippet.split()[0]).stem if snippet else "bash-c"
    bash_script = _bash_script_stem(argv)
    if bash_script is not None:
        return bash_script
    if argv:
        return Path(str(argv[0])).name
    return "shell"


def _shell_log_basename(argv: list[str], log_name: str | None = None) -> str:
    """Derive a stable log basename for a shell subprocess argv."""
    unique = f"{os.getpid()}-{time.monotonic_ns()}"
    if log_name:
        stem = log_name.removesuffix(".log")
        base = "shell-unit-" + re.sub(r"[^a-zA-Z0-9._-]+", "-", stem)
        return f"{base}-{unique}"
    candidate = _shell_argv_log_candidate(argv)
    base = "shell-unit-" + re.sub(r"[^a-zA-Z0-9._-]+", "-", candidate)
    return f"{base}-{unique}"


def _shell_live_stream(stream):
    """Return *stream* only when SHELL_UNIT_LIVE_TEE=1; else None (capture-only)."""
    if os.environ.get("SHELL_UNIT_LIVE_TEE") == "1":
        return stream
    return None


def _format_shell_timeout(kind: str, detail: str, timeout: int, exc: subprocess.TimeoutExpired, log_path: Path) -> str:
    """Build a timeout AssertionError that includes captured output and log path."""
    return (
        f"{kind} exceeded {timeout}s timeout: {detail}\n"
        f"log={log_path}\n"
        f"stdout={exc.output!r}\n"
        f"stderr={exc.stderr!r}"
    )


class _ShellTeeRun:
    """Mutable tee state for one logged shell subprocess."""

    def __init__(self, log_path: Path):
        """Allocate chunk buffers, lock, and sink events for *log_path*."""
        self.log_path = log_path
        self.stdout_chunks: list[str] = []
        self.stderr_chunks: list[str] = []
        self.write_lock = threading.Lock()
        self.sinks = TeeSinks(
            stop_out=threading.Event(),
            stop_err=threading.Event(),
            closed_out=threading.Event(),
            closed_err=threading.Event(),
            log_closed=threading.Event(),
        )
        self.out_thread: threading.Thread | None = None
        self.err_thread: threading.Thread | None = None

    def start(self, proc, log_file) -> None:
        """Spawn stdout/stderr tee workers for *proc*."""
        self.out_thread = threading.Thread(
            target=_tee_shell_stream,
            args=(
                proc.stdout,
                TeeStreamTarget(
                    self.stdout_chunks,
                    _shell_live_stream(sys.stdout),
                    log_file,
                    self.write_lock,
                    self.sinks.stop_out,
                    self.sinks.closed_out,
                    self.sinks.log_closed,
                ),
            ),
            daemon=True,
        )
        self.err_thread = threading.Thread(
            target=_tee_shell_stream,
            args=(
                proc.stderr,
                TeeStreamTarget(
                    self.stderr_chunks,
                    _shell_live_stream(sys.stderr),
                    log_file,
                    self.write_lock,
                    self.sinks.stop_err,
                    self.sinks.closed_err,
                    self.sinks.log_closed,
                ),
            ),
            daemon=True,
        )
        self.out_thread.start()
        self.err_thread.start()

    def finish(self) -> None:
        """Stop tee workers after a normal process exit."""
        self.sinks.stop_out.set()
        self.sinks.stop_err.set()
        assert self.out_thread is not None and self.err_thread is not None
        self.out_thread.join(timeout=_SHELL_LOG_JOIN_SECS)
        self.err_thread.join(timeout=_SHELL_LOG_JOIN_SECS)
        with self.write_lock:
            self.sinks.log_closed.set()
        self.sinks.closed_out.wait(timeout=_SHELL_LOG_JOIN_SECS)
        self.sinks.closed_err.wait(timeout=_SHELL_LOG_JOIN_SECS)

    def abort_timeout(self, proc, timeout, exc) -> None:
        """Kill *proc* and raise TimeoutExpired with captured stdout/stderr."""
        self.sinks.stop_out.set()
        self.sinks.stop_err.set()
        with self.write_lock:
            self.sinks.log_closed.set()
        _kill_process_group(proc)
        try:
            proc.wait(timeout=_SHELL_LOG_JOIN_SECS)
        except subprocess.TimeoutExpired:
            pass
        self.sinks.closed_out.wait(timeout=_SHELL_LOG_JOIN_SECS)
        self.sinks.closed_err.wait(timeout=_SHELL_LOG_JOIN_SECS)
        assert self.out_thread is not None and self.err_thread is not None
        self.out_thread.join(timeout=_SHELL_LOG_JOIN_SECS)
        self.err_thread.join(timeout=_SHELL_LOG_JOIN_SECS)
        timed_out = subprocess.TimeoutExpired(
            exc.cmd,
            timeout,
            output="".join(self.stdout_chunks),
            stderr="".join(self.stderr_chunks),
        )
        timed_out.log_path = str(self.log_path)
        raise timed_out from None


def _run_logged_shell(argv, env, timeout, log_name=None):
    """Run argv capturing stdout/stderr into a log file and CompletedProcess.

    By default product output is not mirrored to the live suite console (expected
    Error:/Warning: lines from negative paths would look like suite failures).
    Set SHELL_UNIT_LIVE_TEE=1 to mirror. Captured text remains on the returned
    process and under the shell unit log dir for debugging failed assertions.
    """
    log_path = _shell_log_root() / f"{_shell_log_basename(list(argv), log_name)}.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    tee = _ShellTeeRun(log_path)

    with open(log_path, "a", encoding="utf-8") as log_file:
        log_file.write(f"# {shlex.join(str(part) for part in argv)}\n")
        log_file.flush()
        with subprocess.Popen(
            list(argv),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
            start_new_session=True,
        ) as proc:
            tee.start(proc, log_file)
            try:
                returncode = proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired as exc:
                tee.abort_timeout(proc, timeout, exc)
            tee.finish()

    completed = subprocess.CompletedProcess(
        args=list(argv),
        returncode=returncode,
        stdout="".join(tee.stdout_chunks),
        stderr="".join(tee.stderr_chunks),
    )
    completed.log_path = str(log_path)
    return completed


def bin_script(name):
    """Return absolute path to a script under the repository bin directory."""
    return str(PROJECT_ROOT / "bin" / name)


def _timeout_log_path(exc: subprocess.TimeoutExpired) -> Path:
    """Prefer the exact per-command log path attached on timeout."""
    attached = getattr(exc, "log_path", None)
    if attached:
        return Path(str(attached))
    return _shell_log_root()


def run_shell_argv(argv, env=None, timeout=15):
    """Execute an argv list with captured stdout/stderr (console mirror opt-in)."""
    try:
        return _run_logged_shell(list(argv), env=env, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        raise AssertionError(
            _format_shell_timeout("Shell argv", str(argv), timeout, exc, _timeout_log_path(exc))
        ) from exc


def run_shell_script(script_path, env=None, timeout=15, args=None):
    """Execute a bash script with captured stdout/stderr (console mirror opt-in)."""
    command = ["bash", script_path]
    if args:
        command.extend(args)
    try:
        return _run_logged_shell(command, env=env, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        raise AssertionError(
            _format_shell_timeout("Shell script", script_path, timeout, exc, _timeout_log_path(exc))
        ) from exc


def run_bash_c(script: str, env=None, timeout=15, log_name=None):
    """Execute a bash -c snippet with captured stdout/stderr (console mirror opt-in)."""
    try:
        return _run_logged_shell(["bash", "-c", script], env=env, timeout=timeout, log_name=log_name)
    except subprocess.TimeoutExpired as exc:
        raise AssertionError(
            _format_shell_timeout("bash -c", "snippet", timeout, exc, _timeout_log_path(exc))
        ) from exc


def setup_mock_install_tree(tmp_dir_path):
    """Return destination paths used by installer/uninstaller tests without creating them."""
    destination = Path(tmp_dir_path) / "dest"
    binaries = destination / "usr/local/bin"
    units = destination / "etc/systemd/system"
    hooks = destination / "lib/systemd/system-sleep"
    return destination, binaries, units, hooks


def create_writable_node(directory_path, filename, initial_content):
    """Create a mock sysfs node file with initial content and owner-only mode (0o600).

    Tests that run helpers as another user should chown the node on the root-only branch
    instead of widening permissions here.
    """
    full_path = os.path.join(directory_path, filename)
    with open(full_path, "w", encoding="utf-8") as file_handle:
        file_handle.write(initial_content)
    os.chmod(full_path, 0o600)
    return full_path


def read_node_content(node_path):
    """Read and strip string content from a mock node file."""
    with open(node_path, encoding="utf-8") as file_handle:
        return file_handle.read().strip()


def write_fake_executable(file_path, script_body, permissions=0o755):
    """Write script_body to file_path and grant executable permissions."""
    with open(file_path, "w", encoding="utf-8") as writer:
        writer.write(script_body)
    os.chmod(file_path, permissions)


def write_stubs(stubs: dict[str, str], mock_bin: Path) -> Path:
    """Write executable stubs into mock_bin and return that directory."""
    mock_bin.mkdir(parents=True, exist_ok=True)
    for name, script_body in stubs.items():
        script_path = mock_bin / name
        script_path.write_text(script_body, encoding="utf-8")
        os.chmod(script_path, 0o755)
    return mock_bin


def _fake_id_username(username):
    """Resolve a stable non-numeric username for id -un stubs."""
    name = username or os.environ.get("USER") or "testuser"
    if name.isdigit():
        return "testuser"
    return name


def fake_id(mock_bin_path, uid="59999", username=None):
    """Install an id stub: -u/-g numeric, -un/-gn username/group name (not numeric)."""
    quoted_user = shlex.quote(_fake_id_username(username))
    quoted_uid = shlex.quote(str(uid))
    write_fake_executable(
        os.path.join(mock_bin_path, "id"),
        (
            "#!/bin/sh\n"
            'case "$1" in\n'
            f"  -u) echo {quoted_uid}; exit 0 ;;\n"
            f"  -un) echo {quoted_user}; exit 0 ;;\n"
            f"  -g) echo {quoted_uid}; exit 0 ;;\n"
            f"  -gn) echo {quoted_user}; exit 0 ;;\n"
            f"  *) echo {quoted_uid}; exit 0 ;;\n"
            "esac\n"
            "exit 127\n"
        ),
    )


def fake_loginctl_no_sessions(mock_bin_path):
    """Install a loginctl stub that returns no active sessions."""
    write_fake_executable(
        os.path.join(mock_bin_path, "loginctl"),
        '#!/bin/sh\nif [ "$1" = "list-sessions" ]; then exit 0; fi\necho stub\n',
    )


def assert_shell_source_smoke(test_case, script_path, expected_function_name):
    """Assert that sourcing a shell script exposes expected functions without running main."""
    command = f"source {shlex.quote(str(script_path))}; type {shlex.quote(expected_function_name)} >/dev/null; echo sourced_ok"
    proc = run_bash_c(command, env=None, timeout=30)
    test_case.assertEqual(proc.returncode, 0)
    test_case.assertEqual(proc.stderr, "")
    test_case.assertEqual(proc.stdout.strip(), "sourced_ok")


def fake_loginctl_active(mock_bin_path, session_details=None):
    """Install a loginctl stub that returns an active graphical session."""
    default_user = _fake_id_username(os.environ.get("USER"))
    info = {
        "sid": "42",
        "stype": "x11",
        "sstate": "active",
        "sseat": "seat0",
        "suser": default_user,
    }
    if session_details:
        info.update(session_details)
    sid = shlex.quote(info["sid"])
    suser = shlex.quote(info["suser"])
    sseat = shlex.quote(info["sseat"])
    stype = shlex.quote(info["stype"])
    sstate = shlex.quote(info["sstate"])
    stub_content = (
        "#!/bin/sh\n"
        'if [ "$1" = "list-sessions" ]; then\n'
        f"    echo {sid} {suser} {sseat}\n"
        "    exit 0\n"
        "fi\n"
        'if [ "$1" = "show-session" ]; then\n'
        '    case "$*" in\n'
        f"        *Type*) echo {stype} ;;\n"
        f"        *State*) echo {sstate} ;;\n"
        f"        *Seat*) echo {sseat} ;;\n"
        f"        *Name*) echo {suser} ;;\n"
        "    esac\n"
        "    exit 0\n"
        "fi\n"
    )
    write_fake_executable(os.path.join(mock_bin_path, "loginctl"), stub_content)


def fake_sudo_passthrough(mock_bin_path):
    """Install a sudo and runuser stub that executes command without privilege drop."""
    script_body = (
        "#!/bin/sh\n"
        "while [ $# -gt 0 ]; do\n"
        '  case "$1" in\n'
        "    -E) shift ;;\n"
        "    -u)\n"
        '      if [ "$#" -ge 2 ]; then shift 2; else shift; break; fi ;;\n'
        "    --) shift; break ;;\n"
        "    -*) shift ;;\n"
        "    *=*) shift ;;\n"
        "    *) break ;;\n"
        "  esac\n"
        "done\n"
        'exec "$@"\n'
    )
    write_fake_executable(os.path.join(mock_bin_path, "sudo"), script_body)
    write_fake_executable(os.path.join(mock_bin_path, "runuser"), script_body)


AF_UNIX_PATH_MAX = 108


def bind_unix_socket(path: Path, listen: int | None = None) -> socket.socket | None:
    """Bind a Unix-domain socket at path.

    When listen is None, close the socket after bind and return None (path remains).
    When listen is set, listen(backlog) and return the open socket for the caller to close.
    """
    path_bytes = os.fsencode(path)
    if len(path_bytes) >= AF_UNIX_PATH_MAX:
        raise ValueError(f"Unix socket path exceeds AF_UNIX limit ({AF_UNIX_PATH_MAX}): {path}")
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.bind(str(path))
    if listen is not None:
        try:
            sock.listen(listen)
        except OSError:
            sock.close()
            raise
        return sock
    sock.close()
    return None
