"""Shared subprocess tee and process-group kill helpers for tests."""

from __future__ import annotations

import os
import signal
import subprocess
import threading
from dataclasses import dataclass

POST_KILL_JOIN_SECS = 2.0


def kill_process_group(proc: subprocess.Popen[object]) -> None:
    """Send SIGKILL to the child process group when spawned with start_new_session.

    Still signals the process group when the leader has already exited so
    descendants that retain stdout/stderr pipes can be terminated.
    """
    try:
        pgid = os.getpgid(proc.pid)
    except OSError:
        # Leader may already be gone; pid is still the session/group id.
        pgid = proc.pid
    if pgid != proc.pid:
        _kill_alive_proc(proc)
        return
    try:
        os.killpg(pgid, signal.SIGKILL)
    except OSError:
        _kill_alive_proc(proc)


def _kill_alive_proc(proc: subprocess.Popen[object]) -> None:
    """SIGKILL *proc* when it has not already exited."""
    if proc.poll() is None:
        proc.kill()


@dataclass
class TeeSinks:
    """Thread synchronization handles for subprocess tee workers."""

    stop_out: threading.Event
    stop_err: threading.Event
    closed_out: threading.Event
    closed_err: threading.Event
    log_closed: threading.Event


@dataclass
class TeeStreamTarget:
    """Capture destinations for one tee worker thread."""

    chunks: list[str]
    live_stream: object
    log_file: object
    write_lock: threading.Lock
    stop_event: threading.Event
    closed_event: threading.Event
    log_closed: threading.Event


def _tee_should_skip_live(target: TeeStreamTarget) -> bool:
    """Return True when live console/log writes should be skipped."""
    return target.stop_event.is_set() or target.log_closed.is_set()


def _tee_write_live(target: TeeStreamTarget, line: str) -> None:
    """Write one line to the optional live stream and log file under the write lock."""
    with target.write_lock:
        if _tee_should_skip_live(target):
            return
        if target.live_stream is not None:
            target.live_stream.write(line)
            target.live_stream.flush()
        target.log_file.write(line)
        target.log_file.flush()


def tee_stream(pipe, target: TeeStreamTarget) -> None:
    """Read *pipe* line-by-line into chunks, optional live_stream, and log_file.

    Always append every line to *target.chunks* until EOF so callers that join after
    ``proc.wait()`` still see the full captured stdout/stderr. *stop_event* /
    *log_closed* only gate live console and log writes (used after timeout kill).
    When *live_stream* is None, console mirroring is skipped (unit-test default).
    """
    try:
        for line in iter(pipe.readline, ""):
            target.chunks.append(line)
            if _tee_should_skip_live(target):
                continue
            _tee_write_live(target, line)
    finally:
        try:
            pipe.close()
        finally:
            target.closed_event.set()


def _collect_alive_tee_names(*threads: threading.Thread) -> list[str]:
    """Join *threads* and return names still alive after the join budget."""
    stuck: list[str] = []
    for thread in threads:
        thread.join(timeout=POST_KILL_JOIN_SECS)
        if thread.is_alive():
            stuck.append(thread.name or repr(thread))
    return stuck


def _partial_chunk_suffix(label: str, chunks: list[str] | None) -> str:
    """Return a labeled partial-output suffix when *chunks* is non-empty."""
    if not chunks:
        return ""
    partial = "".join(chunks)
    if not partial:
        return ""
    return f"\npartial {label}:\n{partial}"


def join_tee_threads(
    *threads: threading.Thread,
    stdout_chunks: list[str] | None = None,
    stderr_chunks: list[str] | None = None,
) -> None:
    """Wait for tee threads with a bounded post-kill budget.

    Raises RuntimeError when a tee thread is still alive after the timeout so
    stuck readers cannot silently mutate capture buffers after the join returns.
    """
    stuck = _collect_alive_tee_names(*threads)
    if not stuck:
        return
    names = ", ".join(stuck)
    message = f"tee thread(s) still alive after {POST_KILL_JOIN_SECS}s join: {names}"
    message += _partial_chunk_suffix("stdout", stdout_chunks)
    message += _partial_chunk_suffix("stderr", stderr_chunks)
    raise RuntimeError(message)
